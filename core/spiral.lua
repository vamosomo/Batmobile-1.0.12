-- Frigate spiral scan: samples points along an Archimedean spiral around a
-- center position and feeds findings into the map. Used during long-nav to:
--   * discover walkable terrain we haven't probed yet (player side AND target side),
--   * surface Traversal_Gizmo actors near the target so chained-traversal routing
--     can reach destinations across floors,
--   * give the path picker hints about reachable approach nodes.
--
-- Scans are budgeted across frames: at most STEP_BUDGET probes per tick. The
-- caller (long_nav.tick) advances the spiral cursor as the player moves so the
-- coverage expands organically rather than blocking on a synchronous sweep.

local utils = require 'core.utils'
local map   = require 'core.map'

local spiral = {}

-- Per-spiral state. A scan is identified by its center; if the center shifts
-- materially the spiral resets. We keep two independent spirals (player + target).
local STEP_BUDGET    = 8       -- probes per tick (one frame's worth)
local CENTER_RESET_R = 8.0     -- if center moves > this, restart the spiral
local DEFAULT_RADIUS = 60.0
local DEFAULT_STEP   = 12.0
local Z_PROBE_RANGE  = 8.0     -- vertical look-up window for set_height_of_valid_position fallback

local function _new_state(label)
    return {
        label       = label,
        center      = nil,
        radius_max  = DEFAULT_RADIUS,
        radius_step = DEFAULT_STEP,
        arc_idx     = 0,
        finished    = false,
        probe_count = 0,
        walkable_count = 0,
        last_advanced = -1,
    }
end

spiral.player = _new_state('player')
spiral.target = _new_state('target')

-- Configure both spirals' radii (called once per tick from long_nav).
function spiral.set_config(radius, step)
    if radius and radius > 0 then
        spiral.player.radius_max = radius
        spiral.target.radius_max = radius
    end
    if step and step > 0 then
        spiral.player.radius_step = step
        spiral.target.radius_step = step
    end
end

-- Recenter and (if necessary) restart the spiral.
local function _set_center(st, pos)
    if not pos then return end
    if not st.center then
        st.center   = pos
        st.arc_idx  = 0
        st.finished = false
        return
    end
    local dx = pos:x() - st.center:x()
    local dy = pos:y() - st.center:y()
    if math.sqrt(dx*dx + dy*dy) > CENTER_RESET_R then
        st.center   = pos
        st.arc_idx  = 0
        st.finished = false
        st.probe_count = 0
        st.walkable_count = 0
    else
        -- nudge the center toward the latest sample (helps tracking)
        st.center = pos
    end
end

-- Generate the next sample point along the spiral.
-- Archimedean: r = radius_step * arc_idx / (2*pi); theta = arc_idx * golden_angle.
-- The golden angle (137.5deg) gives near-uniform coverage without rings collapsing.
local GOLDEN_ANGLE = math.rad(137.50776)
local TWO_PI       = math.pi * 2

local function _next_sample(st)
    if not st.center then return nil end
    if st.finished then return nil end
    local k     = st.arc_idx
    local theta = k * GOLDEN_ANGLE
    -- radial growth: each step out adds radius_step / TWO_PI to r.
    local r     = st.radius_step * (k * 0.18 + 0.5)
    if r > st.radius_max then
        st.finished = true
        return nil
    end
    local pt = vec3:new(
        st.center:x() + math.cos(theta) * r,
        st.center:y() + math.sin(theta) * r,
        st.center:z()
    )
    st.arc_idx = k + 1
    return pt, r
end

-- Probe a sample point: snap to valid Z and check walkability. Record findings
-- in the map. Returns true if walkable.
local function _probe(pt, st)
    if not pt then return false end
    local snapped = pt
    if utility and utility.set_height_of_valid_position then
        local ok, val = pcall(utility.set_height_of_valid_position, pt)
        if ok and val then snapped = val end
    end
    local walk = false
    if utility and utility.is_point_walkeable then
        local ok, val = pcall(utility.is_point_walkeable, snapped)
        if ok then walk = val and true or false end
    end
    map.record_cell(snapped, walk)
    st.probe_count = st.probe_count + 1
    if walk then st.walkable_count = st.walkable_count + 1 end
    return walk
end

-- advance_spiral(st, center, budget) — run up to `budget` probes; returns number probed.
local function _advance(st, center, budget)
    _set_center(st, center)
    if st.finished then return 0 end
    local probed = 0
    for i = 1, budget do
        local pt = _next_sample(st)
        if not pt then break end
        _probe(pt, st)
        probed = probed + 1
    end
    st.last_advanced = get_time_since_inject and get_time_since_inject() or 0
    return probed
end

-- Top-level: called every long_nav tick.
function spiral.tick(player_pos, target_pos, opts)
    opts = opts or {}
    local budget = opts.step_budget or STEP_BUDGET
    -- Player-side spiral always runs.
    if player_pos then
        _advance(spiral.player, player_pos, budget)
    end
    -- Target-side spiral runs when enabled.
    if opts.spiral_around_target and target_pos then
        _advance(spiral.target, target_pos, math.max(1, math.floor(budget / 2)))
    end
end

-- reset() — wipe both spirals. Call on stop_navigation / orchestrator reset.
function spiral.reset()
    spiral.player = _new_state('player')
    spiral.target = _new_state('target')
end

-- has_target_coverage(target_pos, radius) — true if the target spiral has
-- probed at least one walkable cell within `radius` of the target. The long_nav
-- loop uses this to decide whether to wait for more scanning before committing
-- to a path that ends on possibly-blocked mesh.
function spiral.has_target_coverage(target_pos, radius)
    if not target_pos then return false end
    radius = radius or 6.0
    local trs = map.get_traversals_near(target_pos, radius)
    if #trs > 0 then return true end
    -- Walk cells within radius and see if any are known-walkable.
    local r2 = radius * radius
    for _, cell in pairs(map.cells) do
        if cell.walkable then
            local dx = cell.x - target_pos:x()
            local dy = cell.y - target_pos:y()
            if dx*dx + dy*dy <= r2 then return true end
        end
    end
    return false
end

function spiral.stats()
    return string.format('player=%d/%d  target=%d/%d',
        spiral.player.walkable_count, spiral.player.probe_count,
        spiral.target.walkable_count, spiral.target.probe_count)
end

return spiral
