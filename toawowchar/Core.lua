-- toawowchar 0.5.0
--
-- Type /wowchar (or /toawowchar, the same command) to open a window with a text
-- string (who the character is, equipped items, bags, the bank and the warband
-- bank, professions with their recipes, completed quests and the quest log,
-- reputation, money and XP, talents, Legacy, flight paths, the season's PvP rank
-- and the class spells the character knows). Copy it (Ctrl+C) and paste it at wowchar: on «My
-- characters» to add the character, or on the character's BiS page to mark the
-- BiS items you already have as obtained. The addon sends nothing anywhere.
--
-- What it saves (SavedVariables: toawowcharDB, a CACHE only): what the game
-- only lets it read while a window is open (the bank and the warband bank, the
-- recipes of each profession, the flight paths), the Legacy tree and the
-- completed quests. Game events also keep a copy of the equipped items, the
-- bags, the completed quests, the professions and the money, level and XP
-- current (the Snapshot in Cache.lua). Each cached part has the time it was read. The addon works
-- exactly the same when nothing was saved or the client does not keep the file:
-- the text is then made from what the game answers now, and the parts it could
-- not read say why. "/wowchar reset" clears this character's cache.
--
-- Chat: the addon says one short line when it has cached something new (the
-- bank, a profession's recipes, flight paths), one when /wowchar is typed in
-- combat (the window then opens when combat ends) and one for "/wowchar reset".
-- It also says one line when the guide or the waypoint hits an error and turns off
-- (Part, below). It says nothing else; the snapshot of the equipped items, bags, completed
-- quests, professions and player numbers that game events keep current (see
-- Snapshot) is silent.
--
-- The text is "WOWCHAR:3:" followed by plain JSON, written by the small
-- serializer in Serializer.lua (format 3 = format 2's content plus "sections"). No
-- C_EncodingUtil, no compression, no base64. It is decoded by wowchar's
-- server/utils/addon-export.ts, and the shape is described in
-- docs/addon-export-format-3.md. That file and the table built in BuildPayload()
-- (Export.lua) belong together: change one, change the other.
--
-- Every section says where it came from (Live, Cached and Missing below): "live" (read now, or
-- captured while its window was open earlier in this play session), "cache" (an
-- earlier session, with the time it was read) or "missing" with one of the
-- REASONS codes (not text: the server checks them and the page words them).
--
-- Region: identity.region is "US", "KR", "EU", "TW" or "CN", from
-- GetCurrentRegion() (1 to 5). Any other value (the Forever test client reports
-- 110) leaves region out and sends identity.regionId (the number) and
-- identity.portal (the "portal" setting) instead; wowchar then does not compare
-- regions. GetCurrentRegionName() is not used: it errors on the Forever test
-- client. Every game call of the addon is guarded, so a missing function is never an error.
--
-- Race and faction (0.3.1): identity.race is the race file token (the second
-- return of UnitRace("player"), for example "NightElf" or "Scourge") and
-- identity.faction is the first return of UnitFactionGroup("player") ("Alliance",
-- "Horde" or "Neutral"). A value that is not a string leaves its key out. The
-- server decides what it accepts (addon-export.ts), so the addon does not list
-- the races: the Forever tokens for the two new races are not confirmed.
--
-- API facts the addon relies on (Gethe/wow-ui-source, branch forever, 172a387,
-- build 1.60.1.70450, and for the guide ca8368f, build 1.60.1.70532, where none of
-- these changed; nothing was run in a live client; the Blizzard_APIDocumentationGenerated
-- paths are meant): QuestLogDocumentation.lua, ReputationInfoDocumentation.lua,
-- SharedTraitsDocumentation.lua, ClassTalentsDocumentation.lua, TaxiMapDocumentation.lua,
-- TradeSkillUIDocumentation.lua, SpellBookDocumentation.lua, MajorFactionsDocumentation.lua,
-- LegacyConstantsDocumentation.lua. File and line references are with each reader.

-- The files, in the TOC's order (one responsibility each, docs/wow-addon-rules.md 3):
--   Locales/enUS.lua   the words the player sees (L["KEY"])
--   Core.lua           this file: the version, the limits wowchar sets, the helpers every
--                      file uses, the play session's state, the events and /wowchar
--   Serializer.lua     the JSON writer and the "WOWCHAR:3:" text
--   Export.lua         reading the game: one reader per section, the captures, the payload, Run
--   Cache.lua          the SavedVariables cache and the Snapshot that game events keep current
--   UI/Window.lua      the export window

-- The client passes every file of the TOC the addon's name and one private table,
-- the namespace (ns); the files share their state and helpers through it, and the
-- tests load the files the same way and read the helpers from it.
local addonName, ns = ...

local L = ns.L

local ADDON_VERSION = "0.5.0"
local FORMAT_VERSION = 3
local PREFIX = "WOWCHAR:" .. FORMAT_VERSION .. ":"
-- The longest text the server takes (MAX_ENCODED_LENGTH in
-- app/shared/addon-export-format.ts; a test compares the two). The window shows
-- the size; a longer text drops the lowest-priority sections (see Run).
local MAX_EXPORT_LENGTH = 131072
-- The largest request body the two import routes take (ADDON_BODY_MAX in
-- server/utils/request-body.ts: MAX_EXPORT_LENGTH plus 16 KiB for the JSON escapes;
-- a test compares the two). The browser sends the pasted text as {"export": text},
-- which writes every " and \ of it as two bytes, so a text under MAX_EXPORT_LENGTH
-- can still make a body over this. The drop in Run keeps the body, not only the text,
-- inside it.
local ADDON_BODY_MAX = 147456
-- The bytes around the text in that body: {"export":""} is 13; a few more for a
-- client that adds a space or a line break.
local BODY_WRAPPER = 16
local CACHE_VERSION = 1

-- The caps on every list. The server refuses a list over its cap (ADDON_LIST_CAPS
-- in server/utils/addon-export.ts, sized from the maxed-character export of
-- test/lua/maxed-stub.lua; a test compares the two tables name by name), so the
-- lists here are cut at the same numbers. "ids" is MAX_IDS_PER_ARRAY there.
local CAPS = {
    ids = 500,
    professions = 32,
    questsDone = 5000,
    questLog = 50,
    objectivesPerQuest = 12,
    objectiveText = 255,
    factions = 200,
    nameText = 100,
    recipeLines = 12,
    recipesPerLine = 600,
    reagentsPerRecipe = 12,
    talentTrees = 4,
    nodesPerTree = 150,
    legacyTrees = 4,
    challenges = 500,
    flightPaths = 200,
    classSpells = 400,
}

-- The bounds on every number and text the server checks (ADDON_BOUNDS in
-- app/server/utils/addon-export.ts; a test compares the two tables name by name).
-- The server refuses the WHOLE export when one value is outside its bound, so every
-- reader below checks its values against these numbers and LEAVES OUT the row (or
-- the field, when it is optional) that does not fit; a section that cannot be made
-- becomes missing with a reason from REASONS. One odd value therefore never makes
-- the server refuse a paste.
local BOUNDS = {
    id = 2147483647,            -- item, spell, quest, faction, recipe, trait and flight path ids (a 32-bit signed integer)
    reagentCount = 9999,        -- the count of one reagent in a recipe
    traitRank = 255,            -- the rank of a trait node
    counter = 1000000000,       -- XP, standing and its floor and ceiling, objective counts, Legacy points
    money = 10000000000000,     -- copper
    level = 255,
    reaction = 20,              -- the reaction of a reputation row (1 Hated to 8 Exalted in the game)
    honorRank = 1000,           -- seasonRank and seasonMax
    hiddenQuests = 1000,        -- quests the log has that could not be listed
    count = 1000000,            -- the optional counts: region id, class id, a profession's skill line, rank and max rank
    timeMin = 1000000000,       -- unix seconds, 2001-09-09
    timeMax = 4102444800,       -- 2100-01-01
    characterName = 64,         -- text lengths, in bytes here (the server counts characters, which are never more)
    realm = 100,
    classFile = 32,
    specName = 50,
    portal = 32,
    professionName = 64,
}

-- Why a section is missing. Codes, not text. The server accepts exactly these
-- (MISSING_REASONS in app/shared/addon-sections.ts; a test compares the lists).
local REASONS = {
    "open_bank",
    "open_profession_window",
    "open_flight_map",
    "not_loaded",
    "in_combat",
    "not_available",
    "too_large",
}

-- The server refuses an array longer than 500 (MAX_IDS_PER_ARRAY in
-- addon-export.ts); the lists here are cut at the same number.
local MAX_IDS = CAPS.ids
local MAX_PROFESSIONS = CAPS.professions
local LAST_EQUIPMENT_SLOT = 19
-- The server refuses more than 32 bonus ids on one item (MAX_BONUS_IDS_PER_ITEM)
-- and more than 4 gems; the lists here are cut at the same numbers.
local MAX_BONUS_IDS = 32
local MAX_GEMS = 4
-- Item ids, enchant ids and so on are whole numbers that fit a 32-bit signed
-- integer (the server's MAX_ITEM_ID); anything else in an item string is ignored.
local MAX_ID = BOUNDS.id
local MAX_REAGENT_COUNT = BOUNDS.reagentCount
local MAX_TRAIT_RANK = BOUNDS.traitRank
-- The honor system's rank is the renown level of this major faction (Forever,
-- Blizzard_UIPanels_Game/Camelot/PVPRankFrame.lua:1 and :91).
local PVP_RANK_FACTION_ID = 2800
-- The Legacy trees (LegacyConstantsDocumentation.lua, Constants.LegacyConsts; the
-- constants are used when the game has them, these numbers when it does not).
-- NOTE the third tree is "Progression" in Blizzard's code: key on the ids, never
-- on the names.
local LEGACY_TREES = { 1187, 1188, 1189 }

-- State of this play session. Nothing here is saved.
local session = {
    live = {},           -- section -> unix time it was read live in this play session
    bankOpen = false,
    bankDirty = false,   -- the bank cache changed while the bank was open: say so when it closes
    warbankDirty = false,
    pendingOpen = false, -- /wowchar was typed in combat: open the window when it ends
    taxiOpen = false,
    recipesPending = false,
}

-- Set when a read met a value the game hid (a "secret" value), so the section
-- becomes missing/in_combat instead of a half-read one.
-- `truncated`: set when a list had to be cut at its cap, so the window and the
-- export can say so. AddId sets it while a list is being collected. Run() resets it
-- before the bags are read; the bank is scanned earlier (when it opens), so its
-- result is kept apart (the cache's `cut` flag) and combined in BuildPayload.
-- `cutSections`: the same for the new sections, reset by BuildPayload.
-- They live in one table so that every file of the addon sees the same flags.
local scan = {
    secretSeen = false,
    truncated = false,
    cutSections = false,
}

local Cache = {}   -- SavedVariables cache
local Read = {}    -- one reader per section
local Capture = {} -- event captures (a window is open)
local Snapshot = {} -- the cache kept current by game events
local UI = {}      -- the window

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function IsSecret(value)
    if issecretvalue then
        local ok, secret = pcall(issecretvalue, value)
        return ok and secret and true or false
    end
    return false
end

-- A finite number from a game function, or nil. A hidden (secret) value sets
-- scan.secretSeen and gives nil.
local function Num(value)
    if IsSecret(value) then
        scan.secretSeen = true
        return nil
    end
    if type(value) == "number" and value == value and value > -1e15 and value < 1e15 then
        return value
    end
    return nil
end

local function Int(value)
    local n = Num(value)
    if n and n == math.floor(n) then
        return n
    end
    return nil
end

-- A whole number between min and max, or nil (also for a value outside them).
local function InRange(value, min, max)
    local n = Int(value)
    if n and n >= min and n <= max then
        return n
    end
    return nil
end

-- A unix time the server accepts (BOUNDS.timeMin to BOUNDS.timeMax), or nil.
local function CleanTime(value)
    return InRange(value, BOUNDS.timeMin, BOUNDS.timeMax)
end

-- A count from the game for a row: 0 when the game gave none (nil or not a whole
-- number), the number when it is between 0 and `max`, and nil when it is a number
-- outside that: the caller then leaves the row out.
local function CountOrZero(value, max)
    local n = Int(value)
    if n == nil then
        return 0
    end
    if n < 0 or n > max then
        return nil
    end
    return n
end

-- A string for the export: control characters become spaces, the ends are
-- trimmed and the text is cut at `max` bytes on a character boundary. nil when
-- the value is not a string (or is hidden).
local function CleanText(value, max)
    if IsSecret(value) then
        scan.secretSeen = true
        return nil
    end
    if type(value) ~= "string" then
        return nil
    end
    local text = (value:gsub("[%z\1-\31\127]", " "))
    text = text:match("^%s*(.-)%s*$")
    if #text > max then
        local n = max
        while n > 0 do
            local b = text:byte(n + 1)
            if b and b >= 0x80 and b < 0xC0 then
                n = n - 1
            else
                break
            end
        end
        text = text:sub(1, n)
    end
    return text
end

-- A text for an optional identity field: the string itself when it is between 1
-- and `max` bytes with no control character, else nil (the key is left out; the
-- server never gets a cut name or realm, which would be a different one).
local function Fit(value, max)
    if IsSecret(value) then
        scan.secretSeen = true
        return nil
    end
    if type(value) == "string" and #value >= 1 and #value <= max and not value:find("[%z\1-\31\127]") then
        return value
    end
    return nil
end

local function Now()
    return time and time() or 0
end

local function InCombat()
    return InCombatLockdown and InCombatLockdown() and true or false
end

-- One short line in the chat window.
local function Say(message)
    local line = "|cff8B7CFFtoawowchar:|r " .. message
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(line)
    elseif print then
        print(line)
    end
end

---------------------------------------------------------------------------
-- Parts that fail on their own
---------------------------------------------------------------------------
-- The guide, the waypoint and (later) the data collection are parts: each starts and hears its
-- events only through its own Part, so an error in one is caught there. On the first error
-- the part says so in one chat line and is off until /reload; the other parts, the export
-- and the cache go on. The export is not a part: it runs as before, and nothing here touches
-- its state (scan, session, the cache).
--
--   local part = ns.Part("guide", L["PART_GUIDE"])
--   part.Call(fn, ...)   runs fn(...) in pcall; its results, or nothing when off or on error
--   part.Wrap(fn)        a function that does part.Call(fn, ...) (event and click scripts)
--   part.OnFail(fn)      run once (in pcall) when the part turns off: unregister, hide, clear
--                        (at once when it is already off)
--   part.IsOff(), part.SayOff()

local ERROR_MAX = 200

-- The error as one short line for the chat: no control characters, every | doubled (no
-- escape code reaches the chat frame), at most ERROR_MAX bytes cut on a character boundary.
local function ErrorLine(err)
    local text
    if IsSecret(err) then
        return L["UNKNOWN_ERROR"]
    elseif type(err) == "string" then
        text = err
    else
        local ok, s = pcall(tostring, err)
        text = ok and type(s) == "string" and s or nil
    end
    if not text then
        return L["UNKNOWN_ERROR"]
    end
    text = text:gsub("[%z\1-\31\127]", " "):match("^%s*(.-)%s*$")
    if #text > ERROR_MAX then
        local n = ERROR_MAX
        while n > 0 do
            local b = text:byte(n + 1)
            if b and b >= 0x80 and b < 0xC0 then
                n = n - 1
            else
                break
            end
        end
        text = text:sub(1, n) .. "..."
    end
    if text == "" then
        return L["UNKNOWN_ERROR"]
    end
    return (text:gsub("|", "||"))
end

local parts = {}

local function Part(name, label)
    if parts[name] then
        return parts[name]
    end
    local part = {}
    local off = false
    local onFail = {}

    -- Nothing in here may raise: the clean-up runs first, each step in its own pcall, then
    -- the chat line (a chat frame or an error value that raises costs only the line).
    local function Fail(err)
        if off then
            return
        end
        off = true
        for _, fn in ipairs(onFail) do
            pcall(fn)
        end
        local ok, line = pcall(ErrorLine, err)
        if not ok or type(line) ~= "string" then
            line = L["UNKNOWN_ERROR"]
        end
        pcall(Say, string.format(L["PART_OFF"], label, line))
    end

    -- pcall's results without its first: the function's own results, or nothing on error.
    local function Results(ok, ...)
        if ok then
            return ...
        end
        Fail((...))
    end

    function part.Call(fn, ...)
        if off then
            return
        end
        if type(fn) ~= "function" then
            Fail("not loaded")
            return
        end
        return Results(pcall(fn, ...))
    end

    function part.Wrap(fn)
        return function(...)
            return part.Call(fn, ...)
        end
    end

    function part.OnFail(fn)
        if off then
            pcall(fn)
        else
            onFail[#onFail + 1] = fn
        end
    end

    function part.IsOff()
        return off
    end

    -- The chat line for a player who asks for a part that is off (/wowchar guide).
    function part.SayOff()
        pcall(Say, string.format(L["PART_IS_OFF"], label))
    end

    parts[name] = part
    return part
end

-- The keys of a set as a sorted list, cut at `cap`. Second result: true when cut.
local function SortedKeys(set, cap)
    local list = {}
    for id in pairs(set) do
        list[#list + 1] = id
    end
    table.sort(list)
    if #list > cap then
        for i = #list, cap + 1, -1 do
            list[i] = nil
        end
        return list, true
    end
    return list, false
end

local function SameSet(a, b)
    if #a ~= #b then
        return false
    end
    local set = {}
    for i = 1, #a do
        set[a[i]] = true
    end
    for i = 1, #b do
        if not set[b[i]] then
            return false
        end
    end
    return true
end

-- The sources. A marker is the start of a section table; the readers add the
-- data keys. `at` is unix seconds; nil leaves the key out.
local function Live(at)
    -- A live section may have no time; one the server would refuse is left out.
    return { source = "live", at = CleanTime(at) }
end

-- A cached section needs a time the server accepts. Without one the section
-- cannot be made, so it is missing (a missing section carries no data: With).
local function Cached(at)
    local stamp = CleanTime(at)
    if not stamp then
        return { source = "missing", why = "not_available" }
    end
    return { source = "cache", at = stamp }
end

local function Missing(why)
    return { source = "missing", why = why }
end

local function With(marker, data)
    if marker.source == "missing" then
        return marker
    end
    for key, value in pairs(data) do
        marker[key] = value
    end
    return marker
end

-- A count between 0 and BOUNDS.counter, or nil.
local function CleanCount(value)
    local n = Int(value)
    if n and n >= 0 and n <= BOUNDS.counter then
        return n
    end
    return nil
end

-- The Legacy points object, or nil when it would have no key (an empty table is
-- written as a list, and the server wants an object).
local function Points(available, cap, spent)
    if available == nil and cap == nil and spent == nil then
        return nil
    end
    return { available = available, cap = cap, spent = spent }
end

local function RealmName()
    if GetRealmName then
        local ok, value = pcall(GetRealmName)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- SavedVariables: toawowcharDB and its versions
---------------------------------------------------------------------------
-- dbVersion 1 (0.4.x, no dbVersion key): { [realm] = { [name] = cache record } }.
-- dbVersion 2 (0.5.0):
--   dbVersion   2
--   realms      { [realm] = { [name] = cache record } }   the cache, as in version 1 (Cache.lua)
--   guide       { shown, point, characters = { [realm] = { [name] = { route, generated, step,
--                 skipped } } } }                         the leveling guide (Guide.lua)
-- The migration from 1 moves every realm table under `realms`, so the cache survives the
-- update. A table with a dbVersion this addon does not know (a newer addon wrote it) is left
-- untouched: the addon then works on a table of this play session only, never on the file.
local DB_VERSION = 2
local sessionDB

local function MigrateDB(db)
    if db.dbVersion == nil then
        local realms = {}
        for key, value in pairs(db) do
            realms[key] = value
        end
        for key in pairs(realms) do
            db[key] = nil
        end
        db.realms = realms
        db.dbVersion = 2
    end
end

-- The saved table, migrated and with its parts present. Looked up on every call (never
-- kept), because the client assigns the saved file's table after the files ran.
local function DB()
    if type(toawowcharDB) ~= "table" then
        toawowcharDB = {}
    end
    local db = toawowcharDB
    if db.dbVersion ~= DB_VERSION then
        if db.dbVersion == nil then
            MigrateDB(db)
        else
            sessionDB = sessionDB or { dbVersion = DB_VERSION }
            db = sessionDB
        end
    end
    if type(db.realms) ~= "table" then
        db.realms = {}
    end
    if type(db.guide) ~= "table" then
        db.guide = {}
    end
    return db
end

-- What the other files read from the namespace.
ns.DB_VERSION = DB_VERSION
ns.DB = DB
ns.ADDON_VERSION = ADDON_VERSION
ns.FORMAT_VERSION = FORMAT_VERSION
ns.PREFIX = PREFIX
ns.MAX_EXPORT_LENGTH = MAX_EXPORT_LENGTH
ns.ADDON_BODY_MAX = ADDON_BODY_MAX
ns.BODY_WRAPPER = BODY_WRAPPER
ns.CACHE_VERSION = CACHE_VERSION
ns.CAPS = CAPS
ns.BOUNDS = BOUNDS
ns.REASONS = REASONS
ns.MAX_IDS = MAX_IDS
ns.MAX_PROFESSIONS = MAX_PROFESSIONS
ns.LAST_EQUIPMENT_SLOT = LAST_EQUIPMENT_SLOT
ns.MAX_BONUS_IDS = MAX_BONUS_IDS
ns.MAX_GEMS = MAX_GEMS
ns.MAX_ID = MAX_ID
ns.MAX_REAGENT_COUNT = MAX_REAGENT_COUNT
ns.MAX_TRAIT_RANK = MAX_TRAIT_RANK
ns.PVP_RANK_FACTION_ID = PVP_RANK_FACTION_ID
ns.LEGACY_TREES = LEGACY_TREES
ns.session = session
ns.scan = scan
ns.Cache = Cache
ns.Read = Read
ns.Capture = Capture
ns.Snapshot = Snapshot
ns.UI = UI
ns.IsSecret = IsSecret
ns.Num = Num
ns.Int = Int
ns.InRange = InRange
ns.CleanTime = CleanTime
ns.CountOrZero = CountOrZero
ns.CleanText = CleanText
ns.Fit = Fit
ns.Now = Now
ns.InCombat = InCombat
ns.Say = Say
ns.Part = Part
ns.SortedKeys = SortedKeys
ns.SameSet = SameSet
ns.Live = Live
ns.Cached = Cached
ns.Missing = Missing
ns.With = With
ns.CleanCount = CleanCount
ns.Points = Points
ns.RealmName = RealmName

---------------------------------------------------------------------------
-- Events and command
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then
            -- The client has put the saved table in toawowcharDB by now, or left it
            -- nil (nothing saved, or SavedVariables not kept): start with an empty one,
            -- or migrate an older one (DB). The character's record is looked up and
            -- checked when it is first needed.
            DB()
        end
    elseif event == "BANKFRAME_OPENED" then
        session.bankOpen = true
        if not InCombat() then
            ns.ScanBank()
        end
    elseif event == "BANKFRAME_CLOSED" then
        session.bankOpen = false
        local bank, warbank = session.bankDirty, session.warbankDirty
        session.bankDirty, session.warbankDirty = false, false
        if bank and warbank then
            Say(L["SAVED_BANK_AND_WARBANK"])
        elseif warbank then
            Say(L["SAVED_WARBANK"])
        elseif bank then
            Say(L["SAVED_BANK"])
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        -- Bank tabs can fill in just after the window opens.
        if session.bankOpen and not InCombat() then
            ns.ScanBank()
        end
        Snapshot.Request("bags")
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        Snapshot.Request("equipped")
    elseif event == "QUEST_TURNED_IN" then
        Snapshot.TurnedIn(arg1)
        Snapshot.Request("quests")
        Snapshot.Request("player") -- the reward: XP and money
    elseif event == "SKILL_LINES_CHANGED" then
        Snapshot.Request("professions")
    elseif event == "PLAYER_MONEY" or event == "PLAYER_XP_UPDATE" then
        Snapshot.Request("player")
    elseif event == "PLAYER_LEVEL_UP" then
        Snapshot.LevelUp()
    elseif event == "TRADE_SKILL_LIST_UPDATE" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
        Capture.ScheduleRecipes()
    elseif event == "TAXIMAP_OPENED" then
        session.taxiOpen = true
        Capture.Flights()
    elseif event == "TAXI_NODE_STATUS_CHANGED" then
        if session.taxiOpen then
            Capture.Flights()
        end
    elseif event == "TAXIMAP_CLOSED" then
        session.taxiOpen = false
    elseif event == "PLAYER_REGEN_ENABLED" then
        Snapshot.CombatEnded()
        if session.pendingOpen then
            session.pendingOpen = false
            ns.Run()
        end
    end
end)

-- An event name the client does not know raises an error, so each is tried alone.
for _, event in ipairs({
    "ADDON_LOADED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "BAG_UPDATE_DELAYED",
    "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
    "TAXIMAP_OPENED", "TAXIMAP_CLOSED", "TAXI_NODE_STATUS_CHANGED", "PLAYER_REGEN_ENABLED",
    "PLAYER_EQUIPMENT_CHANGED", "QUEST_TURNED_IN", "SKILL_LINES_CHANGED", "PLAYER_LEVEL_UP",
    "PLAYER_MONEY", "PLAYER_XP_UPDATE",
}) do
    pcall(events.RegisterEvent, events, event)
end

local function Command(message)
    local word = (type(message) == "string" and message or ""):lower():match("^%s*(%S*)")
    if word == "reset" then
        Cache.Reset()
        Say(L["RESET_DONE"])
        return
    end
    -- /wowchar guide shows or hides the leveling guide; it holds its own frame changes back in
    -- combat (UI/GuideWindow.lua), so it does not wait like the export does. It runs as the
    -- guide part: an error there turns the guide off, never this command or the export.
    if word == "guide" then
        local guide = Part("guide", L["PART_GUIDE"])
        if guide.IsOff() then
            guide.SayOff()
        else
            guide.Call(ns.Guide and ns.Guide.Toggle)
        end
        return
    end
    -- In combat the game hides values from addons: wait until it ends.
    if InCombat() then
        session.pendingOpen = true
        Say(L["OPENS_AFTER_COMBAT"])
        return
    end
    ns.Run()
end

-- One command, two names: /wowchar and /toawowchar do the same.
SLASH_WOWCHAR1 = "/wowchar"
SLASH_WOWCHAR2 = "/toawowchar"
SlashCmdList["WOWCHAR"] = Command
