-- Frigate map: persistent (per-session) terrain / traversal / floor cache
-- built up as the player navigates. The pathfinder operates on a 2D walkable
-- grid that has zero awareness of Z. The map plugs that gap by:
--
--  * bucketing observations into Z-bands (~floors) so long-distance paths can
--    plan across vertical separations,
--  * remembering walkable / unwalkable cells we have already probed (so spiral
--    scans don't re-probe),
--  * caching every Traversal_Gizmo we observe with its position, name, and the
--    Z-deltas observed on either side of crossings (so long_nav can chain
--    traversals to bridge 100u+ of z variance),
--  * surfacing summary stats / debug overlays.
--
-- The map is intentionally lightweight: no save/load to disk, no cross-session
-- persistence. Reset on character death / portal hop / orchestrator request.

local utils = require 'core.utils'

local map = {}

-- Grid cell size in units. Matches the pathfinder normalization step.
local CELL_SIZE  = 1.0
-- Z-band size: positions whose z values are within this distance share a floor.
local FLOOR_BAND = 6.0
-- Z-delta to call a traversal a 'big climb' vs minor step.
local BIG_DZ     = 4.0
-- Traversal de-duplication radius (units, XY only). Two scans of the same gizmo
-- can return slightly different center positions; collapse them.
local TRAV_DEDUP_R = 2.0
-- How often to scan for new traversals (s). Actors don't move, so a slightly
-- stale cache is safe; this just bounds the per-tick work.
local SCAN_INTERVAL = 0.5
-- Bounding box of cells we'll ever store. Long-distance nav can wander far;
-- this is purely a safety cap so a buggy observer can't OOM us.
local MAX_CELLS = 200000

-- ----- internal state -----
map.cells       = {}    -- "x,y" -> { x, y, z, floor_id, walkable, visit_count, last_t }
map.cells_count = 0
map.traversals  = {}    -- list { id, name, pos, floor_id, z, first_seen, last_seen, paired_id }
map.trav_by_id  = {}    -- id (= name+rounded pos) -> idx in map.traversals
map.floors      = {}    -- floor_id -> { z_min, z_max, cell_count, sample_z }

local _next_floor_id   = 1
local _last_scan_time  = -1

local function _floor_key(z)
    return math.floor(z / FLOOR_BAND + 0.5)
end

local function _cell_key(x, y)
    -- Snap to CELL_SIZE grid and key as "ix,iy" so different decimals collapse.
    local ix = math.floor(x / CELL_SIZE + 0.5)
    local iy = math.floor(y / CELL_SIZE + 0.5)
    return ix .. ',' .. iy, ix, iy
end

local function _ensure_floor(z)
    local fk = _floor_key(z)
    local f = map.floors[fk]
    if not f then
        f = {
            id          = fk,
            z_min       = z,
            z_max       = z,
            cell_count  = 0,
            sample_z    = z,
        }
        map.floors[fk] = f
    else
        if z < f.z_min then f.z_min = z end
        if z > f.z_max then f.z_max = z end
    end
    return f
end

-- record_cell(pos, walkable) — call when we know whether a cell is walkable.
function map.record_cell(pos, walkable)
    if map.cells_count >= MAX_CELLS then return end
    local key, ix, iy = _cell_key(pos:x(), pos:y())
    local cell = map.cells[key]
    local floor = _ensure_floor(pos:z())
    if not cell then
        cell = {
            x           = ix * CELL_SIZE,
            y           = iy * CELL_SIZE,
            z           = pos:z(),
            floor_id    = floor.id,
            walkable    = walkable and true or false,
            visit_count = 0,
            last_t      = -1,
        }
        map.cells[key] = cell
        map.cells_count = map.cells_count + 1
        floor.cell_count = floor.cell_count + 1
    else
        -- If we've now learned the cell is walkable, upgrade. Don't downgrade
        -- (a one-off raycast miss shouldn't permanently flag an island).
        if walkable then cell.walkable = true end
        cell.z = pos:z()
    end
    return cell
end

-- mark_visited(pos) — the player stood here. Implies walkable.
function map.mark_visited(pos)
    local cell = map.record_cell(pos, true)
    if cell then
        cell.visit_count = cell.visit_count + 1
        cell.last_t      = get_time_since_inject and get_time_since_inject() or 0
    end
end

local function _trav_id(name, pos)
    local rx = math.floor(pos:x() / TRAV_DEDUP_R + 0.5)
    local ry = math.floor(pos:y() / TRAV_DEDUP_R + 0.5)
    return (name or '?') .. '@' .. rx .. ',' .. ry
end

-- record_traversal(actor) — call with a Traversal_Gizmo actor.
function map.record_traversal(actor)
    if not actor or not actor.get_position then return end
    local name = actor:get_skin_name() or 'trav'
    local pos  = actor:get_position()
    if not pos then return end
    local id  = _trav_id(name, pos)
    local now = get_time_since_inject and get_time_since_inject() or 0
    local entry = map.trav_by_id[id]
    if not entry then
        local floor = _ensure_floor(pos:z())
        entry = {
            id         = id,
            name       = name,
            pos        = pos,
            floor_id   = floor.id,
            z          = pos:z(),
            first_seen = now,
            last_seen  = now,
            paired_id  = nil,   -- set after we observe the player crossing to another floor
            cross_count = 0,
            actor      = actor,  -- live actor reference for interact_object(actor)
        }
        local idx = #map.traversals + 1
        map.traversals[idx] = entry
        map.trav_by_id[id]  = entry
    else
        entry.last_seen = now
        -- Refresh actor handle: re-zoning can invalidate the prior reference.
        entry.actor     = actor
    end
    return entry
end

-- observe(local_player) — cheap, called every frame. Records the cell under the
-- player and (throttled) scans for nearby traversal gizmos.
function map.observe(local_player)
    if not local_player or not local_player.get_position then return end
    local pos = local_player:get_position()
    if not pos then return end
    map.mark_visited(pos)

    local now = get_time_since_inject and get_time_since_inject() or 0
    if now - _last_scan_time < SCAN_INTERVAL then return end
    _last_scan_time = now

    -- Find any Traversal_Gizmo actors in scan range and cache them.
    if not actors_manager or not actors_manager.get_all_actors then return end
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local ok, name = pcall(function() return actor:get_skin_name() end)
        if ok and name and name:match('[Tt]raversal_Gizmo') then
            map.record_traversal(actor)
        end
    end
end

-- get_traversals_near(pos, radius) — XY-only filter, all floors.
function map.get_traversals_near(pos, radius)
    local px, py = pos:x(), pos:y()
    local r2 = radius * radius
    local out = {}
    for i = 1, #map.traversals do
        local t = map.traversals[i]
        local dx, dy = t.pos:x() - px, t.pos:y() - py
        if dx*dx + dy*dy <= r2 then
            out[#out + 1] = t
        end
    end
    return out
end

-- get_traversals_bridging(from_z, to_z, max_dz) — returns traversals whose Z
-- lies between from_z and to_z (with a slack), useful for picking a candidate
-- to bridge a known vertical gap.
function map.get_traversals_bridging(from_z, to_z, max_dz)
    max_dz = max_dz or BIG_DZ * 2
    local zlo = math.min(from_z, to_z) - max_dz
    local zhi = math.max(from_z, to_z) + max_dz
    local out = {}
    for i = 1, #map.traversals do
        local t = map.traversals[i]
        if t.z >= zlo and t.z <= zhi then
            out[#out + 1] = t
        end
    end
    return out
end

-- get_walkable(pos) — true if we know the cell is walkable, false if we know
-- it's blocked, nil if unknown. Consumers should fall back to live raycast.
function map.get_walkable(pos)
    local key = _cell_key(pos:x(), pos:y())
    local cell = map.cells[key]
    if not cell then return nil end
    return cell.walkable
end

function map.floor_for(pos)
    return _floor_key(pos:z())
end

function map.reset()
    map.cells       = {}
    map.cells_count = 0
    map.traversals  = {}
    map.trav_by_id  = {}
    map.floors      = {}
    _last_scan_time = -1
    _next_floor_id  = 1
end

function map.stats_string()
    local nfloors = 0
    for _ in pairs(map.floors) do nfloors = nfloors + 1 end
    return string.format('cells=%d  traversals=%d  floors=%d',
        map.cells_count, #map.traversals, nfloors)
end

return map
