local plugin_label = 'batmobile'
-- kept plugin label instead of waiting for update_tracker to set it
local navigator  = require 'core.navigator'
local explorer   = require 'core.explorer'
local tracker    = require 'core.tracker'
local utils      = require 'core.utils'
local long_path  = require 'core.long_path'
local pathfinder = require 'core.pathfinder'

local external = {
    name          = plugin_label
}
external.is_done = function ()
    return navigator.is_done()
end
external.is_paused = function ()
    return navigator.paused
end
external.pause = function (caller)
    if caller == nil then
        utils.log(2,'pause called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'pause called by ' .. tostring(caller))
    navigator.pause()
end
external.resume = function (caller)
    if caller == nil then
        utils.log(2,'resume called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'resume called by ' .. tostring(caller))
    navigator.unpause()
end
external.reset = function (caller)
    if caller == nil then
        utils.log(2,'reset called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'reset called by ' .. tostring(caller))
    navigator.reset()
end
-- reset_movement: clears movement/pathfinding state only; exploration history
-- (visited, backtrack, frontier) is preserved.  Use for mid-session interruptions.
external.reset_movement = function (caller)
    if caller == nil then
        utils.log(2,'reset_movement called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'reset_movement called by ' .. tostring(caller))
    navigator.reset_movement()
end
external.move = function (caller)
    if caller == nil then
        utils.log(2,'move called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'move called by ' .. tostring(caller))
    tracker.bench_start("total_move")
    local start_move = os.clock()
    navigator.move()
    tracker.timer_move = os.clock() - start_move
    tracker.bench_stop("total_move")
    tracker.bench_report()
end
external.update = function (caller)
    if caller == nil then
        utils.log(2,'update called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'update called by ' .. tostring(caller))
    tracker.bench_start("total_update")
    local start_update = os.clock()
    navigator.update()
    tracker.timer_update = os.clock() - start_update
    tracker.bench_stop("total_update")
end
external.set_target = function(caller, target, disable_spell)
    if caller == nil then
        utils.log(2,'set_target called with no caller')
        return false
    end
    tracker.external_caller = caller
    utils.log(2, 'set_target called by ' .. tostring(caller))
    return navigator.set_target(target, disable_spell)
end
external.clear_target = function (caller)
    if caller == nil then
        utils.log(2,'clear_target called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'clear_target called by ' .. tostring(caller))
    navigator.clear_target()
end
external.get_backtrack = function(caller)
    if caller == nil then
        utils.log(2,'get_backtrack called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'get_backtrack called by ' .. tostring(caller))
    return explorer.backtrack
end
external.set_priority = function(caller, priority)
    if caller == nil then
        utils.log(2,'set_priority called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'set_priority called by ' .. tostring(caller) .. ' to priortize ' .. tostring(priority))
    explorer.set_priority(priority)
end

-- Find a path without normal distance-scaled caps.
-- Returns path (array of vec3 nodes) or nil on failure.
-- Prints a result line to console automatically.
external.find_long_path = function(caller, target)
    if caller == nil then
        utils.log(2, 'find_long_path called with no caller')
        return nil
    end
    tracker.external_caller = caller
    utils.log(2, 'find_long_path called by ' .. tostring(caller))
    local player = get_local_player()
    if not player then return nil end
    local start = player:get_position()
    return long_path.find_long_path(start, target)
end

-- Find an uncapped path to target and immediately start walking it.
-- Returns true if path was found and navigation started, false otherwise.
external.navigate_long_path = function(caller, target)
    if caller == nil then
        utils.log(2, 'navigate_long_path called with no caller')
        return false
    end
    tracker.external_caller = caller
    utils.log(2, 'navigate_long_path called by ' .. tostring(caller))
    return long_path.navigate_to(target)
end

-- True while long path navigation is actively driving the navigator.
-- Auto-stops (returns false) when the navigator's target was cleared
-- externally (e.g. post-traversal-cross in attempt_escape) while navigating
-- was still true — this leaves navigator.target=nil every frame and the
-- caller stalls because it trusts this flag as "still in progress". Clearing
-- the flag lets callers retry navigate_long_path immediately.
external.is_long_path_navigating = function()
    if long_path.navigating and navigator.target == nil then
        console.print('[LONG PATH] target cleared externally while navigating — auto-stopping so caller can repath')
        long_path.stop_navigation()
        return false
    end
    return long_path.navigating
end

-- Find a walkable, reachable approach node within max_dist of target.
-- Used by callers that need to path to an actor whose mesh sits on a non-walkable tile
-- (e.g. portals, gizmos). Returns vec3 of an approach node, or nil if nothing reachable.
external.get_closeby_node = function(caller, target, max_dist)
    if caller == nil then
        utils.log(2, 'get_closeby_node called with no caller')
        return nil
    end
    tracker.external_caller = caller
    if target == nil then return nil end
    if target.get_position then target = target:get_position() end
    return navigator.get_closeby_node(target, max_dist or 3)
end

-- Engage traversal routing if a usable Traversal_Gizmo is within 30 units.
-- Returns true if a traversal was engaged (caller should yield to nav until
-- crossing completes), false otherwise. Sets navigator.last_trav internally,
-- so subsequent BatmobilePlugin.update + move calls drive the crossing.
external.try_traversal_route = function(caller)
    if caller == nil then
        utils.log(2, 'try_traversal_route called with no caller')
        return false
    end
    tracker.external_caller = caller
    local local_player = get_local_player()
    if local_player == nil then return false end
    local routed = navigator.try_traversal_route(local_player, local_player:get_position())
    return routed and true or false
end

-- Returns true while navigator is mid-traversal-crossing (last_trav set).
-- cross_traversal task uses this to keep priority until the crossing finishes.
external.is_traversal_routing = function()
    return navigator.last_trav ~= nil
end

-- Stop long path navigation and clear the navigator target.
external.stop_long_path = function(caller)
    if caller == nil then
        utils.log(2, 'stop_long_path called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'stop_long_path called by ' .. tostring(caller))
    long_path.stop_navigation()
end

-- Returns the navigator's current target (vec3 or nil).
external.get_target = function()
    return navigator.target
end

-- Returns the navigator's current path (array of vec3, may be empty).
external.get_path = function()
    return navigator.path
end

-- Returns a snapshot of the most recent find_path call:
--   { call_id, status, plen, goal_x, goal_y }
-- call_id is monotonic — callers can detect "is this a new pathfind since I
-- last looked?" by comparing against a remembered id. Used by HR's remembered-
-- chest micro-partial detector to spot consistent A* failure on the same goal.
external.get_last_pathfind = function()
    return pathfinder.last_pathfind
end

-- Clear the traversal blacklist and failed-target state so previously crossed
-- traversals can be selected again.  Call this when the player is stuck on a
-- platform after a traversal and normal exploration has stalled.
external.clear_traversal_blacklist = function(caller)
    if caller == nil then
        utils.log(2, 'clear_traversal_blacklist called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'clear_traversal_blacklist called by ' .. tostring(caller))
    navigator.blacklisted_trav      = {}
    navigator.trav_delay            = nil
    navigator.failed_target         = nil
    navigator.failed_target_time    = -1
    navigator.failed_target_radius  = 15
end

-- Trap-recovery query.  Returns true once the navigator has been stuck in a
-- small bbox for TRAP_GIVEUP_TIMEOUT (60s) without escaping.  Calling plugin
-- (HelltideRevamped) should teleport the player away and call clear_giving_up
-- to reset the state for the new zone.
external.is_giving_up = function()
    return navigator.giving_up
end

-- Returns true while the navigator is actively running its escape routine
-- (cleared in-zone frontiers, routing to a traversal).  HR can use this to
-- avoid issuing competing set_target calls during recovery.
external.is_trapped = function()
    return navigator.trapped
end

-- Resets all trap-detection state (sample history, escape counter, giving_up
-- flag).  Call this after teleporting / leaving the trapped area so the next
-- zone starts with a fresh sliding window.
external.clear_giving_up = function(caller)
    if caller == nil then
        utils.log(2, 'clear_giving_up called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'clear_giving_up called by ' .. tostring(caller))
    navigator.clear_trap_state()
end

return external