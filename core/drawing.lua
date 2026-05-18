local explorer  = require 'core.explorer'
local navigator = require 'core.navigator'
local settings  = require 'core.settings'
local utils     = require 'core.utils'
local tracker   = require 'core.tracker'
local long_path = require 'core.long_path'

-- Nav viz: live walkable-grid scan state
local nav_viz_cache    = {}   -- array of {pos=vec3, walkable=bool}
local nav_viz_last     = -1
local NAV_VIZ_INTERVAL = 0.3  -- seconds between rescans
local NAV_VIZ_RADIUS   = 5.0  -- half-extent in game units around player

-- Frontier marker cache: rebuilt only when the player moves >1 unit or the
-- frontier table size changes. Avoids iterating frontier_node every render
-- frame at 60Hz × ~100 frontiers = 6000+ distance checks/sec.
local frontier_draw_cache = {}    -- array of vec3 (already z-fixed)
local frontier_draw_pos = nil     -- last player pos at cache build
local frontier_draw_count = -1    -- last frontier_count at cache build

local function refresh_nav_viz(player_pos, valid_z)
    local step = settings.step
    local cx   = utils.normalize_value(player_pos:x())
    local cy   = utils.normalize_value(player_pos:y())
    local cache = {}
    local x = cx - NAV_VIZ_RADIUS
    while x <= cx + NAV_VIZ_RADIUS do
        local y = cy - NAV_VIZ_RADIUS
        while y <= cy + NAV_VIZ_RADIUS do
            local raw = vec3:new(x, y, valid_z)
            local n   = utils.get_valid_node(raw, valid_z)
            cache[#cache + 1] = { pos = raw, walkable = (n ~= nil) }
            y = y + step
        end
        x = x + step
    end
    nav_viz_cache = cache
    nav_viz_last  = os.clock()
end

local get_max_length = function(messages)
    local max = 0
    for _, msg in ipairs(messages) do
        if #msg > max then max = #msg end
    end
    return max
end
local drawing = {}

drawing.draw_nodes = function (local_player)
    local start_draw = os.clock()
    local max_dist = 50

    local visited_count = explorer.visited_count
    local frontier_count = explorer.frontier_count
    local backtrack = explorer.backtrack
    local retry_count = explorer.retry_count

    local player_pos = local_player:get_position()
    local valid_z = player_pos:z()
    local cur_node = utils.normalize_node(player_pos)
    local path = navigator.path
    local counter = 0

    -- Frontier markers: green dots at every active frontier within draw range.
    -- Same toggle as the yellow backtrack line (settings.draw, gated in main.lua).
    -- Cached: rebuild only when player moves >1 unit or frontier count changes.
    if frontier_draw_pos == nil
        or utils.distance(cur_node, frontier_draw_pos) > 1
        or frontier_draw_count ~= frontier_count
    then
        frontier_draw_cache = {}
        for _, fnode in pairs(explorer.frontier_node) do
            if utils.distance(cur_node, fnode) <= max_dist then
                frontier_draw_cache[#frontier_draw_cache + 1] =
                    vec3:new(fnode:x(), fnode:y(), valid_z)
            end
        end
        frontier_draw_pos = cur_node
        frontier_draw_count = frontier_count
    end
    if settings.draw_frontiers then
        for _, v in ipairs(frontier_draw_cache) do
            graphics.circle_3d(v, 0.15, color_green(255))
        end
    end
    -- local perimeter = explorer.get_perimeter(cur_node)
    -- for _, node in pairs(perimeter) do
    --     local valid = vec3:new(node:x(), node:y(), valid_z)
    --     -- valid = utility.set_height_of_valid_position(node)
    --     if utils.distance(cur_node, node) <= max_dist then
    --         graphics.circle_3d(valid, 0.05, color_blue(255))
    --     end
    -- end
    local prev_node = nil
    for index = #backtrack, 1, -1 do
        local node = backtrack[index]
        if utils.distance(cur_node, node) <= max_dist then
            local valid = vec3:new(node:x(), node:y(), valid_z)
            graphics.circle_3d(valid, 0.05, color_yellow(255))
            if prev_node ~= nil then
                graphics.line(valid, prev_node, color_yellow(255), 1)
            else
                graphics.line(player_pos, valid, color_yellow(255), 1)
            end
            prev_node = valid
        end
    end
    prev_node = nil
    for _, node in pairs(path) do
        local valid = vec3:new(node:x(), node:y(), valid_z)
        if utils.distance(cur_node, node) <= max_dist then
            graphics.circle_3d(valid, 0.05, color_red(255))
            if prev_node ~= nil then
                graphics.line(valid, prev_node, color_red(255), 1)
            else
                graphics.line(player_pos, valid, color_red(255), 1)
            end
            prev_node = valid
        end
    end

    for node_str, result in pairs(tracker.evaluated) do
        local node = utils.string_to_vec(node_str)
        local valid_node = vec3:new(node:x(), node:y(), valid_z)
        if result ~= nil and result[1] then
            graphics.circle_3d(valid_node, 0.05, color_green(255))
        else
            graphics.circle_3d(valid_node, 0.05, color_blue(255))
        end
    end

    -- Nav viz: live walkable-grid + key navigator vectors
    -- Navigator target: always visible when draw is on (not gated by nav_viz).
    -- Large circle + line so it's visible even when the target is far away.
    if navigator.target then
        local v = vec3:new(navigator.target:x(), navigator.target:y(), valid_z)
        graphics.circle_3d(v, 2.0, color_white(255))
        graphics.line(player_pos, v, color_white(200), 2)
        -- 2D HUD text: direction + distance so target is readable off-screen
        local tv2 = graphics.w2s(v)
        if tv2 then
            local dist = utils.distance(player_pos, v)
            graphics.text_2d(string.format('TARGET %.0fu', dist), tv2, 18, color_white(220))
        end
    end
    -- Failed target + block radius ring (yellow) — always visible
    if navigator.failed_target then
        local v = vec3:new(navigator.failed_target:x(), navigator.failed_target:y(), valid_z)
        graphics.circle_3d(v, 1.5, color_yellow(255))
        graphics.circle_3d(v, navigator.failed_target_radius or 15, color_yellow(60))
    end

    if settings.nav_viz then
        if os.clock() - nav_viz_last >= NAV_VIZ_INTERVAL then
            refresh_nav_viz(player_pos, valid_z)
        end
        for _, entry in ipairs(nav_viz_cache) do
            local v = vec3:new(entry.pos:x(), entry.pos:y(), valid_z)
            if entry.walkable then
                graphics.circle_3d(v, 0.12, color_green(160))
            else
                graphics.circle_3d(v, 0.10, color_red(80))
            end
        end
        -- Traversal approach node (blue)
        if navigator.last_trav then
            local v = vec3:new(navigator.last_trav:x(), navigator.last_trav:y(), valid_z)
            graphics.circle_3d(v, 0.5, color_blue(255))
            graphics.line(player_pos, v, color_blue(180), 1)
        end
        -- Saved post-traversal enemy target (green, large)
        if navigator.trav_final_target then
            local v = vec3:new(navigator.trav_final_target:x(), navigator.trav_final_target:y(), valid_z)
            graphics.circle_3d(v, 0.5, color_green(255))
            graphics.line(player_pos, v, color_green(180), 1)
        end
    end

    -- Long path: draw full planned route in white, target as large circle
    if long_path.active_path ~= nil then
        local lp_prev = nil
        for i, node in ipairs(long_path.active_path) do
            -- Downsample for performance: draw every 4th node, always draw first/last
            if i == 1 or i == #long_path.active_path or i % 4 == 0 then
                local v = vec3:new(node:x(), node:y(), valid_z)
                graphics.circle_3d(v, 0.15, color_white(180))
                if lp_prev ~= nil then
                    graphics.line(v, lp_prev, color_white(180), 1)
                end
                lp_prev = v
            end
        end
    end
    -- Draw pinned target as a large bright circle with a line from player
    if long_path.pinned_target ~= nil then
        local tv = utility.set_height_of_valid_position(long_path.pinned_target)
        graphics.circle_3d(tv, 3, color_white(255))
        graphics.line(player_pos, tv, color_white(200), 1)
    end

    if tracker.debug_pos ~= nil then
        local valid = utility.set_height_of_valid_position(tracker.debug_pos)
        graphics.circle_3d(valid, 5, color_white(255))
        graphics.line(player_pos, valid, color_white(255), 1)
    end
    if tracker.debug_node ~= nil then
        local valid = vec3:new(tracker.debug_node:x(),tracker.debug_node:y(), valid_z)
        graphics.circle_3d(valid, 5, color_white(255))
        graphics.line(player_pos, valid, color_white(255), 1)
    end
    if tracker.debug_actor ~= nil then
        local valid = tracker.debug_actor:get_position()
        graphics.circle_3d(valid, 5, color_white(255))
        graphics.line(player_pos, valid, color_white(255), 1)
    end

    local in_combat =  utils.in_combat(local_player)
    local is_cced = utils.is_cced(local_player)
    local speed = local_player:get_current_speed()
    local speed_str = string.format("%.3f",local_player:get_current_speed())
    if speed < 10 then
        speed_str = speed_str .. '  '
    elseif speed < 100 then
        speed_str = speed_str .. ' '
    end
    local messages_left = {
        ' Speed     ' .. speed_str,
        ' Path      ' .. tostring(#path),
        ' Visited   ' .. tostring(visited_count),
        ' Frontier  ' .. tostring(frontier_count),
        ' Backtrack ' .. tostring(#backtrack),
        ' Retry     ' .. tostring(retry_count),
    }
    local messages_right = {
        ' Movespell ' .. tostring(settings.use_movement),
        ' In_combat ' .. tostring(in_combat),
        ' Is_cc\'ed  ' .. tostring(is_cced),
        ' U_time    ' .. string.format("%.3f",tracker.timer_update),
        ' M_time    ' .. string.format("%.3f",tracker.timer_move),
    }
    local max_left = get_max_length(messages_left)
    local max_right = get_max_length(messages_right)
    local x_pos = get_screen_width() - 20 - (max_left * 11) - (max_right * 11)
    local y_pos = get_screen_height() - 20 - (#messages_left * 20)
    for _, msg in ipairs(messages_left) do
        graphics.text_2d(msg, vec2:new(x_pos, y_pos), 20, color_white(255))
        y_pos = y_pos + 20
    end
    x_pos = get_screen_width() - 20 - (max_right * 11)
    y_pos = get_screen_height() - 40 - (#messages_right * 20)
    for _, msg in ipairs(messages_right) do
        graphics.text_2d(msg, vec2:new(x_pos, y_pos), 20, color_white(255))
        y_pos = y_pos + 20
    end
    tracker.timer_draw = os.clock() - start_draw
    local msg = ' D_time    ' .. string.format("%.3f",tracker.timer_draw)
    graphics.text_2d(msg, vec2:new(x_pos, y_pos), 20, color_white(255))
    -- collectgarbage("collect")
end

return drawing
