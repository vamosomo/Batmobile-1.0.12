local plugin_label = 'batmobile'
local plugin_version = '2.2.0'
console.print("Lua Plugin - Batmobile - Leoric - v" .. plugin_version)

local mrul         = require 'core.movement_rules'
local mhelp        = require 'core.movement_helpers'
local test_targets = require 'core.test_targets'

local get_character_class = function (local_player)
    if not local_player then
        local_player = get_local_player();
    end
    if not local_player then return end
    local class_id = local_player:get_character_class_id()
    local character_classes = {
        [0] = 'sorcerer',
        [1] = 'barbarian',
        [3] = 'rogue',
        [5] = 'druid',
        [6] = 'necromancer',
        [7] = 'spiritborn',
        [8] = 'default', -- new class in expansion, dont know name yet
        [9] = 'paladin',
        [10] = 'warlock'
    }
    if character_classes[class_id] then
        return character_classes[class_id]
    else
        return 'default'
    end
end

local gui = {}

local function create_checkbox(value, key)
    return checkbox:new(value, get_hash(plugin_label .. '_' .. key))
end

gui.plugin_label = plugin_label
gui.plugin_version = plugin_version
gui.log_levels_enum = {
    DISABLED = 0,
    INFO = 1,
    DEBUG = 2
}
gui.log_level = { 'Disabled', 'Info', 'Debug'}

gui.elements = {
    main_tree = tree_node:new(0),
    reset_keybind = keybind:new(0x0A, true, get_hash(plugin_label .. '_reset_keybind' )),
    draw_keybind_toggle = keybind:new(0x0A, true, get_hash(plugin_label .. '_draw_keybind_toggle' )),
    movement_tree = tree_node:new(1),
    move_keybind_toggle = create_checkbox(false, 'use_movement'),
    use_evade = create_checkbox(true, "use_evade"),
    use_teleport = create_checkbox(true, "use_teleport"),
    use_teleport_enchanted = create_checkbox(true, "use_teleport_enchanted"),
    use_dash = create_checkbox(true, "use_dash"),
    use_soar = create_checkbox(true, "use_soar"),
    use_hunter = create_checkbox(true, "use_hunter"),
    use_leap = create_checkbox(true, "use_leap"),
    use_charge = create_checkbox(true, "use_charge"),
    use_whirlwind = create_checkbox(false, "use_whirlwind"),
    use_advance = create_checkbox(true, "use_advance"),
    use_falling_star = create_checkbox(true, "use_falling_star"),
    use_aoj = create_checkbox(true, "use_aoj"),
    use_wraith_step = create_checkbox(true, "use_wraith_step"),
    use_demonic_slash = create_checkbox(true, "use_demonic_slash"),
    demonic_slash_los = create_checkbox(true, "demonic_slash_los"),
    min_spell_dist = slider_float:new(1.0, 20.0, 3.0, get_hash(plugin_label .. '_min_spell_dist')),
    prefer_long_paths = create_checkbox(false, "prefer_long_paths"),
    long_path_threshold = slider_float:new(10.0, 50.0, 20.0, get_hash(plugin_label .. '_long_path_threshold')),
    require_full_path_explore = create_checkbox(true, "require_full_path_explore"),
    explore_path_budget_ms = slider_int:new(50, 500, 150, get_hash(plugin_label .. '_explore_path_budget_ms')),
    path_smooth_step = slider_float:new(0.0, 10.0, 1.0, get_hash(plugin_label .. '_path_smooth_step')),
    wall_path = create_checkbox(true, "wall_path"),
    wall_path_dist = slider_float:new(0.5, 10.0, 4.0, get_hash(plugin_label .. '_wall_path_dist')),
    frontier_max_dist = slider_int:new(5, 50, 40, get_hash(plugin_label .. '_frontier_max_dist')),
    advanced_tree = tree_node:new(1),
    max_iteration = slider_int:new(250, 5000, 1500, get_hash(plugin_label .. '_' .. 'max_iteration')),
    debug_tree = tree_node:new(1),
    debug_logs = create_checkbox(false, "debug_logs"),
    log_level = combo_box:new(0, get_hash(plugin_label .. '_' .. 'log_level')),
    nav_viz = create_checkbox(false, "nav_viz"),
    enable_z_frontier = create_checkbox(false, "enable_z_frontier"),
    move_spell_pause_after_target = slider_float:new(0.0, 10.0, 0.0, get_hash(plugin_label .. '_move_spell_pause_after_target')),
    pause_weight_elite     = slider_int:new(0, 10, 2, get_hash(plugin_label .. '_pause_weight_elite')),
    pause_weight_champion  = slider_int:new(0, 10, 1, get_hash(plugin_label .. '_pause_weight_champion')),
    pause_weight_goblin    = slider_int:new(0, 10, 3, get_hash(plugin_label .. '_pause_weight_goblin')),
    pause_weight_threshold = slider_int:new(0, 500, 120, get_hash(plugin_label .. '_pause_weight_threshold')),
    pause_floor_reset_jump = slider_int:new(50, 1500, 300, get_hash(plugin_label .. '_pause_floor_reset_jump')),
    freeroam_keybind_toggle = keybind:new(0x0A, true, get_hash(plugin_label .. '_freeroam_keybind_toggle' )),
    long_path_tree = tree_node:new(1),
    long_path_set_target        = keybind:new(0x0A, true, get_hash(plugin_label .. '_long_path_set_target')),
    long_path_set_target_cursor = keybind:new(0x0A, true, get_hash(plugin_label .. '_long_path_set_target_cursor')),
    long_path_test              = keybind:new(0x0A, true, get_hash(plugin_label .. '_long_path_test')),
    -- Frigate long-nav widgets
    -- Profile system
    profiles_tree      = tree_node:new(0),
    profile_combo      = combo_box:new(0, get_hash(plugin_label .. '_profile_combo')),
    profile_rename     = input_text:new(get_hash(plugin_label .. '_profile_rename')),
    profile_rename_btn = create_checkbox(false, 'profile_rename_btn'),
    new_profile        = create_checkbox(false, 'new_profile'),
    delete_profile     = create_checkbox(false, 'delete_profile'),

    long_nav_tree              = tree_node:new(0),
    test_target_combo          = combo_box:new(0, get_hash(plugin_label .. '_test_target_combo')),
    spiral_radius              = slider_float:new(20.0, 200.0, 60.0, get_hash(plugin_label .. '_spiral_radius')),
    spiral_step                = slider_float:new(5.0, 40.0, 12.0, get_hash(plugin_label .. '_spiral_step')),
    spiral_around_target       = create_checkbox(true, 'spiral_around_target'),
    z_variance_tolerance       = slider_float:new(20.0, 300.0, 120.0, get_hash(plugin_label .. '_z_variance_tolerance')),
    clear_map_keybind          = keybind:new(0x0A, true, get_hash(plugin_label .. '_clear_map_keybind')),
    -- Frigate test / overlays
    test_tree                  = tree_node:new(0),
    verbose_logging            = create_checkbox(true,  'verbose_logging'),
    verbose_status_interval    = slider_float:new(0.5, 10.0, 2.0, get_hash(plugin_label .. '_verbose_status_interval')),
    draw_frontiers             = create_checkbox(false, 'draw_frontiers'),
    draw_frigate_map           = create_checkbox(true,  'draw_frigate_map'),
    draw_map_cells             = create_checkbox(true,  'draw_map_cells'),
    draw_map_traversals        = create_checkbox(true,  'draw_map_traversals'),
    draw_spiral                = create_checkbox(true,  'draw_spiral'),
    draw_state_hud             = create_checkbox(true,  'draw_state_hud'),
    draw_target_pin            = create_checkbox(true,  'draw_target_pin'),
    map_draw_radius            = slider_float:new(10.0, 200.0, 60.0, get_hash(plugin_label .. '_map_draw_radius')),
    map_cell_alpha             = slider_int:new(20, 255, 120, get_hash(plugin_label .. '_map_cell_alpha')),
}
gui.long_path_target_str  = nil    -- updated by main.lua after set_target()
gui.long_path_navigating  = false  -- updated by main.lua each frame
gui.frigate_map_stats     = nil    -- updated by main.lua each frame
gui.frigate_status_str    = nil    -- updated by main.lua each frame

-- ────────────────────────────────────────────────────────────────────────
-- Movement revamp widgets. Pre-allocated with stable hash keys so registry
-- persistence survives script reload. Combo widgets are never :set()
-- programmatically (that historically crashed UR's dynamic buff combo).
-- The persistent source-of-truth for a chosen buff is the per-condition
-- `buff_hash` slider_int; the buff combo is a UX surface that updates the
-- slider via change-detection (combo idx delta vs previous frame).
-- ────────────────────────────────────────────────────────────────────────
local function _mvr_hash(suffix)
    return get_hash(plugin_label .. '_mvr_' .. suffix)
end

gui.elements.mvr_enabled  = checkbox:new(false, _mvr_hash('enabled'))
gui.elements.mvr_tree     = tree_node:new(0)
gui.elements.mvr_active_rule_count = slider_int:new(0, mrul.MAX_RULES, 0, _mvr_hash('active_rule_count'))

gui.elements.mvr_rule_widgets = {}
for r = 1, mrul.MAX_RULES do
    local rp = 'r' .. r .. '_'
    local rw = {
        tree              = tree_node:new(0),
        enabled           = checkbox:new(true, _mvr_hash(rp .. 'enabled')),
        skill             = combo_box:new(0, _mvr_hash(rp .. 'skill')),
        cast_position     = combo_box:new(0, _mvr_hash(rp .. 'cast_position')),
        density_radius    = slider_int:new(1, 20, 6, _mvr_hash(rp .. 'density_radius')),
        throttle_ms       = slider_int:new(0, 5000, 0, _mvr_hash(rp .. 'throttle_ms')),
        cond_tree         = tree_node:new(0),
        active_cond_count = slider_int:new(0, mrul.MAX_CONDITIONS_PER_RULE, 0,
                                           _mvr_hash(rp .. 'active_cond_count')),
        cond_widgets      = {},
    }
    for c = 1, mrul.MAX_CONDITIONS_PER_RULE do
        local cp = rp .. 'c' .. c .. '_'
        rw.cond_widgets[c] = {
            combinator = combo_box:new(0, _mvr_hash(cp .. 'combinator')),
            type       = combo_box:new(0, _mvr_hash(cp .. 'type')),
            buff_combo = combo_box:new(0, _mvr_hash(cp .. 'buff_combo')),
            -- 2^30 keeps us well inside int32 while covering all hashes we have observed.
            buff_hash  = slider_int:new(0, 1073741823, 0, _mvr_hash(cp .. 'buff_hash')),
            op         = combo_box:new(0, _mvr_hash(cp .. 'op')),
            value      = slider_int:new(0, 100, 0, _mvr_hash(cp .. 'value')),
            radius     = slider_int:new(1, 20, 6, _mvr_hash(cp .. 'radius')),
        }
    end
    gui.elements.mvr_rule_widgets[r] = rw
end

-- Build display labels for the skill combo. Catalog order is stable;
-- unequipped skills get a "(unequipped)" suffix as a hint, but stay
-- selectable (engine simply won't fire them when can_cast returns false).
local function _build_skill_labels()
    local items = { '(none)' }
    local equipped_set = {}
    if type(get_equipped_spell_ids) == 'function' then
        local ok, eq = pcall(get_equipped_spell_ids)
        if ok and type(eq) == 'table' then
            for _, id in pairs(eq) do
                if type(id) == 'number' then equipped_set[id] = true end
            end
        end
    end
    for i, s in ipairs(mrul.skill_catalog) do
        if equipped_set[s.id] then
            items[i + 1] = s.name
        else
            items[i + 1] = s.name .. ' (unequipped)'
        end
    end
    return items
end

-- Render the revamp rule builder. Called from gui.render() when the
-- mvr_enabled checkbox is on. Walks `active_rule_count` slots and renders
-- each rule with its conditions list.
-- Updated each tick by main.lua so the render path stays free of requires.
gui.profile_names  = {}
gui.active_profile = 'Default'

-- ---- Profile selector UI ------------------------------------------------
function gui.render_profiles()
    if not gui.elements.profiles_tree:push('Profiles') then return end

    local names = gui.profile_names
    if names and #names > 0 then
        gui.elements.profile_combo:render('Profile', names,
            'Switch between saved Movement Revamp profiles. Switching auto-saves the current one.')
        pcall(function()
            gui.elements.profile_rename:render('Rename profile',
                'Type a new name for the active profile, then click Apply Rename.')
        end)
        gui.elements.profile_rename_btn:render('Apply Rename',
            'Apply the name typed above to the active profile.')
        gui.elements.new_profile:render('New Profile (copy current)',
            'Create a new profile by copying all current rule settings.')
        if #names > 1 then
            gui.elements.delete_profile:render('Delete Current Profile',
                'Permanently delete the active profile and switch to the first remaining one.')
        end
    end

    gui.elements.profiles_tree:pop()
end

function gui.render_movement_revamp()
    if not gui.elements.mvr_tree:push('Movement Rules') then return end

    render_menu_header("Rules are evaluated in slot order. First match casts.")
    render_menu_header("Drag 'Number of rules' to add/remove rule slots.")
    gui.elements.mvr_active_rule_count:render('Number of rules',
        'Number of active rule slots (0 = revamp disabled). Drag to add or remove.')

    local skill_items = _build_skill_labels()
    local cast_items  = mrul.cast_position_labels
    local type_items  = mrul.condition_labels
    local op_items    = mrul.op_labels
    local combinator_items = mrul.combinators

    local active_rules = gui.elements.mvr_active_rule_count:get() or 0
    if active_rules > mrul.MAX_RULES then active_rules = mrul.MAX_RULES end

    -- UR-style: seed the catalog with any user-saved hashes BEFORE building
    -- buff_items so the combo always has those entries available on reload.
    local seed_ok, seed_err = pcall(function ()
        for r = 1, active_rules do
            local rw = gui.elements.mvr_rule_widgets[r]
            if rw then
                local nconds = rw.active_cond_count:get() or 0
                if nconds > mrul.MAX_CONDITIONS_PER_RULE then
                    nconds = mrul.MAX_CONDITIONS_PER_RULE
                end
                for c = 1, nconds do
                    local cw = rw.cond_widgets[c]
                    if cw then mhelp.seed_buff_hash(cw.buff_hash:get() or 0) end
                end
            end
        end
    end)
    if not seed_ok then
        console.print('[mvr] seed_buff_hash pass failed: ' .. tostring(seed_err))
    end
    local buff_items = mhelp.buff_combo_items()

    for r = 1, active_rules do
        local rw = gui.elements.mvr_rule_widgets[r]
        if rw then
            -- Rule header label: show selected skill name for quick scanning.
            -- combo_box:get() is 0-indexed; idx 0 = "(none)".
            local skill_idx = rw.skill:get() or 0
            local label = string.format('Rule %d', r)
            if skill_idx > 0 and mrul.skill_catalog[skill_idx] then
                label = label .. ' — ' .. mrul.skill_catalog[skill_idx].name
            end
            if rw.tree:push(label) then
                rw.enabled:render('Enabled',
                    'When off, this rule is skipped during evaluation.')
                if (rw.skill:get() or 0) >= #skill_items then rw.skill:set(0) end
                rw.skill:render('Skill', skill_items,
                    'Which movement skill this rule casts. Unequipped skills will not fire.')
                if (rw.cast_position:get() or 0) >= #cast_items then rw.cast_position:set(0) end
                rw.cast_position:render('Cast position', cast_items,
                    'Where to aim the spell:\n' ..
                    '• Next path node: farthest path node within range (legacy behavior).\n' ..
                    '• Toward largest pack on path: aim at the densest cluster along the path.')
                rw.density_radius:render('Pack target radius',
                    'When cast position is "toward largest pack", the search radius (in units)\n' ..
                    'around each candidate path node used to find the densest cluster.')
                rw.throttle_ms:render('Per-rule throttle (ms)',
                    'Minimum delay between two firings of THIS rule. 0 = no throttle\n' ..
                    '(only the spell\'s native cooldown gates it).')

                -- Conditions
                if rw.cond_tree:push('Conditions') then
                    rw.active_cond_count:render('Number of conditions',
                        'Number of active condition rows for this rule (0 = always passes).\n' ..
                        'Drag to add or remove condition slots.')

                    local active_conds = rw.active_cond_count:get() or 0
                    if active_conds > mrul.MAX_CONDITIONS_PER_RULE then
                        active_conds = mrul.MAX_CONDITIONS_PER_RULE
                    end

                    for c = 1, active_conds do
                        local cw = rw.cond_widgets[c]
                        if cw then
                            local ok, err = pcall(function ()
                                local id_suffix = ' (' .. c .. ')'
                                render_menu_header(string.format('-- Condition %d --', c))
                                if (cw.combinator:get() or 0) >= #combinator_items then cw.combinator:set(0) end
                                cw.combinator:render('Combinator' .. id_suffix, combinator_items,
                                    'AND/OR combinator with prior rows. (First row ignored.)')
                                if (cw.type:get() or 0) >= #type_items then cw.type:set(0) end
                                cw.type:render('Type' .. id_suffix, type_items,
                                    'What this condition checks. "(none)" disables this row.')

                                local type_idx = (cw.type:get() or 0) + 1
                                local type_entry = mrul.condition_types[type_idx] or { key = 'none' }
                                local meta       = mrul.condition_meta_by_key[type_entry.key] or {}

                                if meta.uses_buff then
                                    local saved_hash = cw.buff_hash:get() or 0
                                    if saved_hash > 0 then
                                        local entry = mhelp.known_buffs_by_hash[saved_hash]
                                        local nm = (entry and entry.name) or ('Buff hash ' .. tostring(saved_hash))
                                        render_menu_header('Saved buff: ' .. nm .. ' (hash=' .. saved_hash .. ')')
                                    else
                                        local combo_idx = cw.buff_combo:get() or 0
                                        local combo_hash = mhelp.buff_hash_for_combo_index(combo_idx) or 0
                                        if combo_hash > 0 then
                                            render_menu_header('Combo buff hash: ' .. tostring(combo_hash) .. ' — copy this into the override slider below')
                                        else
                                            render_menu_header('Saved buff: combo selection')
                                        end
                                    end
                                    if (cw.buff_combo:get() or 0) >= #buff_items then cw.buff_combo:set(0) end
                                    cw.buff_combo:render('Buff' .. id_suffix, buff_items,
                                        'Pick from observed/seeded buffs. Engine prefers hash slider below.')
                                    cw.buff_hash:render('  buff hash (override)' .. id_suffix,
                                        'Explicit buff hash. When > 0 the engine uses this directly.')
                                end

                                if meta.uses_op then
                                    if (cw.op:get() or 0) >= #op_items then cw.op:set(0) end
                                    cw.op:render('Op' .. id_suffix, op_items,
                                        'Comparison operator.')
                                    cw.value:render('Value' .. id_suffix,
                                        'Right-hand side of the comparison.')
                                end

                                if meta.uses_radius then
                                    cw.radius:render('Search radius' .. id_suffix,
                                        'Radius used for Pack-size-on-path.')
                                end
                            end)
                            if not ok then
                                console.print('[mvr] render condition r=' .. r .. ' c=' .. c
                                    .. ' failed: ' .. tostring(err))
                            end
                        end
                    end
                    rw.cond_tree:pop()
                end

                rw.tree:pop()
            end
        end
    end

    gui.elements.mvr_tree:pop()
end

function gui.render()
    if not gui.elements.main_tree:push('Z | Batmobile | Leoric | v' .. gui.plugin_version) then return end
    gui.render_profiles()
    gui.elements.draw_keybind_toggle:render('Toggle Drawing', 'Toggle drawing')
    gui.elements.move_keybind_toggle:render('use movement spells', 'use movement spells')
    gui.elements.reset_keybind:render('Reset batmobile', 'Keybind to reset batmobile')
    gui.elements.mvr_enabled:render('Movement Revamp',
        'When ON, the legacy per-skill movement toggles are replaced by the rules-based\n' ..
        'engine below. Build a list of rules; each rule picks a skill, a cast position,\n' ..
        'and a list of conditions (with AND/OR combinators). The first rule whose\n' ..
        'conditions all pass casts. Rule slot order = priority.')
    if gui.elements.mvr_enabled:get() then
        gui.render_movement_revamp()
    end
    if (not gui.elements.mvr_enabled:get()) and gui.elements.movement_tree:push('Movement Spells') then
        render_menu_header("Need 'use movement spell' to be toggled on to work")
        local class = get_character_class()
        gui.elements.use_evade:render('evade', 'use evade for movement')
        if class == 'sorcerer' then
            gui.elements.use_teleport:render('teleport', 'use teleport for movement')
            gui.elements.use_teleport_enchanted:render('teleport enchanted', 'use teleport enchanted for movement')
        elseif class == 'rogue' then
            gui.elements.use_dash:render('dash', 'use dash for movement')
        elseif class == 'spiritborn' then
            gui.elements.use_soar:render('soar', 'use soar for movement')
            gui.elements.use_hunter:render('hunter', 'use hunter for movement')
        elseif class == 'barbarian' then
            gui.elements.use_leap:render('leap', 'use leap for movement')
            gui.elements.use_charge:render('charge', 'use charge for movement')
            gui.elements.use_whirlwind:render('whirlwind',
                'Use Whirlwind for movement. Fires via repeated position-casts toward the\n' ..
                'next path node. Path and replan cooldown are preserved between casts so\n' ..
                'the spin runs continuously without walking gaps.')
        elseif class == 'paladin' then
            gui.elements.use_advance:render('advance', 'use advance for movement')
            gui.elements.use_falling_star:render('falling star', 'use falling star for movement')
            gui.elements.use_aoj:render('Arbiter of Justice', 'use Arbiter of Justice for movement')
        elseif class == 'warlock' then
            gui.elements.use_wraith_step:render('wraith step', 'use wraith step for movement (position-cast mobility, the proper warlock movement skill)')
            gui.elements.use_demonic_slash:render('demonic slash', 'use demonic slash for movement (NOTE: target-cast cooldown — may not fire via Batmobile position-cast)')
            gui.elements.demonic_slash_los:render('  demonic slash requires LOS',
                'On = require line-of-sight raycast to the destination (charge-style: blocked by walls).\n' ..
                'Off = skip the LOS check (blink-style: phases through obstacles).\n' ..
                'Try OFF first if the cast never fires.')
        end
        gui.elements.movement_tree:pop()
    end
    -- Shared movement/path settings: always rendered so both legacy and revamp
    -- modes can tune cast distance + path length. The revamp engine reads
    -- min_spell_dist for its node picker and depends on the explorer's path
    -- length for pack-density scanning + node selection.
    gui.elements.min_spell_dist:render('Min spell distance',
        'Minimum distance (in units) from the player to a path node before a movement\n' ..
        'spell will target that node. Raise to stop the bot from burning movement\n' ..
        'cooldowns on tiny hops; lower to let it cast more aggressively on short paths.\n' ..
        'Default 3.0.', 1)
    gui.elements.prefer_long_paths:render('Prefer long paths (experimental)',
        'Bias the explorer toward distant targets so each computed path is at least\n' ..
        'the threshold below in length. Gives movement spells a node ~N units out\n' ..
        'to actually cast on instead of the explorer picking a 12-unit perimeter hop.\n' ..
        'Falls back to the normal (closest/direction) pick when no frontier meets the\n' ..
        'threshold, so the bot still finishes exploration.')
    if gui.elements.prefer_long_paths:get() then
        gui.elements.long_path_threshold:render('Preferred path length',
            'Minimum straight-line distance from the player to an explorer target.\n' ..
            'Path length is always >= this (the path can only be longer than the\n' ..
            'straight line), so the movement spell always has a far enough node to\n' ..
            'target. Default 20.0.', 1)
    end
    gui.elements.require_full_path_explore:render('Full path only (explore)',
        'Skip any frontier the pathfinder cannot fully reach from the current position.\n' ..
        'Prevents the bot from walking toward unreachable cells (cliffs, walls across floors).\n' ..
        'Only applies to explorer targets — custom targets (kill, chest) are unaffected.')
    if gui.elements.require_full_path_explore:get() then
        gui.elements.explore_path_budget_ms:render('Path budget (ms)',
            'A* time budget per frontier pathfind when Full path only is on.\n' ..
            'Higher = handles longer winding paths correctly but costs more CPU per pick.\n' ..
            '150ms is reasonable; 300ms+ will cause noticeable lag on busy floors.')
    end
    gui.elements.path_smooth_step:render('Path smoothing step',
        'LOS sample interval used when simplifying A* paths (string-pull).\n' ..
        '0 = disabled (raw A* grid path, maximum safety near thin walls).\n' ..
        '0.5-1.0 = conservative (tight sampling, follows grid closely).\n' ..
        '1.0-3.0 = normal range (default 1.0).\n' ..
        '3.0-10.0 = super smooth (very few LOS samples, longest straight segments).\n' ..
        'Raise if paths look jagged or the bot over-corrects; lower/disable if it clips small pillars.', 1)
    gui.elements.wall_path:render('Wall path avoidance',
        'Heavily penalize partial paths whose endpoint lands within N units of an unwalkable cell.\n' ..
        'When the pathfinder cannot reach the goal and dumps the player against a wall/cliff,\n' ..
        'this skips that partial path so the explorer picks a different frontier instead.\n' ..
        'Only applies to explorer targets; custom targets (kill, chest, traversal) are unaffected.')
    if gui.elements.wall_path:get() then
        gui.elements.wall_path_dist:render('Wall path distance',
            'How many units around the partial-path endpoint to scan for unwalkable cells.\n' ..
            'Higher = more aggressive avoidance (rejects paths even with walls farther away).\n' ..
            'Lower = only rejects paths that hug a wall closely.\n' ..
            'Default 4.0; raise to 6-8 if the bot keeps wedging against ledges, lower if it refuses\n' ..
            'legitimate frontiers near tight corridors.', 1)
    end
    gui.elements.frontier_max_dist:render('Frontier range',
        'Max straight-line distance (units) from the player when selecting explorer frontier nodes.\n' ..
        'Lower = only targets nearby frontiers; pathfind faster, less likely to pick nodes across walls.\n' ..
        'Higher = targets farther frontiers; covers more ground per step but more prone to long detours.\n' ..
        'Default 40. Reduce to 20-25 for tight pit corridors if unreachable-node churn is high.\n' ..
        'The fallback (pick_closest_frontier) ignores this cap when no in-range frontiers remain,\n' ..
        'so lowering this value does not slow overall exploration.', 1)
    if gui.elements.debug_tree:push('Debug') then
        gui.elements.freeroam_keybind_toggle:render('Toggle explorer', 'enable freeroam explorer')
        render_menu_header('WARNING running explorer in overworld can cause big lag spike due to multiple elevation and traversals close by')
        gui.elements.debug_logs:render('Debug logs', 'Print verbose navigation and movement debug logs to console. Off by default.')
        gui.elements.log_level:render('logging', gui.log_level, 'Select log level')
        gui.elements.nav_viz:render('Nav viz (walkable grid)', 'Show walkable/wall grid + nav vectors around player. Green=walkable, Red=blocked. Rescans every 0.3s.')
        gui.elements.enable_z_frontier:render('Pit traversal frontier (debug, off by default)',
            'When enabled: if the explorer\'s next target is >40u away but a traversal gizmo is ' ..
            'within 30u, route through the traversal instead. Lets the bot discover and explore ' ..
            'areas above/below cliffs that are invisible to the 2D frontier BFS (elevated pit floors). ' ..
            'Prefers Up traversals; ignores Down. Re-triggers whenever the far-frontier fallback fires.')
        gui.elements.move_spell_pause_after_target:render('Pause movement spells after kill (sec)',
            'After we reach a custom target (kill_monster, kill_boss, etc.) and the\n' ..
            'target is released, suppress movement spells (teleport / dash / leap / etc.)\n' ..
            'for this many seconds. 0 = disabled.\n\n' ..
            'Use case: fast-clearing speed builds blink onto an elite, instantly kill it,\n' ..
            'and immediately teleport to the next frontier — skipping past the boss spawn\n' ..
            'animation on the final floor. A 1-3s pause keeps you in place long enough\n' ..
            'for the boss to materialize and become detectable.', 1)
        render_menu_header('--- Pause weight gate (skip pauses early in pit) ---')
        gui.elements.pause_weight_elite:render('Weight: elite',
            'Weight contribution per visible elite seen on the current floor. Higher means\n' ..
            'elites push toward the pause threshold faster. Default 2 (elites are rarer\n' ..
            'and worth more toward boss-spawn progress).')
        gui.elements.pause_weight_champion:render('Weight: champion',
            'Weight contribution per visible champion (yellow rare pack member). Default 1.')
        gui.elements.pause_weight_goblin:render('Weight: goblin',
            'Weight contribution per visible treasure goblin. Default 3 (rare and valuable).')
        gui.elements.pause_weight_threshold:render('Pause weight threshold',
            'Cumulative weight (across the entire pit run, all floors) required before\n' ..
            'the post-kill pause arms. Below the threshold all kills pass through\n' ..
            'full-speed; above it the pause behaves normally.\n\n' ..
            'Derived from log analysis: avg total weighted kills to reach the pit\n' ..
            'guardian ≈ 134 (28+29+36+41 across 4 floors with elite=2 champion=1\n' ..
            'goblin=3); avg last-2-packs buffer ≈ 8-14. Default 120 leaves a small\n' ..
            'cushion before the boss room. Lower = safer (pauses arm sooner);\n' ..
            'higher = faster runs (skips more early/mid-pit pauses).')
        gui.elements.pause_floor_reset_jump:render('Run-reset jump dist',
            'Player position jump (in units) between scan ticks that resets the\n' ..
            'cumulative run weight. Crossing a pit floor portal jumps ~150-180u, so\n' ..
            'the default 300 deliberately does NOT reset on intra-pit transitions —\n' ..
            'the count keeps accumulating across all 5 floors. Town-port style jumps\n' ..
            '(re-entering the pit after the boss / leaving for restock) are 1000+u\n' ..
            'and will reset cleanly so the next run starts at 0.')
        gui.elements.debug_tree:pop()
    end
    -- if gui.elements.advanced_tree:push('Advanced settings') then
    --     gui.elements.max_iteration:render('Max iteration', 'smaller = weaker but less lag, bigger = better pathfinding but laggier')

    --     gui.elements.advanced_tree:pop()
    -- end
    if gui.elements.long_nav_tree:push('Long-distance navigation') then
        render_menu_header('1. Walk to destination, click Set Target (Player).')
        render_menu_header('2. Walk far away, click Test Long Path to navigate back.')
        render_menu_header('   Click Test again to abort.')
        local target_display = gui.long_path_target_str or '(none pinned)'
        render_menu_header('Pinned target: ' .. target_display)
        if gui.long_path_navigating then
            render_menu_header('Status: NAVIGATING  (click Test to stop)')
        end
        if gui.frigate_status_str then
            render_menu_header('Nav: ' .. gui.frigate_status_str)
        end
        if gui.frigate_map_stats then
            render_menu_header('Map: ' .. gui.frigate_map_stats)
        end

        render_menu_header('-- Test target --')
        gui.elements.test_target_combo:render('Preset target',
            test_targets.labels(),
            'Pick a known location to navigate to when you press Test Long Path.\n' ..
            'Maiden positions come from HelltideRevamped/data/enums.lua.\n' ..
            'Select "(none — use pinned target)" to fall back to the Set Target pins below.')
        render_menu_header('  ' .. test_targets.describe(gui.elements.test_target_combo:get() or 0))

        gui.elements.long_path_set_target:render('Set Target (Player)',
            'Pin the current player position as the long-nav goal.\n' ..
            'Used when the preset combo is set to (none).')
        gui.elements.long_path_set_target_cursor:render('Set Target (Cursor)',
            'Pin the current cursor world position as the long-nav goal.\n' ..
            'Used when the preset combo is set to (none).')
        local test_label = gui.long_path_navigating and 'Stop Navigation' or 'Test Long Path'
        gui.elements.long_path_test:render(test_label,
            'Navigate to the preset combo selection, or — if (none) — the pinned target.\n' ..
            'Spiral-scans around current + target while routing.')
        gui.elements.clear_map_keybind:render('Clear discovered map',
            'Wipe the discovered terrain/traversal/floor cache. The map rebuilds as you walk.')

        render_menu_header('-- Spiral scan tuning --')
        gui.elements.spiral_radius:render('Spiral max radius',
            'Outer radius (units) of the circular spiral scan around current position.\n' ..
            'Larger = discovers more terrain/traversals per scan but costs more frame time.', 1)
        gui.elements.spiral_step:render('Spiral step',
            'Sample spacing along each spiral arm. Smaller = denser map, more work per scan.', 1)
        gui.elements.spiral_around_target:render('Also spiral around target',
            'In addition to scanning around the player, sample the area around the pinned target.\n' ..
            'Helps find a viable approach node when the target sits on / near non-walkable mesh.')
        gui.elements.z_variance_tolerance:render('Z-variance tolerance',
            'Maximum vertical separation (units) the long-nav loop will try to bridge by\n' ..
            'chaining through traversal gizmos. Larger values allow deeper multi-floor descents.', 1)

        gui.elements.long_nav_tree:pop()
    end
    if gui.elements.test_tree:push('Test & overlays') then
        render_menu_header('In-plugin test workflow:')
        render_menu_header(' 1. Stand at destination, press Set Target (Player).')
        render_menu_header(' 2. Walk 600u+ away (cross floors if testing z variance).')
        render_menu_header(' 3. Press Test Long Path. Watch console + on-screen HUD.')
        render_menu_header(' 4. Press Test again to abort. Reset Batmobile to wipe map.')

        gui.elements.verbose_logging:render('Verbose logging',
            'Log every long-nav state transition, leg pick, traversal candidate score,\n' ..
            'progress milestone, and pathfind outcome.')
        gui.elements.verbose_status_interval:render('Status snapshot (s)',
            'Seconds between throttled [FRIGATE STATUS] lines while a run is active.\n' ..
            'Lower = more frequent. 2s is a good default.', 1)

        render_menu_header('-- On-screen overlays --')
        gui.elements.draw_frontiers:render('  frontier nodes',
            'Green dots at every unexplored frontier cell. Useful for debugging explorer selection.')
        gui.elements.draw_frigate_map:render('Draw discovered map',
            'Master toggle for Frigate-specific overlays below.')
        gui.elements.draw_map_cells:render('  cells (terrain)',
            'Discovered walkable/blocked cells. Green = walkable, dim red = blocked.')
        gui.elements.draw_map_traversals:render('  traversals',
            'Yellow square at every Traversal_Gizmo Frigate has cached.')
        gui.elements.draw_spiral:render('  spiral scan centers',
            'Cyan ring around the player spiral center, magenta ring around the target spiral center.')
        gui.elements.draw_state_hud:render('  long-nav state HUD',
            'Text panel showing state, distance to target, fail counters, and best distance.')
        gui.elements.draw_target_pin:render('  pinned target pin',
            'Large white circle at the long_path.pinned_target.')
        gui.elements.map_draw_radius:render('  map draw radius',
            'Only draw map cells / traversals within this distance of the player.', 1)
        gui.elements.map_cell_alpha:render('  cell alpha',
            'Per-cell render alpha (0-255). Lower = subtler overlay.', 1)

        gui.elements.test_tree:pop()
    end
    gui.elements.main_tree:pop()
end

return gui