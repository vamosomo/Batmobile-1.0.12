-- Movement revamp condition evaluators. Each evaluator is a pure function
-- of (condition_state, ctx). The engine builds ctx once per candidate rule
-- and walks the rule's condition list with a flat left-to-right AND/OR fold.
local rules   = require 'core.movement_rules'
local helpers = require 'core.movement_helpers'
local utils   = require 'core.utils'
local settings = require 'core.settings'

local function dlog(msg) if settings.debug_logs then console.print(msg) end end

local conditions = {}

-- ctx fields:
--   local_player              -- entity
--   path                      -- navigator.path (table of vec3)
--   skill_id                  -- the rule's primary skill (for skill_ready)
--   prospective_cast_pos      -- the position the engine pre-picked (vec3 or nil)
--   player_pos                -- vec3
--   buffs                     -- pre-fetched buff list

local function _eval_buff_active(cs, ctx)
    local res = helpers.find_buff(ctx.buffs, cs.buff_hash) ~= nil
    dlog(string.format('[mvr]   cond buff_active hash=%d -> %s',
        cs.buff_hash or 0, tostring(res)))
    return res
end

local function _eval_buff_not_active(cs, ctx)
    local res = helpers.find_buff(ctx.buffs, cs.buff_hash) == nil
    dlog(string.format('[mvr]   cond buff_not_active hash=%d -> %s',
        cs.buff_hash or 0, tostring(res)))
    return res
end

local function _eval_buff_stacks(cs, ctx)
    local buff = helpers.find_buff(ctx.buffs, cs.buff_hash)
    local stacks = helpers.buff_stacks(buff)
    local res = rules.apply_op(cs.op or '>=', stacks, cs.value or 0)
    dlog(string.format('[mvr]   cond buff_stacks hash=%d stacks=%d %s %d -> %s',
        cs.buff_hash or 0, stacks, cs.op or '>=', cs.value or 0, tostring(res)))
    return res
end

local function _eval_skill_ready(cs, ctx)
    if not ctx.skill_id then
        dlog('[mvr]   cond skill_ready -> false (no skill_id in ctx)')
        return false
    end
    local res = helpers.can_cast(ctx.skill_id)
    dlog(string.format('[mvr]   cond skill_ready id=%d -> %s',
        ctx.skill_id, tostring(res)))
    return res
end

local function _eval_distance(cs, ctx)
    if not ctx.prospective_cast_pos or not ctx.player_pos then
        dlog('[mvr]   cond distance -> false (no cast pos)')
        return false
    end
    local dist = utils.distance(ctx.prospective_cast_pos, ctx.player_pos)
    local res = rules.apply_op(cs.op or '>=', dist, cs.value or 0)
    dlog(string.format('[mvr]   cond distance %.1f %s %d -> %s',
        dist, cs.op or '>=', cs.value or 0, tostring(res)))
    return res
end

local function _eval_path_pack_density(cs, ctx)
    local count = helpers.largest_pack_on_path(ctx.path, cs.radius or 6)
    local res = rules.apply_op(cs.op or '>', count, cs.value or 0)
    dlog(string.format('[mvr]   cond pack_density r=%d count=%d %s %d -> %s',
        cs.radius or 6, count, cs.op or '>', cs.value or 0, tostring(res)))
    return res
end

conditions.dispatch = {
    buff_active        = _eval_buff_active,
    buff_not_active    = _eval_buff_not_active,
    buff_stacks        = _eval_buff_stacks,
    skill_ready        = _eval_skill_ready,
    distance           = _eval_distance,
    path_pack_density  = _eval_path_pack_density,
}

conditions.eval_one = function (cs, ctx)
    if not cs or not cs.type or cs.type == 'none' then return true end
    local fn = conditions.dispatch[cs.type]
    if not fn then return true end
    local ok, res = pcall(fn, cs, ctx)
    if not ok then return false end
    return res == true
end

-- Flat AND/OR fold across the condition list. The first non-(none) row
-- seeds the accumulator; each subsequent row applies its own combinator
-- against the running value. "none" rows are skipped entirely.
conditions.eval_list = function (list, ctx)
    if not list or #list == 0 then return true end
    local acc = nil
    for i, cs in ipairs(list) do
        if cs.type and cs.type ~= 'none' then
            local v = conditions.eval_one(cs, ctx)
            if acc == nil then
                acc = v
                dlog(string.format('[mvr]   acc#%d (seed) = %s', i, tostring(acc)))
            elseif cs.combinator == 'OR' then
                acc = acc or v
                dlog(string.format('[mvr]   acc#%d OR %s = %s', i, tostring(v), tostring(acc)))
            else
                acc = acc and v
                dlog(string.format('[mvr]   acc#%d AND %s = %s', i, tostring(v), tostring(acc)))
            end
        end
    end
    if acc == nil then return true end
    return acc == true
end

return conditions
