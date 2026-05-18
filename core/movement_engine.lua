-- Movement revamp engine. Walks the user's rule list in slot order, picks
-- the first rule whose conditions all evaluate true, and returns the cast
-- parameters (skill_id, needs_raycast, range, override_pos, override_idx).
--
-- Returning `override_pos` (and the path index it corresponds to) lets the
-- caller in navigator.move() skip its own node-picker for revamp rules
-- while preserving the legacy behaviour when no rule matches.
local rules      = require 'core.movement_rules'
local helpers    = require 'core.movement_helpers'
local conditions = require 'core.movement_conditions'
local utils      = require 'core.utils'
local settings   = require 'core.settings'

local function dlog(msg) if settings.debug_logs then console.print(msg) end end

local engine = {}

-- Per-slot last-fired timestamps. Not persisted across reload — cooldowns
-- naturally reset along with the script, which matches the legacy
-- spell_time behaviour.
engine.last_fire = {}

-- Find the farthest path node within [min_req, range] of player_pos.
-- Uses utils.distance (octile) for parity with the legacy node picker.
local function _pick_next_node_pos(path, player_pos, range, min_req, blacklist)
    if not path or #path == 0 then return nil, 0 end
    local picked, picked_idx, picked_dist = nil, 0, -1
    for i, node in ipairs(path) do
        if node and node.x then
            local dist = utils.distance(node, player_pos)
            if dist > range then break end
            local key = utils.vec_to_string(node)
            local bl  = blacklist and key and blacklist[key] ~= nil
            if dist >= min_req and not bl and dist > picked_dist then
                picked, picked_idx, picked_dist = node, i, dist
            end
        end
    end
    return picked, picked_idx
end

-- Find the densest cluster on the remaining path, return the path node at
-- that cluster's centre (only if it sits within cast range).
local function _pick_pack_pos(path, density_radius, range, player_pos, min_req)
    local count, node = helpers.largest_pack_on_path(path, density_radius or 6)
    if not node or count <= 0 then return nil, 0 end
    local dist = utils.distance(node, player_pos)
    if dist < min_req or dist > range then return nil, 0 end
    local picked_idx = 0
    for i, n in ipairs(path) do
        if n == node then picked_idx = i; break end
    end
    return node, picked_idx
end

-- Main entry. `rule_state_list` is the array of rule tables built by
-- settings.update_settings() from the GUI widgets. ctx must include:
--   local_player, path, player_pos, default_range, min_spell_dist, blacklist
-- Returns (skill_id, needs_raycast, range, override_pos, override_idx) or nil.
engine.pick = function (rule_state_list, ctx)
    if not rule_state_list or #rule_state_list == 0 then
        dlog('[mvr] pick skip: no rules')
        return nil
    end
    if not ctx.player_pos or not ctx.path then
        dlog('[mvr] pick skip: no player_pos or path')
        return nil
    end

    local now = get_time_since_inject()
    ctx.buffs = helpers.get_player_buffs(ctx.local_player)

    dlog(string.format('[mvr] pick: rules=%d path_nodes=%d buffs=%d',
        #rule_state_list, #ctx.path, #(ctx.buffs or {})))

    for slot, rule in ipairs(rule_state_list) do
        if not rule.enabled then
            dlog(string.format('[mvr] slot=%d skip: disabled', slot))
        elseif not rule.skill_id or rule.skill_id == 0 then
            dlog(string.format('[mvr] slot=%d skip: no skill selected', slot))
        else
            local last = engine.last_fire[slot] or -1
            local throttle = (rule.throttle_ms or 0) / 1000.0
            if throttle > 0 and now - last < throttle then
                dlog(string.format('[mvr] slot=%d skip: throttled (%.2fs left)',
                    slot, throttle - (now - last)))
            else
                local catalog = rules.skill_by_id[rule.skill_id]
                if not catalog then
                    dlog(string.format('[mvr] slot=%d skip: unknown skill_id=%d',
                        slot, rule.skill_id))
                else
                    local range   = catalog.range or ctx.default_range or 12
                    local min_req = ctx.min_spell_dist or 3
                    local pos, idx
                    if rule.cast_position == 'toward_largest_pack_on_path' then
                        pos, idx = _pick_pack_pos(ctx.path, rule.density_radius, range, ctx.player_pos, min_req)
                        dlog(string.format('[mvr] slot=%d skill=%s cast=pack r=%d range=%.1f pos=%s',
                            slot, catalog.name, rule.density_radius or 6, range,
                            pos and utils.vec_to_string(pos) or 'nil'))
                    else
                        pos, idx = _pick_next_node_pos(ctx.path, ctx.player_pos, range, min_req, ctx.blacklist)
                        dlog(string.format('[mvr] slot=%d skill=%s cast=node range=%.1f min=%.1f pos=%s',
                            slot, catalog.name, range, min_req,
                            pos and utils.vec_to_string(pos) or 'nil'))
                    end
                    ctx.prospective_cast_pos = pos
                    ctx.skill_id             = rule.skill_id
                    if not pos then
                        dlog(string.format('[mvr] slot=%d skip: no cast position found', slot))
                    else
                        local cond_ok = conditions.eval_list(rule.conditions, ctx)
                        if cond_ok then
                            dlog(string.format('[mvr] slot=%d MATCH skill=%s pos=%s idx=%d',
                                slot, catalog.name, utils.vec_to_string(pos), idx))
                            engine.last_fire[slot] = now
                            return rule.skill_id, catalog.needs_raycast, range, pos, idx
                        else
                            dlog(string.format('[mvr] slot=%d skip: conditions failed', slot))
                        end
                    end
                end
            end
        end
    end
    dlog('[mvr] no rule matched this tick')
    return nil
end

return engine
