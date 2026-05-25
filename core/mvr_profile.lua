-- core/mvr_profile.lua
-- Movement Revamp profile save / load.
-- Mirrors the UR multi-profile pattern: manifest JSON + one file per profile.
-- No cloud sharing.

local profile_io = require 'core.profile_io'
local mrul       = require 'core.movement_rules'
local mhelp      = require 'core.movement_helpers'

local M = {}

local LABEL = '[Batmobile/Profile]'
local function _log(msg) console.print(LABEL .. ' ' .. msg) end

-- ---- Path helpers --------------------------------------------------------

local function _script_root()
    local p = string.gmatch(package.path, '.*?\\?')()
    return p and p:gsub('?', '') or ''
end

local function _manifest_path()
    return _script_root() .. 'batmobile_mvr_manifest.json'
end

local function _profile_path(name)
    name = name or 'Default'
    if name == 'Default' then
        return _script_root() .. 'batmobile_mvr_default.json'
    end
    local safe = tostring(name):lower():gsub('%s+', '_'):gsub('[^%w_]', '')
    return _script_root() .. 'batmobile_mvr_' .. safe .. '.json'
end

-- ---- State ---------------------------------------------------------------

local _profile_names    = {}
local _active_profile   = 'Default'
local _last_profile_idx = nil
local _last_saved_json  = nil
local _last_autosave_t  = 0
local AUTOSAVE_INTERVAL = 10.0
local _apply_gen        = 0   -- incremented on every slider rebuild

-- ---- Manifest ------------------------------------------------------------

local function _save_manifest()
    local json = profile_io.to_json({ active = _active_profile, profiles = _profile_names })
    profile_io.write_file(_manifest_path(), json)
end

local function _load_manifest()
    local json = profile_io.read_file(_manifest_path())
    if json then
        local d = profile_io.from_json(json)
        if type(d) == 'table' then
            _profile_names  = type(d.profiles) == 'table' and d.profiles or { 'Default' }
            _active_profile = type(d.active)   == 'string' and d.active  or 'Default'
        end
    end
    if #_profile_names == 0 then _profile_names = { 'Default' } end
    -- Ensure active profile is in the list
    local found = false
    for _, n in ipairs(_profile_names) do
        if n == _active_profile then found = true; break end
    end
    if not found then _active_profile = _profile_names[1] end
end

local function _get_active_index()
    for i, n in ipairs(_profile_names) do
        if n == _active_profile then return i - 1 end  -- 0-based for combo_box
    end
    return 0
end

-- ---- Widget helpers ------------------------------------------------------

local function _set_el(el, val)
    if not el or val == nil then return end
    if type(el.set) == 'function' then pcall(el.set, el, val) end
end

-- Sliders have no :set() on this host.  Rebuild with a fresh hash so the
-- host has no cached value and renders the widget at its constructor default
-- (= the value we want to load).  Identical to the UR _apply_global_slider
-- trick; generation counter ensures the hash is unique every time.
local function _rsl_int(tbl, key, min, max, val)
    if val == nil then return end
    _apply_gen = _apply_gen + 1
    tbl[key] = slider_int:new(min, max, val,
        get_hash('batmobile_mvr_apply_g' .. _apply_gen))
end

-- ---- Snapshot: widgets -> data table -------------------------------------

local function _build_data(name)
    local gui  = require 'gui'
    local data = {
        version     = 1,
        name        = name or _active_profile,
        mvr_enabled = gui.elements.mvr_enabled and gui.elements.mvr_enabled:get() or false,
        rule_count  = gui.elements.mvr_active_rule_count
                        and gui.elements.mvr_active_rule_count:get() or 0,
        rules       = {},
    }
    for r = 1, mrul.MAX_RULES do
        local rw = gui.elements.mvr_rule_widgets and gui.elements.mvr_rule_widgets[r]
        if rw then
            local rd = {
                enabled           = rw.enabled:get(),
                skill_idx         = rw.skill:get()           or 0,
                cast_position_idx = rw.cast_position:get()   or 0,
                density_radius    = rw.density_radius:get()  or 6,
                throttle_ms       = rw.throttle_ms:get()     or 0,
                cond_count        = rw.active_cond_count:get() or 0,
                conditions        = {},
            }
            for c = 1, mrul.MAX_CONDITIONS_PER_RULE do
                local cw = rw.cond_widgets and rw.cond_widgets[c]
                if cw then
                    -- Resolve buff_hash from combo when the slider was never
                    -- explicitly set. This means picking a buff from the combo
                    -- dropdown is enough — the hash is captured at autosave time
                    -- and persists correctly across logins and characters.
                    local bh = cw.buff_hash:get() or 0
                    if bh == 0 then
                        local bc_idx = cw.buff_combo:get() or 0
                        bh = mhelp.buff_hash_for_combo_index(bc_idx) or 0
                    end
                    rd.conditions[c] = {
                        combinator = cw.combinator:get() or 0,
                        type       = cw.type:get()       or 0,
                        buff_combo = cw.buff_combo:get() or 0,
                        buff_hash  = bh,
                        op         = cw.op:get()         or 0,
                        value      = cw.value:get()      or 0,
                        radius     = cw.radius:get()     or 6,
                    }
                end
            end
            data.rules[r] = rd
        end
    end
    return data
end

-- ---- Restore: data table -> widgets --------------------------------------

local function _apply_data(data)
    if type(data) ~= 'table' then return false end
    local gui = require 'gui'

    _set_el(gui.elements.mvr_enabled, data.mvr_enabled)
    _rsl_int(gui.elements, 'mvr_active_rule_count', 0, mrul.MAX_RULES, data.rule_count)

    local rules = type(data.rules) == 'table' and data.rules or {}
    for r = 1, mrul.MAX_RULES do
        local rw = gui.elements.mvr_rule_widgets and gui.elements.mvr_rule_widgets[r]
        local rd = rules[r]
        if rw and rd then
            _set_el(rw.enabled,       rd.enabled)
            _set_el(rw.skill,         rd.skill_idx)
            _set_el(rw.cast_position, rd.cast_position_idx)
            _rsl_int(rw, 'density_radius',    1, 20,                           rd.density_radius)
            _rsl_int(rw, 'throttle_ms',       0, 5000,                         rd.throttle_ms)
            _rsl_int(rw, 'active_cond_count', 0, mrul.MAX_CONDITIONS_PER_RULE, rd.cond_count)

            local conds = type(rd.conditions) == 'table' and rd.conditions or {}
            for c = 1, mrul.MAX_CONDITIONS_PER_RULE do
                local cw = rw.cond_widgets and rw.cond_widgets[c]
                local cd = conds[c]
                if cw and cd then
                    _set_el(cw.combinator, cd.combinator)
                    _set_el(cw.type,       cd.type)
                    _set_el(cw.op,         cd.op)
                    _rsl_int(cw, 'buff_hash', 0, 1073741823, cd.buff_hash)
                    _rsl_int(cw, 'value',     0, 100,        cd.value)
                    _rsl_int(cw, 'radius',    1, 20,         cd.radius)
                    -- Restore the combo to the correct catalog position for the
                    -- saved hash. Seed first so the entry always exists, then
                    -- find its index — this way the combo shows the real buff name
                    -- rather than "(unused N)" regardless of catalog observation order.
                    if cd.buff_hash and cd.buff_hash > 0 then
                        mhelp.seed_buff_hash(cd.buff_hash)
                        local combo_idx = 0
                        for idx, entry in ipairs(mhelp.known_buffs_ordered) do
                            if entry.hash == cd.buff_hash then
                                combo_idx = idx  -- catalog[idx] maps to combo index idx
                                break
                            end
                        end
                        _set_el(cw.buff_combo, combo_idx)
                    else
                        _set_el(cw.buff_combo, cd.buff_combo)
                    end
                end
            end
        end
    end
    return true
end

-- ---- File I/O ------------------------------------------------------------

local function _export(name)
    name = name or _active_profile
    local data = _build_data(name)
    local json = profile_io.to_json(data)
    local ok   = profile_io.write_file(_profile_path(name), json)
    if ok then
        _log('Saved: ' .. name)
        if name == _active_profile then _last_saved_json = json end
    else
        _log('Save failed: ' .. name)
    end
    _save_manifest()
end

local function _import(name, silent)
    name = name or _active_profile
    local json = profile_io.read_file(_profile_path(name))
    if not json then
        if not silent then _log('Profile not found: ' .. name) end
        return false
    end
    local data = profile_io.from_json(json)
    if type(data) ~= 'table' then
        if not silent then _log('Invalid JSON for: ' .. name) end
        return false
    end
    if name == _active_profile then _last_saved_json = json end
    local ok = _apply_data(data)
    if ok and not silent then _log('Loaded: ' .. name) end
    return ok
end

-- ---- CRUD ----------------------------------------------------------------

local function _switch(new_name)
    if new_name == _active_profile then return end
    _export(_active_profile)
    _active_profile = new_name
    _save_manifest()
    _import(new_name, false)
end

local function _create_new()
    local old = _active_profile
    _export(old)
    -- Find next unique name
    local num  = #_profile_names + 1
    local name = 'Profile ' .. num
    local busy = true
    while busy do
        busy = false
        for _, n in ipairs(_profile_names) do
            if n == name then busy = true; break end
        end
        if busy then num = num + 1; name = 'Profile ' .. num end
    end
    table.insert(_profile_names, name)
    _active_profile = name
    _export(name)
    _save_manifest()
    _log('Created: ' .. name .. ' (copy of ' .. old .. ')')
end

local function _delete()
    if #_profile_names <= 1 then
        _log('Cannot delete the last profile.')
        return
    end
    local target = _active_profile
    local path   = _profile_path(target)
    for i, n in ipairs(_profile_names) do
        if n == target then table.remove(_profile_names, i); break end
    end
    _active_profile = _profile_names[1] or 'Default'
    _save_manifest()
    pcall(function() os.remove(path) end)
    _import(_active_profile, false)
    _log('Deleted: ' .. target)
end

local function _rename(new_name)
    new_name = tostring(new_name):gsub('^%s+', ''):gsub('%s+$', '')
    if new_name == '' or new_name == _active_profile then return end
    for _, n in ipairs(_profile_names) do
        if n == new_name then _log('Name already in use: ' .. new_name); return end
    end
    local old      = _active_profile
    local old_path = _profile_path(old)
    local new_path = _profile_path(new_name)
    for i, n in ipairs(_profile_names) do
        if n == old then _profile_names[i] = new_name; break end
    end
    _active_profile = new_name
    -- Copy file under new name then delete old
    local content = profile_io.read_file(old_path)
    if content then
        profile_io.write_file(new_path, content)
        pcall(function() os.remove(old_path) end)
    end
    _save_manifest()
    _log('Renamed: ' .. old .. ' -> ' .. new_name)
end

-- ---- Autosave ------------------------------------------------------------

local function _autosave()
    if _active_profile == '' then return end
    local now = get_time_since_inject()
    if now - _last_autosave_t < AUTOSAVE_INTERVAL then return end
    _last_autosave_t = now
    local data = _build_data(_active_profile)
    local json = profile_io.to_json(data)
    if json == _last_saved_json then return end
    local ok = profile_io.write_file(_profile_path(_active_profile), json)
    if ok then _last_saved_json = json end
end

-- ---- Public API ----------------------------------------------------------

-- Call once at script load to restore the last active profile.
function M.init()
    _load_manifest()
    _import(_active_profile, true)
    local gui = require 'gui'
    _last_profile_idx = _get_active_index()
    _set_el(gui.elements.profile_combo, _last_profile_idx)
    _log('Ready. Active: ' .. _active_profile)
end

-- Call every tick from main_pulse. Handles combo switching and autosave only.
-- Button clicks (New / Delete / Rename) are handled in main.lua directly,
-- mirroring UR's pattern of reading gui.elements from the top-level module
-- rather than from inside a require'd module.
function M.handle_io()
    local gui = require 'gui'

    if gui.elements.profile_combo then
        local sel = gui.elements.profile_combo:get()
        if type(sel) == 'number' and sel ~= _last_profile_idx then
            local new_name = _profile_names[sel + 1]
            if new_name and new_name ~= _active_profile then
                _switch(new_name)
            end
            _last_profile_idx = sel
        end
    end

    _autosave()
end

-- Individual profile operations called directly from main.lua.
function M.create_new()
    _create_new()
    _last_profile_idx = _get_active_index()
end

function M.delete()
    _delete()
    _last_profile_idx = _get_active_index()
end

function M.rename(new_name)
    _rename(new_name)
    _last_profile_idx = _get_active_index()
end

function M.get_active_index()   return _get_active_index()  end
function M.get_profile_names()  return _profile_names       end
function M.get_active_profile() return _active_profile      end

return M
