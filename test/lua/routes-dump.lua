-- Loads a routes file (toawowchar/Data/Routes.lua, or the path in arg[1]) the way the client
-- does (the addon's name and a namespace table) and prints ns.RouteData as one line of JSON, with
-- every step written out as an object, the name and text indexes resolved. Lua 5.1, no WoW API:
-- the file must need nothing but its namespace.
local path = arg[1] or "toawowchar/Data/Routes.lua"
local chunk = assert(loadfile(path))
local ns = {}
chunk("toawowchar", ns)
local data = assert(ns.RouteData, "the file did not set ns.RouteData")

local function quote(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
        return string.format("\\u%04x", c:byte())
    end) .. '"'
end

local write
local function list(t)
    local out = {}
    for i = 1, #t do out[i] = write(t[i]) end
    return "[" .. table.concat(out, ",") .. "]"
end
local function object(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local out = {}
    for i, k in ipairs(keys) do
        local v = t[k]
        if v == nil then v = t[tonumber(k)] end
        out[i] = quote(k) .. ":" .. write(v)
    end
    return "{" .. table.concat(out, ",") .. "}"
end
write = function(v)
    local kind = type(v)
    if kind == "string" then return quote(v)
    elseif kind == "number" then return string.format("%.14g", v)
    elseif kind == "boolean" then return tostring(v)
    elseif v == nil then return "null"
    end
    return (#v > 0 or next(v) == nil) and list(v) or object(v)
end

local problems = {}
local function problem(text) problems[#problems + 1] = text end

local routes = {}
for key, route in pairs(data.routes) do
    local steps = {}
    for i, s in ipairs(route.steps) do
        if #s ~= 8 then problem(key .. " step " .. i .. " has " .. #s .. " fields") end
        local name = s[6] ~= 0 and data.texts[s[6]] or nil
        local text = s[8] ~= 0 and data.texts[s[8]] or nil
        if s[6] ~= 0 and name == nil then problem(key .. " step " .. i .. ": name index " .. tostring(s[6])) end
        if s[8] ~= 0 and text == nil then problem(key .. " step " .. i .. ": text index " .. tostring(s[8])) end
        if type(s[5]) ~= "table" then problem(key .. " step " .. i .. ": questIds") end
        for _, q in ipairs(s[5] or {}) do
            if data.quests[q] == nil then problem(key .. " step " .. i .. ": quest " .. tostring(q) .. " has no name") end
        end
        if data.zones[s[2]] == nil then problem(key .. " step " .. i .. ": map " .. tostring(s[2]) .. " has no name") end
        steps[i] = { kind = s[1], uiMapId = s[2], x = s[3], y = s[4], questIds = s[5], name = name or false, level = s[7], text = text or false }
    end
    routes[key] = {
        start = route.start, faction = route.faction, questie = route.questie, generated = route.generated,
        confirmed = route.confirmed, levelEnd = route.levelEnd, steps = steps,
    }
end
local quests, zones = {}, {}
for id, name in pairs(data.quests) do quests[tostring(id)] = name end
for id, name in pairs(data.zones) do zones[tostring(id)] = name end
print(write({ routes = routes, quests = quests, zones = zones, texts = #data.texts, problems = problems }))
