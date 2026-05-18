-- Frigate test targets: named waypoints we can pick from a GUI dropdown to
-- exercise long-nav against known locations across the world.
--
-- Two sources of maiden positions:
--   * HR baseline — the 6 hardcoded entries originally from
--     HelltideRevamped-0.4/data/enums.lua (which inherited them from the
--     archived helltide_maiden_auto plugin, verified against the last waypoint
--     of each *_to_maiden.lua file).
--   * Community nav dump — additional spawn sites discovered by scraping
--     S04_SMP_Succuboss_Altar_A_Dyn actor positions across many sessions. Each
--     additional entry below has a `sessions` comment showing how many merged
--     sessions confirmed the site (proxy for confidence). Sites with sessions=1
--     are speculative — use the primary site first.
--
-- Adding a new entry: append to test_targets.entries. The GUI rebuilds the
-- combo from this list so order matters (entry 1 is "(none)").

local test_targets = {}

-- Each entry: { label, region, zone, world, pos = vec3 } or { label, kind = 'none' }.
--   region  — helltide region prefix Frigate / HR plugins key off (Frac_, Hawe_, …)
--   zone    — playable-zone string the in-game world uses
--   world   — engine-level world name (Sanctuary_Eastern_Continent for overworld,
--             DGN_<x> for dungeon interiors). The orchestrator should check that
--             the player's current world matches before triggering long-nav, or
--             the run will be against a target the engine can't pathfind to.
test_targets.entries = {
    { label = '(none — use pinned target)', kind = 'none' },

    -- ── Helltide maiden altars (overworld) ───────────────────────────────────
    -- Fractured Peaks (Frac_)
    { label = 'Maiden — Frac_Tundra_S #1 primary (Fractured Peaks)',
      region = 'Frac_', zone = 'Frac_Tundra_S', world = 'Sanctuary_Eastern_Continent',
      pos    = vec3:new(-1517.776733,  -20.840151, 105.299805) },   -- HR baseline; 26 dump sessions

    { label = 'Maiden — Frac_Tundra_S #2 alt (Fractured Peaks)',
      region = 'Frac_', zone = 'Frac_Tundra_S', world = 'Sanctuary_Eastern_Continent',
      pos    = vec3:new(-1660.0,         167.2,    95.1) },          -- dump only; 7 sessions

    -- Scosglen (Scos_)
    { label = 'Maiden — Scos_Coast (Scosglen)',
      region = 'Scos_', zone = 'Scos_Coast', world = 'Sanctuary_Eastern_Continent',
      pos    = vec3:new(-1982.549438, -1143.823364,  12.758240) },   -- HR baseline; 13 dump sessions

    -- Kehjistan (Kehj_). Note: the dump catalogues all three Kehj altars under
    -- zone=Kehj_Oasis, but HR has historically labelled the 7.5z altar as
    -- Kehj_HighDesert (it physically straddles a zone boundary; HR's runtime
    -- zone check reports HighDesert from where the player approaches).
    { label = 'Maiden — Kehj_Oasis #1 primary (Kehjistan, high-conf)',
      region = 'Kehj_', zone = 'Kehj_Oasis', world = 'Sanctuary_Eastern_Continent',
      pos    = vec3:new(  374.5,       -765.7,      15.6) },          -- dump only; 27 sessions

    { label = 'Maiden — Kehj_HighDesert (Kehjistan, HR-labelled site)',
      region = 'Kehj_', zone = 'Kehj_HighDesert', world = 'Sanctuary_Eastern_Continent',
      pos    = vec3:new(  120.874367,  -746.962341,   7.089052) },    -- HR baseline; 3 dump sessions
                                                                       -- (dump zone = Kehj_Oasis)

    { label = 'Maiden — Kehj_Oasis #3 east-edge (Kehjistan, speculative)',
      region = 'Kehj_', zone = 'Kehj_Oasis', world = 'Sanctuary_Eastern_Continent',
      pos    = vec3:new(  489.0,       -383.6,       6.1) },          -- dump only; 1 session

    -- Hawezar (Hawe_)
    { label = 'Maiden — Hawe_Verge (Hawezar)',
      region = 'Hawe_', zone = 'Hawe_Verge', world = 'Sanctuary_Eastern_Continent',
      pos    = vec3:new(-1070.214600,   449.095276,  16.321373) },    -- HR baseline; 19 dump sessions

    { label = 'Maiden — Hawe_ZakFort (Zakarum Fortress)',
      region = 'Hawe_', zone = 'Hawe_ZakFort', world = 'Sanctuary_Eastern_Continent',
      pos    = vec3:new( -680.988770,   725.340576,   0.389648) },    -- HR baseline; 2 dump sessions

    -- Dry Steppes (Step_)
    { label = 'Maiden — Step_South #1 primary (Dry Steppes)',
      region = 'Step_', zone = 'Step_South', world = 'Sanctuary_Eastern_Continent',
      pos    = vec3:new( -464.924530,  -327.773132,  36.178608) },    -- HR baseline; 28 dump sessions

    { label = 'Maiden — Step_South #2 alt (Dry Steppes, speculative)',
      region = 'Step_', zone = 'Step_South', world = 'Sanctuary_Eastern_Continent',
      pos    = vec3:new( -868.5,       -603.9,       26.1) },         -- dump only; 1 session

    -- ── SeersReach dungeon (Skov_Philios overworld + DGN_Skov_SeersReach interior) ──
    -- Boss arena centroid weighted by 438 observations across all 46 procedural
    -- scenes in the community nav dump. Z is consistent at 2.0 across every
    -- scene observed; the boss never spawns at a different floor.
    -- World caveat: the dungeon interior is a separate world from the overworld.
    -- The 'entrance' entry below sits in Sanctuary_Eastern_Continent; the
    -- 'return portal' and 'boss arena' entries only resolve once the player has
    -- crossed the entrance portal and is inside DGN_Skov_SeersReach.
    { label = 'SeersReach entrance (overworld door in Skov_Philios)',
      region = 'Skov_', zone = 'Skov_Philios', world = 'Sanctuary_Eastern_Continent',
      pos    = vec3:new( 2322.0, -489.1, 15.2) },

    { label = 'SeersReach return portal (inside dungeon)',
      region = 'DGN_',  zone = 'DGN_Skov_SeersReach', world = 'DGN_Skov_SeersReach',
      pos    = vec3:new(   60.3,  105.7,  1.3) },

    { label = 'SeersReach boss arena (Tormented Stinger, inside dungeon)',
      region = 'DGN_',  zone = 'DGN_Skov_SeersReach', world = 'DGN_Skov_SeersReach',
      pos    = vec3:new(   -6.69,  -7.59,  2.01) },
}

-- Returns the array of GUI labels (one per entry).
function test_targets.labels()
    local out = {}
    for i, e in ipairs(test_targets.entries) do
        out[i] = e.label
    end
    return out
end

-- combo_box:get() returns a 0-indexed value. Convert to entry (1-indexed) and
-- return the entry table, or nil if the (none) row is selected.
function test_targets.entry_at(combo_idx)
    local i = (combo_idx or 0) + 1
    local entry = test_targets.entries[i]
    if not entry or entry.kind == 'none' then return nil end
    return entry
end

-- Convenience: vec3 at a given combo index, or nil for (none).
function test_targets.pos_at(combo_idx)
    local entry = test_targets.entry_at(combo_idx)
    return entry and entry.pos or nil
end

-- One-line description for the GUI status header.
function test_targets.describe(combo_idx)
    local entry = test_targets.entry_at(combo_idx)
    if not entry then return '(none — using pinned target)' end
    local world_tag = entry.world and (' world=' .. entry.world) or ''
    return string.format('zone=%s  region=%s%s  (%.1f, %.1f, %.1f)',
        entry.zone, entry.region, world_tag,
        entry.pos:x(), entry.pos:y(), entry.pos:z())
end

return test_targets
