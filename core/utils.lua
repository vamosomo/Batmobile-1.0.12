local settings     = require 'core.settings'

local utils    = {}

-- Pre-computed constant (avoids recalculating math.sqrt(2) every call)
local SQRT2_MINUS1 = math.sqrt(2) - 1
utils.distance_to = function (target)
    local player_pos = get_player_position()
    local target_pos

    if target.get_position then
        target_pos = target:get_position()
    elseif target.x then
        target_pos = target
    end

    return player_pos:dist_to(target_pos)
end
utils.is_same_position = function (pos1, pos2)
    return pos1:x() == pos2:x() and pos1:y() == pos2:y() and pos1:z() == pos2:z()
end
utils.is_mounted = function ()
    local local_player = get_local_player()
    return local_player:get_attribute(attributes.CURRENT_MOUNT) < 0
end
utils.player_in_zone = function (zname)
    local world = get_current_world()
    if not world then return false end
    return world:get_current_zone_name() == zname
end
utils.player_loading = function ()
    local world = get_current_world()
    if not world then return true end
    return world:get_current_zone_name() == '[sno none]'
end
 utils.player_in_town = function()
    if get_local_player():get_attribute(attributes.PLAYER_IN_TOWN_LEVEL_AREA) == 1 then
        return true
    else
        return false
    end
end
utils.in_combat = function (local_player)
    local active_spell = local_player:get_active_spell_id()
    return active_spell ~= nil and active_spell ~= -1 and active_spell ~= 186139
end
utils.is_cced = function (local_player)
    local debuffs = {
        ['39809'] = 'GenericCrowdControlBuff',
        ['290961'] = 'GenericChillBuff',
        ['290962'] = 'GenericFrozenBuff',
    }
    local buffs = local_player:get_buffs()
    for _, buff in pairs(buffs) do
        if debuffs[buff.name_hash] then
            return true
        end
    end
    return false
end
utils.normalize_value = function (val)
    local normalizer = settings.normalizer
    return math.floor(val * normalizer + 0.5) / normalizer
end
utils.normalize_node = function (node)
    local norm_x = utils.normalize_value(node:x())
    local norm_y = utils.normalize_value(node:y())
    return vec3:new(norm_x, norm_y, node:z())
end
utils.vec_to_string = function (node)
    if node.x == nil or node.y == nil then return nil end
    return tostring(node:x()) .. ',' .. tostring(node:y())
end
utils.string_to_vec = function (str)
    local node = {}
    for match in string.gmatch(str, "([^,]+)") do
        node[#node+1] = tonumber(match)
    end
    return vec3:new(node[1], node[2], 0)
end
utils.distance = function (a, b)
    if a.get_position then
        a = a:get_position()
    end
    if b.get_position then
        b = b:get_position()
    end
    local dx = math.abs(a:x() - b:x())
    local dy = math.abs(a:y() - b:y())
    return math.max(dx, dy) + SQRT2_MINUS1 * math.min(dx, dy)
end
utils.distance_z = function (a, b)
    return math.abs(a:z() - b:z())
end
utils.get_set_count = function (set)
    local counter = 0
    for _, _ in pairs(set) do
        counter = counter + 1
    end
    return counter
end
utils.get_character_class = function (local_player)
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
utils.log = function (level, msg)
    if level > settings.log_level then return end
    console.print(settings.plugin_label .. ': ' .. tostring(msg))
end

utils.get_valid_node = function (node, alt_z)
    local check_node, valid
    check_node = utility.set_height_of_valid_position(node)
    valid = utility.is_point_walkeable(check_node)
    if not valid and alt_z ~= nil then
        check_node = vec3:new(node:x(), node:y(), alt_z)
        valid = utility.is_point_walkeable(check_node)
    end
    if valid then
        return check_node
    end
    return nil
end



return utils
