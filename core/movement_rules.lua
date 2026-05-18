-- Movement revamp data model: skill catalog, condition type registry,
-- operators / combinators / cast position modes, and small helpers.
local rules = {}

-- Bounds on slot pre-allocation. Increasing requires bumping widget counts
-- in gui.lua; keep these in sync.
rules.MAX_RULES                 = 8
rules.MAX_CONDITIONS_PER_RULE   = 5

-- Movement-capable skill catalog. We intersect this against
-- get_equipped_spell_ids() at render time so the picker only shows skills
-- the character actually has on the bar. `needs_raycast` mirrors the LOS
-- requirement Batmobile's existing chain uses for that skill. `range` lets
-- us override the global spell_dist for skills with a known fixed reach
-- (e.g. Warlock movement is hardcoded to 15 in the legacy path).
rules.skill_catalog = {
    -- universal
    { id = 337031,  name = 'Evade',              needs_raycast = false, range = nil },
    -- sorcerer
    { id = 288106,  name = 'Teleport',           needs_raycast = false, range = nil },
    { id = 959728,  name = 'Teleport Enchanted', needs_raycast = false, range = nil },
    -- spiritborn
    { id = 1871821, name = 'Soar',               needs_raycast = false, range = nil },
    { id = 1871761, name = 'Rushing Claw',       needs_raycast = false, range = nil },
    { id = 1663206, name = 'Hunter',             needs_raycast = false, range = nil },
    -- rogue
    { id = 358761,  name = 'Dash',               needs_raycast = false, range = nil },
    -- barbarian
    { id = 196545,  name = 'Leap',               needs_raycast = false, range = nil },
    { id = 204662,  name = 'Charge',             needs_raycast = true,  range = nil },
    { id = 206435,  name = 'Whirlwind',          needs_raycast = false, range = nil },
    -- paladin
    { id = 2329865, name = 'Advance',            needs_raycast = true,  range = nil },
    { id = 2106904, name = 'Falling Star',       needs_raycast = true,  range = nil },
    { id = 2297125, name = 'Arbiter of Justice', needs_raycast = true,  range = nil },
    -- warlock
    { id = 2218211, name = 'Wraith Step',        needs_raycast = false, range = 15 },
    { id = 2221282, name = 'Demonic Slash',      needs_raycast = false, range = 15 },
}

rules.skill_by_id = {}
for _, s in ipairs(rules.skill_catalog) do rules.skill_by_id[s.id] = s end

-- Condition types. The combo at index 1 ("none") is the natural default,
-- meaning a condition row is empty / has no effect.
rules.condition_types = {
    { key = 'none',              label = '(none)',                  uses_op = false, uses_buff = false, uses_radius = false },
    { key = 'buff_active',       label = 'Buff is active',          uses_op = false, uses_buff = true,  uses_radius = false },
    { key = 'buff_not_active',   label = 'Buff is NOT active',      uses_op = false, uses_buff = true,  uses_radius = false },
    { key = 'buff_stacks',       label = 'Buff stacks',             uses_op = true,  uses_buff = true,  uses_radius = false },
    { key = 'skill_ready',       label = 'This skill is ready',     uses_op = false, uses_buff = false, uses_radius = false },
    { key = 'distance',          label = 'Distance to cast node',   uses_op = true,  uses_buff = false, uses_radius = false },
    { key = 'path_pack_density', label = 'Pack size on path',       uses_op = true,  uses_buff = false, uses_radius = true  },
}

rules.condition_labels = {}
for i, c in ipairs(rules.condition_types) do rules.condition_labels[i] = c.label end

rules.condition_key_by_index = {}
for i, c in ipairs(rules.condition_types) do rules.condition_key_by_index[i] = c.key end

rules.condition_meta_by_key = {}
for _, c in ipairs(rules.condition_types) do rules.condition_meta_by_key[c.key] = c end

-- Comparison operators. `ops` is the internal key list used by apply_op;
-- `op_labels` is the display string used in the GUI combo (the bare angle
-- brackets render poorly in QQT's font).
rules.ops = { '<', '<=', '=', '>=', '>' }
rules.op_labels = {
    '< (less than)',
    '<= (less or equal)',
    '= (equals)',
    '>= (greater or equal)',
    '> (greater than)',
}

-- Combinators
rules.combinators = { 'AND', 'OR' }

-- Cast position modes
rules.cast_positions = {
    { key = 'next_node',                   label = 'Toward next path node' },
    { key = 'toward_largest_pack_on_path', label = 'Toward largest pack on path' },
}
rules.cast_position_labels = {}
for i, p in ipairs(rules.cast_positions) do rules.cast_position_labels[i] = p.label end

rules.apply_op = function (op, a, b)
    if op == '<'  then return a <  b end
    if op == '<=' then return a <= b end
    if op == '='  then return a == b end
    if op == '>=' then return a >= b end
    if op == '>'  then return a >  b end
    return false
end

-- Equipped + movement-capable skills, in catalog order. Returns table of
-- catalog entries (each: {id, name, needs_raycast, range}).
rules.equipped_movement_skills = function ()
    local out = {}
    if type(get_equipped_spell_ids) ~= 'function' then return out end
    local ok, equipped = pcall(get_equipped_spell_ids)
    if not ok or type(equipped) ~= 'table' then return out end
    local equipped_set = {}
    for _, id in pairs(equipped) do
        if type(id) == 'number' then equipped_set[id] = true end
    end
    for _, s in ipairs(rules.skill_catalog) do
        if equipped_set[s.id] then out[#out + 1] = s end
    end
    return out
end

-- Build combo items for the rule's skill picker. Index 1 = "(none)".
rules.skill_combo_items = function (equipped_only)
    local items = { '(none)' }
    local src = equipped_only and rules.equipped_movement_skills() or rules.skill_catalog
    for i, s in ipairs(src) do items[i + 1] = s.name end
    return items, src
end

return rules
