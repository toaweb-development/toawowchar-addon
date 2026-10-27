local _, ns = ...

local L = ns.L

local PREFIX = ns.PREFIX

---------------------------------------------------------------------------
-- Encoding: plain JSON, written here
---------------------------------------------------------------------------

-- The text of an export is "WOWCHAR:3:" and then one JSON value. The writer
-- below handles only what the payload holds: whole numbers, booleans, strings,
-- lists and objects. Rules (the tests pin them):
--   * Object keys are written in sorted order, so the same data always gives the
--     same text. A key whose value is nil is not written.
--   * A table with no keys at all is written as [] (an empty list). Every list
--     in the payload may be empty and none of the objects is, so the server can
--     rely on that.
--   * A table whose keys are exactly 1..n is a list; one with only string keys is
--     an object. Anything else (mixed keys, holes, other key types), a cycle,
--     more than MAX_DEPTH levels, or a value that is a function, userdata or
--     thread, is an error: the export is not made.
--   * A number that is a whole number (within +-2^53) is written as an integer.
--     A fraction, NaN, infinity or a larger number is written as null (the
--     payload has none of these).
--   * Strings are escaped: " and \ get a backslash, line feed, carriage return
--     and tab are written \n, \r and \t, every other control character (below
--     0x20) and DEL are written as \u00XX, and "|" is written as |. A "|"
--     is the start of a colour code or link in the game's text box, so no "|"
--     may reach the copy box; the server reads | as "|" again. Other bytes
--     (UTF-8 letters) are written as they are.
-- The deepest value is a reagent in a recipe of a profession of the recipes
-- section: payload > sections > recipes > lines > line > recipes > recipe >
-- reagents > reagent > number, 9 tables and the number: MAX_DEPTH leaves room.
local MAX_DEPTH = 10

local function EscapeChar(c)
    if c == '"' then return '\\"'
    elseif c == "\\" then return "\\\\"
    elseif c == "\n" then return "\\n"
    elseif c == "\r" then return "\\r"
    elseif c == "\t" then return "\\t"
    end
    return string.format("\\u%04x", c:byte())
end

local function WriteString(buffer, value)
    buffer[#buffer + 1] = '"' .. value:gsub('[%z\1-\31\127"\\|]', EscapeChar) .. '"'
end

local function WriteNumber(buffer, value)
    if value ~= value or value ~= math.floor(value) or value > 9007199254740991 or value < -9007199254740991 then
        buffer[#buffer + 1] = "null"
    else
        buffer[#buffer + 1] = string.format("%.0f", value)
    end
end

local WriteValue

local function WriteTable(buffer, value, depth)
    if depth > MAX_DEPTH then
        error("too deep")
    end
    local count, stringKeys = 0, {}
    for key in pairs(value) do
        count = count + 1
        if type(key) == "string" then
            stringKeys[#stringKeys + 1] = key
        end
    end

    if count == 0 then
        buffer[#buffer + 1] = "[]"
    elseif #stringKeys == 0 then
        -- Must be exactly 1..count.
        for i = 1, count do
            if value[i] == nil then
                error("list with a hole or a key that is not a string")
            end
        end
        buffer[#buffer + 1] = "["
        for i = 1, count do
            if i > 1 then
                buffer[#buffer + 1] = ","
            end
            WriteValue(buffer, value[i], depth + 1)
        end
        buffer[#buffer + 1] = "]"
    elseif #stringKeys == count then
        table.sort(stringKeys)
        buffer[#buffer + 1] = "{"
        for i, key in ipairs(stringKeys) do
            if i > 1 then
                buffer[#buffer + 1] = ","
            end
            WriteString(buffer, key)
            buffer[#buffer + 1] = ":"
            WriteValue(buffer, value[key], depth + 1)
        end
        buffer[#buffer + 1] = "}"
    else
        error("table with mixed keys")
    end
end

WriteValue = function(buffer, value, depth)
    local kind = type(value)
    if kind == "string" then
        WriteString(buffer, value)
    elseif kind == "number" then
        WriteNumber(buffer, value)
    elseif kind == "boolean" then
        buffer[#buffer + 1] = value and "true" or "false"
    elseif kind == "table" then
        -- A table inside itself would never end; the depth limit stops it.
        WriteTable(buffer, value, depth)
    else
        error("cannot write a " .. kind)
    end
end

-- Returns the JSON text of a value. Raises on what the rules above refuse.
local function Serialize(value)
    local buffer = {}
    WriteValue(buffer, value, 1)
    return table.concat(buffer)
end

local function Encode(payload)
    local ok, result = pcall(Serialize, payload)
    if not ok or type(result) ~= "string" then
        return nil, L["EXPORT_FAILED"]
    end
    return PREFIX .. result
end

ns.Serialize = Serialize
ns.Encode = Encode
