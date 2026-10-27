-- Quest data collection: what the game shows about quests while Tor plays, kept as facts in
-- toawowcharDB.observed (Core.lua, dbVersion 3), for Forever's new zones that Questie and the
-- client files do not have. Nothing is sent anywhere; the export can carry it later (Export.lua,
-- the «observed» section, off until wowchar accepts it).
--
-- What is recorded, outside combat only (InCombatLockdown), and only while the setting
-- «Collect quest data» is on (toawowcharDB.settings.collect, default on):
--   offered (QUEST_DETAIL)   quest id, title, quest level, the objective summary, the reward
--                            choices (item ids); the giver's NPC id and name; the player's map
--                            and x, y (standing next to the giver)
--   accepted (QUEST_ACCEPTED) title, level and the objectives (text, count needed) from the log
--   an objective counts up    the player's map and x, y, at most MAX_SPREAD points per objective,
--   (QUEST_LOG_UPDATE,        spread over the area (Spread). A count that went up in combat is
--   UNIT_QUEST_LOG_CHANGED)   recorded at the first update after combat, where the player is then.
--   finished (QUEST_COMPLETE) the finisher's NPC id, name and position
--   turned in (QUEST_TURNED_IN) the XP and money the game gave (its own numbers for Forever)
--   the world map opens       the quest offers it shows (C_QuestLine), with x, y, for the map
--                            the player is on or one around it (not for zones only browsed)
-- Inside an instance, or when the game gives no position (or a hidden one), the facts are kept
-- without a position. Records hold facts only: no time per point and no trail. Each quest and
-- NPC record has `first` and `last` (days since 1970, from time()) and the client build.
--
-- Layout:
--   observed.quests[questID] = { title, level, summary, choices = { itemID ... },
--       objectives = { { text, need } ... }, giver = npcID, finisher = npcID, startItem = itemID,
--       start = { map, x, y }, offer = { map, x, y }, xp, money,
--       points = { [objective] = { { map, x, y } ... } }, first, last, build }
--   observed.npcs[npcID] = { name, map, x, y, first, last, build }
-- Positions are per mille of the map (0 to 1000), the precision of the route's coordinates.
--
-- Size: at most MAX_QUESTS quests and MAX_NPCS NPCs (a new one past that is not kept) and
-- MAX_POINTS points in all. When the points are full, the oldest go first: points of the quest
-- seen longest ago (its `last`), one at a time. Quests and NPCs stay.
--
-- Collection is a part (Core.lua, Part): its events, the map hook and every read run through
-- it. An error turns off only the collection until /reload; the export, the cache and the guide
-- never call into it except Export's guarded Section() and the settings panel's Counts().
--
-- API (Gethe/wow-ui-source, branch forever, ca8368f, build 1.60.1.70532):
--   Events: QUEST_DETAIL (QuestLogDocumentation.lua:1349, payload questStartItemID),
--     QUEST_ACCEPTED (:1310), QUEST_COMPLETE (:1332), QUEST_TURNED_IN (:1396, questID, xpReward,
--     moneyReward), QUEST_LOG_UPDATE (:1371), QUESTLINE_UPDATE (:1430, requestRequired),
--     UNIT_QUEST_LOG_CHANGED (UnitDocumentation.lua:4565), PLAYER_REGEN_ENABLED (:3891).
--   The quest frame's legacy globals, as Blizzard's own quest frame calls them
--   (Blizzard_UIPanels_Game/Mainline/QuestInfo.lua, QuestFrame.lua): GetQuestID, GetTitleText,
--     GetObjectiveText (:393), GetNumQuestChoices (QuestFrame.lua:155), GetQuestItemInfo
--     (:525, sixth return itemID), GetQuestItemInfoLootType (:787, 0 = an item).
--   C_QuestLog: GetQuestDifficultyLevel (:380), GetTitleForQuestID (:668), GetInfo (:191, .level),
--     GetLogIndexForQuestID (:206), GetQuestObjectives (:477), GetNumQuestLogEntries (:303),
--     GetQuestIDForLogIndex (:395).
--   C_QuestLine: RequestQuestLinesForMap (QuestLineInfoDocumentation.lua:104),
--     GetAvailableQuestLines (:11, QuestLineInfo questID, questName, x, y); Blizzard reads them
--     the same way (Blizzard_SharedMapDataProviders/QuestOfferDataProvider.lua:174, :353).
--   WorldMapFrame (Blizzard_WorldMap/Blizzard_WorldMap.xml:67, not load on demand) with
--     HookScript (SimpleScriptRegionAPIDocumentation.lua:365) and GetMapID
--     (Blizzard_MapCanvas/Blizzard_MapCanvas.lua:77).
--   Position: C_Map.GetBestMapForUnit (MapDocumentation.lua:49), C_Map.GetMapInfo (:312,
--     parentMapID :703, for the maps around the player), C_Map.GetPlayerMapPosition
--     (:437, a Vector2D; GetXY Blizzard_SharedXML/Vector2D.lua:77), IsInInstance
--     (InstanceDocumentation.lua:170).
--   Units: UnitGUID (UnitDocumentation.lua:1241; may be secret), UnitName (:2489).
--   GetBuildInfo (BuildDocumentation.lua:10), C_Timer.After (UITimerDocumentation.lua:11).
-- Left out: the quest's required level (no call gives it for a quest that is offered or in
-- the log in this build); quest givers that are objects (only Creature and Vehicle GUIDs give
-- an NPC id).
local _, ns = ...

local L = ns.L
local DB = ns.DB
local Int = ns.Int
local IsSecret = ns.IsSecret
local InCombat = ns.InCombat

local Collect = {}
ns.Collect = Collect

local part = ns.Part("collect", L["PART_COLLECT"])
Collect.part = part

local MAX_SPREAD = 20       -- points per objective
local MAX_POINTS = 4000     -- points in all
local MAX_QUESTS = 3000
local MAX_NPCS = 3000
local MAX_OBJECTIVES = 12   -- wowchar's objectivesPerQuest (test/contract.json)
local MAX_CHOICES = 10
local MAX_TEXT = 255        -- wowchar's objectiveText
local MAX_NAME = 100        -- wowchar's nameText
local SAME_PLACE = 5        -- per mille: a point this close to one already kept adds nothing
local DEBOUNCE = 0.3        -- seconds: a burst of quest log updates is read once
Collect.MAX_SPREAD, Collect.MAX_POINTS = MAX_SPREAD, MAX_POINTS
Collect.MAX_QUESTS, Collect.MAX_NPCS = MAX_QUESTS, MAX_NPCS

-- This session: the last objective counts seen (questID -> { [i] = count }), what the last
-- quest window offered, how many records there are (counted once, then kept up to date).
local counts
local offered = {}
local sizes
local pendingRead = false
local missedInCombat = false

local function Observed()
    return DB().observed
end

local function On()
    return DB().settings.collect == true and not InCombat()
end

---------------------------------------------------------------------------
-- Reading the game, carefully
---------------------------------------------------------------------------

-- A text from the game: not secret, a non-empty string, cut at max bytes on a character boundary.
local function GameText(value, max)
    if IsSecret(value) or type(value) ~= "string" then
        return nil
    end
    local text = value:gsub("[%z\1-\31\127]", " "):match("^%s*(.-)%s*$")
    if text == "" then
        return nil
    end
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

local function Number(value, min, max)
    if IsSecret(value) then
        return nil
    end
    local n = Int(value)
    if n and n >= min and n <= max then
        return n
    end
    return nil
end

-- fn(...) in pcall; its first result, or nil. The value is not looked at here (no truth test,
-- no comparison): it may be secret, and only GameText, Number and NpcId check that first.
local function Ask(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn, ...)
    if not ok then
        return nil
    end
    return value
end

local function Day()
    local now = Number(time and Ask(time), 1, 4102444800)
    return now and math.floor(now / 86400) or nil
end

-- The client build of a record (the second return; pcall also covers a missing function).
local function Build()
    local ok, _, build = pcall(GetBuildInfo)
    return ok and GameText(build, 16) or nil
end

local function Touch(record)
    local day = Day()
    record.first = record.first or day
    record.last = day or record.last
    record.build = Build() or record.build
end

-- The player's { map, x, y } (per mille), or nil: inside an instance, or no position.
local function Position()
    if IsInInstance then
        local ok, inside = pcall(IsInInstance)
        if not ok or IsSecret(inside) or inside == true then
            return nil
        end
    end
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then
        return nil
    end
    local map = Number(Ask(C_Map.GetBestMapForUnit, "player"), 1, 1e9)
    if not map then
        return nil
    end
    local point = Ask(C_Map.GetPlayerMapPosition, map, "player")
    if type(point) ~= "table" or type(point.GetXY) ~= "function" then
        return nil
    end
    local ok, x, y = pcall(point.GetXY, point)
    if not ok or IsSecret(x) or IsSecret(y) or type(x) ~= "number" or type(y) ~= "number" then
        return nil
    end
    if x < 0 or x > 1 or y < 0 or y > 1 or (x == 0 and y == 0) then
        return nil
    end
    return { map, math.floor(x * 1000 + 0.5), math.floor(y * 1000 + 0.5) }
end
Collect.Position = Position

-- The NPC id of the unit "npc" (the one the quest window talks to), from its GUID
-- ("Creature-0-server-instance-zone-npcID-spawn"), or nil.
local function NpcId(guid)
    if IsSecret(guid) or type(guid) ~= "string" then
        return nil
    end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if kind ~= "Creature" and kind ~= "Vehicle" then
        return nil
    end
    return Number(tonumber(id), 1, 2147483647)
end
Collect.NpcId = NpcId

---------------------------------------------------------------------------
-- The records
---------------------------------------------------------------------------

local function Sizes()
    if not sizes then
        sizes = { quests = 0, npcs = 0, points = 0 }
        local o = Observed()
        for _, q in pairs(o.quests) do
            sizes.quests = sizes.quests + 1
            if type(q) == "table" and type(q.points) == "table" then
                for _, list in pairs(q.points) do
                    sizes.points = sizes.points + (type(list) == "table" and #list or 0)
                end
            end
        end
        for _ in pairs(o.npcs) do
            sizes.npcs = sizes.npcs + 1
        end
    end
    return sizes
end

-- The quest's record, made when there is room; nil for a bad id or when full.
local function Quest(id)
    id = Number(id, 1, 2147483647)
    if not id then
        return nil
    end
    local quests = Observed().quests
    local q = quests[id]
    if type(q) ~= "table" then
        if Sizes().quests >= MAX_QUESTS then
            return nil
        end
        q = {}
        quests[id] = q
        sizes.quests = sizes.quests + 1
    end
    Touch(q)
    return q, id
end

-- The NPC of the unit "npc", recorded with its name and the player's position (beside it).
local function Npc(position)
    local id = NpcId(Ask(UnitGUID, "npc"))
    if not id then
        return nil
    end
    local npcs = Observed().npcs
    local n = npcs[id]
    if type(n) ~= "table" then
        if Sizes().npcs >= MAX_NPCS then
            return id
        end
        n = {}
        npcs[id] = n
        sizes.npcs = sizes.npcs + 1
    end
    n.name = GameText(Ask(UnitName, "npc"), MAX_NAME) or n.name
    if position then
        n.map, n.x, n.y = position[1], position[2], position[3]
    end
    Touch(n)
    return id
end

local function Title(q, id)
    q.title = GameText(Ask(C_QuestLog and C_QuestLog.GetTitleForQuestID, id), MAX_NAME) or q.title
end

local function Level(q, id)
    local level = Number(Ask(C_QuestLog and C_QuestLog.GetQuestDifficultyLevel, id), 1, 255)
    if not level and C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetInfo then
        local index = Number(Ask(C_QuestLog.GetLogIndexForQuestID, id), 1, 500)
        local info = index and Ask(C_QuestLog.GetInfo, index)
        level = type(info) == "table" and Number(info.level, 1, 255) or nil
    end
    q.level = level or q.level
end

-- The quest log's objectives of a quest: a list of the game's objective tables, or {}.
local function Objectives(id)
    local list = Ask(C_QuestLog and C_QuestLog.GetQuestObjectives, id)
    return type(list) == "table" and list or {}
end

local function StoreObjectives(q, id)
    local list = {}
    for i, o in ipairs(Objectives(id)) do
        if i > MAX_OBJECTIVES then
            break
        end
        if type(o) == "table" then
            list[i] = { GameText(o.text, MAX_TEXT) or "", Number(o.numRequired, 0, 1e9) or 0 }
        end
    end
    if #list > 0 then
        q.objectives = list
    end
end

---------------------------------------------------------------------------
-- Points: spread over the area, and the cap
---------------------------------------------------------------------------

local function Distance2(a, b)
    if a[1] ~= b[1] then
        return math.huge -- another map: as far apart as can be
    end
    local dx, dy = a[2] - b[2], a[3] - b[3]
    return dx * dx + dy * dy
end

-- The squared distance from p to the nearest point of the list, leaving out index skip.
local function Nearest(list, p, skip)
    local best = math.huge
    for i, q in ipairs(list) do
        if i ~= skip then
            local d = Distance2(p, q)
            if d < best then
                best = d
            end
        end
    end
    return best
end

-- Adds p to the list (at most MAX_SPREAD) so the points cover the area: a point beside one
-- already kept adds nothing; when the list is full, p takes the place of the point that is
-- closest to another, if p is farther from the rest than that one is. Returns "added",
-- "replaced" or nil.
function Collect.Spread(list, p)
    if Nearest(list, p) <= SAME_PLACE * SAME_PLACE then
        return nil
    end
    if #list < MAX_SPREAD then
        list[#list + 1] = p
        return "added"
    end
    local crowded, crowdedDistance = nil, math.huge
    for i, q in ipairs(list) do
        local d = Nearest(list, q, i)
        if d < crowdedDistance then
            crowded, crowdedDistance = i, d
        end
    end
    if crowded and Nearest(list, p, crowded) > crowdedDistance then
        list[crowded] = p
        return "replaced"
    end
    return nil
end

-- Takes away one point of the quest seen longest ago (then the lowest id).
local function DropOldest()
    local oldestId, oldestDay
    for id, q in pairs(Observed().quests) do
        if type(q) == "table" and type(q.points) == "table" then
            for _, list in pairs(q.points) do
                if type(list) == "table" and #list > 0 then
                    local day = q.last or 0
                    if not oldestId or day < oldestDay or (day == oldestDay and id < oldestId) then
                        oldestId, oldestDay = id, day
                    end
                    break
                end
            end
        end
    end
    if not oldestId then
        return false
    end
    local q = Observed().quests[oldestId]
    local longest
    for i, list in pairs(q.points) do
        if type(list) == "table" and #list > 0 and (not longest or #list > #q.points[longest]) then
            longest = i
        end
    end
    table.remove(q.points[longest], 1) -- the first kept is the oldest of that list
    sizes.points = sizes.points - 1
    return true
end

local function AddPoint(id, objective, position)
    local q = Quest(id)
    if not q or not position then
        return
    end
    q.points = type(q.points) == "table" and q.points or {}
    local list = q.points[objective]
    if type(list) ~= "table" then
        list = {}
        q.points[objective] = list
    end
    if Collect.Spread(list, position) == "added" then
        Sizes().points = sizes.points + 1
        while sizes.points > MAX_POINTS and DropOldest() do
            -- the oldest go first
        end
    end
end

---------------------------------------------------------------------------
-- The events
---------------------------------------------------------------------------

local handlers = {}

function handlers.QUEST_DETAIL(startItem)
    if not On() then
        return
    end
    local q, id = Quest(Ask(GetQuestID))
    if not q then
        return
    end
    local position = Position()
    q.title = GameText(Ask(GetTitleText), MAX_NAME) or q.title
    q.summary = GameText(Ask(GetObjectiveText), MAX_TEXT) or q.summary
    Level(q, id)
    local choices = {}
    local n = Number(Ask(GetNumQuestChoices), 0, 100) or 0
    for i = 1, math.min(n, MAX_CHOICES) do
        local item = true
        if GetQuestItemInfoLootType then
            item = Number(Ask(GetQuestItemInfoLootType, "choice", i), 0, 100) == 0
        end
        if item and GetQuestItemInfo then
            local ok, _, _, _, _, _, itemId = pcall(GetQuestItemInfo, "choice", i)
            itemId = ok and Number(itemId, 1, 2147483647) or nil
            if itemId then
                choices[#choices + 1] = itemId
            end
        end
    end
    if #choices > 0 then
        q.choices = choices
    end
    local giver = Npc(position)
    local item = Number(startItem, 1, 2147483647)
    q.giver = giver or q.giver
    q.startItem = item or q.startItem
    -- The place counts as the quest's start only next to its giver (or with its item): a quest
    -- a party member shares is offered wherever the player is.
    if position and (giver or item) then
        q.start = position
    end
    offered[id] = true
end

-- Remembers the counts of every quest in the log, so the next update sees what went up.
local function Baseline(id)
    counts = counts or {}
    local now = {}
    for i, o in ipairs(Objectives(id)) do
        now[i] = type(o) == "table" and Number(o.numFulfilled, 0, 1e9) or 0
    end
    counts[id] = now
end

function handlers.QUEST_ACCEPTED(questId)
    if not On() then
        return
    end
    local q, id = Quest(questId)
    if not q then
        return
    end
    Title(q, id)
    Level(q, id)
    StoreObjectives(q, id)
    if not offered[id] then
        -- accepted without the quest window this session (shared, auto-accepted): the giver,
        -- when the game still names one, and where the player stands
        local position = Position()
        q.giver = Npc(position) or q.giver
        if position and not q.start then
            q.start = position
        end
    end
    Baseline(id)
end

-- Every quest in the log: the counts that went up since last time get a point here.
local function ReadLog()
    pendingRead = false
    if InCombat() then
        missedInCombat = true -- combat began while the read waited: it comes after combat
        return
    end
    if not On() then
        return
    end
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetQuestIDForLogIndex) then
        return
    end
    local first = counts == nil
    counts = counts or {}
    local entries = Number(Ask(C_QuestLog.GetNumQuestLogEntries), 0, 500) or 0
    local position
    for index = 1, entries do
        local id = Number(Ask(C_QuestLog.GetQuestIDForLogIndex, index), 1, 2147483647)
        if id then
            local last = counts[id]
            local now = {}
            for i, o in ipairs(Objectives(id)) do
                local have = type(o) == "table" and Number(o.numFulfilled, 0, 1e9) or 0
                now[i] = have
                if not first and last and i <= MAX_OBJECTIVES and have > (last[i] or 0) then
                    position = position or Position() or false
                    AddPoint(id, i, position or nil)
                    local q = Quest(id)
                    if q and not q.objectives then
                        Title(q, id)
                        StoreObjectives(q, id)
                    end
                end
            end
            counts[id] = now
        end
    end
end
Collect.ReadLog = ReadLog

local function LogChanged()
    if InCombat() then
        missedInCombat = true
        return
    end
    if not On() then
        if DB().settings.collect ~= true then
            counts = nil -- off: the next read starts afresh, it does not count what passed meanwhile
        end
        return
    end
    if C_Timer and C_Timer.After then
        if not pendingRead then
            pendingRead = true
            C_Timer.After(DEBOUNCE, part.Wrap(ReadLog))
        end
    else
        ReadLog()
    end
end

handlers.QUEST_LOG_UPDATE = LogChanged

function handlers.UNIT_QUEST_LOG_CHANGED(unit)
    if unit == "player" then
        LogChanged()
    end
end

-- After combat: what counted up during it is recorded where the player is now (only when a
-- quest log update came in combat).
function handlers.PLAYER_REGEN_ENABLED()
    if missedInCombat then
        missedInCombat = false
        LogChanged()
    end
end

function handlers.QUEST_COMPLETE()
    if not On() then
        return
    end
    local q = Quest(Ask(GetQuestID))
    if not q then
        return
    end
    q.finisher = Npc(Position()) or q.finisher
end

function handlers.QUEST_TURNED_IN(questId, xp, money)
    if not On() then
        return
    end
    local q, id = Quest(questId)
    if not q then
        return
    end
    q.xp = Number(xp, 0, 1e9) or q.xp
    q.money = Number(money, 0, 1e13) or q.money
    offered[id] = nil
    if counts then
        counts[id] = nil
    end
end

-- True when map is the player's map or one of the maps around it (up to MAP_DEPTH parents).
local MAP_DEPTH = 6
local function AroundPlayer(map)
    local here = Number(Ask(C_Map and C_Map.GetBestMapForUnit, "player"), 1, 1e9)
    for _ = 1, MAP_DEPTH do
        if not here then
            return false
        end
        if here == map then
            return true
        end
        local info = Ask(C_Map.GetMapInfo, here)
        here = type(info) == "table" and Number(info.parentMapID, 1, 1e9) or nil
    end
    return false
end

-- The world map's quest offers for the map it shows.
local function ReadMap()
    if not On() or not (WorldMapFrame and WorldMapFrame.GetMapID and C_QuestLine and C_QuestLine.GetAvailableQuestLines) then
        return
    end
    if WorldMapFrame.IsShown and not WorldMapFrame:IsShown() then
        return
    end
    local map = Number(Ask(WorldMapFrame.GetMapID, WorldMapFrame), 1, 1e9)
    -- Only the map the player is on (or one around it): browsing other zones does not fill
    -- the store with quests from everywhere.
    if not map or not AroundPlayer(map) then
        return
    end
    local lines = Ask(C_QuestLine.GetAvailableQuestLines, map)
    if type(lines) ~= "table" then
        return
    end
    for _, info in ipairs(lines) do
        if type(info) == "table" then
            local q = Quest(info.questID)
            if q then
                q.title = q.title or GameText(info.questName, MAX_NAME)
                local x, y = info.x, info.y
                if not IsSecret(x) and not IsSecret(y) and type(x) == "number" and type(y) == "number"
                    and x > 0 and x <= 1 and y > 0 and y <= 1 then
                    q.offer = { map, math.floor(x * 1000 + 0.5), math.floor(y * 1000 + 0.5) }
                end
            end
        end
    end
end
Collect.ReadMap = ReadMap

local function MapShown()
    if not On() then
        return
    end
    local map = Number(Ask(WorldMapFrame.GetMapID, WorldMapFrame), 1, 1e9)
    if map and C_QuestLine and C_QuestLine.RequestQuestLinesForMap then
        pcall(C_QuestLine.RequestQuestLinesForMap, map)
    end
    ReadMap()
end

function handlers.QUESTLINE_UPDATE()
    ReadMap()
end

---------------------------------------------------------------------------
-- What the settings panel and the export read
---------------------------------------------------------------------------

-- How many quests, NPCs and points are stored.
function Collect.Counts()
    sizes = nil
    local s = Sizes()
    return s.quests, s.npcs, s.points
end

-- The export's «observed» section (docs/addon-export-format-3.md in wowchar): lists sorted by
-- id, each record with only the keys it has. Points are flattened to [objective, map, x, y].
local QUEST_KEYS = { "title", "level", "summary", "giver", "finisher", "startItem", "xp", "money", "first", "last", "build" }
local NPC_KEYS = { "name", "map", "x", "y", "first", "last", "build" }

local function SortedIds(set)
    local ids = {}
    for id, record in pairs(set) do
        if type(id) == "number" and type(record) == "table" then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    return ids
end

local function Copy(record, keys, into)
    for _, key in ipairs(keys) do
        if record[key] ~= nil then
            into[key] = record[key]
        end
    end
    return into
end

function Collect.Section()
    local o = Observed()
    local quests, npcs = {}, {}
    for _, id in ipairs(SortedIds(o.quests)) do
        local q = o.quests[id]
        local entry = Copy(q, QUEST_KEYS, { id = id })
        entry.choices = type(q.choices) == "table" and #q.choices > 0 and q.choices or nil
        entry.objectives = type(q.objectives) == "table" and #q.objectives > 0 and q.objectives or nil
        entry.start = q.start
        entry.offer = q.offer
        if type(q.points) == "table" then
            local flat = {}
            for objective = 1, MAX_OBJECTIVES do
                for _, p in ipairs(q.points[objective] or {}) do
                    flat[#flat + 1] = { objective, p[1], p[2], p[3] }
                end
            end
            entry.points = #flat > 0 and flat or nil
        end
        quests[#quests + 1] = entry
    end
    for _, id in ipairs(SortedIds(o.npcs)) do
        npcs[#npcs + 1] = Copy(o.npcs[id], NPC_KEYS, { id = id })
    end
    return { source = "live", quests = quests, npcs = npcs }
end

-- The setting was switched: the counts and what this session saw are taken afresh.
function Collect.Forget()
    sizes, counts, offered = nil, nil, {}
end

---------------------------------------------------------------------------
-- Start: one event frame, a table of handlers, the map hook; all through the part
---------------------------------------------------------------------------

local frame
part.OnFail(function()
    if frame then
        pcall(frame.UnregisterAllEvents, frame)
    end
end)

part.Call(function()
    frame = CreateFrame("Frame")
    frame:SetScript("OnEvent", part.Wrap(function(_, event, ...)
        local handler = handlers[event]
        if handler then
            handler(...)
        end
    end))
    -- An event name the client does not know raises an error, so each is tried alone.
    for event in pairs(handlers) do
        pcall(frame.RegisterEvent, frame, event)
    end
    if WorldMapFrame and WorldMapFrame.HookScript then
        WorldMapFrame:HookScript("OnShow", part.Wrap(MapShown))
    end
end)
