local utils = require 'core.utils'
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local explorer = {
    cur_pos = nil,
    prev_pos = nil,
    visited = {},
    visited_count = 0,
    radius = 12,
    retry = {},
    frontier = {},
    frontier_node = {},
    frontier_order = {},
    frontier_index = 0,
    frontier_count = 0,
    frontier_radius = 20,
    frontier_max_dist = 40,
    retry_count = 0,
    backtrack = {},
    backtrack_secondary = {},
    last_dir = nil,
    backtracking = false,
    backtrack_node = nil,
    backtrack_min_dist = 8,
    backtrack_failed_time = -1,
    backtrack_timeout = 5,
    priority = 'direction',
    wrong_dir_count = 0,
    -- Cells (walkable or not) ever examined by an update() scan. A frontier is
    -- a walkable cell with at least one neighbor NOT in `scanned` — i.e. the
    -- only frontiers are walkable cells adjacent to unknown territory. Without
    -- this set the frontier table accumulates every walkable cell the player
    -- passed near but >12 units from, growing without bound.
    scanned = {},
    -- Aliased by navigator on load to its own `failed_directions` list.  Each
    -- entry: { origin_x, origin_y, x, y (unit vector), time, target_dist }.
    -- Used by direction_penalty() to demote frontier candidates pointing into
    -- recently-failed bearings — see select_node_distance / select_node_direction.
    failed_directions = nil,
    -- Set by navigator when prefer_long_paths has produced nil for >=5s.
    -- While get_time_since_inject() <= this value the threshold filter is
    -- suspended so the bot can move at all on a freshly-entered floor.
    long_paths_bypass_until = 0,
}

-- Direction-failure penalty tunables.  The penalty subtracts from a candidate's
-- distance score (or adds to its direction-diff score), pushing the selector
-- away from frontiers behind known walls / unreachable clusters.
local FAILED_DIR_PROXIMITY      = 25                       -- only apply if origin within this dist
local FAILED_DIR_HALF_ANGLE_COS = math.cos(math.rad(45))   -- ~45° cone — wider than typical doorway
local FAILED_DIR_MAX_PENALTY    = 60                       -- max distance-units of penalty (> frontier_max_dist default 40)
local FAILED_DIR_TTL            = 25                       -- mirror navigator.failed_direction_ttl

-- Compute a non-negative penalty for picking `node` from `from_pos`, based on
-- recent failed-direction entries.  Stronger when the candidate's direction is
-- closely aligned with the failed bearing, when the failure is recent, and when
-- the failure originated near the current position.
local function direction_penalty(node, from_pos)
    local list = explorer.failed_directions
    if not list or #list == 0 then return 0 end
    local dx = node:x() - from_pos:x()
    local dy = node:y() - from_pos:y()
    local len = math.sqrt(dx*dx + dy*dy)
    if len < 0.001 then return 0 end
    local nx, ny = dx / len, dy / len
    local now = (get_time_since_inject and get_time_since_inject()) or 0
    local px, py = from_pos:x(), from_pos:y()
    local penalty = 0
    for i = 1, #list do
        local d = list[i]
        local age = now - d.time
        if age < FAILED_DIR_TTL then
            local odx = px - d.origin_x
            local ody = py - d.origin_y
            local origin_dist_sq = odx*odx + ody*ody
            if origin_dist_sq < FAILED_DIR_PROXIMITY * FAILED_DIR_PROXIMITY then
                local sim = nx * d.x + ny * d.y
                if sim >= FAILED_DIR_HALF_ANGLE_COS then
                    -- Map sim ∈ [cos(45°), 1] → strength ∈ [0, 1]
                    local strength    = (sim - FAILED_DIR_HALF_ANGLE_COS) / (1 - FAILED_DIR_HALF_ANGLE_COS)
                    local age_factor  = 1 - (age / FAILED_DIR_TTL)
                    local prox_factor = 1 - (math.sqrt(origin_dist_sq) / FAILED_DIR_PROXIMITY)
                    local p = FAILED_DIR_MAX_PENALTY * strength * age_factor * prox_factor
                    if p > penalty then penalty = p end
                end
            end
        end
    end
    return penalty
end
explorer.direction_penalty = direction_penalty
-- Spatial index for fast bbox queries during eviction.  Without this, the
-- evict pass iterates all 6000+ frontiers per call to find ~50 in the scan box.
-- Bucket size tuned to scan box (~26 units): one query touches ~4 buckets.
local FRONTIER_CHUNK = 16
local frontier_chunks = {}  -- "cx,cy" -> { node_str = true, ... }
-- Cap total frontiers to prevent open-world explosion (helltide reaches 7500-9700; pit peaks ~2000)
local MAX_FRONTIERS = 4000

local function chunk_key(x, y)
    return tostring(math.floor(x / FRONTIER_CHUNK)) .. ',' .. tostring(math.floor(y / FRONTIER_CHUNK))
end

local add_frontier = function (node_str, node)
    if explorer.frontier_count >= MAX_FRONTIERS then return end
    explorer.frontier[node_str] = explorer.frontier_index
    explorer.frontier_node[node_str] = node
    explorer.frontier_order[explorer.frontier_index] = node_str
    explorer.frontier_index = explorer.frontier_index + 1
    explorer.frontier_count = explorer.frontier_count + 1
    local ck = chunk_key(node:x(), node:y())
    local bucket = frontier_chunks[ck]
    if bucket == nil then
        bucket = {}
        frontier_chunks[ck] = bucket
    end
    bucket[node_str] = true
end
local remove_frontier = function (node_str)
    local index = explorer.frontier[node_str]
    if index ~= nil then
        local fnode = explorer.frontier_node[node_str]
        explorer.frontier_order[index] = nil
        explorer.frontier[node_str] = nil
        explorer.frontier_node[node_str] = nil
        explorer.frontier_count = explorer.frontier_count - 1
        if fnode ~= nil then
            local ck = chunk_key(fnode:x(), fnode:y())
            local bucket = frontier_chunks[ck]
            if bucket ~= nil then
                bucket[node_str] = nil
                if next(bucket) == nil then
                    frontier_chunks[ck] = nil
                end
            end
        end
    end
end
local add_visited = function (node_str)
    if explorer.visited[node_str] == nil then
        explorer.visited[node_str] = node_str
        explorer.visited_count = explorer.visited_count + 1
    end
end
explorer.add_visited    = add_visited
explorer.remove_frontier = remove_frontier

-- Trap-recovery helper: marks every frontier within an axis-aligned box as
-- visited so the explorer's selector stops cycling through them.  Returns the
-- count cleared.  Uses the chunk index so the cost is proportional to the box
-- size, not the total frontier count.
explorer.clear_frontiers_in_box = function(min_x, max_x, min_y, max_y)
    local cleared = 0
    local cmin_x = math.floor(min_x / FRONTIER_CHUNK)
    local cmax_x = math.floor(max_x / FRONTIER_CHUNK)
    local cmin_y = math.floor(min_y / FRONTIER_CHUNK)
    local cmax_y = math.floor(max_y / FRONTIER_CHUNK)
    local to_clear = {}
    for cx = cmin_x, cmax_x do
        for cy = cmin_y, cmax_y do
            local bucket = frontier_chunks[tostring(cx) .. ',' .. tostring(cy)]
            if bucket ~= nil then
                for node_str in pairs(bucket) do
                    local fnode = explorer.frontier_node[node_str]
                    if fnode ~= nil
                        and fnode:x() >= min_x and fnode:x() <= max_x
                        and fnode:y() >= min_y and fnode:y() <= max_y
                    then
                        to_clear[#to_clear + 1] = node_str
                    end
                end
            end
        end
    end
    for _, ns in ipairs(to_clear) do
        remove_frontier(ns)
        add_visited(ns)
        cleared = cleared + 1
    end
    return cleared
end
local remove_visited = function (node_str)
    if explorer.visited[node_str] ~= nil then
        explorer.visited[node_str] = nil
        explorer.visited_count = explorer.visited_count - 1
    end
end
local add_retry = function (node_str)
    if explorer.retry[node_str] == nil then
        explorer.retry[node_str] = node_str
        explorer.retry_count = explorer.retry_count + 1
    end
end
local remove_retry = function (node_str)
    if explorer.retry[node_str] ~= nil then
        explorer.retry[node_str] = nil
        explorer.retry_count = explorer.retry_count - 1
    end
end
local NEIGHBOR_OFFSETS = { {1, 0}, {-1, 0}, {0, 1}, {0, -1} }
-- True iff at least one of the 4 cardinal step-neighbors hasn't been scanned.
-- Used to prune frontiers that are now interior (all neighbors known).
local has_unscanned_neighbor = function (node_x, node_y, step)
    for _, off in ipairs(NEIGHBOR_OFFSETS) do
        local nx = utils.normalize_value(node_x + off[1] * step)
        local ny = utils.normalize_value(node_y + off[2] * step)
        if explorer.scanned[tostring(nx) .. ',' .. tostring(ny)] == nil then
            return true
        end
    end
    return false
end
local check_perimeter_node = function (perimeter, cx, cy, node_x, node_y, z)
    if cx == node_x and cy == node_y then return end
    local norm_x = utils.normalize_value(cx)
    local norm_y = utils.normalize_value(cy)
    local new_node = vec3:new(norm_x, norm_y, z)
    local new_node_str = utils.vec_to_string(new_node)
    if explorer.visited[new_node_str] == nil then
        local valid = utility.set_height_of_valid_position(new_node)
        if utility.is_point_walkeable(valid) then
            perimeter[#perimeter+1] = valid
        end
    end
end
local get_perimeter = function (node)
    local perimeter = {}
    local radius = explorer.radius
    local step = settings.step
    local x = node:x()
    local y = node:y()
    local min_x = x - radius
    local max_x = x + radius
    local min_y = y - radius
    local max_y = y + radius
    local z = node:z()
    -- Iterate only the 4 edges of the perimeter square
    -- Was: full 48x48 grid (2304 iterations) filtered to ~192 edge nodes
    -- Now: directly iterate ~192 edge nodes (12x fewer iterations)
    -- Top edge (j = min_y) and bottom edge (j = max_y)
    for i = min_x, max_x, step do
        check_perimeter_node(perimeter, i, min_y, x, y, z)
        check_perimeter_node(perimeter, i, max_y, x, y, z)
    end
    -- Left edge (i = min_x) and right edge (i = max_x), excluding corners
    for j = min_y + step, max_y - step, step do
        check_perimeter_node(perimeter, min_x, j, x, y, z)
        check_perimeter_node(perimeter, max_x, j, x, y, z)
    end
    return perimeter
end
-- Fallback when no perimeter, no in-range frontier, and no usable backtrack.
-- Picks the closest remaining frontier on the same Z level regardless of
-- frontier_max_dist. Without this the selector returns nil, four nil returns
-- in a row trigger navigator.reset() which wipes the entire frontier table —
-- even though valid waypoints existed, just farther than the 40-unit cap.
local pick_closest_frontier = function ()
    -- Direction-weighted scoring: backward frontiers are penalised by BACKWARD_MULT
    -- so a nearby backward branch can still beat a very far forward frontier, but a
    -- distant start-area frontier loses to essentially any forward candidate.
    --
    -- BACKWARD_MULT = 5: a backward frontier at 20u scores 100 and beats a forward
    -- frontier only if it is beyond 100u away.  A start-area frontier at 80u scores
    -- 400 — it can only win if forward territory is completely exhausted within 400u,
    -- which never happens in a bounded pit.  Nearby side-corridor branches (5–20u
    -- behind) still get explored when forward options are far, keeping total travel
    -- distance efficient without the "goes all the way back to start" pattern.
    local BACKWARD_MULT = 5.0

    local best_node  = nil
    local best_str   = nil
    local best_score = nil
    local best_dist  = nil   -- raw dist for the log
    local fallback_node = nil   -- wrong-Z candidate
    local fallback_str  = nil
    local fallback_dist = nil
    local n_wrong_z = 0

    -- Precompute normalised last_dir for dot-product test
    local ldx, ldy, have_dir = 0, 0, false
    local last_dir = explorer.last_dir
    local cur_pos  = explorer.cur_pos
    if last_dir ~= nil then
        local llen = math.sqrt(last_dir[1] * last_dir[1] + last_dir[2] * last_dir[2])
        if llen > 0.001 then
            ldx = last_dir[1] / llen
            ldy = last_dir[2] / llen
            have_dir = true
        end
    end

    for node_str, fnode in pairs(explorer.frontier_node) do
        if explorer.visited[node_str] ~= nil then
            remove_frontier(node_str)
        elseif math.abs(fnode:z() - cur_pos:z()) <= 3 then
            local d = utils.distance(fnode, cur_pos)
            local score = d
            if have_dir then
                local ndx = fnode:x() - cur_pos:x()
                local ndy = fnode:y() - cur_pos:y()
                -- dot < 0: frontier is behind the current heading → penalise
                if ldx * ndx + ldy * ndy < 0 then
                    score = d * BACKWARD_MULT
                end
            end
            if best_score == nil or score < best_score then
                best_score = score
                best_dist  = d
                best_node  = fnode
                best_str   = node_str
            end
        else
            n_wrong_z = n_wrong_z + 1
            local d = utils.distance(fnode, cur_pos)
            if fallback_dist == nil or d < fallback_dist then
                fallback_dist = d
                fallback_node = fnode
                fallback_str  = node_str
            end
        end
    end

    if best_node ~= nil then
        remove_frontier(best_str)
        explorer.backtracking = false
        explorer.last_dir = {
            best_node:x() - cur_pos:x(),
            best_node:y() - cur_pos:y(),
        }
        utils.log(1, string.format('far-frontier fallback: picking %s dist=%.1f score=%.1f',
            utils.vec_to_string(best_node), best_dist, best_score))
        return best_node
    end
    -- No same-Z frontier. Try the closest frontier regardless of Z so that
    -- terrain-level variation (dz 3-8u within the same pit floor) or a genuine
    -- cross-floor target doesn't leave the bot with no target at all.  The
    -- pathfinder + traversal-routing handles unreachable cross-floor nodes.
    if fallback_node ~= nil then
        remove_frontier(fallback_str)
        explorer.backtracking = false
        explorer.last_dir = {
            fallback_node:x() - cur_pos:x(),
            fallback_node:y() - cur_pos:y(),
        }
        if settings.debug_logs then console.print(string.format(
            '[pick_closest_frontier] no same-Z frontier (%d wrong-Z skipped); picking dz=%.1f dist=%.1f: %s',
            n_wrong_z,
            math.abs(fallback_node:z() - cur_pos:z()),
            fallback_dist,
            utils.vec_to_string(fallback_node))) end
        return fallback_node
    end
    explorer.backtracking = false
    return nil
end
local restore_backtrack = function ()
    -- restore secondary backtrack, incase other frontier needs it
    local index = #explorer.backtrack_secondary
    local cur_node = explorer.cur_pos
    local backtrack_tertiary = {}
    -- add path back to when it first removed
    while index > 0 do
        local backtrack_node = explorer.backtrack_secondary[index]
        local need_backtrack_node = false
        local index2 = explorer.frontier_index
        while index2 >= 0 do
            local most_recent_str = explorer.frontier_order[index2]
            if most_recent_str ~= nil then
                -- skip if node is visited
                if explorer.visited[most_recent_str] ~= nil then
                    remove_frontier(most_recent_str)
                else
                    local frontier_node = explorer.frontier_node[most_recent_str]
                    local cur_dist = utils.distance(cur_node, frontier_node)
                    local backtrack_dist = utils.distance(backtrack_node, frontier_node)
                    if backtrack_dist < cur_dist and
                        backtrack_dist <= explorer.frontier_max_dist and
                        cur_dist > explorer.frontier_max_dist
                    then
                        need_backtrack_node = true
                        break
                    end
                end
            end
            index2 = index2 - 1
        end
        if need_backtrack_node then
            if #backtrack_tertiary ~= 0 then
                for _, t_backtrack_node in ipairs(backtrack_tertiary) do
                    utils.log(2, 'adding ' .. utils.vec_to_string(t_backtrack_node) .. ' backtracks')
                    explorer.backtrack[#explorer.backtrack+1] = t_backtrack_node
                end
                backtrack_tertiary = {}
            end
            explorer.backtrack[#explorer.backtrack+1] = backtrack_node
            utils.log(2, 'adding ' .. utils.vec_to_string(backtrack_node) .. ' backtracks')
        else
            backtrack_tertiary[#backtrack_tertiary+1] = backtrack_node
        end
        cur_node = backtrack_node
        index = index - 1
    end
    utils.log(2, 'skipping ' .. #backtrack_tertiary .. ' backtracks')
    utils.log(2, 'total ' .. #explorer.backtrack_secondary .. ' secondaries')
    -- add path from when it first removed (or first skipped) until now
    for index, backtrack in ipairs(explorer.backtrack_secondary) do
        if #backtrack_tertiary < index then
            utils.log(2, 'adding ' .. utils.vec_to_string(backtrack) .. ' backtracks')
            explorer.backtrack[#explorer.backtrack+1] = backtrack
        end
    end
    explorer.backtrack_secondary = {}
end
local select_node_distance = function ()
    -- get all perimeter (unvisited) of current position
    local perimeter = get_perimeter(explorer.cur_pos)
    -- Experimental prefer_long_paths: drop perimeter entries closer than the
    -- threshold so the explorer target produces a path >= threshold. Perimeter
    -- nodes sit on the radius=12 ring (12..17u from cur_pos), so a 20u
    -- threshold filters them all and selection falls through to frontiers.
    -- Bypass: if navigator set long_paths_bypass_until (stuck 5s with no far
    -- target), skip filtering so the bot can move on freshly-entered floors.
    local _now_lf = get_time_since_inject()
    local long_filter = settings.prefer_long_paths
        and (explorer.long_paths_bypass_until or 0) < _now_lf
    local long_thresh = settings.long_path_threshold or 20
    if long_filter then
        local kept = {}
        for _, p_node in ipairs(perimeter) do
            if utils.distance(p_node, explorer.cur_pos) >= long_thresh then
                kept[#kept+1] = p_node
            end
        end
        perimeter = kept
    end
    -- furthest from first backtrack
    local furthest_node = nil
    local furthest_node_str = nil
    local furthers_dist = nil
    local check_pos = explorer.backtrack[1] or explorer.cur_pos
    local cur_dist = utils.distance(explorer.cur_pos, check_pos)

    -- check perimeter and frontier for furthest if not backtracking.
    -- Score = distance_from_check - direction_penalty.  The penalty pushes
    -- selection away from candidates pointing into recently-failed bearings,
    -- so we don't keep choosing the same wall-blocked frontier.
    if explorer.wrong_dir_count <= 2 then
        for _, p_node in ipairs(perimeter) do
            local dist  = utils.distance(p_node, check_pos)
            local score = dist - direction_penalty(p_node, explorer.cur_pos)
            if furthest_node == nil or score > furthers_dist then
                furthest_node = p_node
                furthers_dist = score
            end
        end
        if furthers_dist ~= nil and furthers_dist < cur_dist then
            explorer.wrong_dir_count = explorer.wrong_dir_count + 1
        else
            explorer.wrong_dir_count = 0
        end
    end
    if furthest_node == nil then
        -- Iterate only active frontier entries (pairs over frontier_node) instead
        -- of walking the full frontier_index range (which includes nil holes from
        -- removed entries and grows unboundedly in long sessions).
        local to_evict = nil
        for node_str, fnode in pairs(explorer.frontier_node) do
            if explorer.visited[node_str] ~= nil then
                if to_evict == nil then to_evict = {} end
                to_evict[#to_evict + 1] = node_str
            else
                -- prefer_long_paths: skip frontiers too close to produce a
                -- long-enough path. If every frontier is filtered the selector
                -- falls through to backtrack / pick_closest_frontier (the
                -- deadlock-prevention path) which ignores the threshold.
                local d_cur = long_filter and utils.distance(fnode, explorer.cur_pos) or 0
                if not long_filter or d_cur >= long_thresh then
                    local dist  = utils.distance(fnode, check_pos)
                    local score = dist - direction_penalty(fnode, explorer.cur_pos)
                    if furthest_node == nil or score > furthers_dist then
                        furthest_node     = fnode
                        furthers_dist     = score
                        furthest_node_str = node_str
                    end
                end
            end
        end
        if to_evict ~= nil then
            for _, ns in ipairs(to_evict) do remove_frontier(ns) end
        end
    end
    if furthest_node ~= nil and
        utils.distance(furthest_node, explorer.cur_pos) <= explorer.frontier_max_dist
    then
        if furthest_node_str ~= nil then
            explorer.wrong_dir_count = 0
            remove_frontier(furthest_node_str)
        end
        restore_backtrack()
        explorer.backtracking = false
        return furthest_node
    end
    -- Backtrack to discover new frontiers — moving back triggers update() which
    -- scans the surrounding area and may find unexplored walkable nodes
    local deferred_bt = {}
    while #explorer.backtrack > 0 do
        -- simulating pop()
        local last_index = #explorer.backtrack
        local last_pos = explorer.backtrack[last_index]
        explorer.backtrack[last_index] = nil
        -- Skip backtrack points that were blacklisted by the navigator (added to visited
        -- after repeated pathfind failures).  Without this check the
        -- same blacklisted point is re-returned every call, creating an infinite loop.
        local last_pos_str = utils.vec_to_string(last_pos)
        if explorer.visited[last_pos_str] ~= nil then goto continue_bt_distance end
        -- Skip backtrack nodes on a different Z-level (e.g. after traversal crossing).
        -- Defer them so they can be tried later if we cross back.
        if math.abs(last_pos:z() - explorer.cur_pos:z()) > 3 then
            deferred_bt[#deferred_bt+1] = last_pos
            goto continue_bt_distance
        end
        if utils.distance(last_pos, explorer.cur_pos) ~= 0 then
            -- Re-insert deferred nodes back into the backtrack stack
            for _, d in ipairs(deferred_bt) do
                explorer.backtrack[#explorer.backtrack+1] = d
            end
            explorer.backtracking = true
            -- store backrack to secondary so it can be restored
            explorer.backtrack_secondary[#explorer.backtrack_secondary+1] = last_pos
            return last_pos
        end
        ::continue_bt_distance::
    end
    -- Re-insert deferred (wrong-Z) nodes — they may become reachable later
    for _, d in ipairs(deferred_bt) do
        explorer.backtrack[#explorer.backtrack+1] = d
    end
    -- No perimeter / in-range frontier / usable backtrack. Before giving up,
    -- try the closest remaining frontier on this Z level — far waypoints are
    -- still valid targets, the pathfinder + traversal-routing can handle them.
    local far = pick_closest_frontier()
    if far ~= nil then return far end
    explorer.backtracking = false
    return nil
end
local select_node_direction = function (failed)
    -- get all perimeter (unvisited) of current position
    local perimeter = get_perimeter(explorer.cur_pos)
    -- Experimental prefer_long_paths: see select_node_distance for rationale.
    -- Bypass when navigator sets long_paths_bypass_until (stuck 5s with no far target).
    local _now_lf = get_time_since_inject()
    local long_filter = settings.prefer_long_paths
        and (explorer.long_paths_bypass_until or 0) < _now_lf
    local long_thresh = settings.long_path_threshold or 20
    if long_filter then
        local kept = {}
        for _, p_node in ipairs(perimeter) do
            if utils.distance(p_node, explorer.cur_pos) >= long_thresh then
                kept[#kept+1] = p_node
            end
        end
        perimeter = kept
    end
    if #perimeter > 0 then
        if explorer.last_dir ~= nil then
            local last_dx = explorer.last_dir[1]
            local last_dy = explorer.last_dir[2]
            local check_pos = explorer.cur_pos
            if failed ~= nil then
                check_pos = failed
            end

            -- closest direction
            local closest_dir_node = nil
            local closest_dir_diff = nil
            local closest_dir_dx = nil
            local closest_dir_dy = nil

            for _, p_node in ipairs(perimeter) do
                local dx = p_node:x() - check_pos:x()
                local dy = p_node:y() - check_pos:y()
                -- diff is L1 direction-error (lower=better); add penalty so a
                -- candidate pointing into a recently-failed bearing scores worse
                -- than a slightly-less-aligned but reachable alternative.
                local diff = math.abs(dx - last_dx) + math.abs(dy - last_dy)
                            + direction_penalty(p_node, explorer.cur_pos)
                if closest_dir_diff == nil or closest_dir_diff > diff then
                    closest_dir_diff = diff
                    closest_dir_node = p_node
                    closest_dir_dx = dx
                    closest_dir_dy = dy
                end
            end

            explorer.last_dir = {closest_dir_dx, closest_dir_dy}
            explorer.backtracking = false
            return closest_dir_node
        end

        -- if no last direction, just pick first one
        local dx = perimeter[1]:x() - explorer.cur_pos:x()
        local dy = perimeter[1]:y() - explorer.cur_pos:y()
        explorer.last_dir = {dx, dy}
        explorer.backtracking = false
        return perimeter[1]
    end

    -- if no unvisited perimeter, find the lowest-penalty in-range frontier
    -- (was: first-in-range; now picks among all in-range to avoid favouring
    -- a candidate that points into a known-failed bearing).
    -- Iterate pairs(frontier_node) instead of walking frontier_index down to 0:
    -- frontier_index is a monotonically-increasing insert counter that grows
    -- unboundedly (nil holes accumulate from removed entries), making the old
    -- loop O(ever-inserted) not O(currently-active).  pairs() skips nils natively.
    local best_str, best_node, best_penalty
    local to_evict = nil
    for node_str, fnode in pairs(explorer.frontier_node) do
        if explorer.visited[node_str] ~= nil then
            if to_evict == nil then to_evict = {} end
            to_evict[#to_evict + 1] = node_str
        else
            local d_cur = utils.distance(fnode, explorer.cur_pos)
            if d_cur <= explorer.frontier_max_dist
               and (not long_filter or d_cur >= long_thresh)
            then
                local p = direction_penalty(fnode, explorer.cur_pos)
                if best_node == nil or p < best_penalty then
                    best_node    = fnode
                    best_str     = node_str
                    best_penalty = p
                    if p == 0 then break end  -- can't beat zero-penalty pick
                end
            end
        end
    end
    if to_evict ~= nil then
        for _, ns in ipairs(to_evict) do remove_frontier(ns) end
    end
    if best_node ~= nil then
        remove_frontier(best_str)
        explorer.backtracking = false
        local dx = best_node:x() - explorer.cur_pos:x()
        local dy = best_node:y() - explorer.cur_pos:y()
        explorer.last_dir = {dx, dy}
        return best_node
    end
    -- Backtrack to discover new frontiers — moving back triggers update() which
    -- scans the surrounding area and may find unexplored walkable nodes
    local deferred_bt = {}
    while #explorer.backtrack > 0 do
        -- simulating pop()
        local last_index = #explorer.backtrack
        local last_pos = explorer.backtrack[last_index]
        explorer.backtrack[last_index] = nil
        -- Skip blacklisted backtrack points (see select_node_distance comment)
        local last_pos_str = utils.vec_to_string(last_pos)
        if explorer.visited[last_pos_str] ~= nil then goto continue_bt_direction end
        -- Skip backtrack nodes on a different Z-level; defer for later
        if math.abs(last_pos:z() - explorer.cur_pos:z()) > 3 then
            deferred_bt[#deferred_bt+1] = last_pos
            goto continue_bt_direction
        end
        if utils.distance(last_pos, explorer.cur_pos) ~= 0 then
            -- Re-insert deferred nodes back into the backtrack stack
            for _, d in ipairs(deferred_bt) do
                explorer.backtrack[#explorer.backtrack+1] = d
            end
            explorer.backtracking = true
            local dx = last_pos:x() - explorer.cur_pos:x()
            local dy = last_pos:y() - explorer.cur_pos:y()
            explorer.last_dir = {dx, dy}
            return last_pos
        end
        ::continue_bt_direction::
    end
    -- Re-insert deferred (wrong-Z) nodes — they may become reachable later
    for _, d in ipairs(deferred_bt) do
        explorer.backtrack[#explorer.backtrack+1] = d
    end
    -- No perimeter / in-range frontier / usable backtrack. Try the closest
    -- remaining frontier on this Z before triggering a full explorer reset.
    local far = pick_closest_frontier()
    if far ~= nil then return far end
    explorer.backtracking = false
    return nil
end
explorer.get_perimeter = get_perimeter
-- Track last full-scan position to throttle expensive grid rescans
local _last_scan_pos = nil
-- Eviction pass runs every 2nd update to cut the pairs() iteration cost in
-- half. Frontiers stay at most 1 extra scan past becoming interior — the
-- selectors already lazy-evict visited frontiers, so the only effect is
-- slightly stale frontier_count display.
local _evict_counter = 0

explorer.reset = function ()
    explorer.visited = {}
    explorer.visited_count = 0
    explorer.frontier = {}
    explorer.frontier_order = {}
    explorer.frontier_node = {}
    explorer.frontier_index = 0
    explorer.frontier_count = 0
    explorer.retry = {}
    explorer.retry_count = 0
    explorer.cur_pos = nil
    explorer.prev_pos = nil
    explorer.backtrack = {}
    explorer.backtrack_secondary = {}
    explorer.backtrack_node = nil
    explorer.backtracking = false
    explorer.backtrack_failed_time = -1
    explorer.last_dir = nil
    explorer.wrong_dir_count = 0
    explorer.scanned = {}
    frontier_chunks = {}
    _last_scan_pos = nil
    explorer.long_paths_bypass_until = 0
end
explorer.set_priority = function (priority)
    local allowed = {
        ['direction'] = true,
        ['distance'] = true,
    }
    if allowed[priority] then
        explorer.priority = priority
    end
end
explorer.set_current_pos = function (local_player)
    explorer.prev_pos = explorer.cur_pos
    explorer.cur_pos = utils.normalize_node(local_player:get_position())
    if not explorer.backtracking then
        if #explorer.backtrack > 0 then
            local last_index = #explorer.backtrack
            local last_pos = explorer.backtrack[last_index]

            local dist = utils.distance(last_pos, explorer.cur_pos)
            if dist >= explorer.backtrack_min_dist then
                explorer.backtrack[last_index+1] = explorer.cur_pos
            end
        else
            restore_backtrack()
            explorer.backtrack[1] = explorer.cur_pos
        end
    end
end
explorer.update = function (local_player)
    explorer.set_current_pos(local_player)
    local cur_pos = explorer.cur_pos
    -- Throttle: only rescan grid when moved >= 1 unit from last scan position
    -- Cuts scan frequency ~2x; frontier_radius (13) easily tolerates 1-unit delay
    -- (was: rescan on any 0.5-unit movement, causing ~70+ scans per 5s)
    if _last_scan_pos ~= nil and utils.distance(cur_pos, _last_scan_pos) < 1 then
        tracker.bench_count("explorer_scan_throttled")
        return
    end
    _last_scan_pos = cur_pos
    tracker.bench_start("explorer_scan")
    local _scan_walkable_checks = 0

    local x = cur_pos:x()
    local y = cur_pos:y()

    local f_radius = explorer.frontier_radius
    local v_radius = explorer.radius
    local step = settings.step

    local f_min_x = x - f_radius
    local f_max_x = x + f_radius
    local f_min_y = y - f_radius
    local f_max_y = y + f_radius

    local v_min_x = x - v_radius + step
    local v_max_x = x + v_radius - step
    local v_min_y = y - v_radius + step
    local v_max_y = y + v_radius - step

    local cur_z = cur_pos:z()
    for i = f_min_x, f_max_x, step do
        -- normalize_value(i) and tostring hoisted outside inner loop
        local norm_x = utils.normalize_value(i)
        local str_x = tostring(norm_x)
        for j = f_min_y, f_max_y, step do
            local norm_y = utils.normalize_value(j)
            -- Build node_str directly without creating vec3 first
            -- Skips vec3 allocation for already-visited nodes (~70% of grid in explored areas)
            local node_str = str_x .. ',' .. tostring(norm_y)

            -- Mark every cell as scanned.  Tri-state value:
            --   nil   = never seen
            --   true  = seen (walkable, visited, or status-irrelevant)
            --   false = seen and confirmed non-walkable — used to skip the
            --           expensive engine walk check on subsequent scans.
            -- has_unscanned_neighbor only checks for nil, so both true/false
            -- count as scanned for eviction purposes.  Don't overwrite a
            -- previously-recorded `false`: re-asserting `true` here would
            -- defeat the skip and re-trigger the engine check next pass.
            local prev_scanned = explorer.scanned[node_str]
            if prev_scanned == nil then
                explorer.scanned[node_str] = true
            end

            if explorer.visited[node_str] == nil or
                explorer.retry[node_str] ~= nil
            then
                if i >= v_min_x and i <= v_max_x and j >= v_min_y and j <= v_max_y then
                    add_visited(node_str)
                    remove_retry(node_str)
                    remove_frontier(node_str)
                elseif explorer.frontier[node_str] == nil and prev_scanned ~= false
                        and explorer.frontier_count < MAX_FRONTIERS then
                    if explorer.retry[node_str] ~= nil then
                        remove_visited(node_str)
                        remove_retry(node_str)
                    end
                    -- Only create vec3 when actually needed for walkability check
                    local node = vec3:new(norm_x, norm_y, cur_z)
                    local valid = utility.set_height_of_valid_position(node)
                    local walkable = utility.is_point_walkeable(valid)
                    _scan_walkable_checks = _scan_walkable_checks + 1
                    if walkable then
                        add_frontier(node_str, valid)
                    else
                        -- Cache the negative result so the next scan skips this cell
                        explorer.scanned[node_str] = false
                    end
                end
            end
        end
    end
    tracker.bench_stop("explorer_scan", string.format("walk_checks=%d frontiers=%d",
        _scan_walkable_checks, explorer.frontier_count))

    -- Eviction pass: drop frontiers that just became interior. A frontier is
    -- a walkable cell adjacent to *unknown* (unscanned) territory. After a
    -- scan, cells in the f_radius box (plus 1-step margin) may have had their
    -- last unscanned neighbor filled in — those are no longer frontiers.
    -- Cells outside that box can't have changed status from this scan.
    -- Throttled to every other update; 1-scan staleness is harmless.
    _evict_counter = _evict_counter + 1
    if _evict_counter % 2 == 0 then
        tracker.bench_start("explorer_evict")
        local evict_min_x = f_min_x - step
        local evict_max_x = f_max_x + step
        local evict_min_y = f_min_y - step
        local evict_max_y = f_max_y + step
        local _evict_scanned = 0
        local to_evict = nil
        -- Spatial-indexed eviction: visit only the chunk buckets intersecting
        -- the scan box (~4 buckets × handful of frontiers each) instead of
        -- iterating all 6000+ frontiers.  Was the #2 lag source — see logzewx.
        local cmin_x = math.floor(evict_min_x / FRONTIER_CHUNK)
        local cmax_x = math.floor(evict_max_x / FRONTIER_CHUNK)
        local cmin_y = math.floor(evict_min_y / FRONTIER_CHUNK)
        local cmax_y = math.floor(evict_max_y / FRONTIER_CHUNK)
        for cx = cmin_x, cmax_x do
            for cy = cmin_y, cmax_y do
                local bucket = frontier_chunks[tostring(cx) .. ',' .. tostring(cy)]
                if bucket ~= nil then
                    for node_str in pairs(bucket) do
                        local fnode = explorer.frontier_node[node_str]
                        if fnode ~= nil then
                            local fx = fnode:x()
                            local fy = fnode:y()
                            if fx >= evict_min_x and fx <= evict_max_x
                                and fy >= evict_min_y and fy <= evict_max_y
                                and not has_unscanned_neighbor(fx, fy, step)
                            then
                                if to_evict == nil then to_evict = {} end
                                to_evict[#to_evict + 1] = node_str
                            end
                            _evict_scanned = _evict_scanned + 1
                        end
                    end
                end
            end
        end
        if to_evict ~= nil then
            for _, ns in ipairs(to_evict) do
                remove_frontier(ns)
            end
        end
        tracker.bench_stop("explorer_evict", string.format("scanned=%d evicted=%d total_frontiers=%d",
            _evict_scanned, to_evict and #to_evict or 0, explorer.frontier_count))
    end
end
explorer.select_node = function (local_player, failed)
    if explorer.cur_pos == nil then
        explorer.set_current_pos(local_player)
    end
    if failed ~= nil then
        -- if failed at backtrack, try again
        if explorer.backtracking then
            if explorer.backtrack_node ~= utils.vec_to_string(failed) then
                explorer.backtrack_failed_time = get_time_since_inject()
                explorer.backtrack_node = utils.vec_to_string(failed)
                return failed
            -- retry the failed node for up to 5 seconds
            elseif explorer.backtrack_failed_time + explorer.backtrack_timeout >= get_time_since_inject() then
                return failed
            end
        end
        failed = utils.normalize_node(failed)
        local failed_str = utils.vec_to_string(failed)
        add_visited(failed_str)
        add_retry(failed_str)
    end

    if explorer.priority == 'distance' then
        return select_node_distance()
    end

    -- default priority explorer.priority == 'direction'
    return select_node_direction(failed)
end

return explorer