local profile_io = {}

local function _escape_str(s)
    s = tostring(s)
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    return '"' .. s .. '"'
end

local function _is_array(t)
    local n = 0
    for k, _ in pairs(t) do
        if type(k) ~= 'number' then return false end
        if k > n then n = k end
    end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

local function _encode(v)
    local tv = type(v)
    if tv == 'nil'     then return 'null' end
    if tv == 'boolean' then return v and 'true' or 'false' end
    if tv == 'number'  then return tostring(v) end
    if tv == 'string'  then return _escape_str(v) end
    if tv == 'table'   then
        if _is_array(v) then
            local out = {}
            for i = 1, #v do out[#out + 1] = _encode(v[i]) end
            return '[' .. table.concat(out, ',') .. ']'
        end
        local out = {}
        for k, val in pairs(v) do
            out[#out + 1] = _escape_str(k) .. ':' .. _encode(val)
        end
        return '{' .. table.concat(out, ',') .. '}'
    end
    return 'null'
end

function profile_io.to_json(tbl)
    return _encode(tbl)
end

local function _skip_ws(s, i)
    while true do
        local c = s:sub(i, i)
        if c == '' then return i end
        if c ~= ' ' and c ~= '\n' and c ~= '\r' and c ~= '\t' then return i end
        i = i + 1
    end
end

local function _parse_str(s, i)
    i = i + 1
    local out = {}
    while true do
        local c = s:sub(i, i)
        if c == ''  then return nil, i end
        if c == '"' then return table.concat(out), i + 1 end
        if c == '\\' then
            local n = s:sub(i + 1, i + 1)
            if n == '"' or n == '\\' or n == '/' then out[#out + 1] = n
            elseif n == 'n' then out[#out + 1] = '\n'
            elseif n == 'r' then out[#out + 1] = '\r'
            elseif n == 't' then out[#out + 1] = '\t'
            else out[#out + 1] = n end
            i = i + 2
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
end

local function _parse_num(s, i)
    local j = i
    while s:sub(j, j):match('[%d%+%-%eE%.]') do j = j + 1 end
    return tonumber(s:sub(i, j - 1)), j
end

local function _parse_val(s, i)
    i = _skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then return _parse_str(s, i) end
    if c == '{' then
        i = i + 1
        local obj = {}
        i = _skip_ws(s, i)
        if s:sub(i, i) == '}' then return obj, i + 1 end
        while true do
            i = _skip_ws(s, i)
            local k; k, i = _parse_str(s, i)
            i = _skip_ws(s, i)
            i = i + 1  -- ':'
            local v; v, i = _parse_val(s, i)
            obj[k] = v
            i = _skip_ws(s, i)
            if s:sub(i, i) == '}' then return obj, i + 1 end
            i = i + 1  -- ','
        end
    end
    if c == '[' then
        i = i + 1
        local arr = {}
        i = _skip_ws(s, i)
        if s:sub(i, i) == ']' then return arr, i + 1 end
        local idx = 1
        while true do
            local v; v, i = _parse_val(s, i)
            arr[idx] = v
            idx = idx + 1
            i = _skip_ws(s, i)
            if s:sub(i, i) == ']' then return arr, i + 1 end
            i = i + 1  -- ','
        end
    end
    if c:match('[%d%-]') then return _parse_num(s, i) end
    local lit = s:sub(i, i + 4)
    if lit:sub(1, 4) == 'true'  then return true,  i + 4 end
    if lit:sub(1, 5) == 'false' then return false, i + 5 end
    if lit:sub(1, 4) == 'null'  then return nil,   i + 4 end
    return nil, i
end

function profile_io.from_json(json)
    if type(json) ~= 'string' then return nil end
    local ok, val = pcall(function()
        return select(1, _parse_val(json, 1))
    end)
    return ok and val or nil
end

function profile_io.write_file(path, text)
    local f = io.open(path, 'w')
    if not f then return false end
    f:write(text)
    f:flush()
    f:close()
    return true
end

function profile_io.read_file(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local t = f:read('*a')
    f:close()
    return t
end

return profile_io
