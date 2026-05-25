local plugin_label = 'batmobile'

local gui          = require 'gui'
local settings     = require 'core.settings'
local external     = require 'core.external'
local drawing      = require 'core.drawing'
local utils        = require 'core.utils'
local tracker      = require 'core.tracker'
local navigator    = require 'core.navigator'
local long_path    = require 'core.long_path'
local long_nav     = require 'core.long_nav'
local map          = require 'core.map'
local test_targets = require 'core.test_targets'
local mhelp        = require 'core.movement_helpers'
local mvr_profile  = require 'core.mvr_profile'

-- Load saved profile on script start (reads manifest + active profile from disk).
mvr_profile.init()

-- Safely calls :set() on any widget (mirrors UR's _set_element pattern).
local function _set_el(el, val)
    if not el or val == nil then return end
    if type(el.set) == 'function' then pcall(el.set, el, val) end
end

local local_player
local debounce_time = nil
local debounce_timeout = 1
local draw_keybind_data = checkbox:new(false, get_hash(plugin_label .. '_draw_keybind_data'))
if PERSISTENT_MODE ~= nil and PERSISTENT_MODE ~= false then
    gui.elements.draw_keybind_toggle:set(draw_keybind_data:get())
end

local function update_locals()
    local_player = get_local_player()
    if local_player then
        mhelp.observe_buffs(local_player)
    end
end

local function main_pulse()
    -- Profile system: mirrors UR's handle_profile_io pattern.
    -- gui is a direct top-level local here (not require'd inside a handler),
    -- which is why button clicks register reliably — same as UR.
    gui.profile_names  = mvr_profile.get_profile_names()
    gui.active_profile = mvr_profile.get_active_profile()

    if gui.elements.new_profile and gui.elements.new_profile:get() then
        mvr_profile.create_new()
        _set_el(gui.elements.profile_combo, mvr_profile.get_active_index())
        gui.elements.new_profile:set(false)
    end

    if gui.elements.delete_profile and gui.elements.delete_profile:get() then
        mvr_profile.delete()
        _set_el(gui.elements.profile_combo, mvr_profile.get_active_index())
        gui.elements.delete_profile:set(false)
    end

    if gui.elements.profile_rename_btn and gui.elements.profile_rename_btn:get() then
        gui.elements.profile_rename_btn:set(false)
        local rename_el = gui.elements.profile_rename
        local new_name = ''
        if rename_el and type(rename_el.get) == 'function' then
            local ok, v = pcall(rename_el.get, rename_el)
            if ok and type(v) == 'string' then new_name = v end
        end
        if new_name ~= '' then
            mvr_profile.rename(new_name)
            _set_el(gui.elements.profile_combo, mvr_profile.get_active_index())
        end
    end

    mvr_profile.handle_io()  -- combo switching + autosave

    if utils.player_loading() then
        -- extend last_update so unstuck doesn't fire right after loading
        navigator.last_update = get_time_since_inject() + 5
        return
    end
    settings:update_settings()
    if PERSISTENT_MODE ~= nil and PERSISTENT_MODE ~= false  then
        if draw_keybind_data:get() ~= (gui.elements.draw_keybind_toggle:get_state() == 1) then
            draw_keybind_data:set(gui.elements.draw_keybind_toggle:get_state() == 1)
        end
    end
    if gui.elements.reset_keybind:get_state() == 1 then
        if debounce_time ~= nil and debounce_time + debounce_timeout > get_time_since_inject() then return end
        gui.elements.reset_keybind:set(false)
        debounce_time = get_time_since_inject()
        long_nav.stop('reset_keybind')
        navigator.reset()
        map.reset()
    end
    -- Emergency hard-stop for the Whirlwind channel. Bypasses every gate;
    -- yanks the channel from the engine directly. For debug / unsticking.
    if gui.elements.whirlwind_force_stop_keybind:get_state() == 1 then
        gui.elements.whirlwind_force_stop_keybind:set(false)
        if navigator.whirlwind_force_stop then
            navigator.whirlwind_force_stop()
        end
    end
    if gui.elements.long_path_set_target:get_state() == 1 then
        gui.elements.long_path_set_target:set(false)
        long_path.set_target()
        if long_path.pinned_target then
            local p = long_path.pinned_target
            gui.long_path_target_str = string.format("(%.1f, %.1f, %.1f)", p:x(), p:y(), p:z())
        end
    end
    if gui.elements.long_path_set_target_cursor:get_state() == 1 then
        gui.elements.long_path_set_target_cursor:set(false)
        long_path.set_target_cursor()
        if long_path.pinned_target then
            local p = long_path.pinned_target
            gui.long_path_target_str = string.format("(%.1f, %.1f, %.1f) [cursor]", p:x(), p:y(), p:z())
        end
    end
    if gui.elements.long_path_test:get_state() == 1 then
        gui.elements.long_path_test:set(false)
        if long_nav.is_navigating() then
            long_nav.stop('debug_button')
        else
            -- Resolve the test target: combo selection wins, else fall back to
            -- the pinned target. Lets the user pick a known waypoint (maiden
            -- altar etc.) without having to physically walk there to pin it.
            local combo_idx  = gui.elements.test_target_combo:get() or 0
            local preset     = test_targets.entry_at(combo_idx)
            local target_pos = preset and preset.pos or long_path.pinned_target
            if preset then
                console.print(string.format('[BATMOBILE] preset target: %s  zone=%s', preset.label, preset.zone))
            end
            if target_pos then
                long_nav.navigate('debug_button', target_pos)
            else
                console.print('[BATMOBILE] No target — pick a preset or pin one with Set Target')
            end
        end
    end
    if gui.elements.clear_map_keybind:get_state() == 1 then
        gui.elements.clear_map_keybind:set(false)
        map.reset()
    end
    -- Keep GUI state in sync
    gui.long_path_navigating = long_nav.is_navigating() or long_path.navigating
    gui.frigate_map_stats    = map.stats_string()
    gui.frigate_status_str   = long_nav.status_string()
    -- Map sampling: per-tick observation of player position + nearby traversals.
    -- Always-on so the map grows continuously while the player is in motion,
    -- regardless of whether long_nav is driving.
    if local_player and not local_player:is_dead() then
        map.observe(local_player)
    end
    -- Long-nav loop: orchestrator-driven. Runs when navigate() has been called
    -- (from the debug button or a plugin caller). long_nav.tick drives the
    -- navigator internally.
    if long_nav.is_navigating() then
        if not local_player or local_player:is_dead() then
            long_nav.stop('player_dead')
        else
            long_nav.tick(local_player)
        end
        return
    end
    -- Low-level long_path: drive navigator for callers that pushed a path
    -- directly (e.g. BatmobilePlugin.navigate_long_path). Skip if long_nav
    -- owns the run (handled above).
    if long_path.navigating then
        if not local_player or local_player:is_dead() then
            long_path.stop_navigation()
        else
            local cur = utils.normalize_node(local_player:get_position())
            -- Reached target: navigator consumed the path and is at the goal
            if navigator.target ~= nil and utils.distance(cur, navigator.target) <= 1 then
                console.print("[LONG PATH] Reached target!")
                long_path.navigating  = false
                long_path.active_path = nil
                navigator.clear_target()
            elseif navigator.target == nil and #navigator.path == 0 then
                console.print("[LONG PATH] Navigation complete")
                long_path.navigating  = false
                long_path.active_path = nil
            else
                navigator.unpause()
                local start_update = os.clock()
                navigator.update()
                tracker.timer_update = os.clock() - start_update
                local start_move = os.clock()
                navigator.move()
                tracker.timer_move = os.clock() - start_move
                -- Detect: move() caused the navigator to switch from a custom long-path
                -- target to an explorer (non-custom) frontier. This happens when the
                -- pre-computed path nodes are consumed and the player is within 1 unit of
                -- the approach node. Guard on last_trav/trav_escape_pos to avoid false
                -- positives during traversal routing (z_frontier sets is_custom_target=false).
                if long_path.navigating
                    and navigator.target ~= nil
                    and not navigator.is_custom_target
                    and navigator.last_trav == nil
                    and navigator.trav_escape_pos == nil
                then
                    console.print('[LONG PATH] navigator selected explorer target during long path — stopping so caller can repath')
                    long_path.navigating  = false
                    long_path.active_path = nil
                    navigator.clear_target()
                end
            end
        end
    end
    if gui.elements.freeroam_keybind_toggle:get_state() == 1 then
        if local_player:is_dead() then
            revive_at_checkpoint()
        end
        navigator.unpause()
        local start_update = os.clock()
        navigator.update()
        tracker.timer_update = os.clock() - start_update
        local start_move = os.clock()
        navigator.move()
        tracker.timer_move = os.clock() - start_move
    end
    -- Run unconditionally so the Whirlwind channel is torn down even when no
    -- navigation driver is active (freeroam off, long_path idle, plugin
    -- disabled via use_movement). Otherwise the engine keeps casting at the
    -- long finish horizon and the bot whirlwinds in place forever.
    if navigator.whirlwind_idle_teardown then
        navigator.whirlwind_idle_teardown(local_player)
    end
end

local function render_pulse()
    if not local_player then return end
    if not settings.draw then return end
    drawing.draw_nodes(local_player)
end

on_update(function()
    update_locals()
    main_pulse()
end)

on_render_menu(function ()
    gui.render()
end)
on_render(render_pulse)
BatmobilePlugin = external

external.enable_movement = function(caller)
    if caller == nil then
        utils.log(2, 'enable_movement called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'enable_movement called by ' .. tostring(caller))
    gui.elements.move_keybind_toggle:set(true)
end
external.disable_movement = function(caller)
    if caller == nil then
        utils.log(2, 'disable_movement called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'disable_movement called by ' .. tostring(caller))
    gui.elements.move_keybind_toggle:set(false)
end
external.get_movement_enabled = function()
    return gui.elements.move_keybind_toggle:get()
end
