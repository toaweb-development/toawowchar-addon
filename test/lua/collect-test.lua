-- Quest data collection (Collect.lua) with stubs of the quest frame, the quest log, the map
-- and the world map. Usage (from the repository root):
--     lua test/lua/collect-test.lua <scenario>
-- Prints lines `label<TAB>json` (the addon's own serializer); test/collect.test.mjs reads them.
local scenario = arg[1] or "events"
local Env = dofile("test/lua/wow-env.lua")

local function emit(label, value)
    print(label .. "\t" .. Env.ns.Serialize(value))
end

-- ── the game ────────────────────────────────────────────────────────────
local SECRET = setmetatable({}, { __tostring = function() return "secret" end })
issecretvalue = function(v) return v == SECRET end

local game = {
    map = 2400, x = 0.4321, y = 0.5678, inInstance = false,
    npc = nil,        -- { guid, name } of the unit "npc", or nil
    detail = nil,     -- what the quest window shows: { id, title, summary, choices = { { lootType, itemId } } }
    complete = nil,   -- the quest id of the reward window
    log = {},         -- questID -> { title, level, objectives = { { text, have, need } } }, in log order
    order = {},       -- the log's quest ids in order
    lines = {},       -- uiMapID -> the QuestLineInfo list of the world map
    requested = {},
}

UnitGUID = function(unit)
    if unit == "npc" then return game.npc and game.npc.guid end
    return "Player-0000-00000001"
end
UnitName = function(unit)
    if unit == "npc" then return game.npc and game.npc.name end
    return "Thor"
end
IsInInstance = function() return game.inInstance, game.inInstance and "party" or "none" end
GetBuildInfo = function() return "1.60.1", "70532", "Oct 1 2026", 16001 end

GetQuestID = function() return game.detail and game.detail.id or game.complete end
GetTitleText = function() return game.detail and game.detail.title end
GetObjectiveText = function() return game.detail and game.detail.summary end
GetNumQuestChoices = function() return game.detail and #game.detail.choices or 0 end
GetQuestItemInfoLootType = function(_, i) return game.detail.choices[i][1] end
GetQuestItemInfo = function(_, i)
    local c = game.detail.choices[i]
    return "Reward " .. i, 0, 1, 2, true, c[1] == 0 and c[2] or nil
end

C_Map = {
    GetBestMapForUnit = function() return game.map end,
    GetPlayerMapPosition = function(map)
        if game.x == nil or map ~= game.map then return nil end
        local x, y = game.x, game.y
        return { GetXY = function() return x, y end }
    end,
    GetMapInfo = function(id) return { mapID = id, parentMapID = 0 } end,
}

C_QuestLog = {
    GetTitleForQuestID = function(id) return game.log[id] and game.log[id].title end,
    GetQuestDifficultyLevel = function(id) return game.log[id] and game.log[id].level or (game.detail and game.detail.level) end,
    GetQuestObjectives = function(id)
        local q = game.log[id]
        if not q then return {} end
        local list = {}
        for i, o in ipairs(q.objectives) do
            list[i] = { text = o[1], numFulfilled = o[2], numRequired = o[3], finished = o[2] >= o[3], type = "monster" }
        end
        return list
    end,
    GetNumQuestLogEntries = function() return #game.order, #game.order end,
    GetQuestIDForLogIndex = function(i) return game.order[i] end,
    GetLogIndexForQuestID = function(id)
        for i, q in ipairs(game.order) do if q == id then return i end end
    end,
    GetInfo = function(i) local id = game.order[i]; return id and { questID = id, level = game.log[id].level } end,
    IsQuestFlaggedCompleted = function() return false end,
}

C_QuestLine = {
    RequestQuestLinesForMap = function(map) game.requested[#game.requested + 1] = map end,
    GetAvailableQuestLines = function(map) return game.lines[map] or {} end,
}

local worldMap = { shown = false, mapID = 2400, hooks = {} }
function worldMap.GetMapID(self) return self.mapID end
function worldMap.IsShown(self) return self.shown end
function worldMap.HookScript(self, name, fn) self.hooks[name] = fn end
WorldMapFrame = worldMap
local function openMap(map)
    worldMap.mapID, worldMap.shown = map, true
    worldMap.hooks.OnShow(worldMap)
end

-- ── helpers ─────────────────────────────────────────────────────────────
local function load()
    Env.load()
    Env.fire("ADDON_LOADED", "toawowchar")
end
local function O() return toawowcharDB.observed end
-- The observed table as the export section writes it (lists sorted by id), for printing.
local function quest(id)
    for _, q in ipairs(Env.ns.Collect.Section().quests) do if q.id == id then return q end end
    return false
end
local function npc(id)
    for _, n in ipairs(Env.ns.Collect.Section().npcs) do if n.id == id then return n end end
    return false
end
local function at(x, y, map) game.x, game.y, game.map = x, y, map or game.map end
local function giver(id, name) game.npc = { guid = "Creature-0-3110-0-47-" .. id .. "-0000A1B2C3", name = name } end

local function offer(id, title, npc, npcName)
    giver(npc, npcName)
    game.detail = { id = id, title = title, summary = "Do the thing for " .. npcName .. ".", level = 12, choices = { { 0, 9001 }, { 1, 0 }, { 0, 9002 } } }
    Env.fire("QUEST_DETAIL")
end

local function accept(id, title, objectives)
    game.log[id] = { title = title, level = 12, objectives = objectives }
    game.order[#game.order + 1] = id
    Env.fire("QUEST_ACCEPTED", id)
    game.detail = nil
end

local function count(id, objective, have)
    game.log[id].objectives[objective][2] = have
    Env.fire("QUEST_LOG_UPDATE")
end

local function turnIn(id, npc, npcName, xp, money)
    giver(npc, npcName)
    game.complete = id
    Env.fire("QUEST_COMPLETE")
    Env.fire("QUEST_TURNED_IN", id, xp, money)
    game.complete = nil
    game.log[id] = nil
    for i, q in ipairs(game.order) do if q == id then table.remove(game.order, i) break end end
end

local function points(id, objective)
    local q = O().quests[id]
    return q and q.points and q.points[objective] or {}
end

-- ── scenarios ───────────────────────────────────────────────────────────
if scenario == "events" then
    load()
    Env.fire("PLAYER_ENTERING_WORLD", true, false)
    -- offered: id, title, level, summary, the item choices (not the currency), giver and place
    at(0.4321, 0.5678)
    offer(501, "The Skyward Path", 70001, "Ranger Aelith")
    emit("offered", quest(501))
    emit("giver", npc(70001))
    -- accepted: the objectives from the log
    accept(501, "The Skyward Path", { { "Windscale slain: 0/8", 0, 8 }, { "Feather collected: 0/4", 0, 4 } })
    emit("accepted", { O().quests[501].objectives, O().quests[501].level })
    -- counts up: a point where the player is; the same place again adds nothing
    at(0.5, 0.5)
    count(501, 1, 1)
    count(501, 1, 2)
    at(0.6, 0.55)
    count(501, 1, 3)
    at(0.61, 0.4)
    count(501, 2, 1)
    emit("points", { points(501, 1), points(501, 2) })
    -- finished and turned in: the finisher, the real XP and money
    at(0.4, 0.6)
    turnIn(501, 70002, "Elder Myr", 1350, 425)
    local q = O().quests[501]
    emit("turned-in", { q.finisher, q.xp, q.money })
    emit("finisher", npc(70002))
    -- the dates and the build on every record, and nothing that looks like a trail
    emit("facts", { q.first, q.last, q.build, O().npcs[70001].first, O().npcs[70001].build })

elseif scenario == "map" then
    -- The world map opens: its quest offers for that map, with their places.
    load()
    game.lines[2400] = {
        { questID = 601, questName = "Feathers in the Wind", x = 0.25, y = 0.75, isHidden = false },
        { questID = 602, questName = "Storm Crows", x = 0.5, y = 0.125, isHidden = false },
    }
    openMap(2400)
    emit("requested", game.requested)
    emit("offers", { O().quests[601].title, O().quests[601].offer, O().quests[602].offer })
    -- QUESTLINE_UPDATE while open reads the map it shows now
    game.lines[2401] = { { questID = 603, questName = "Isle Watch", x = 0.9, y = 0.9 } }
    worldMap.mapID = 2401
    Env.fire("QUESTLINE_UPDATE", false)
    emit("update", { O().quests[603].offer })
    -- closed: nothing
    worldMap.shown = false
    game.lines[2401] = { { questID = 604, questName = "Late", x = 0.1, y = 0.1 } }
    Env.fire("QUESTLINE_UPDATE", false)
    emit("closed", { O().quests[604] == nil })

elseif scenario == "no-position" then
    -- Inside an instance, and where the game gives no position (or a hidden one): facts only.
    load()
    game.inInstance = true
    offer(701, "Deep Trouble", 70101, "Captain Holt")
    accept(701, "Deep Trouble", { { "Ooze: 0/5", 0, 5 } })
    count(701, 1, 1)
    local q = O().quests[701]
    emit("instance", { q.title, q.giver, q.start == nil, O().npcs[70101].name, O().npcs[70101].map == nil, #points(701, 1) })
    game.inInstance = false
    game.x = nil
    offer(702, "No Map", 70102, "Scout Pell")
    emit("no-map", { O().quests[702].start == nil, O().npcs[70102].map == nil })
    game.x, game.y = SECRET, 0.5
    offer(703, "Hidden", 70103, "Watcher")
    emit("hidden", { O().quests[703].start == nil })
    -- a secret GUID: no NPC
    game.x, game.y = 0.3, 0.3
    game.npc = { guid = SECRET, name = "Someone" }
    game.detail = { id = 704, title = "Secret", choices = {} }
    Env.fire("QUEST_DETAIL")
    emit("secret-guid", { O().quests[704].giver == nil })
    -- an object, not an NPC
    game.npc = { guid = "GameObject-0-3110-0-47-123456-0000A1B2C3", name = "Wanted Poster" }
    game.detail = { id = 705, title = "Wanted", choices = {} }
    Env.fire("QUEST_DETAIL")
    emit("object", { O().quests[705].giver == nil, O().npcs[123456] == nil })

elseif scenario == "combat" then
    -- In combat nothing is read or written; what counted up is recorded after combat.
    load()
    offer(801, "Before", 70201, "Guard Lin")
    accept(801, "Before", { { "Wolves: 0/6", 0, 6 } })
    local before = Env.ns.Serialize(Env.ns.Collect.Section())
    Env.combat = true
    offer(802, "In Combat", 70202, "Guard Ran")
    accept(802, "In Combat", { { "Bears: 0/2", 0, 2 } })
    at(0.7, 0.7)
    count(801, 1, 1)
    count(801, 1, 2)
    turnIn(802, 70203, "Guard Tam", 500, 10)
    openMap(2400)
    emit("in-combat", { Env.ns.Serialize(Env.ns.Collect.Section()) == before })
    Env.combat = false
    Env.fire("PLAYER_REGEN_ENABLED")
    emit("after-combat", { points(801, 1), O().quests[802] == nil })

elseif scenario == "off" then
    -- «Collect quest data» off: nothing; on again, it starts afresh (no catch-up of what passed).
    load()
    offer(901, "Kept", 70301, "Aide")
    accept(901, "Kept", { { "Rats: 0/9", 0, 9 } })
    toawowcharDB.settings.collect = false
    offer(902, "Not kept", 70302, "Aide Two")
    at(0.2, 0.2)
    count(901, 1, 3)
    emit("off", { O().quests[902] == nil, #points(901, 1) })
    toawowcharDB.settings.collect = true
    count(901, 1, 3)
    emit("on-again", { #points(901, 1) })
    at(0.8, 0.8)
    count(901, 1, 4)
    emit("counted", { #points(901, 1) })

elseif scenario == "spread" then
    -- 40 kills walking across the map from west to east: 20 points, spread over the whole way
    -- (not the first 20).
    local list = {}
    load()
    for i = 1, 40 do
        Env.ns.Collect.Spread(list, { 2400, 100 + i * 20, 500 })
    end
    local xs = {}
    for i, p in ipairs(list) do xs[i] = p[2] end
    table.sort(xs)
    emit("spread", { #list, xs[1], xs[#xs] })
    -- the same place twice: once; another map is always far
    local two = {}
    emit("same", { Env.ns.Collect.Spread(two, { 2400, 500, 500 }), Env.ns.Collect.Spread(two, { 2400, 503, 502 }) or false,
        Env.ns.Collect.Spread(two, { 2401, 500, 500 }) })
    -- through the events: 30 count-ups at 30 places give 20 points
    accept(1001, "Many", { { "Kills: 0/30", 0, 30 } })
    for i = 1, 30 do
        at(0.1 + i * 0.025, 0.5)
        count(1001, 1, i)
    end
    emit("through-events", { #points(1001, 1) })

elseif scenario == "cap" then
    -- Full: the oldest quest's points go first; quests and NPCs stay.
    load()
    local quests = O().quests
    local MAX = Env.ns.Collect.MAX_POINTS
    -- 200 quests x 20 points = 4000; quest 1 seen on day 100 (oldest), the others on day 200
    for id = 1, 200 do
        local list = {}
        for i = 1, 20 do list[i] = { 2400, i * 40, id } end
        quests[id] = { title = "Q" .. id, first = 100, last = id == 1 and 100 or 200, points = { list } }
    end
    O().npcs[5] = { name = "Kept NPC", first = 1, last = 1 }
    Env.ns.Collect.Forget()
    local q, n, p = Env.ns.Collect.Counts()
    emit("full", { q, n, p, p == MAX })
    accept(2001, "New", { { "Boars: 0/3", 0, 3 } })
    at(0.5, 0.5)
    count(2001, 1, 1)
    at(0.9, 0.1)
    count(2001, 1, 2)
    q, n, p = Env.ns.Collect.Counts()
    emit("after", { q, n, p, #quests[1].points[1], #quests[2].points[1], #points(2001, 1), O().npcs[5] ~= nil })

elseif scenario == "zone15" then
    -- A made-up zone of 15 quests played through: each offered by an NPC, accepted, two
    -- objectives counted up 12 and 25 times across the area, turned in at another NPC; the
    -- world map shows the offers. How big the observed table is then.
    load()
    local lines = {}
    for i = 1, 15 do
        lines[i] = { questID = 3000 + i, questName = "Zone Quest " .. i, x = 0.03 * i, y = 0.05 * i }
    end
    game.lines[2400] = lines
    openMap(2400)
    worldMap.shown = false
    for i = 1, 15 do
        local id = 3000 + i
        at(0.05 * i, 0.06 * i)
        offer(id, "Zone Quest " .. i, 71000 + i, "Quest Giver Number " .. i)
        accept(id, "Zone Quest " .. i, { { "Zone Beast slain: 0/12", 0, 12 }, { "Zone Relic collected: 0/25", 0, 25 } })
        for k = 1, 12 do
            at(0.2 + ((i * 7 + k * 13) % 60) / 100, 0.2 + ((i * 11 + k * 17) % 60) / 100)
            count(id, 1, k)
        end
        for k = 1, 25 do
            at(0.15 + ((i * 5 + k * 19) % 70) / 100, 0.15 + ((i * 3 + k * 23) % 70) / 100)
            count(id, 2, k)
        end
        at(0.5, 0.5)
        turnIn(id, 72000 + (i % 4), "Quest Ender " .. (i % 4), 1000 + i * 50, 200 + i * 10)
    end
    local q, n, p = Env.ns.Collect.Counts()
    local text = Env.ns.Serialize(Env.ns.Collect.Section())
    emit("zone15", { q, n, p, #text })

elseif scenario == "error" then
    -- An error in the collection: one chat line, collection off, the guide goes on.
    load()
    Env.fire("PLAYER_ENTERING_WORLD", true, false)
    accept(1101, "Broken", { { "Things: 0/3", 0, 3 } })
    Env.ns.Collect.Spread = function() error("spread broke", 0) end
    at(0.3, 0.3)
    count(1101, 1, 1)
    local lines = {}
    for _, line in ipairs(Env.chat) do
        if line:find("hit an error", 1, true) then lines[#lines + 1] = line end
    end
    emit("error", { lines, Env.ns.Collect.part.IsOff(), Env.ns.Guide.part.IsOff() })
    -- the collection's events stop: a new offer is not recorded
    offer(1102, "After", 70401, "Anyone")
    emit("after", { O().quests[1102] == nil })
end
