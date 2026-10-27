-- The leveling guide (Guide.lua, Waypoint.lua, UI/GuideWindow.lua) on a small made-up route,
-- with stubs of the quest log, the map and the waypoint API. Usage (from the repository root):
--     lua test/lua/guide-test.lua <scenario>
-- Prints lines `label<TAB>json` (the addon's own serializer); test/guide.test.mjs reads them.
local scenario = arg[1] or "start"
local Env = dofile("test/lua/wow-env.lua")

local function emit(label, value)
    print(label .. "\t" .. Env.ns.Serialize(value))
end

-- A set { [n] = true } as a sorted list (the serializer writes lists 1..n only).
local function keys(set)
    local list = {}
    for k in pairs(set or {}) do list[#list + 1] = k end
    table.sort(list)
    return list
end

-- What is saved for Thor on Forever, with the skipped steps as a list.
local function savedGuide()
    local slot = toawowcharDB.guide.characters.Forever.Thor
    return { route = slot.route, generated = slot.generated, step = slot.step, skipped = keys(slot.skipped) }
end

-- ── the game ────────────────────────────────────────────────────────────
local game = {
    race = "Human", faction = "Alliance", level = 1, map = 1429,
    completed = {},   -- [questID] = true
    log = {},         -- [questID] = { complete = bool, objectives = { { text, finished } } }
    parents = { [1453] = 1429, [1429] = 1415, [1415] = 947, [1460] = 1436, [1436] = 1415 }, -- town maps inside the zones
    waypoint = nil,   -- the user waypoint the game holds
    superTracked = false,
    calls = {},       -- the waypoint calls, in order
    canSet = { [1429] = true, [1436] = true },
}

UnitRace = function() return game.race, (game.race:gsub(" ", "")), 1 end
UnitFactionGroup = function() return game.faction, game.faction end
UnitLevel = function() return game.level end

C_QuestLog = {
    IsQuestFlaggedCompleted = function(id) return game.completed[id] == true end,
    GetLogIndexForQuestID = function(id) return game.log[id] and 1 or nil end,
    IsComplete = function(id) return game.log[id] ~= nil and game.log[id].complete == true end,
    GetQuestObjectives = function(id)
        local q = game.log[id]
        if not q then return {} end
        local list = {}
        for i, o in ipairs(q.objectives or {}) do
            list[i] = { text = o[1], type = "monster", finished = o[2], numFulfilled = o[2] and 1 or 0, numRequired = 1 }
        end
        return list
    end,
}

C_Map = {
    GetBestMapForUnit = function() return game.map end,
    GetMapInfo = function(id) return { mapID = id, name = "map", mapType = 3, parentMapID = game.parents[id] or 0, flags = 0 } end,
    CanSetUserWaypointOnMap = function(id) return game.canSet[id] == true end,
    SetUserWaypoint = function(point)
        -- per mille: the serializer writes whole numbers only
        game.calls[#game.calls + 1] = { "set", point.uiMapID, math.floor(point.position.x * 1000 + 0.5), math.floor(point.position.y * 1000 + 0.5) }
        game.waypoint = point
        return true
    end,
    ClearUserWaypoint = function()
        game.calls[#game.calls + 1] = { "clear" }
        game.waypoint = nil
        game.superTracked = false
    end,
    HasUserWaypoint = function() return game.waypoint ~= nil end,
    GetUserWaypoint = function() return game.waypoint end,
}
UiMapPoint = {
    CreateFromCoordinates = function(mapID, x, y, z)
        return { uiMapID = mapID, position = { x = x, y = y }, z = z }
    end,
}
C_SuperTrack = {
    SetSuperTrackedUserWaypoint = function(on)
        game.calls[#game.calls + 1] = { "track", on }
        game.superTracked = on
    end,
    IsSuperTrackingUserWaypoint = function() return game.superTracked == true end,
}
C_Navigation = {
    GetDistance = function() return game.distance end,
    GetTargetState = function() return game.navState end, -- 0 Invalid, 1 Occluded, 2 InRange, 3 Disabled
}
game.navState = 2
CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
RAID_CLASS_COLORS = { WARRIOR = { r = 0.78, g = 0.61, b = 0.43 } }
GetSubZoneText = function() return game.subzone end
GetZoneText = function() return game.zone end
UnitXP = function() return game.xp end
UnitXPMax = function() return game.xpMax end
game.distance, game.subzone, game.zone, game.xp, game.xpMax = 24.4, "Goldshire", "Elwynn Forest", 450, 1000

-- C_Timer.NewTicker only (no After: the cache then reads at once, as before). Each ticker is
-- kept in `tickers` with its interval; tick(t) runs it once.
local tickers = {}
C_Timer = { NewTicker = function(seconds, fn)
    local t = { seconds = seconds, fn = fn, cancelled = false }
    function t.Cancel(self) self.cancelled = true end
    tickers[#tickers + 1] = t
    return t
end }
-- The ticker that is running now, or nil.
local function running()
    local live
    for _, t in ipairs(tickers) do
        if not t.cancelled then
            assert(live == nil, "two tickers run at once")
            live = t
        end
    end
    return live
end

-- ── the route ───────────────────────────────────────────────────────────
-- { kind, uiMapId, x, y, questIds, name, level, text }; T holds the names and notes.
local T = { "Marshal Dughan", "Kobold Vermin", "Tough Wolf Meat; Boar Hide", "Travel to Westfall", "Grind to level 5 (about 900 XP)", "Gryan Stoutmantle" }
local function routeData()
    return {
        texts = T,
        quests = { [101] = "Kobold Camp Cleanup", [102] = "Wolves | Boars", [201] = "The People's Militia" },
        zones = { [1429] = "Elwynn Forest", [1436] = "Westfall" },
        routes = {
            human = {
                start = "human", faction = "A", questie = "v1", generated = "2026-10-27T06:00:43.496Z", confirmed = true, levelEnd = 6,
                steps = {
                    { 1, 1429, 42.1, 65.9, { 101 }, 1, 1, 0 },      -- 1 accept 101 from the Marshal
                    { 1, 1429, 42.1, 65.9, { 102 }, 1, 1, 0 },      -- 2 accept 102
                    { 2, 1429, 61.0, 47.5, { 101 }, 0, 2, 2 },      -- 3 objective of 101: Kobold Vermin
                    { 2, 1429, 70.2, 30.0, { 102 }, 0, 3, 3 },      -- 4 objectives of 102: wolf meat and boar hide
                    { 3, 1429, 42.1, 65.9, { 101, 102 }, 1, 4, 0 }, -- 5 turn in both
                    { 4, 1436, 50, 50, {}, 0, 4, 4 },               -- 6 travel to Westfall
                    { 5, 1436, 50, 50, {}, 0, 4, 5 },               -- 7 grind to the next step's level (5)
                    { 1, 1436, 56.3, 47.5, { 201 }, 6, 5, 0 },      -- 8 accept 201
                    { 3, 1436, 56.3, 47.5, { 201 }, 6, 6, 0 },      -- 9 turn in 201
                },
            },
            ["skyborne-a"] = {
                start = "skyborne-a", faction = "A", questie = "v1", generated = "2026-10-27T06:00:43.496Z", confirmed = false, levelEnd = 2,
                steps = { { 1, 1429, 10, 10, { 101 }, 1, 1, 0 } },
            },
            ["skyborne-h"] = {
                start = "skyborne-h", faction = "H", questie = "v1", generated = "2026-10-27T06:00:43.496Z", confirmed = false, levelEnd = 2,
                steps = { { 1, 1429, 10, 10, { 101 }, 1, 1, 0 } },
            },
        },
    }
end

local function load()
    Env.load()
    Env.ns.RouteData = routeData()
    Env.fire("ADDON_LOADED", "toawowchar")
end

local function login()
    Env.fire("PLAYER_ENTERING_WORLD", true, false)
end

local G = function() return Env.ns.Guide end
local function index() return G().state.index end

local function frameText()
    local f = Env.ns.GuideWindow.Frame()
    local lines = {}
    if not f then return lines end
    for _, fs in ipairs(Env.fontStrings) do
        if fs.parent == f and fs.shown and fs.text and fs.text ~= "" then lines[#lines + 1] = fs.text end
    end
    return lines
end

-- What the panel shows, region by region (false: hidden or empty). Fractions as per mille:
-- the serializer writes whole numbers only.
local function permille(v) return v and math.floor(v * 1000 + 0.5) or false end
local function panel()
    local w = Env.ns.GuideWindow.Widgets()
    local function t(fs) return fs.shown and fs.text and fs.text ~= "" and fs.text or false end
    local function tint(tx) return tx.tint and { permille(tx.tint[1]), permille(tx.tint[2]), permille(tx.tint[3]) } or false end
    local objectives, following = {}, {}
    for _, fs in ipairs(w.objectives) do
        if t(fs) then objectives[#objectives + 1] = fs.text end
    end
    for _, row in ipairs(w.following) do
        if t(row.text) then following[#following + 1] = { row.icon.atlas, row.text.text } end
    end
    return {
        title = t(w.title), count = t(w.count), note = t(w.note), zone = t(w.zone), level = t(w.level),
        icon = w.icon.shown and w.icon.atlas or false, tint = tint(w.icon),
        kind = t(w.kind), quest = t(w.quest), detail = t(w.detail), objectives = objectives,
        coords = t(w.coords), distance = t(w.distance), xp = w.xp.shown and permille(w.xp.value) or false,
        following = following, message = t(w.message),
        progress = w.progress.shown and permille(w.progress.value) or false,
        height = Env.ns.GuideWindow.Frame().height,
    }
end

local function shown()
    local f = Env.ns.GuideWindow.Frame()
    return f ~= nil and f.shown == true
end

-- ── scenarios ───────────────────────────────────────────────────────────
if scenario == "start" then
    -- The start key for every race token the game may give, and the route the guide takes.
    load()
    local cases = {
        { "Human", "Alliance" }, { "Dwarf", "Alliance" }, { "Gnome", "Alliance" }, { "NightElf", "Alliance" },
        { "Orc", "Horde" }, { "Troll", "Horde" }, { "Scourge", "Horde" }, { "Tauren", "Horde" },
        { "HighOrderSkyborne", "Alliance" }, { "WindshaperSkyborne", "Horde" }, { "Skyborne", "Alliance" }, { "Skyborne", "Horde" },
        { "Skyborne", "Neutral" }, { "Harronir", "Alliance" }, { "Pandaren", "Neutral" },
    }
    local keys = {}
    for i, c in ipairs(cases) do keys[i] = { c[1], c[2], G().StartFor(c[1], c[2]) or false } end
    emit("keys", keys)
    emit("not-a-string", { G().StartFor(nil, "Alliance") or false })

elseif scenario == "window-start" then
    -- What the window says at the start of a confirmed route, a Skyborne one, and with no route.
    local function windowFor(race, faction)
        Env.relog()
        toawowcharDB = nil
        game.race, game.faction = race, faction
        load()
        login()
        Env.slash("/wowchar guide")
        local p = panel()
        return { G().state.key or false, p.title, p.note, p.message }
    end
    emit("human", windowFor("Human", "Alliance"))
    emit("skyborne", windowFor("High Order Skyborne", "Alliance"))
    emit("skyborne-h", windowFor("Windshaper Skyborne", "Horde"))
    emit("none", windowFor("Pandaren", "Alliance"))

elseif scenario == "login" then
    -- Login and /reload: the first quest step whose quests are not all done.
    load()
    local function at(setup)
        Env.relog()
        toawowcharDB = nil
        game.completed, game.log, game.level, game.map = {}, {}, 1, 1429
        setup()
        load()
        login()
        return index()
    end
    emit("fresh", { at(function() end) })
    emit("one-accepted", { at(function() game.log[101] = { objectives = { { "Kobold Vermin slain: 0/10", false } } } end) })
    emit("both-accepted", { at(function()
        game.log[101] = { objectives = { { "Kobold Vermin slain: 0/10", false } } }
        game.log[102] = { objectives = {} }
    end) })
    emit("objective-done", { at(function()
        game.log[101] = { complete = true }
        game.log[102] = { objectives = { { "Tough Wolf Meat: 8/8", true }, { "Boar Hide: 2/6", false } } }
    end) })
    -- both turned in, still in Elwynn: the travel step before the next quest step comes first
    emit("turned-in-elwynn", { at(function() game.completed[101], game.completed[102] = true, true end) })
    -- in Westfall at level 4: the grind step (the next step wants level 5)
    emit("turned-in-westfall", { at(function()
        game.completed[101], game.completed[102] = true, true
        game.map, game.level = 1436, 4
    end) })
    -- in Westfall at level 5: the accept after the grind
    emit("turned-in-level5", { at(function()
        game.completed[101], game.completed[102] = true, true
        game.map, game.level = 1436, 5
    end) })
    emit("all-done", { at(function() game.completed[101], game.completed[102], game.completed[201] = true, true, true end), #G().state.route.steps })
    -- a quest turned in out of order does not move the position past an earlier step
    emit("out-of-order", { at(function() game.completed[201] = true end) })
    -- the quest log may still be empty when the world is entered: the first update finds it again
    Env.relog()
    toawowcharDB = nil
    game.completed, game.log, game.level, game.map = {}, {}, 1, 1429
    load()
    login()
    local before = index()
    game.log[101], game.log[102] = { objectives = {} }, { objectives = {} }
    Env.fire("QUEST_LOG_UPDATE")
    emit("late-log", { before, index() })

elseif scenario == "advance" then
    -- Every kind of step moves on with its own event, and only then.
    load()
    login()
    local trail = { { "login", index() } }
    local function note(label) trail[#trail + 1] = { label, index() } end
    Env.fire("QUEST_LOG_UPDATE"); note("log-update-nothing")
    game.log[101] = { objectives = { { "Kobold Vermin slain: 0/10", false } } }
    Env.fire("QUEST_ACCEPTED", 101); note("accepted-101")
    game.log[102] = { objectives = { { "Tough Wolf Meat: 0/8", false }, { "Boar Hide: 0/6", false } } }
    Env.fire("QUEST_ACCEPTED", 102); note("accepted-102")
    game.log[101].objectives[1][2] = true
    Env.fire("UNIT_QUEST_LOG_CHANGED", "target"); note("other-unit")
    Env.fire("UNIT_QUEST_LOG_CHANGED", "player"); note("kobolds-done")
    game.log[102].objectives[1][2] = true
    Env.fire("QUEST_LOG_UPDATE"); note("one-of-two")
    game.log[102].objectives[2][2] = true
    Env.fire("QUEST_LOG_UPDATE"); note("both")
    game.log[101] = nil
    Env.fire("QUEST_TURNED_IN", 101, 100, 10); note("turned-in-101")
    game.log[102] = nil
    Env.fire("QUEST_TURNED_IN", 102, 100, 10); note("turned-in-102") -- the game's flag is not set yet
    Env.fire("ZONE_CHANGED"); note("zone-changed-still-elwynn")
    game.map = 1436
    Env.fire("ZONE_CHANGED_NEW_AREA"); note("westfall")
    game.level = 4
    Env.fire("PLAYER_LEVEL_UP", 4); note("level-4")
    Env.fire("PLAYER_LEVEL_UP", 5); note("level-5") -- UnitLevel still says 4: the event's level counts
    game.log[201] = { objectives = {} }
    Env.fire("QUEST_ACCEPTED", 201); note("accepted-201")
    game.log[201] = nil
    game.completed[201] = true
    Env.fire("QUEST_TURNED_IN", 201, 100, 10); note("done")
    emit("trail", trail)
    emit("saved", savedGuide())
    -- a town map inside the zone to travel to counts as the zone
    Env.relog()
    toawowcharDB = nil
    game.completed, game.log, game.level = { [101] = true, [102] = true }, {}, 1
    game.map = 1460
    load()
    login()
    emit("town-in-elwynn", { index(), G().StepDone(6) })

elseif scenario == "buttons" then
    -- Skip, Back and Hide, and what is saved per character.
    load()
    login()
    Env.slash("/wowchar guide")
    local f = Env.ns.GuideWindow.Frame()
    local buttons = {}
    for _, child in ipairs(Env.frames) do
        if child.parent == f and child.kind == "Button" then buttons[child.label] = child end
    end
    emit("labels", { buttons.Back ~= nil, buttons.Skip ~= nil, buttons.Hide ~= nil })
    buttons.Skip.scripts.OnClick(buttons.Skip)
    emit("skip", { index(), savedGuide().skipped })
    buttons.Back.scripts.OnClick(buttons.Back)
    emit("back", { index(), G().state.held, savedGuide().skipped })
    -- held: an event that finishes the step does not move it on
    game.log[101] = { objectives = {} }
    Env.fire("QUEST_ACCEPTED", 101)
    emit("held", { index() })
    buttons.Skip.scripts.OnClick(buttons.Skip)
    emit("skip-after-back", { index(), G().state.held })
    -- a relog keeps the skipped steps: 101 is abandoned, but step 1 was skipped, so the guide is at 2
    game.log[101] = nil
    Env.relog()
    load()
    login()
    emit("relog", { index(), savedGuide().step, savedGuide().skipped })
    -- a new route (another generated time) forgets the skipped steps
    Env.relog()
    Env.load()
    local data = routeData()
    data.routes.human.generated = "2026-11-01T00:00:00.000Z"
    Env.ns.RouteData = data
    Env.fire("ADDON_LOADED", "toawowchar")
    login()
    emit("new-route", { index() })
    -- Hide: the window goes, shown = false is saved
    Env.slash("/wowchar guide")
    Env.slash("/wowchar guide")
    local f2 = Env.ns.GuideWindow.Frame()
    local hide
    for _, child in ipairs(Env.frames) do
        if child.parent == f2 and child.kind == "Button" and child.label == "Hide" then hide = child end
    end
    hide.scripts.OnClick(hide)
    emit("hidden", { shown(), toawowcharDB.guide.shown })

elseif scenario == "window" then
    -- The window: three steps with /way lines, its place saved, shown again after a relog.
    load()
    login()
    emit("before-command", { shown() })
    Env.slash("/wowchar guide")
    emit("after-command", { shown(), toawowcharDB.guide.shown })
    emit("text", panel())
    local f = Env.ns.GuideWindow.Frame()
    f.scripts.OnDragStart(f)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 120.4, 640.6)
    f.scripts.OnDragStop(f)
    emit("point", toawowcharDB.guide.point)
    local saved = toawowcharDB
    Env.relog()
    toawowcharDB = saved
    load()
    login()
    local g = Env.ns.GuideWindow.Frame()
    emit("relog", { shown(), g.points[1][1], g.points[1][3], g.points[1][4], g.points[1][5] })
    -- a damaged point puts it at the default place
    toawowcharDB.guide.point = { "NOWHERE", "TOP", 1, 2 }
    Env.relog()
    toawowcharDB = saved
    load()
    login()
    emit("damaged-point", { Env.ns.GuideWindow.Frame().points[1][1] })
    -- /wowchar guide twice: hidden again
    Env.slash("/wowchar guide")
    emit("toggled", { shown(), toawowcharDB.guide.shown })

elseif scenario == "waypoint" then
    load()
    login()
    emit("hidden-no-waypoint", game.calls)
    Env.slash("/wowchar guide")
    emit("shown", game.calls)
    game.calls = {}
    game.log[101] = { objectives = {} }
    Env.fire("QUEST_ACCEPTED", 101)
    emit("next-step", game.calls)
    game.calls = {}
    Env.slash("/wowchar guide")
    emit("hidden", { game.calls, game.waypoint ~= nil })
    -- a waypoint the player placed is not cleared
    Env.slash("/wowchar guide")
    game.waypoint = { uiMapID = 1436, position = { x = 0.3, y = 0.3 } }
    game.calls = {}
    Env.slash("/wowchar guide")
    emit("players-own", { game.calls, game.waypoint ~= nil })
    -- grind steps have no waypoint; a map the game refuses gets none
    Env.relog()
    toawowcharDB = nil
    game.calls, game.waypoint = {}, nil
    game.completed, game.log, game.map, game.level = { [101] = true, [102] = true }, {}, 1436, 4
    load()
    login()
    Env.slash("/wowchar guide")
    emit("grind", { index(), game.calls })
    game.canSet[1436] = false
    Env.fire("PLAYER_LEVEL_UP", 5)
    emit("refused-map", { index(), game.calls, Env.ns.Waypoint.Mine() or false })
    -- without the waypoint API the guide still works
    Env.relog()
    toawowcharDB = nil
    C_Map.SetUserWaypoint, UiMapPoint = nil, nil
    game.completed, game.log, game.map, game.level = {}, {}, 1429, 1
    load()
    login()
    Env.slash("/wowchar guide")
    emit("no-api", { index(), shown() })

elseif scenario == "combat" then
    -- In combat no frame changes: show, hide and redraw wait for PLAYER_REGEN_ENABLED.
    load()
    login()
    Env.combat = true
    Env.slash("/wowchar guide")
    emit("in-combat", { shown(), Env.ns.GuideWindow.Frame() ~= nil, toawowcharDB.guide.shown })
    Env.combat = false
    Env.fire("PLAYER_REGEN_ENABLED")
    emit("after-combat", { shown() })
    local before = frameText()[2]
    Env.combat = true
    game.log[101] = { objectives = {} }
    Env.fire("QUEST_ACCEPTED", 101)
    emit("step-in-combat", { index(), frameText()[2] == before })
    local f = Env.ns.GuideWindow.Frame()
    f.moving = false
    f.scripts.OnDragStart(f)
    emit("drag-in-combat", { f.moving })
    Env.slash("/wowchar guide")
    emit("hide-in-combat", { shown() })
    Env.combat = false
    Env.fire("PLAYER_REGEN_ENABLED")
    emit("hidden-after", { shown() })

elseif scenario == "failsafe" then
    -- The guide and the waypoint are parts (Core.lua, Part): the first error says one chat line
    -- and turns only that part off until /reload.
    local function guideLines()
        local list = {}
        for _, line in ipairs(Env.chat) do
            if line:find("the guide ", 1, true) or line:find("the waypoint ", 1, true) then list[#list + 1] = line end
        end
        return list
    end
    local function button(label)
        for _, f in ipairs(Env.frames) do
            if f.kind == "Button" and f.parent == Env.ns.GuideWindow.Frame() and f.label == label then return f end
        end
    end
    local function fresh()
        Env.relog()
        toawowcharDB = nil
        game.completed, game.log, game.map, game.level = {}, {}, 1429, 1
        game.calls, game.waypoint = {}, nil
        load()
    end
    local calls = 0
    local function counting() calls = calls + 1 end
    -- The guide's event frame (the only one that hears QUEST_ACCEPTED), and whether it still hears anything.
    local function guideFrame()
        for _, f in ipairs(Env.frames) do
            if f.events and f.events.QUEST_ACCEPTED then return f end
        end
    end
    local function deaf(f) return f ~= nil and next(f.events) == nil end

    -- 1. at the start: route data that raises on every read
    load()
    local events1 = guideFrame()
    Env.ns.RouteData = setmetatable({}, { __index = function() error("route data broken on purpose", 0) end })
    login()
    local afterStart = guideLines()
    Env.ns.Guide.Settle = counting
    game.log[101] = { objectives = {} }
    Env.fire("QUEST_ACCEPTED", 101)
    Env.fire("QUEST_LOG_UPDATE")
    Env.fire("PLAYER_LEVEL_UP", 2)
    Env.fire("PLAYER_ENTERING_WORLD", false, true)
    emit("start-error", { afterStart, calls, Env.ns.Guide.part.IsOff(), Env.ns.Waypoint.Mine() == nil, deaf(events1) })
    Env.slash("/wowchar guide")
    emit("command-when-off", { guideLines(), Env.ns.GuideWindow.Frame() == nil })

    -- 2. in an event handler, while shown: the window hides, its waypoint goes, events stop
    fresh()
    login()
    Env.slash("/wowchar guide")
    local before = { shown(), Env.ns.Waypoint.Mine() ~= nil }
    game.calls = {}
    local events2 = guideFrame()
    Env.ns.Guide.Settle = function() error("settle broke", 0) end
    game.log[101] = { objectives = {} }
    Env.fire("QUEST_ACCEPTED", 101)
    local line = guideLines()
    calls = 0
    Env.ns.Guide.Settle = counting
    Env.fire("QUEST_ACCEPTED", 101)
    Env.fire("QUEST_TURNED_IN", 101)
    Env.fire("ZONE_CHANGED_NEW_AREA")
    emit("event-error", { before, line, shown(), game.calls, game.waypoint == nil, calls, #guideLines(), deaf(events2), running() == nil })

    -- 3. a button
    fresh()
    login()
    Env.slash("/wowchar guide")
    Env.ns.Guide.Skip = function() error("skip broke", 0) end
    button("Skip").scripts.OnClick(button("Skip"))
    button("Back").scripts.OnClick(button("Back"))
    emit("button-error", { guideLines(), shown(), Env.ns.Guide.part.IsOff() })

    -- 4. /wowchar guide itself (an error in Toggle); the command and the export go on
    fresh()
    login()
    Env.ns.Guide.Toggle = function() error("toggle broke", 0) end
    local answered = Env.slash("/wowchar guide")
    Env.slash("/wowchar guide")
    emit("command-error", { answered, guideLines() })

    -- 5. the waypoint alone: the guide goes on without the marker
    fresh()
    local superTrack = C_SuperTrack
    C_SuperTrack = setmetatable({}, { __index = function() error("super track broke", 0) end })
    login()
    Env.slash("/wowchar guide")
    local first = { guideLines(), game.calls }
    game.calls = {}
    game.log[101] = { objectives = {} }
    Env.fire("QUEST_ACCEPTED", 101)
    game.log[102] = { objectives = {} }
    Env.fire("QUEST_ACCEPTED", 102)
    emit("waypoint-error", { first, index(), shown(), game.calls, Env.ns.Guide.part.IsOff(), #guideLines() })
    C_SuperTrack = superTrack

    -- 6. the message: one line, no escape codes, cut
    fresh()
    login()
    Env.slash("/wowchar guide")
    Env.ns.Guide.Back = function() error("a |cffff0000red|r line\nwith a newline " .. string.rep("x", 300), 0) end
    button("Back").scripts.OnClick(button("Back"))
    emit("message", guideLines())

    -- 7. a new session (/reload) has the guide again, shown as it was saved
    Env.relog()
    load()
    login()
    emit("after-reload", { Env.ns.Guide.part.IsOff(), shown(), Env.ns.Waypoint.Mine() ~= nil, #guideLines() })

elseif scenario == "part" then
    -- The guard itself (Core.lua, Part): nothing that fails inside it may escape it.
    load()
    local Part = Env.ns.Part
    local function lastLine() return Env.chat[#Env.chat] end
    local function failWith(name, value)
        local p = Part(name, name)
        local ok = pcall(p.Call, function() error(value, 0) end)
        return { ok, p.IsOff(), lastLine() }
    end
    emit("table", failWith("t", {}))
    emit("bad-tostring", failWith("b", setmetatable({}, { __tostring = function() error("no") end })))
    emit("nil", failWith("n", nil))
    emit("empty", failWith("e", "   "))
    -- a two-byte character across byte 200: cut before it
    local p = Part("u", "u")
    p.Call(function() error(string.rep("x", 199) .. "\195\169" .. "tail", 0) end)
    emit("utf8", { lastLine() })
    -- a raising hook does not stop the next; a hook added when off runs at once
    local q = Part("h", "h")
    local ran = {}
    q.OnFail(function() error("hook broke") end)
    q.OnFail(function() ran[#ran + 1] = "second" end)
    q.Call(error, "x")
    q.OnFail(function() ran[#ran + 1] = "late" end)
    emit("hooks", ran)
    -- a chat frame that raises: Call still returns, the hooks still ran
    local chat = DEFAULT_CHAT_FRAME
    DEFAULT_CHAT_FRAME = { AddMessage = function() error("chat broke") end }
    local r = Part("c", "c")
    local cleaned = false
    r.OnFail(function() cleaned = true end)
    local ok = pcall(r.Call, error, "x")
    DEFAULT_CHAT_FRAME = chat
    emit("chat-raises", { ok, cleaned, r.IsOff() })
    -- the window fails half made (CreateColor raises in the middle of it): hidden, and the guide off
    Env.relog()
    toawowcharDB = nil
    load()
    login()
    local createColor = CreateColor
    CreateColor = function() error("no colour", 0) end
    local answered = Env.slash("/wowchar guide")
    CreateColor = createColor
    local f = Env.ns.GuideWindow.Frame()
    emit("half-window", { answered, f ~= nil, f ~= nil and f.shown, Env.ns.Guide.part.IsOff() })

elseif scenario == "panel" then
    -- The panel, step kind by step kind, on the made-up route (Human, Elwynn Forest).
    load()
    login()
    Env.slash("/wowchar guide")
    emit("accept", panel())
    local acceptHeight = panel().height
    -- the distance ticker: every half second at most; it reads the game's distance to our waypoint
    local t = running()
    emit("ticker", { t ~= nil and permille(t.seconds), #tickers })
    game.distance = 130.6
    t.fn()
    emit("tick", { panel().distance })
    game.superTracked = false
    t.fn()
    emit("not-tracked", { panel().distance })
    game.superTracked = true
    game.navState = 0
    t.fn()
    emit("nav-invalid", { panel().distance })
    game.navState = 2
    -- the crest in the class colour, the gold gradient behind the current step
    local w = Env.ns.GuideWindow.Widgets()
    emit("crest", { permille(w.crest.color[1]), permille(w.crest.color[2]), permille(w.crest.color[3]) })
    local gr = w.glow.gradient
    emit("gradient", { gr[1], permille(gr[2].r), permille(gr[2].g), permille(gr[2].b), permille(gr[2].a), permille(gr[3].a) })
    -- QUEST_LOG_UPDATE with nothing new on an accept step: no redraw (the first one after
    -- login finds the place again and draws; the next ones do not)
    Env.fire("QUEST_LOG_UPDATE")
    local writes = 0
    Env.spy = function() writes = writes + 1 end
    Env.fire("QUEST_LOG_UPDATE")
    Env.spy = nil
    emit("quiet-update", { writes })
    -- the next steps: one line each, cut with an ellipsis
    Env.ns.RouteData.quests[102] = string.rep("A very long quest name ", 4)
    Env.fire("QUEST_LOG_UPDATE")
    Env.ns.GuideWindow.Update()
    emit("cut", panel().following)
    Env.ns.RouteData.quests[102] = "Wolves | Boars"
    -- objective: the quest log's lines, updated on QUEST_LOG_UPDATE
    game.log[101] = { objectives = { { "Kobold Vermin slain: 4/10", false } } }
    Env.fire("QUEST_ACCEPTED", 101)
    game.log[102] = { objectives = { { "Tough Wolf Meat: 8/8", true }, { "Boar Hide: 2/6", false } } }
    Env.fire("QUEST_ACCEPTED", 102)
    emit("objective", panel())
    game.log[101].objectives[1][1] = "Kobold Vermin slain: 7/10"
    Env.fire("QUEST_LOG_UPDATE")
    emit("objective-updated", panel().objectives)
    -- the same lines again: no redraw
    local again = 0
    Env.spy = function() again = again + 1 end
    Env.fire("QUEST_LOG_UPDATE")
    Env.fire("UNIT_QUEST_LOG_CHANGED", "player")
    Env.spy = nil
    emit("same-objectives", { again })
    game.log[101] = { complete = true, objectives = { { "Kobold Vermin slain: 10/10", true } } }
    Env.fire("QUEST_LOG_UPDATE")
    local two = panel()
    emit("objective-two", { two.objectives, two.height - acceptHeight })
    -- turn-in
    game.log[102] = { complete = true, objectives = { { "Tough Wolf Meat: 8/8", true }, { "Boar Hide: 6/6", true } } }
    Env.fire("QUEST_LOG_UPDATE")
    emit("turnin", panel())
    -- travel: no coordinates, no distance, no ticker
    game.completed[101], game.completed[102], game.log = true, true, {}
    Env.fire("QUEST_TURNED_IN", 101)
    Env.fire("QUEST_TURNED_IN", 102)
    emit("travel", { panel(), running() == nil })
    -- grind: the route's XP and a bar from the step's level (4) to the next step's (5)
    game.map, game.level, game.subzone, game.zone = 1436, 4, "", "Westfall"
    Env.fire("ZONE_CHANGED_NEW_AREA")
    emit("grind", panel())
    game.xp = 900
    Env.fire("PLAYER_XP_UPDATE", "player")
    emit("grind-xp", { panel().xp })
    -- hidden: the ticker stops; shown on an accept step it runs again
    game.level = 5
    local before = #tickers
    Env.fire("PLAYER_LEVEL_UP", 5)
    emit("accept-again", { running() ~= nil, #tickers > before })
    Env.slash("/wowchar guide")
    emit("hidden", { running() == nil })

elseif scenario == "panel-combat" then
    -- In combat the layout stays; the coordinate line says it waits; it all catches up after.
    load()
    login()
    Env.slash("/wowchar guide")
    local before = panel()
    local w = Env.ns.GuideWindow.Widgets()
    local names = { [w.coords] = "coords", [w.distance] = "distance" }
    local writes = {}
    Env.spy = function(region, method) writes[#writes + 1] = (names[region] or "other") .. ":" .. method end
    Env.combat = true
    Env.fire("PLAYER_REGEN_DISABLED")
    local during = panel()
    emit("in-combat", { during.coords, during.distance, during.height == before.height, during.quest == before.quest, running() == nil })
    game.log[101] = { objectives = {} }
    Env.fire("QUEST_ACCEPTED", 101)
    emit("step-in-combat", { index(), panel().quest == before.quest, panel().coords })
    Env.ns.GuideWindow.Update()
    Env.fire("ZONE_CHANGED")
    Env.fire("QUEST_LOG_UPDATE")
    Env.spy = nil
    emit("combat-writes", writes)
    Env.combat = false
    Env.fire("PLAYER_REGEN_ENABLED")
    local after = panel()
    emit("after-combat", { after.quest, after.coords, after.distance, running() ~= nil })

elseif scenario == "migration" then
    -- dbVersion 1 (0.4.x: realms at the top) becomes 2; the cache survives; a newer file is left alone.
    toawowcharDB = { Forever = { Thor = { v = 1, quests = { at = 1790000000, ids = { 3, 9 } } } }, ["Argent Dawn"] = { Thorin = { v = 1 } } }
    load()
    emit("migrated", { toawowcharDB.dbVersion, toawowcharDB.Forever == nil, toawowcharDB.realms.Forever.Thor.quests.ids, toawowcharDB.realms["Argent Dawn"] ~= nil })
    Env.relog()
    toawowcharDB = { dbVersion = 9, whatever = { 1 } }
    load()
    login()
    Env.slash("/wowchar guide")
    emit("newer", { toawowcharDB.dbVersion, toawowcharDB.whatever, toawowcharDB.realms == nil, toawowcharDB.guide == nil })
end
