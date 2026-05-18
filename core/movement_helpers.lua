-- Movement revamp helpers: buff lookup, density-on-path, enemy enumeration,
-- can-cast caching, and the grow-only buff catalog used by the GUI.
local helpers = {}

-- ────────────────────────────────────────────────────────────────────────
-- can_cast cache (per-tick). utility.can_cast_spell is cheap but called
-- many times per frame when the engine walks rules; coalesce per tick.
-- ────────────────────────────────────────────────────────────────────────
local can_cast_cache = {}
local can_cast_cache_tick = -1

helpers.can_cast = function (skill_id)
    if not skill_id then return false end
    local now = get_time_since_inject()
    if now ~= can_cast_cache_tick then
        can_cast_cache = {}
        can_cast_cache_tick = now
    end
    local v = can_cast_cache[skill_id]
    if v == nil then
        v = utility.can_cast_spell(skill_id) == true
        can_cast_cache[skill_id] = v
    end
    return v
end

-- ────────────────────────────────────────────────────────────────────────
-- Buff helpers
-- ────────────────────────────────────────────────────────────────────────
helpers.get_player_buffs = function (local_player)
    if not local_player or type(local_player.get_buffs) ~= 'function' then return {} end
    return local_player:get_buffs() or {}
end

local function _buff_hash(b)
    if type(b.get_name_hash) == 'function' then
        return tonumber(b:get_name_hash())
    elseif type(b.name_hash) == 'number' then
        return b.name_hash
    elseif type(b.name_hash) == 'string' then
        return tonumber(b.name_hash)
    end
    return nil
end

local function _buff_name(b)
    -- In QQT, `b.name` is itself a function (callable). Try invoking it
    -- first; only fall through to `get_name` or a literal string field.
    -- (Mirrors UniversalRotation's buff_provider resolution order.)
    local n = nil
    if type(b.name) == 'function' then
        local ok, v = pcall(b.name, b)
        if ok then n = v end
    elseif type(b.get_name) == 'function' then
        local ok, v = pcall(b.get_name, b)
        if ok then n = v end
    elseif type(b.name) == 'string' then
        n = b.name
    end
    if type(n) == 'string' and n ~= '' then return n end
    return nil
end

helpers.find_buff = function (buffs, name_hash)
    if not name_hash or name_hash == 0 then return nil end
    for _, b in pairs(buffs or {}) do
        if _buff_hash(b) == name_hash then return b end
    end
    return nil
end

helpers.buff_stacks = function (buff)
    if not buff then return 0 end
    if type(buff.get_stacks) == 'function' then
        local ok, s = pcall(buff.get_stacks, buff)
        if ok then return tonumber(s) or 0 end
    end
    if type(buff.stacks) == 'number' then return buff.stacks end
    return 0
end

-- ────────────────────────────────────────────────────────────────────────
-- Grow-only buff catalog. We never shrink this list across the session so
-- combo_box indices remain stable (QQT widget :set() on a shrinking combo
-- has historically crashed). The GUI pulls items from `ordered`.
-- ────────────────────────────────────────────────────────────────────────
helpers.known_buffs_by_hash = {}
helpers.known_buffs_ordered = {}        -- { {name=, hash=}, ... } stable index

local function _looks_like_bad_name(s)
    -- Stale entries from before the resolution fix were tostring(function),
    -- which serializes as "function: 0x...". Detect those so we can replace.
    if type(s) ~= 'string' then return true end
    if s == '' then return true end
    if s:sub(1, 9) == 'function:' then return true end
    return false
end

helpers.observe_buffs = function (local_player)
    local buffs = helpers.get_player_buffs(local_player)
    for _, b in pairs(buffs) do
        local h = _buff_hash(b)
        if h and h ~= 0 then
            local existing = helpers.known_buffs_by_hash[h]
            if not existing then
                local nm = _buff_name(b) or ('buff_' .. tostring(h))
                local entry = { name = nm, hash = h }
                helpers.known_buffs_by_hash[h] = entry
                helpers.known_buffs_ordered[#helpers.known_buffs_ordered + 1] = entry
                console.print(string.format('[mvr] buff catalog +1: name="%s" hash=%d (combo idx=%d)',
                    tostring(nm), h, #helpers.known_buffs_ordered))
            elseif _looks_like_bad_name(existing.name) then
                -- Upgrade in place. `entry` is shared with known_buffs_ordered
                -- so mutating its `name` field updates both lookups.
                local nm = _buff_name(b)
                if nm and not _looks_like_bad_name(nm) then
                    console.print(string.format('[mvr] buff catalog refresh: hash=%d "%s" -> "%s"',
                        h, tostring(existing.name), tostring(nm)))
                    existing.name = nm
                end
            end
        end
    end
end

-- Labels for the buff combo. Index 0 = "(none)"; indices 1..N show
-- observed/seeded buff names. The combo's persisted index can outlive
-- the in-memory catalog (combo state survives reload via QQT registry,
-- but the catalog is rebuilt each session). Callers should also call
-- `seed_buff_hash` per-condition before render so user-saved hashes get
-- appended as "Buff #<hash>" placeholders.
--
-- Defensive padding: even after seeding, the combo's saved index might
-- exceed the catalog length (e.g. previous session saw more buffs than
-- got seeded this session). Pad with "(unused #N)" placeholders so
-- combo render never goes out-of-bounds in QQT's wrapper.
local BUFF_COMBO_MIN_ITEMS = 32

helpers.buff_combo_items = function ()
    local items = { '(none)' }
    local observed = #helpers.known_buffs_ordered
    for i = 1, observed do
        items[i + 1] = helpers.known_buffs_ordered[i].name
    end
    local pad_to = math.max(BUFF_COMBO_MIN_ITEMS, observed)
    for i = observed + 1, pad_to do
        items[i + 1] = '(unused ' .. i .. ')'
    end
    return items
end

-- UR's _seed_saved_buff pattern: ensure a user-saved hash is always
-- present in the catalog so it renders as a real combo entry on reload
-- (with a placeholder name until the buff is observed live).
helpers.seed_buff_hash = function (hash)
    if not hash or hash == 0 then return end
    if helpers.known_buffs_by_hash[hash] then return end
    -- Avoid '#' in the label: ImGui treats it as an ID delimiter and QQT's
    -- combo_box wrapper has been observed to crash on labels containing '#'.
    local entry = { name = 'Buff hash ' .. tostring(hash), hash = hash }
    helpers.known_buffs_by_hash[hash] = entry
    helpers.known_buffs_ordered[#helpers.known_buffs_ordered + 1] = entry
    console.print(string.format('[mvr] buff catalog seeded from saved hash=%d (combo idx=%d)',
        hash, #helpers.known_buffs_ordered))
end

-- Map a combo selection (0-indexed; 0 = "(none)") to a buff hash, or nil.
helpers.buff_hash_for_combo_index = function (idx)
    if not idx or idx <= 0 then return nil end
    local entry = helpers.known_buffs_ordered[idx]
    if entry then return entry.hash end
    return nil
end

-- ────────────────────────────────────────────────────────────────────────
-- Enemy enumeration (per-tick cache)
-- ────────────────────────────────────────────────────────────────────────
local enemies_cache = nil
local enemies_cache_tick = -1

helpers.get_enemies = function ()
    local now = get_time_since_inject()
    if now == enemies_cache_tick and enemies_cache then return enemies_cache end
    enemies_cache_tick = now
    local list = {}
    if actors_manager and type(actors_manager.get_enemy_npcs) == 'function' then
        local ok, raw = pcall(actors_manager.get_enemy_npcs)
        if ok and raw then
            for _, e in pairs(raw) do
                if e then
                    local alive = true
                    if type(e.is_dead) == 'function' then
                        local ok_d, dead = pcall(e.is_dead, e)
                        if ok_d and dead then alive = false end
                    end
                    if alive then list[#list + 1] = e end
                end
            end
        end
    end
    enemies_cache = list
    return list
end

-- ────────────────────────────────────────────────────────────────────────
-- Path-pack density: for each (every Nth) node along `path`, count enemies
-- within `radius`. Returns (best_count, best_node).
-- Subsamples the path when long to keep cost bounded.
-- ────────────────────────────────────────────────────────────────────────
helpers.largest_pack_on_path = function (path, radius)
    if not path or #path == 0 then return 0, nil end
    local enemies = helpers.get_enemies()
    if #enemies == 0 then return 0, nil end
    local r = radius or 6
    local r2 = r * r
    local step = 1
    if #path > 24 then step = 2 end
    if #path > 60 then step = 3 end
    local best_count, best_node = 0, nil
    for i = 1, #path, step do
        local node = path[i]
        if node and node.x then
            local nx, ny = node:x(), node:y()
            local count = 0
            for _, e in ipairs(enemies) do
                local pos
                if type(e.get_position) == 'function' then
                    local ok, p = pcall(e.get_position, e)
                    if ok then pos = p end
                end
                if pos then
                    local dx = pos:x() - nx
                    local dy = pos:y() - ny
                    if dx * dx + dy * dy <= r2 then count = count + 1 end
                end
            end
            if count > best_count then
                best_count = count
                best_node = node
            end
        end
    end
    return best_count, best_node
end

return helpers
