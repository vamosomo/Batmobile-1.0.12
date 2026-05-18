-- Frigate long-nav orchestrator: drives ultra-long-distance navigation by
-- combining
--   * map.lua          (discovered terrain / traversal cache)
--   * spiral.lua       (circular spiral scan around player + target)
--   * long_path.lua    (uncapped A* + navigator drive)
--   * navigator.lua    (traversal interaction, movement spells, escape logic)
--
-- The orchestrator runs as a small state machine, ticked once per frame from
-- main_pulse. It is API-driven: orchestrators call navigate(caller, target)
-- and poll is_navigating() / stop(caller).
--
-- States:
--   IDLE                — nothing in flight
--   WARMUP              — recently started; let spiral discover terrain before committing
--   ROUTING_DIRECT      — long_path A* to target is live; following navigator
--   ROUTING_VIA_TRAV    — long_path leg is to a traversal gizmo; resume target after cross
--   REACHED             — within REACH_TOLERANCE of target
--   FAILED              — exhausted retries / no viable route

local utils      = require 'core.utils'
local settings   = require 'core.settings'
local navigator  = require 'core.navigator'
local long_path  = require 'core.long_path'
local map        = require 'core.map'
local spiral     = require 'core.spiral'
local tracker    = require 'core.tracker'

local long_nav = {}

-- Tunables
local WARMUP_DURATION       = 0.6   -- s of spiral scanning before first pathfind
local REACH_TOLERANCE       = 3.0   -- units from target counts as 'reached'
local DIRECT_RETRY_COOLDOWN = 2.0   -- s before retrying long_path after a failure
local DIRECT_FAIL_MAX       = 3     -- consecutive direct-route failures before going to ROUTING_VIA_TRAV
local TRAV_FAIL_MAX         = 4     -- traversal-bridge attempts before giving up
local TRAV_SEARCH_RADIUS    = 50.0  -- map traversals to consider when bridging
local TRAV_REACH_TOLERANCE  = 5.0   -- distance to traversal approach point that counts as 'crossed'
local STALL_TIMEOUT         = 12.0  -- s without distance progress before forcing retry
local MIN_PROGRESS_DELTA    = 1.5   -- units of XY distance to count as 'progress'

-- ----- state -----
local state          = 'IDLE'
local caller         = nil
local target         = nil
local started_at     = -1
local last_progress_at = -1
local best_target_dist = math.huge
local direct_fail_count = 0
local trav_fail_count   = 0
local next_direct_retry = -1
local current_leg_target = nil   -- intermediate goal (traversal approach) or final target
local current_leg_kind   = nil   -- 'direct' | 'trav'
local visited_trav_ids   = {}    -- ids of traversals we've already used this run

-- Logging
--
-- Three channels:
--   _log        — always-on, prints state transitions / leg outcomes / errors.
--                 Sparse by construction: only called on events.
--   _vlog       — verbose, gated by settings.frigate_verbose_logging. Prints
--                 in-depth diagnostics (candidate scoring, partial-path stats,
--                 spiral stats). Still event-driven, not per-frame.
--   _status_log — throttled status snapshot, prints once every
--                 settings.frigate_verbose_status_interval seconds while a run
--                 is in flight. One line: state + dist + leg + counters.
local function _log(msg)
    console.print('[FRIGATE] ' .. msg)
end

local function _vlog(msg)
    if settings.frigate_verbose_logging ~= false then
        console.print('[FRIGATE.V] ' .. msg)
    end
end

local _last_status_log_t = -1
local _last_status_line  = nil
local _milestone_grid    = 25   -- units; verbose log fires once per 25u-band crossed
local _last_milestone    = nil
-- Forward-declared, defined later; need them here so _reset_run_state can clear them.
local _direct_empty_count = 0   -- consecutive A* limit_empty/no_path on direct legs
local _tiny_partial_count = 0   -- consecutive A* time/iter_limit_partial with plen<=TINY_PARTIAL_PLEN
local _stall_at_dist      = nil -- distance at which the last stall happened (for repeat-stall detection)
local _stall_repeat_count = 0
local _visited_detours    = {}  -- "x,y" -> true, prevents revisiting same detour area
local _detour_pre_dist    = nil -- best_target_dist captured at detour start
local _detour_useless_streak = 0 -- consecutive detours that did NOT improve best
local _direct_attempt_n   = 0   -- counter of direct attempts this run; first attempts get a bigger budget
local TINY_PARTIAL_PLEN   = 3   -- partial paths this short are 'wedged' (was 5; SeersReach plen=2-3 paths
                                -- were dragging the navigator into mini-replans before the wedge fired)
local DETOUR_USELESS_MAX  = 2   -- this many in a row -> FAIL (no point looping)
local function _status_log(msg)
    if settings.frigate_verbose_logging == false then return end
    local interval = settings.frigate_verbose_status_interval or 2.0
    local now = get_time_since_inject and get_time_since_inject() or 0
    if now - _last_status_log_t < interval then return end
    -- Suppress consecutive identical snapshots to keep the log readable when
    -- nothing has changed (rare, since 'd=' usually moves a bit each tick).
    if msg == _last_status_line then
        _last_status_log_t = now
        return
    end
    _last_status_log_t = now
    _last_status_line  = msg
    console.print('[FRIGATE STATUS] ' .. msg)
end

local function _set_state(new_state, reason)
    if state ~= new_state then
        _log(string.format('state: %s -> %s%s', state, new_state, reason and ('  (' .. reason .. ')') or ''))
        state = new_state
    end
end

local function _now()
    return get_time_since_inject and get_time_since_inject() or 0
end

local function _reset_run_state()
    target               = nil
    caller               = nil
    started_at           = -1
    last_progress_at     = -1
    best_target_dist     = math.huge
    direct_fail_count    = 0
    trav_fail_count      = 0
    next_direct_retry    = -1
    current_leg_target   = nil
    current_leg_kind     = nil
    visited_trav_ids     = {}
    _last_status_log_t   = -1
    _last_status_line    = nil
    _last_milestone      = nil
    _visited_detours     = {}
    _direct_empty_count  = 0
    _tiny_partial_count  = 0
    _stall_at_dist       = nil
    _stall_repeat_count  = 0
    _detour_pre_dist     = nil
    _detour_useless_streak = 0
    _direct_attempt_n    = 0
end

-- Public: orchestrator entry point.
function long_nav.navigate(caller_name, target_pos)
    if not target_pos then
        _log('navigate: nil target')
        return false
    end
    if target_pos.get_position then target_pos = target_pos:get_position() end
    local local_player = get_local_player()
    if not local_player then
        _log('navigate: no local player')
        return false
    end
    -- Reset prior run
    long_path.stop_navigation()
    navigator.clear_target()
    spiral.reset()
    _reset_run_state()

    target     = utils.normalize_node(target_pos)
    caller     = caller_name or 'unknown'
    started_at = _now()
    last_progress_at = started_at
    local p = local_player:get_position()
    best_target_dist = utils.distance(p, target)
    _log(string.format('navigate(%s) target=(%.1f, %.1f, %.1f)  dist=%.1f  dz=%.1f',
        caller, target:x(), target:y(), target:z(),
        best_target_dist, math.abs(target:z() - p:z())))
    _set_state('WARMUP', 'initial spiral scan')
    return true
end

function long_nav.stop(caller_name)
    if state == 'IDLE' then return end
    _log(string.format('stop(%s) from state=%s', caller_name or '?', state))
    long_path.stop_navigation()
    navigator.clear_target()
    spiral.reset()
    _reset_run_state()
    state = 'IDLE'
end

function long_nav.is_navigating()
    return state ~= 'IDLE' and state ~= 'REACHED' and state ~= 'FAILED'
end

function long_nav.get_state()
    return state
end

function long_nav.get_target()
    return target
end

-- Sort traversals by usefulness for bridging player -> target.
-- Score:
--   * prefer unvisited (haven't used this run)
--   * prefer XY-close to player
--   * prefer Z between player_z and target_z (steps in the right direction)
local function _score_trav(t, player_pos, target_pos)
    if visited_trav_ids[t.id] then return -math.huge end
    local dx = t.pos:x() - player_pos:x()
    local dy = t.pos:y() - player_pos:y()
    local horiz = math.sqrt(dx*dx + dy*dy)
    if horiz > TRAV_SEARCH_RADIUS then return -math.huge end
    local pz, tz = player_pos:z(), target_pos:z()
    local zlo, zhi = math.min(pz, tz), math.max(pz, tz)
    local z_band_bonus = 0
    if t.z >= zlo - 4 and t.z <= zhi + 4 then z_band_bonus = 30 end
    -- closer is better; same-floor-as-player gets extra weight (need to use that floor's gizmo)
    local same_floor = (math.abs(t.z - pz) <= 6) and 20 or 0
    return same_floor + z_band_bonus - horiz * 0.5
end

-- Pick a "detour" cell from the discovered map. Used when A* keeps returning
-- tiny / empty partials on the direct path because the target sits across a
-- concave obstacle and the only walkable route goes the long way around.
--
-- Hard rules (zewxlog SeersReach evidence: dropping these caused the bot to
-- retreat north into walls on every wedge):
--   * Same floor: |cell.z - player.z| <= DETOUR_Z_TOL.
--   * Bounded retreat: projected new dist-to-target must not exceed
--     current_dist + DETOUR_MAX_RETREAT. Rejects "directly away" candidates
--     that double the run length without unblocking anything.
--   * No re-picks: visited_detours dedupe by 5u-quantized xy.
--
-- Score (higher = better):
--   * Perpendicularity: 1 - |dot|, peaks at dot=0 (lateral hop). Strongly-away
--     (dot<<0) and strongly-toward (dot>>0) both score low. Lateral hops are
--     what actually find a new corridor; retreats just back into the wedge.
--   * Mid-range pdist: peaks at the middle of the tier's pdist range.
--   * Less-explored area bonus: cell quantization key not in visited_detours.
local _DETOUR_TIERS = {
    { dot_max = 0.4,  pdist_min = 12, pdist_max = 40, label = 'lateral' },
    { dot_max = 0.7,  pdist_min = 10, pdist_max = 50, label = 'loose' },
    { dot_max = 1.1,  pdist_min = 8,  pdist_max = 60, label = 'any-walkable' },
}
local DETOUR_Z_TOL       = 3.0   -- cells more than 3u off in z are different floor
local DETOUR_MAX_RETREAT = 15.0  -- max projected new-dist - current-dist before reject

local function _pick_detour(player_pos)
    if not target then return nil end
    local dx = target:x() - player_pos:x()
    local dy = target:y() - player_pos:y()
    local cur_d = math.sqrt(dx*dx + dy*dy)
    if cur_d < 0.001 then return nil end
    local tx, ty = dx/cur_d, dy/cur_d   -- unit vector player -> target
    local pz = player_pos:z()

    local scanned = 0
    for _, _ in pairs(map.cells) do scanned = scanned + 1 end

    for tier_i, tier in ipairs(_DETOUR_TIERS) do
        local best, best_score = nil, -math.huge
        local in_range, on_floor, in_cone, in_retreat_budget = 0, 0, 0, 0
        for _, cell in pairs(map.cells) do
            if cell.walkable then
                local pdx = cell.x - player_pos:x()
                local pdy = cell.y - player_pos:y()
                local pdist = math.sqrt(pdx*pdx + pdy*pdy)
                if pdist >= tier.pdist_min and pdist <= tier.pdist_max then
                    in_range = in_range + 1
                    if math.abs(cell.z - pz) <= DETOUR_Z_TOL then
                        on_floor = on_floor + 1
                        local dot = (pdx/pdist) * tx + (pdy/pdist) * ty
                        if dot < tier.dot_max then
                            in_cone = in_cone + 1
                            -- Projected new dist-to-target: cur_d - dot * pdist.
                            -- dot=-1 (directly away) -> cur_d + pdist (retreat).
                            -- dot=0  (perpendicular) -> cur_d (lateral).
                            -- dot=+1 (toward)        -> cur_d - pdist (progress).
                            local proj_new = cur_d - dot * pdist
                            if proj_new - cur_d <= DETOUR_MAX_RETREAT then
                                in_retreat_budget = in_retreat_budget + 1
                                local key = string.format('%d,%d',
                                    math.floor(cell.x / 5 + 0.5),
                                    math.floor(cell.y / 5 + 0.5))
                                if not _visited_detours[key] then
                                    -- New scoring: prefer perpendicular (dot near 0).
                                    -- Strong retreats get lower score even if not
                                    -- filtered out.
                                    local perp = 1.0 - math.abs(dot)   -- 0..1
                                    local middle_target = (tier.pdist_min + tier.pdist_max) * 0.5
                                    local middle = 1.0 - math.abs(pdist - middle_target) / middle_target
                                    local score = perp * 50 + middle * 20
                                    if score > best_score then
                                        best_score = score
                                        best = { cell = cell, key = key, pdist = pdist, dot = dot,
                                                 score = score, tier = tier.label, proj_new = proj_new }
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        _vlog(string.format(
            'detour scan tier=%s  cells=%d  in_range=%d  on_floor=%d  in_cone=%d  budget_ok=%d  picked=%s',
            tier.label, scanned, in_range, on_floor, in_cone, in_retreat_budget,
            best and 'yes' or 'no'))
        if best then return best end
    end
    return nil
end

local function _pick_traversal(player_pos, target_pos)
    local best, best_score = nil, -math.huge
    for i = 1, #map.traversals do
        local t = map.traversals[i]
        local s = _score_trav(t, player_pos, target_pos)
        if s > best_score then
            best_score = s
            best       = t
        end
    end
    if best_score == -math.huge then return nil end
    return best
end

-- Build pathfinder caps for a direct leg attempt. Two-axis tuning:
--
--   * closer to target -> bigger budget (curving ramps with z variance can need
--     a much longer path than the straight-line distance suggests; iter limit
--     is what kills close-in attempts that have to detour around obstacles).
--   * first attempt of a run -> bigger budget (the warmup leg is the one that
--     can find a 450-node full route; subsequent retries are typically from
--     positions where A* is already wedged, so spending more time there is
--     wasted. zewxlog SeersReach run: full path found at attempt 7 with
--     6248 iters / 274ms — but the first 6 attempts hit 300ms with only
--     ~2000 iters because walkability checks were slow at the start
--     position. A bigger first-attempt cap lets A* break through).
local function _direct_caps(player_pos)
    local d = utils.distance(player_pos, target)
    local iter = 10000
    local time = 0.300
    if d < 80 then iter = 16000; time = 0.500 end
    if d < 50 then iter = 25000; time = 0.700 end
    if d < 30 then iter = 35000; time = 0.900 end

    -- First-attempt boost. The very first direct leg of a run is the only one
    -- with NO prior context, and is most likely to be the warmup-to-full-path
    -- transition. Give it a big chunk of time once; later attempts retry with
    -- normal scaling.
    if _direct_attempt_n == 0 then
        iter = math.max(iter, 25000)
        time = math.max(time, 0.800)
    elseif _direct_attempt_n == 1 then
        iter = math.max(iter, 18000)
        time = math.max(time, 0.550)
    end
    return { iter_cap = iter, time_cap = time }
end

local function _start_direct_leg()
    if not target then return false end
    local player = get_local_player()
    local p = player and player:get_position() or nil
    local d = p and utils.distance(p, target) or -1
    local caps = p and _direct_caps(p) or nil
    _vlog(string.format('direct leg attempt #%d: dist=%.1f  dz=%.1f  caps=%s',
        _direct_attempt_n + 1, d, p and math.abs(target:z() - p:z()) or 0,
        caps and (string.format('iter=%d time=%.0fms', caps.iter_cap, caps.time_cap * 1000)) or 'default'))
    _direct_attempt_n = _direct_attempt_n + 1
    local ok = long_path.navigate_to(target, caps)
    if ok then
        current_leg_target = target
        current_leg_kind   = 'direct'
        _set_state('ROUTING_DIRECT', 'long_path accepted')
        _vlog(string.format('direct leg OK: navigator now has %d path nodes', #navigator.path))
        return true
    end
    direct_fail_count = direct_fail_count + 1
    next_direct_retry = _now() + DIRECT_RETRY_COOLDOWN
    _log(string.format('direct leg failed (count=%d) — cooldown %.1fs', direct_fail_count, DIRECT_RETRY_COOLDOWN))
    return false
end

-- Pick a detour cell and start navigating there. Returns true on success.
-- Caller should already have decided that direct routing is wedged.
local function _start_detour_leg(player_pos)
    local pick = _pick_detour(player_pos)
    if not pick then
        _vlog('detour: no candidate found in map (need walkable cells away from target)')
        return false
    end
    local cell   = pick.cell
    local goal   = vec3:new(cell.x, cell.y, cell.z or player_pos:z())
    _visited_detours[pick.key] = true
    -- Use the same generous caps as a close-in direct leg: detours are typically
    -- short hops but the path may still curve.
    local caps = { iter_cap = 12000, time_cap = 0.400 }
    _vlog(string.format(
        'detour leg: cell=(%.1f, %.1f, %.1f)  pdist=%.1f  dot=%.2f  proj_new=%.1f  score=%.1f',
        cell.x, cell.y, cell.z, pick.pdist, pick.dot, pick.proj_new or -1, pick.score))
    local ok = long_path.navigate_to(goal, caps)
    if not ok then
        _vlog(string.format('detour leg: long_path rejected (status=%s)',
            long_path.last_status or '?'))
        return false
    end
    -- Capture best_target_dist at detour start so we can tell on completion
    -- whether the detour actually unblocked progress (i.e. best improved during
    -- or after the detour). zewxlog evidence: bot looped 2 useless detours that
    -- each moved 20u further from target and accomplished nothing.
    _detour_pre_dist = best_target_dist
    current_leg_target = utils.normalize_node(goal)
    current_leg_kind   = 'detour'
    _set_state('ROUTING_DETOUR', 'long_path accepted')
    return true
end

local function _start_trav_leg(player_pos)
    -- Verbose: dump the top-3 candidate scores so the user can see why a
    -- particular gizmo was picked (or not).
    if settings.frigate_verbose_logging ~= false then
        local scored = {}
        for i = 1, #map.traversals do
            local t = map.traversals[i]
            local s = _score_trav(t, player_pos, target)
            if s > -math.huge then
                scored[#scored + 1] = { t = t, s = s }
            end
        end
        table.sort(scored, function(a, b) return a.s > b.s end)
        local top = math.min(3, #scored)
        _vlog(string.format('trav candidates: %d/%d in range', #scored, #map.traversals))
        for i = 1, top do
            local e = scored[i]
            _vlog(string.format('  [%d] %s @ (%.1f, %.1f, %.1f)  score=%.1f  visited=%s',
                i, e.t.name, e.t.pos:x(), e.t.pos:y(), e.t.pos:z(), e.s,
                visited_trav_ids[e.t.id] and 'yes' or 'no'))
        end
    end

    local t = _pick_traversal(player_pos, target)
    if not t then
        _log('no candidate traversal in map — failing')
        _set_state('FAILED', 'no traversal candidates')
        return false
    end
    visited_trav_ids[t.id] = true
    -- Find an approach node (a walkable tile close to the gizmo)
    local approach = navigator.get_closeby_node(t.pos, 4) or t.pos
    _vlog(string.format('trav leg pick: %s  approach=(%.1f, %.1f, %.1f) %s',
        t.name, approach:x(), approach:y(), approach:z(),
        (approach == t.pos) and '(fallback: gizmo pos)' or ''))
    local ok = long_path.navigate_to(approach)
    if not ok then
        _log(string.format('trav leg failed: %s @ (%.1f, %.1f, %.1f)',
            t.name, t.pos:x(), t.pos:y(), t.pos:z()))
        trav_fail_count = trav_fail_count + 1
        if trav_fail_count >= TRAV_FAIL_MAX then
            _set_state('FAILED', 'trav leg attempts exhausted')
        end
        return false
    end
    -- Pin the navigator to OUR chosen gizmo so when the player gets within 3u
    -- of it, navigator.move()'s interact_object block fires for THIS trav
    -- rather than whatever's currently closest (which might be the wrong floor
    -- or the wrong direction). We use the actor reference stored on the map
    -- entry — see map.record_traversal which keeps `actor` alongside name/pos.
    if t.actor ~= nil then
        navigator.last_trav  = t.actor
        navigator.pre_trav_z = player_pos:z()
        _vlog('trav leg: pinned navigator.last_trav to chosen gizmo')
    else
        _vlog('trav leg: no actor reference on map entry, navigator will pick opportunistically when block lifts')
    end
    current_leg_target = utils.normalize_node(approach)
    current_leg_kind   = 'trav'
    _log(string.format('trav leg: %s @ (%.1f, %.1f, %.1f) via approach (%.1f, %.1f)',
        t.name, t.pos:x(), t.pos:y(), t.pos:z(), approach:x(), approach:y()))
    _set_state('ROUTING_VIA_TRAV', 'long_path accepted')
    return true
end

-- Drive the navigator one frame (mirror of main_pulse's freeroam branch but
-- without the freeroam gate — long_nav owns the navigator while active).
local function _drive_navigator()
    navigator.unpause()
    local t0 = os.clock()
    navigator.update()
    tracker.timer_update = os.clock() - t0
    local t1 = os.clock()
    navigator.move()
    tracker.timer_move = os.clock() - t1
end

-- Reach detection: depends on which leg we're on.
local function _leg_reached(player_pos)
    if not current_leg_target then return false end
    local tol = (current_leg_kind == 'trav') and TRAV_REACH_TOLERANCE or REACH_TOLERANCE
    return utils.distance(player_pos, current_leg_target) <= tol
end

local function _final_reached(player_pos)
    if not target then return false end
    return utils.distance(player_pos, target) <= REACH_TOLERANCE
end

-- Progress watchdog: if XY distance to target hasn't shrunk by MIN_PROGRESS_DELTA
-- in STALL_TIMEOUT seconds, force a retry (likely stuck or wedged).
-- Also drops a verbose log each time we cross a coarse milestone, so a long run
-- gives the user a feel for progress without spamming every frame.
-- _milestone_grid + _last_milestone are declared above so _reset_run_state can see them.
local function _check_progress(player_pos)
    local d = utils.distance(player_pos, target)
    if d + MIN_PROGRESS_DELTA < best_target_dist then
        best_target_dist = d
        last_progress_at = _now()
        local m = math.floor(d / _milestone_grid)
        if _last_milestone == nil or m < _last_milestone then
            _last_milestone = m
            _vlog(string.format('progress milestone: dist=%.1f (band <=%d)', d, (m + 1) * _milestone_grid))
        end
    end
    return (_now() - last_progress_at) < STALL_TIMEOUT
end

function long_nav.tick(local_player)
    if state == 'IDLE' or state == 'REACHED' or state == 'FAILED' then return end
    if not local_player or local_player:is_dead() then
        long_nav.stop('player_dead_in_tick')
        return
    end
    local pos = local_player:get_position()

    -- Always run spiral scan (cheap, budgeted). Picks up terrain + traversals
    -- around both the player and the target so we keep discovering even while
    -- in motion mid-leg.
    spiral.set_config(settings.frigate_spiral_radius, settings.frigate_spiral_step)
    spiral.tick(pos, target, {
        step_budget         = 6,
        spiral_around_target = settings.frigate_spiral_around_target ~= false,
    })

    -- Suppress opportunistic traversal pickup while routing direct/detour.
    -- navigator.select_target() arms its trav-grabber the moment long_path
    -- returns a partial path (which is every leg in long-distance runs), so
    -- without this block the bot would climb random ladders within 15u that
    -- happen to be roughly toward target (see zewxlog.md: Player_Traversal_
    -- LadderUp / LadderDown firing during a >70u direct leg). Re-asserted every
    -- tick so the suppression never lapses mid-leg. Lifted automatically when
    -- we transition into ROUTING_VIA_TRAV (we set our own last_trav there).
    if state == 'ROUTING_DIRECT' or state == 'ROUTING_DETOUR' or state == 'WARMUP' then
        navigator.all_trav_blocked_until = _now() + 0.5
    end

    -- Throttled status snapshot: one line every N seconds with everything
    -- you need to see at a glance.
    _status_log(string.format(
        '%s  d=%.1f  dz=%.1f  best=%.1f  fail{d=%d t=%d}  path=%d  map{%s}  spiral{%s}  age=%.1fs',
        state, utils.distance(pos, target), math.abs(target:z() - pos:z()),
        best_target_dist, direct_fail_count, trav_fail_count,
        #navigator.path,
        map.stats_string(),
        spiral.stats(),
        _now() - started_at))

    -- Final-reach check applies in any routing state.
    if _final_reached(pos) then
        _log(string.format('target reached. dist=%.2f', utils.distance(pos, target)))
        long_path.stop_navigation()
        navigator.clear_target()
        _set_state('REACHED', 'final target')
        return
    end

    if state == 'WARMUP' then
        if (_now() - started_at) >= WARMUP_DURATION then
            _start_direct_leg()
        end
        return
    end

    if state == 'ROUTING_DIRECT' then
        -- Defense 0: long_path is "navigating" but its path got fully consumed
        -- (player walked all the way through it without reaching final target).
        -- If we don't stop here, the next navigator.move() sees an empty path,
        -- _skip_replan goes false, and navigator runs its OWN 70ms-cap replan
        -- that returns plen=2 partials pointing into walls. Stop cleanly so
        -- long_nav's own retry logic fires (with the bigger _direct_caps
        -- budget for short-distance attempts) on the next tick. zewxlog
        -- evidence: 30s of wedge from a 3-node initial path because path
        -- emptied in <1s and navigator's mini-replans took over.
        if long_path.navigating and #navigator.path == 0 and navigator.target ~= nil then
            _vlog('long_path path consumed -> stopping cleanly for long_nav retry')
            long_path.stop_navigation()
        end
        -- Defense 1: navigator's traversal-escape logic can clear target mid-leg
        -- even while long_path.navigating is still true. Treat as leg-ended.
        if long_path.navigating and navigator.target == nil then
            long_path.stop_navigation()
        end
        -- Defense 2: when long_path's plan gets consumed without reaching the
        -- goal, navigator.move() can fall through to select_target() and pick an
        -- explorer FRONTIER (is_custom_target=false) — this dragged the bot
        -- 30u BACK from the goal in zewxlog.md. Detect and reclaim immediately.
        if long_path.navigating
            and not navigator.is_custom_target
            and navigator.last_trav == nil
            and navigator.trav_escape_pos == nil
        then
            _vlog('navigator dropped custom target -> explorer frontier; reclaiming')
            long_path.stop_navigation()
            -- This is navigator wandering, not a pathfinder failure — don't
            -- accrue direct_fail_count.
            next_direct_retry = _now() + 0.5
        end
        if not long_path.navigating then
            -- Decide what to do next. Four concave-obstacle signals:
            --   (a) limit_empty / no_path / time_limit  — A* fully blocked.
            --   (b) tiny partial path (plen <= 5)       — A* "found" a path
            --       but it's just 2-3 nodes pointing at the wall. Following
            --       it wedges the bot against unwalkable mesh; the screenshot
            --       (red line) is the exact symptom.
            --   (c) stuck at same distance               — repeated stalls at
            --       roughly the same d-to-target = wedged.
            --   (d) closeness                            — applies all four
            --       triggers only while still close; far-away runs prefer
            --       a fresh direct retry with bigger budget.
            if _now() >= next_direct_retry then
                local cur_d  = utils.distance(pos, target)
                local stat   = long_path.last_status or ''
                local plen   = long_path.last_path_len or 0
                local empty  = (stat == 'no_path' or stat == 'time_limit' or stat == 'iter_limit')
                local tiny   = (stat == 'time_limit_partial' or stat == 'iter_limit_partial'
                                or stat == 'no_path_partial')
                                and plen > 0 and plen <= TINY_PARTIAL_PLEN

                if empty then
                    _direct_empty_count = _direct_empty_count + 1
                else
                    _direct_empty_count = 0
                end
                if tiny then
                    _tiny_partial_count = _tiny_partial_count + 1
                else
                    _tiny_partial_count = 0
                end

                -- "close" gates trav-bridge fallback: when the target is
                -- XY-near, direct routing usually finishes the job. But this
                -- assumption breaks when the target sits across a floor — a
                -- chest down a ladder is XY-close yet unreachable laterally,
                -- and lateral detours just walk us in circles at the player's
                -- elevation. Treat Z-far targets as non-close so the trav
                -- bridge can engage.
                local dz_to_target = math.abs(target:z() - pos:z())
                local z_far = dz_to_target > 5.0
                local close = cur_d <= math.max(best_target_dist * 1.25, 35.0)
                            and not z_far
                local wedged = (_direct_empty_count >= 2)
                            or (_tiny_partial_count >= 3)
                            or (_stall_repeat_count >= 2)

                if wedged and map.cells_count >= 20 then
                    _vlog(string.format(
                        'wedged trigger: empty=%d tiny=%d stall_repeat=%d cur=%.1f best=%.1f dz=%.1f',
                        _direct_empty_count, _tiny_partial_count, _stall_repeat_count,
                        cur_d, best_target_dist, dz_to_target))
                    -- Z-mismatch escape: when the target is on a different
                    -- elevation AND a traversal candidate exists, prefer the
                    -- traversal over a lateral detour. _pick_traversal is a
                    -- pure read against map.traversals (no side effects) so
                    -- it's safe to call as a feasibility check before
                    -- committing to _start_trav_leg.
                    if z_far and _pick_traversal(pos, target) ~= nil then
                        _vlog(string.format(
                            '  z_far (%.1f) with trav candidate -> trav bridge first',
                            dz_to_target))
                        if _start_trav_leg(pos) then
                            _direct_empty_count = 0
                            _tiny_partial_count = 0
                            _stall_repeat_count = 0
                            _stall_at_dist      = nil
                            return
                        end
                    end
                    if _start_detour_leg(pos) then
                        _direct_empty_count = 0
                        _tiny_partial_count = 0
                        _stall_repeat_count = 0
                        _stall_at_dist      = nil
                        return
                    end
                end

                if direct_fail_count < DIRECT_FAIL_MAX or close then
                    _start_direct_leg()
                else
                    _vlog(string.format(
                        'direct exhausted (fail=%d, cur=%.1f, best=%.1f) -> trav bridge',
                        direct_fail_count, cur_d, best_target_dist))
                    _start_trav_leg(pos)
                end
            end
            return
        end
        _drive_navigator()
        if not _check_progress(pos) then
            local cur_d = utils.distance(pos, target)
            _log(string.format('stalled in ROUTING_DIRECT  best=%.1f  cur=%.1f', best_target_dist, cur_d))
            long_path.stop_navigation()

            -- Repeat-stall-at-same-distance detector. If we stall at roughly
            -- the same d-to-target as the previous stall (within 5u band),
            -- we're wedged. Two repeats trips the detour trigger above on
            -- the next retry tick. This catches the screenshot's red-line
            -- case: 2-node partial paths drag the bot onto unwalkable mesh,
            -- stall fires, retry produces the same 2-node path, stall again
            -- at the same distance — without this counter the bot loops
            -- forever.
            if _stall_at_dist and math.abs(cur_d - _stall_at_dist) <= 5.0 then
                _stall_repeat_count = _stall_repeat_count + 1
                _vlog(string.format('repeat stall at dist~%.1f  count=%d', cur_d, _stall_repeat_count))
            else
                _stall_repeat_count = 1
            end
            _stall_at_dist = cur_d

            -- Don't force trav bridge if we're still close to target on the
            -- SAME floor; retry direct with the bigger budget _direct_caps()
            -- gives at short range. But if dz to target is significant, even
            -- a close XY distance can't be closed laterally — push to trav.
            local dz_to_target_s = math.abs(target:z() - pos:z())
            if cur_d > math.max(best_target_dist * 1.5, 50.0)
               or dz_to_target_s > 5.0
            then
                direct_fail_count = DIRECT_FAIL_MAX
            end
            next_direct_retry = _now() + DIRECT_RETRY_COOLDOWN
            -- Reset best so subsequent _check_progress isn't immediately stalled.
            best_target_dist = cur_d
            last_progress_at = _now()
        end
        return
    end

    if state == 'ROUTING_VIA_TRAV' then
        if long_path.navigating and navigator.target == nil then
            long_path.stop_navigation()
        end
        if _leg_reached(pos) then
            _log('trav leg approach reached — clearing leg, awaiting cross / direct retry')
            long_path.stop_navigation()
            current_leg_target = nil
            current_leg_kind   = nil
            -- Navigator's own traversal logic should have engaged the gizmo as
            -- we approached. Give it a moment to cross, then try direct again.
            direct_fail_count = 0
            next_direct_retry = _now() + 1.0
            _set_state('ROUTING_DIRECT', 'post-trav direct retry')
            return
        end
        if not long_path.navigating then
            -- Trav leg path got consumed before we reached the approach.
            -- Pick a different traversal.
            trav_fail_count = trav_fail_count + 1
            if trav_fail_count >= TRAV_FAIL_MAX then
                _set_state('FAILED', 'trav leg attempts exhausted')
                return
            end
            _start_trav_leg(pos)
            return
        end
        _drive_navigator()
        return
    end

    if state == 'ROUTING_DETOUR' then
        -- Defense 0 (same as ROUTING_DIRECT): if long_path.navigating but
        -- navigator.path emptied, stop so long_nav handles the transition
        -- rather than letting navigator do 70ms-cap mini-replans.
        if long_path.navigating and #navigator.path == 0 and navigator.target ~= nil then
            _vlog('detour: long_path path consumed -> stopping for long_nav transition')
            long_path.stop_navigation()
        end
        -- Same explorer-takeover defense as the other routing states.
        if long_path.navigating and navigator.target == nil then
            long_path.stop_navigation()
        end
        if long_path.navigating
            and not navigator.is_custom_target
            and navigator.last_trav == nil
            and navigator.trav_escape_pos == nil
        then
            _vlog('navigator dropped detour target -> explorer; reclaiming via direct retry')
            long_path.stop_navigation()
        end

        if _leg_reached(pos) then
            local cur_d_to_target = utils.distance(pos, target)
            -- Did this detour actually unblock anything? Compare against the
            -- best_target_dist captured when the detour started. If we never
            -- got closer than that during/after the detour, the detour was
            -- useless. Two useless detours in a row -> FAIL (no point looping
            -- through the same dead-end area; the zewxlog SeersReach run
            -- did exactly this for 100+s).
            local useful = false
            if _detour_pre_dist ~= nil and cur_d_to_target < _detour_pre_dist - 2.0 then
                useful = true
            end
            if useful then
                _detour_useless_streak = 0
                _vlog(string.format(
                    'detour leg reached: USEFUL  pre=%.1f  cur=%.1f  Δ=%.1f',
                    _detour_pre_dist or -1, cur_d_to_target,
                    (_detour_pre_dist or 0) - cur_d_to_target))
            else
                _detour_useless_streak = _detour_useless_streak + 1
                _vlog(string.format(
                    'detour leg reached: USELESS streak=%d  pre=%.1f  cur=%.1f',
                    _detour_useless_streak, _detour_pre_dist or -1, cur_d_to_target))
            end
            _log(string.format('detour leg reached  cur_d_to_target=%.1f  best=%.1f',
                cur_d_to_target, best_target_dist))
            long_path.stop_navigation()
            current_leg_target = nil
            current_leg_kind   = nil

            if _detour_useless_streak >= DETOUR_USELESS_MAX then
                _vlog(string.format('detour useless streak hit %d -> FAILED', DETOUR_USELESS_MAX))
                _set_state('FAILED', 'detours not unblocking direct')
                return
            end

            -- After a useful detour the player is at a new vantage. Reset
            -- direct failure tracking and let _check_progress restart from
            -- this point.
            direct_fail_count    = 0
            _direct_empty_count  = 0
            best_target_dist     = cur_d_to_target
            last_progress_at     = _now()
            next_direct_retry    = _now() + 0.3
            _set_state('ROUTING_DIRECT', 'post-detour retry')
            return
        end

        if not long_path.navigating then
            -- Detour path consumed without reaching the waypoint. Try a
            -- different detour cell, or fall back to direct (which may have
            -- become viable since we moved).
            _vlog('detour leg path exhausted before reaching waypoint')
            current_leg_target = nil
            current_leg_kind   = nil
            -- Don't loop on detours forever. Cap roughly at 5 within a run.
            local detour_count = 0
            for _ in pairs(_visited_detours) do detour_count = detour_count + 1 end
            if detour_count >= 5 then
                _vlog('detour cap reached, returning to direct')
                next_direct_retry = _now() + 0.3
                _set_state('ROUTING_DIRECT', 'detour cap')
            else
                if not _start_detour_leg(pos) then
                    next_direct_retry = _now() + 0.3
                    _set_state('ROUTING_DIRECT', 'detour pick failed')
                end
            end
            return
        end

        _drive_navigator()
        return
    end
end

-- One-line status for GUI display.
function long_nav.status_string()
    if state == 'IDLE' then return 'idle' end
    if not target then return state end
    local p = get_local_player() and get_local_player():get_position()
    if not p then return state end
    return string.format('%s  d=%.1f  dz=%.1f  best=%.1f  fails=d%d/t%d',
        state, utils.distance(p, target), math.abs(target:z() - p:z()),
        best_target_dist, direct_fail_count, trav_fail_count)
end

return long_nav
