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
    parents = { [2400] = 2401 }, -- the player's map 2400 lies inside 2401
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
    GetMapInfo = function(id) return { mapID = id, parentMapID = game.parents[id] or 0 } end,
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
    -- a map elsewhere (not the player's, nor around it): nothing from browsing
    game.lines[2500] = { { questID = 605, questName = "Far Away", x = 0.4, y = 0.4 } }
    worldMap.mapID = 2500
    Env.fire("QUESTLINE_UPDATE", false)
    emit("elsewhere", { O().quests[605] == nil })
    -- closed: nothing
    worldMap.mapID = 2401
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
    -- shared by a party member (the "npc" is a player): the start next to the real giver stays
    at(0.3, 0.3)
    offer(706, "Shared", 70106, "Real Giver")
    at(0.9, 0.9)
    game.npc = { guid = "Player-3110-0A1B2C3D", name = "Friend" }
    game.detail = { id = 706, title = "Shared", choices = {} }
    Env.fire("QUEST_DETAIL")
    emit("shared", { quest(706).start, quest(706).giver })

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
    emit("after", { q, n, p, #quests[1].points[1], #quests[2].points[1], #points(2001, 1), O().npcs[5] ~= nil,
        quests[1].points[1][1][2] })

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

if scenario == "settings" then
    -- The settings panel: registered at login, opened by /wowchar settings, two switches and
    -- the stored counts.
    local registered, opened = {}, {}
    Settings = {
        RegisterCanvasLayoutCategory = function(frame, name)
            local c = { frame = frame, name = name }
            function c.GetID() return 77 end
            return c
        end,
        RegisterAddOnCategory = function(c) registered[#registered + 1] = c.name end,
        OpenToCategory = function(id) opened[#opened + 1] = id end,
    }
    load()
    Env.slash("/wowchar settings")
    emit("before-login", { Env.chat[#Env.chat], #opened })
    Env.fire("PLAYER_LOGIN")
    local panel, w, category = Env.ns.SettingsPanel.Frame()
    emit("registered", { registered, category.frame == panel })
    Env.slash("/wowchar settings")
    emit("opened", opened)
    -- the switches show the defaults; the line counts what is stored
    offer(1201, "Counted", 70501, "Clerk")
    accept(1201, "Counted", { { "Ledgers: 0/2", 0, 2 } })
    at(0.2, 0.7)
    count(1201, 1, 1)
    panel:Show()
    emit("panel", { w.collect.Text.text, w.collect:GetChecked(), w.guide.Text.text, w.guide:GetChecked(), w.stored.text })
    -- clicking writes the saved settings
    w.collect:SetChecked(false)
    w.collect.scripts.OnClick(w.collect)
    w.guide:SetChecked(true)
    w.guide.scripts.OnClick(w.guide)
    emit("clicked", { toawowcharDB.settings.collect, toawowcharDB.settings.guideAtLogin })
    -- in combat: it opens when combat ends
    Env.combat = true
    Env.slash("/wowchar settings")
    emit("in-combat", { Env.chat[#Env.chat], #opened })
    Env.combat = false
    Env.fire("PLAYER_REGEN_ENABLED")
    emit("after-combat", { #opened })
    -- an error in the panel: only the panel is off; /wowchar still exports
    Settings.OpenToCategory = function() error("settings broke", 0) end
    Env.slash("/wowchar settings")
    local text = Env.run()
    emit("error", { Env.chat[#Env.chat], Env.ns.SettingsPanel.part.IsOff(), Env.ns.Collect.part.IsOff(), text:sub(1, 10) })
end

if scenario == "debounce" then
    -- With C_Timer: a burst of updates is read once; a read that waits into combat comes after it.
    Env.useTimers()
    load()
    accept(1301, "Timed", { { "Crabs: 0/9", 0, 9 } })
    at(0.2, 0.2)
    game.log[1301].objectives[1][2] = 1
    Env.fire("QUEST_LOG_UPDATE")
    Env.fire("QUEST_LOG_UPDATE")
    Env.fire("UNIT_QUEST_LOG_CHANGED", "player")
    emit("burst", { #Env.timers, math.floor(Env.timerDelays[1] * 1000 + 0.5) })
    Env.flushTimers()
    emit("read", { #points(1301, 1) })
    at(0.7, 0.7)
    game.log[1301].objectives[1][2] = 2
    Env.fire("QUEST_LOG_UPDATE")
    Env.combat = true
    Env.flushTimers()
    emit("waited-into-combat", { #points(1301, 1) })
    Env.combat = false
    Env.fire("PLAYER_REGEN_ENABLED")
    Env.flushTimers()
    emit("after-combat", { #points(1301, 1) })
end

-- A-104: real-module acceptance probes. Secrets are modeled by opaque tables;
-- __index traps prove rejection before indexing, not real-client secret VM behavior.
local secretTables = {}
issecrettable = function(v) return secretTables[v] == true end
local function hiddenTable()
    local t = setmetatable({}, { __index = function() error("indexed secret table", 0) end })
    secretTables[t] = true
    return t
end
local UNKNOWN = 2147483000 -- not present in the shipped guide; still within format-3 ID bounds
local function seedUnknown()
    offer(UNKNOWN, "Uncharted Forever Quest", 79999, "Uncharted Giver")
    accept(UNKNOWN, "Uncharted Forever Quest", { { "Unknown relic: 0/50", 0, 50 } })
end
local function healthy()
    return not Env.ns.Collect.part.IsOff()
end

if scenario == "independent" or scenario == "independent-absent" then
    if scenario == "independent-absent" then
        local files = Env.tocFiles
        Env.tocFiles = function()
            local result = {}
            for _, path in ipairs(files()) do
                if not path:find("Navigation.lua", 1, true) then result[#result + 1] = path end
            end
            return result
        end
    end
    load()
    assert(not Env.ns.Guide.state.route)
    -- No guide startup or route lookup is needed. Failed parts must stay irrelevant.
    Env.ns.Guide.part.Call(function() error("test guide failure") end)
    if Env.ns.Navigation then Env.ns.Navigation.part.Call(function() error("test navigation failure") end) end
    seedUnknown()
    count(UNKNOWN, 1, 1)
    local q = O().quests[UNKNOWN]
    emit("independent", { q.title, q.giver, q.start, points(UNKNOWN, 1), healthy(), not Env.ns.Guide.state.route })

elseif scenario == "record-caps" then
    load()
    for id = 1, 3000 do
        O().quests[id] = { title = "Preserved quest " .. id, first = 1, last = 2 }
        O().npcs[id] = { name = "Preserved NPC " .. id, first = 1, last = 2 }
    end
    Env.ns.Collect.Forget()
    offer(3000, "Updated at cap", 3000, "Updated NPC")
    offer(3001, "Rejected at cap", 3001, "Rejected NPC")
    -- NPC cap is independent: an existing quest may reference a newly seen NPC.
    offer(3000, "Updated at cap", 3001, "Rejected NPC")
    emit("caps", { Env.ns.Collect.Counts() })
    emit("preserved", { O().quests[1].title, O().npcs[1].name, O().quests[3000].title,
        O().quests[3001] == nil, O().npcs[3001] == nil, O().quests[3000].giver })
    toawowcharDB.settings.collect = false
    Env.ns.Collect.Forget()
    offer(3000, "Disabled", 3000, "Disabled")
    toawowcharDB.settings.collect = true
    Env.ns.Collect.Forget()
    offer(3000, "Reenabled", 3000, "Reenabled")
    emit("reenabled", { Env.ns.Collect.Counts() })
    emit("updated", { O().quests[3000].title, O().npcs[3000].name })

elseif scenario == "reload-points" then
    load()
    -- Realistic full objective lists, one slot free globally. First point after
    -- session init must not be counted twice and evict an old valid point.
    for id = 1, 200 do
        local list = {}
        for i = 1, (id == 200 and 19 or 20) do list[i] = { 2400, i * 40, id } end
        O().quests[id] = { title = "Q" .. id, last = id, points = { list } }
    end
    Env.relog()
    load()
    accept(200, "Q200", { { "Relics: 0/50", 0, 50 } })
    at(0.95, 0.95)
    count(200, 1, 1)
    emit("reload-points", { Env.ns.Collect.Counts() })
    emit("no-eviction", { #O().quests[1].points[1], #points(200, 1) })

elseif scenario == "storm" then
    Env.useTimers()
    load()
    seedUnknown()
    for burst = 1, 25 do
        game.log[UNKNOWN].objectives[1][2] = burst
        for _ = 1, 100 do
            Env.fire("QUEST_LOG_UPDATE")
            Env.fire("UNIT_QUEST_LOG_CHANGED", "player")
        end
        assert(#Env.timers == 1, "event storm multiplied timers")
        Env.flushTimers()
        assert(#Env.timers == 0, "timer callback rescheduled itself")
    end
    emit("storm", { #points(UNKNOWN, 1), healthy() })
    -- Pending read survives the settings switch without multiplication/catch-up.
    game.log[UNKNOWN].objectives[1][2] = 26
    Env.fire("QUEST_LOG_UPDATE")
    toawowcharDB.settings.collect = false
    Env.ns.Collect.Forget()
    Env.flushTimers()
    toawowcharDB.settings.collect = true
    Env.ns.Collect.Forget()
    at(0.8, 0.8)
    Env.fire("QUEST_LOG_UPDATE")
    Env.flushTimers()
    emit("baseline", { #points(UNKNOWN, 1) })
    count(UNKNOWN, 1, 27)
    Env.flushTimers()
    emit("resumed", { #points(UNKNOWN, 1), #Env.timers })

elseif scenario:find("^unsafe%-") then
    load()
    seedUnknown()
    local mode = scenario:sub(8)
    if mode == "position-table" then
        C_Map.GetPlayerMapPosition = function() return hiddenTable() end
    elseif mode == "position-scalar" then
        C_Map.GetPlayerMapPosition = function() return SECRET end
    elseif mode == "nan" then
        game.x = 0 / 0
    elseif mode == "infinite" then
        game.x = math.huge
    elseif mode == "range" then
        game.x = -0.1
    elseif mode == "missing" then
        C_Map.GetPlayerMapPosition = nil
    elseif mode == "raising" then
        C_Map.GetPlayerMapPosition = function() error("position unavailable") end
    elseif mode == "method-secret" then
        C_Map.GetPlayerMapPosition = function() return { GetXY = SECRET } end
    elseif mode == "objective-list" then
        C_QuestLog.GetQuestObjectives = function() return hiddenTable() end
    elseif mode == "objective-record" then
        C_QuestLog.GetQuestObjectives = function() return { hiddenTable() } end
    elseif mode == "objective-count" then
        C_QuestLog.GetQuestObjectives = function() return { { text = SECRET, numFulfilled = SECRET, numRequired = SECRET } } end
    elseif mode == "objective-nil" then
        C_QuestLog.GetQuestObjectives = function() return { { text = "Available text" } } end
    elseif mode == "level-table" then
        C_QuestLog.GetQuestDifficultyLevel = nil
        C_QuestLog.GetInfo = function() return hiddenTable() end
    elseif mode == "map-list" or mode == "map-record" then
        C_QuestLine.GetAvailableQuestLines = function()
            if mode == "map-list" then return hiddenTable() end
            return { hiddenTable() }
        end
    elseif mode == "map-parent" then
        C_Map.GetMapInfo = function() return hiddenTable() end
    elseif mode == "map-shown" then
        WorldMapFrame.IsShown = function() error("map not available") end
    elseif mode == "map-shown-secret" then
        WorldMapFrame.IsShown = function() return SECRET end
    elseif mode == "scalar-fields" then
        GetTitleText = function() return SECRET end
        GetObjectiveText = function() return SECRET end
        UnitName = function() return SECRET end
        UnitGUID = function() return SECRET end
        GetNumQuestChoices = function() return SECRET end
        C_QuestLog.GetQuestDifficultyLevel = function() return math.huge end
        GetBuildInfo = function() return nil, SECRET end
        time = function() return 0 / 0 end
    elseif mode == "bad-ids" then
        for _, id in ipairs({ SECRET, 0 / 0, math.huge, -1, 2147483648, 1.5 }) do
            Env.fire("QUEST_ACCEPTED", id)
        end
    else error("unknown unsafe probe " .. mode) end
    Env.fire("QUEST_ACCEPTED", UNKNOWN)
    count(UNKNOWN, 1, 1)
    if mode:find("^map%-") then
        if mode == "map-parent" then openMap(2401) else openMap(2400) end
    end
    Env.fire("QUEST_TURNED_IN", UNKNOWN, SECRET, math.huge)
    local q = O().quests[UNKNOWN]
    emit("safe", { healthy(), q.title, q.giver, q.start, q.level, q.xp == nil, q.money == nil })
    if mode == "nan" or mode == "infinite" or mode == "range" or mode == "missing" or mode == "raising"
        or mode == "position-table" or mode == "position-scalar" or mode == "method-secret" then
        emit("invalid-position", { #points(UNKNOWN, 1) })
        C_Map.GetPlayerMapPosition = function() return { GetXY = function() return 0.8, 0.8 end } end
        count(UNKNOWN, 1, 2)
        emit("recovered", { healthy(), points(UNKNOWN, 1) })
    end
    if mode == "bad-ids" then emit("ids", { Env.ns.Collect.Counts() }) end

elseif scenario == "restrictions" then
    load()
    seedUnknown()
    local active = true
    Enum = Enum or {}
    Enum.AddOnRestrictionType = { Map = 7 }
    C_RestrictedActions = { IsAddOnRestrictionActive = function() return active end }
    Env.fire("ADDON_RESTRICTION_STATE_CHANGED", 7, 1)
    at(0.7, 0.7)
    count(UNKNOWN, 1, 1)
    offer(UNKNOWN, "Metadata while restricted", 79999, "Uncharted Giver")
    emit("restricted", { #points(UNKNOWN, 1), O().quests[UNKNOWN].title, healthy() })
    active = false
    Env.fire("ADDON_RESTRICTION_STATE_CHANGED", 7, 0)
    count(UNKNOWN, 1, 2)
    emit("unrestricted", { points(UNKNOWN, 1), healthy() })
    -- Activating event wins even if the query has not changed yet.
    Env.fire("ADDON_RESTRICTION_STATE_CHANGED", 7, 1)
    at(0.9, 0.9)
    count(UNKNOWN, 1, 3)
    emit("activating", { #points(UNKNOWN, 1) })
    Env.fire("ADDON_RESTRICTION_STATE_CHANGED", 7, 0)
    count(UNKNOWN, 1, 4)
    emit("restriction-resumed", { #points(UNKNOWN, 1) })

elseif scenario == "persist-produce" then
    load()
    seedUnknown()
    count(UNKNOWN, 1, 1)
    -- Controlled primitive Lua literal, test-only. No game/import input is executed.
    local function literal(v)
        if type(v) == "table" then
            local keys, entries = {}, {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do entries[#entries + 1] = "[" .. literal(k) .. "]=" .. literal(v[k]) end
            return "{" .. table.concat(entries, ",") .. "}"
        end
        if type(v) == "string" then return string.format("%q", v) end
        assert(type(v) == "number" or type(v) == "boolean")
        return tostring(v)
    end
    toawowcharDB.realms.Preserved = { Character = { marker = "cache survives" } }
    toawowcharDB.guide.saved = { step = 7 }
    toawowcharDB.settings.guideAtLogin = false
    emit("literal", "return " .. literal(toawowcharDB))
    emit("observed", O())

elseif scenario == "persist-consume" then
    -- Fresh Lua process; only the Node test's generated temporary literal is loaded.
    toawowcharDB = assert(loadfile(assert(arg[2])))()
    local before = Env.ns -- no addon namespace from the producer process
    load()
    assert(before == Env.ns)
    emit("observed", O())
    emit("preserved", { toawowcharDB.dbVersion, toawowcharDB.realms.Preserved.Character.marker,
        toawowcharDB.guide.saved.step, toawowcharDB.settings.guideAtLogin })
    emit("counts", { Env.ns.Collect.Counts() })
    accept(UNKNOWN, "Uncharted Forever Quest", { { "Unknown relic: 0/50", 1, 50 } })
    count(UNKNOWN, 1, 1)
    at(0.8, 0.8)
    count(UNKNOWN, 1, 2)
    emit("continued", { Env.ns.Collect.Counts() })
end
