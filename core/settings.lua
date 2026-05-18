local gui   = require 'gui'
local mrul  = require 'core.movement_rules'
local mhelp = require 'core.movement_helpers'

local settings = {
    plugin_label = gui.plugin_label,
    plugin_version = gui.plugin_version,
    draw = false,
    step = 0.5,
    normalizer = 2, -- *10/5 to get steps of 0.5
    use_movement = false,
    use_evade = false,
    use_teleport = false,
    use_teleport_enchanted = false,
    use_dash = false,
    use_soar = false,
    use_hunter = false,
    use_leap = false,
    use_charge = false,
    use_whirlwind = false,
    use_advance = false,
    use_falling_star = false,
    use_aoj = false,
    use_wraith_step = false,
    use_demonic_slash = false,
    demonic_slash_los = false,
    min_spell_dist = 3.0,
    prefer_long_paths = false,
    long_path_threshold = 20.0,
    log_level = gui.log_levels_enum['INFO'],
    nav_viz = false,
    debug_logs = false,
    require_full_path_explore = true,
    explore_path_budget_ms = 30,
    path_smooth_step = 1.0,
    wall_path = true,
    wall_path_dist = 4.0,
    frontier_max_dist = 40,
    enable_z_frontier = false,
    -- Frigate long-nav
    frigate_spiral_radius        = 60.0,
    frigate_spiral_step          = 12.0,
    frigate_spiral_around_target = true,
    frigate_z_variance_tolerance = 120.0,
    frigate_draw_map             = true,
    -- Frigate test / observability
    frigate_verbose_logging         = true,
    frigate_verbose_status_interval = 2.0,
    frigate_draw_map_cells          = true,
    frigate_draw_map_traversals     = true,
    frigate_draw_spiral             = true,
    frigate_draw_state_hud          = true,
    frigate_draw_target_pin         = true,
    frigate_map_draw_radius         = 60.0,
    frigate_map_cell_alpha          = 120,
    move_spell_pause_after_target = 0.0,
    pause_weight_elite     = 2,
    pause_weight_champion  = 1,
    pause_weight_goblin    = 3,
    pause_weight_threshold = 120,
    pause_floor_reset_jump = 300,
    -- Movement revamp
    movement_revamp = false,
    movement_rules  = {},   -- rebuilt each tick from widget state
}

-- Read a single rule slot's widget state into a plain rule table.
local function _read_rule(slot)
    local rw = gui.elements.mvr_rule_widgets and gui.elements.mvr_rule_widgets[slot]
    if not rw then return nil end
    local rule = {
        enabled         = rw.enabled:get(),
        skill_id        = 0,
        cast_position   = 'next_node',
        density_radius  = rw.density_radius:get(),
        throttle_ms     = rw.throttle_ms:get(),
        conditions      = {},
    }
    -- combo_box:get() is 0-indexed. items[1] = "(none)" therefore idx 0 = none,
    -- idx N>=1 = the N-th catalog entry.
    local skill_idx = rw.skill:get() or 0
    if skill_idx > 0 then
        local cat = mrul.skill_catalog[skill_idx]
        if cat then rule.skill_id = cat.id end
    end
    local cp_idx = rw.cast_position:get() or 0
    local cp_entry = mrul.cast_positions[cp_idx + 1]
    if cp_entry then rule.cast_position = cp_entry.key end
    -- Conditions
    local active_count = rw.active_cond_count:get() or 0
    if active_count > mrul.MAX_CONDITIONS_PER_RULE then
        active_count = mrul.MAX_CONDITIONS_PER_RULE
    end
    for c = 1, active_count do
        local cw = rw.cond_widgets[c]
        if cw then
            -- combo_box values are all 0-indexed. Items arrays are 1-indexed
            -- in Lua, so we add 1 when looking them up.
            local type_idx = (cw.type:get() or 0) + 1
            local type_key = (mrul.condition_types[type_idx] or { key = 'none' }).key
            local op_idx   = (cw.op:get() or 0) + 1
            -- Buff hash resolution (UR pattern): the explicit slider wins
            -- when set; else fall back to the combo's current selection
            -- mapped through the grow-only catalog. Combo index is clamped
            -- to the catalog length as a defensive guard.
            local buff_hash = cw.buff_hash:get() or 0
            if buff_hash == 0 then
                local bc_idx = cw.buff_combo:get() or 0
                local catalog_len = #mhelp.known_buffs_ordered
                if bc_idx > catalog_len then bc_idx = catalog_len end
                if bc_idx < 0 then bc_idx = 0 end
                buff_hash = mhelp.buff_hash_for_combo_index(bc_idx) or 0
            end
            local cond = {
                combinator = (cw.combinator:get() == 1) and 'OR' or 'AND',
                type       = type_key,
                op         = mrul.ops[op_idx] or '<',
                value      = cw.value:get() or 0,
                buff_hash  = buff_hash,
                radius     = cw.radius:get() or 6,
            }
            rule.conditions[#rule.conditions + 1] = cond
        end
    end
    return rule
end

local function _read_all_rules()
    if not gui.elements.mvr_active_rule_count then return {} end
    local n = gui.elements.mvr_active_rule_count:get() or 0
    if n > mrul.MAX_RULES then n = mrul.MAX_RULES end
    local out = {}
    for i = 1, n do
        local r = _read_rule(i)
        if r then out[#out + 1] = r end
    end
    return out
end

settings.update_settings = function ()
    settings.draw = gui.elements.draw_keybind_toggle:get_state() == 1
    settings.use_movement = gui.elements.move_keybind_toggle:get()
    settings.use_evade = gui.elements.use_evade:get()
    settings.use_teleport = gui.elements.use_teleport:get()
    settings.use_teleport_enchanted = gui.elements.use_teleport_enchanted:get()
    settings.use_dash = gui.elements.use_dash:get()
    settings.use_soar = gui.elements.use_soar:get()
    settings.use_hunter = gui.elements.use_hunter:get()
    settings.use_leap = gui.elements.use_leap:get()
    settings.use_charge = gui.elements.use_charge:get()
    settings.use_whirlwind = gui.elements.use_whirlwind:get()
    settings.use_advance = gui.elements.use_advance:get()
    settings.use_falling_star = gui.elements.use_falling_star:get()
    settings.use_aoj = gui.elements.use_aoj:get()
    settings.use_wraith_step = gui.elements.use_wraith_step:get()
    settings.use_demonic_slash = gui.elements.use_demonic_slash:get()
    settings.demonic_slash_los = gui.elements.demonic_slash_los:get()
    settings.min_spell_dist = gui.elements.min_spell_dist:get()
    settings.prefer_long_paths   = gui.elements.prefer_long_paths:get()
    settings.long_path_threshold = gui.elements.long_path_threshold:get()
    settings.log_level = gui.elements.log_level:get()
    settings.nav_viz   = gui.elements.nav_viz:get()
    settings.debug_logs = gui.elements.debug_logs:get()
    settings.require_full_path_explore = gui.elements.require_full_path_explore:get()
    settings.explore_path_budget_ms    = gui.elements.explore_path_budget_ms:get()
    settings.path_smooth_step          = gui.elements.path_smooth_step:get()
    settings.wall_path                 = gui.elements.wall_path:get()
    settings.wall_path_dist            = gui.elements.wall_path_dist:get()
    settings.frontier_max_dist         = gui.elements.frontier_max_dist:get()
    settings.enable_z_frontier         = gui.elements.enable_z_frontier:get()
    -- Frigate long-nav (defensive: widgets may be absent in older saved layouts)
    if gui.elements.spiral_radius then
        settings.frigate_spiral_radius = gui.elements.spiral_radius:get()
    end
    if gui.elements.spiral_step then
        settings.frigate_spiral_step = gui.elements.spiral_step:get()
    end
    if gui.elements.spiral_around_target then
        settings.frigate_spiral_around_target = gui.elements.spiral_around_target:get()
    end
    if gui.elements.z_variance_tolerance then
        settings.frigate_z_variance_tolerance = gui.elements.z_variance_tolerance:get()
    end
    if gui.elements.draw_frontiers then
        settings.draw_frontiers = gui.elements.draw_frontiers:get()
    end
    if gui.elements.draw_frigate_map then
        settings.frigate_draw_map = gui.elements.draw_frigate_map:get()
    end
    if gui.elements.verbose_logging then
        settings.frigate_verbose_logging = gui.elements.verbose_logging:get()
    end
    if gui.elements.verbose_status_interval then
        settings.frigate_verbose_status_interval = gui.elements.verbose_status_interval:get()
    end
    if gui.elements.draw_map_cells then
        settings.frigate_draw_map_cells = gui.elements.draw_map_cells:get()
    end
    if gui.elements.draw_map_traversals then
        settings.frigate_draw_map_traversals = gui.elements.draw_map_traversals:get()
    end
    if gui.elements.draw_spiral then
        settings.frigate_draw_spiral = gui.elements.draw_spiral:get()
    end
    if gui.elements.draw_state_hud then
        settings.frigate_draw_state_hud = gui.elements.draw_state_hud:get()
    end
    if gui.elements.draw_target_pin then
        settings.frigate_draw_target_pin = gui.elements.draw_target_pin:get()
    end
    if gui.elements.map_draw_radius then
        settings.frigate_map_draw_radius = gui.elements.map_draw_radius:get()
    end
    if gui.elements.map_cell_alpha then
        settings.frigate_map_cell_alpha = gui.elements.map_cell_alpha:get()
    end
    settings.move_spell_pause_after_target = gui.elements.move_spell_pause_after_target:get()
    settings.pause_weight_elite        = gui.elements.pause_weight_elite:get()
    settings.pause_weight_champion     = gui.elements.pause_weight_champion:get()
    settings.pause_weight_goblin       = gui.elements.pause_weight_goblin:get()
    settings.pause_weight_threshold    = gui.elements.pause_weight_threshold:get()
    settings.pause_floor_reset_jump    = gui.elements.pause_floor_reset_jump:get()
    -- Movement revamp
    if gui.elements.mvr_enabled then
        settings.movement_revamp = gui.elements.mvr_enabled:get()
    end
    settings.movement_rules = _read_all_rules()
end

return settings
