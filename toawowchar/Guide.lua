-- The leveling guide: picks this character's route (Data/Routes.lua, from wowchar), finds where
-- the character is on it and moves on as the game says a step is done. The window is
-- UI/GuideWindow.lua and the game's waypoint Waypoint.lua; this file holds the rules.
--
-- Start: the route of the player's race (UnitRace's second return, the race file token). The
-- Forever tokens of the two Skyborne races are not confirmed (the client's own code only shows
-- a "Skyborne" model key), so any token with "Skyborne" in it takes the route of the player's
-- faction. The Skyborne routes are marked unconfirmed in the data; the window says so.
--
-- Position, at login and /reload: the first quest step (accept, objective, turn-in) whose quests
-- are not all done, the steps the player skipped counting as done. If travel or grind steps come
-- right before it, the first of them that is not done yet comes first (the player may still have
-- to get there or level up). The position is found again on the first quest log update after
-- login too: the game may not know every quest yet when the world is entered.
--
-- A step is done:
--   accept     every quest of it is in the quest log or completed (QUEST_ACCEPTED)
--   objective  every quest of it is completed, ready to turn in, or has the objectives the step
--              is about finished (the step's note names them; without a match, all of them)
--              (QUEST_LOG_UPDATE, UNIT_QUEST_LOG_CHANGED)
--   turn-in    every quest of it is completed (QUEST_TURNED_IN)
--   travel     the player is on the step's map or a map inside it (ZONE_CHANGED_NEW_AREA,
--              ZONE_CHANGED, ZONE_CHANGED_INDOORS)
--   grind      the player's level has reached the next step's level (PLAYER_LEVEL_UP)
-- After an event the guide moves past every step that is done, in order. «Skip» marks the step
-- skipped and moves on; «Back» goes one step back and holds there (no event moves it on) until
-- «Skip» is pressed. Skipped steps and the current step are saved per character.
--
-- API (Gethe/wow-ui-source, branch forever, ca8368f, build 1.60.1.70532; Blizzard_APIDocumentationGenerated):
--   C_QuestLog.IsQuestFlaggedCompleted(questID) -> bool        QuestLogDocumentation.lua:916
--   C_QuestLog.GetLogIndexForQuestID(questID) -> index or nil  QuestLogDocumentation.lua:206
--   C_QuestLog.IsOnQuest(questID) -> bool                      QuestLogDocumentation.lua:825
--   C_QuestLog.IsComplete(questID) -> bool                     QuestLogDocumentation.lua:734
--   C_QuestLog.GetQuestObjectives(questID) -> {text, finished, ...}  :477, struct :1581
--   C_Map.GetBestMapForUnit("player") -> uiMapID or nil        MapDocumentation.lua:49
--   C_Map.GetMapInfo(uiMapID) -> { parentMapID, ... }          MapDocumentation.lua:312, struct :696
--   UnitRace("player") -> name, raceFile, raceID               UnitDocumentation.lua:2925
--   UnitFactionGroup("player"), UnitLevel("player")            UnitDocumentation.lua:1207, :2474
--   Events: QUEST_ACCEPTED (questId) QuestLogDocumentation.lua:1310; QUEST_TURNED_IN (questID,
--   xpReward, moneyReward) :1394; QUEST_LOG_UPDATE :1371; QUEST_REMOVED :1383;
--   UNIT_QUEST_LOG_CHANGED (unitTarget) UnitDocumentation.lua:4563; PLAYER_LEVEL_UP (level, ...)
--   :3830; ZONE_CHANGED_NEW_AREA, ZONE_CHANGED, ZONE_CHANGED_INDOORS MapDocumentation.lua:663,
--   :651, :657; PLAYER_ENTERING_WORLD SystemDocumentation.lua:134; PLAYER_REGEN_ENABLED
--   UnitDocumentation.lua:3891.
local _, ns = ...

local L = ns.L
local Int = ns.Int
local RealmName = ns.RealmName
local DB = ns.DB

local Guide = {}
ns.Guide = Guide

-- The kinds of a step, as Data/Routes.lua stores them (scripts/fetch-routes.py, KINDS).
local ACCEPT, OBJECTIVE, TURNIN, TRAVEL, GRIND = 1, 2, 3, 4, 5
Guide.KINDS = { accept = ACCEPT, objective = OBJECTIVE, turnin = TURNIN, travel = TRAVEL, grind = GRIND }

-- The race file token -> the start key. The Skyborne races: see StartFor.
local RACE_STARTS = {
    Human = "human",
    Dwarf = "dwarf-gnome",
    Gnome = "dwarf-gnome",
    NightElf = "nightelf",
    Orc = "orc-troll",
    Troll = "orc-troll",
    Scourge = "undead",
    Tauren = "tauren",
}

-- The window's name for each start.
local START_LABELS = {
    ["human"] = L["START_HUMAN"],
    ["dwarf-gnome"] = L["START_DWARF_GNOME"],
    ["nightelf"] = L["START_NIGHTELF"],
    ["skyborne-a"] = L["START_SKYBORNE_A"],
    ["orc-troll"] = L["START_ORC_TROLL"],
    ["undead"] = L["START_UNDEAD"],
    ["tauren"] = L["START_TAUREN"],
    ["skyborne-h"] = L["START_SKYBORNE_H"],
}

-- How many steps the window shows: the current one and the next two.
Guide.SHOWN = 3
-- At most this many skipped steps are kept per character (a damaged file cannot grow it).
local MAX_SKIPPED = 2000
-- How far up the map tree a travel step looks (a cave or a town has its own map inside the zone).
local MAP_DEPTH = 6

-- This play session. Nothing here is saved except through Save().
local state = {
    started = false,
    key = nil,         -- the route's start key, or nil when the race has none
    route = nil,       -- the route of Data/Routes.lua
    index = 1,         -- the current step; #steps + 1 when the route is finished
    held = false,      -- «Back» was pressed: events do not move the guide on
    skipped = {},      -- [step] = true
    turnedIn = {},     -- [questID] = true: turned in this session (the game's flag may come later)
    level = nil,       -- the level PLAYER_LEVEL_UP said (UnitLevel may still answer the old one)
    positioned = false, -- the position was found again on the first quest log update
}
Guide.state = state

---------------------------------------------------------------------------
-- The start
---------------------------------------------------------------------------

-- The start key of a race file token and a faction ("Alliance" or "Horde"), or nil.
function Guide.StartFor(raceFile, faction)
    if type(raceFile) ~= "string" then
        return nil
    end
    local key = RACE_STARTS[raceFile]
    if key then
        return key
    end
    if raceFile:find("Skyborne", 1, true) then
        if faction == "Alliance" then
            return "skyborne-a"
        elseif faction == "Horde" then
            return "skyborne-h"
        end
    end
    return nil
end

local function PlayerString(fn, index)
    if not fn then
        return nil
    end
    local results = { pcall(fn, "player") }
    local value = results[index + 1]
    if results[1] and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

---------------------------------------------------------------------------
-- What the game says
---------------------------------------------------------------------------

local function Completed(id)
    if state.turnedIn[id] then
        return true
    end
    local Q = C_QuestLog
    if Q and Q.IsQuestFlaggedCompleted then
        local ok, done = pcall(Q.IsQuestFlaggedCompleted, id)
        if ok and done == true then
            return true
        end
    end
    return false
end

local function InLog(id)
    local Q = C_QuestLog
    if not Q then
        return false
    end
    if Q.GetLogIndexForQuestID then
        local ok, index = pcall(Q.GetLogIndexForQuestID, id)
        if ok and Int(index) then
            return true
        end
    end
    if Q.IsOnQuest then
        local ok, on = pcall(Q.IsOnQuest, id)
        if ok and on == true then
            return true
        end
    end
    return false
end

-- The parts of a step's note ("A; B; C"), lower case, for matching objective texts.
local function NoteParts(text)
    local parts = {}
    if type(text) == "string" then
        for part in text:gmatch("[^;]+") do
            part = part:match("^%s*(.-)%s*$"):lower()
            if part ~= "" then
                parts[#parts + 1] = part
            end
        end
    end
    return parts
end

-- True when the quest is ready to turn in, or the objectives the step is about are finished.
local function ObjectivesDone(id, parts)
    local Q = C_QuestLog
    if not Q then
        return false
    end
    if Q.IsComplete then
        local ok, complete = pcall(Q.IsComplete, id)
        if ok and complete == true then
            return true
        end
    end
    if not Q.GetQuestObjectives then
        return false
    end
    local ok, list = pcall(Q.GetQuestObjectives, id)
    if not ok or type(list) ~= "table" or #list == 0 then
        return false
    end
    local matched, matchedDone, all = 0, 0, true
    for _, objective in ipairs(list) do
        if type(objective) == "table" then
            local finished = objective.finished == true
            if not finished then
                all = false
            end
            local text = type(objective.text) == "string" and objective.text:lower() or ""
            for _, part in ipairs(parts) do
                if text:find(part, 1, true) then
                    matched = matched + 1
                    if finished then
                        matchedDone = matchedDone + 1
                    end
                    break
                end
            end
        end
    end
    if matched > 0 then
        return matchedDone == matched
    end
    return all
end

local function Level()
    local level
    if UnitLevel then
        local ok, value = pcall(UnitLevel, "player")
        level = ok and Int(value) or nil
    end
    if state.level and (not level or state.level > level) then
        level = state.level
    end
    return level or 0
end

-- True when the player is on uiMapId or a map inside it.
local function OnMap(uiMapId)
    if not (C_Map and C_Map.GetBestMapForUnit) then
        return false
    end
    local ok, map = pcall(C_Map.GetBestMapForUnit, "player")
    map = ok and Int(map) or nil
    for _ = 1, MAP_DEPTH do
        if not map or map <= 0 then
            return false
        end
        if map == uiMapId then
            return true
        end
        if not C_Map.GetMapInfo then
            return false
        end
        local okInfo, info = pcall(C_Map.GetMapInfo, map)
        map = okInfo and type(info) == "table" and Int(info.parentMapID) or nil
    end
    return false
end

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------

local function Steps()
    return state.route and state.route.steps or {}
end

local function QuestStepDone(step)
    local quests = step[5]
    if step[1] == OBJECTIVE then
        local parts = NoteParts(step[8] ~= 0 and ns.RouteData.texts[step[8]] or nil)
        for _, id in ipairs(quests) do
            if not (Completed(id) or (InLog(id) and ObjectivesDone(id, parts))) then
                return false
            end
        end
        return true
    end
    for _, id in ipairs(quests) do
        if step[1] == ACCEPT then
            if not (Completed(id) or InLog(id)) then
                return false
            end
        elseif not Completed(id) then
            return false
        end
    end
    return true
end

-- True when step i is done now (or was skipped).
local function StepDone(i)
    if state.skipped[i] then
        return true
    end
    local steps = Steps()
    local step = steps[i]
    if not step then
        return true
    end
    local kind = step[1]
    if kind == TRAVEL then
        return OnMap(step[2])
    elseif kind == GRIND then
        local next = steps[i + 1]
        local target = next and next[7] or state.route.levelEnd
        return Level() >= target
    end
    local ok, done = pcall(QuestStepDone, step)
    return ok and done == true
end
Guide.StepDone = StepDone

-- Where the character is on the route (the rule at the top of this file).
function Guide.Position()
    local steps = Steps()
    local first = #steps + 1
    for i, step in ipairs(steps) do
        if step[1] <= TURNIN and not state.skipped[i] then
            local ok, done = pcall(QuestStepDone, step)
            if not (ok and done == true) then
                first = i
                break
            end
        end
    end
    local from = first
    while from > 1 and steps[from - 1][1] >= TRAVEL do
        from = from - 1
    end
    for i = from, first - 1 do
        if not StepDone(i) then
            return i
        end
    end
    return first
end

---------------------------------------------------------------------------
-- Saved per character: toawowcharDB.guide.characters[realm][name]
---------------------------------------------------------------------------

local function CharacterSlot(create)
    local name = UnitName and PlayerString(UnitName, 1)
    if not name then
        return nil
    end
    local guide = DB().guide
    if type(guide.characters) ~= "table" then
        if not create then
            return nil
        end
        guide.characters = {}
    end
    local realm = RealmName() or "?"
    if type(guide.characters[realm]) ~= "table" then
        if not create then
            return nil
        end
        guide.characters[realm] = {}
    end
    local realms = guide.characters[realm]
    if type(realms[name]) ~= "table" then
        if not create then
            return nil
        end
        realms[name] = {}
    end
    return realms[name]
end

-- The skipped steps saved for this route, cleaned: only when the saved route is this one
-- (the same start and the same generated time; a new route has other step numbers).
local function LoadSaved()
    state.skipped = {}
    local slot = CharacterSlot(false)
    local route = state.route
    if not (slot and route and slot.route == state.key and slot.generated == route.generated) then
        return
    end
    if type(slot.skipped) == "table" then
        local count = 0
        for n, value in pairs(slot.skipped) do
            local i = Int(n)
            if value == true and i and i >= 1 and i <= #route.steps and count < MAX_SKIPPED then
                state.skipped[i] = true
                count = count + 1
            end
        end
    end
end

local function Save()
    if not state.route then
        return
    end
    local slot = CharacterSlot(true)
    if not slot then
        return
    end
    slot.route = state.key
    slot.generated = state.route.generated
    slot.step = state.index
    local skipped = {}
    for i in pairs(state.skipped) do
        skipped[i] = true
    end
    slot.skipped = skipped
end

---------------------------------------------------------------------------
-- Moving
---------------------------------------------------------------------------

local function Changed()
    Save()
    if ns.GuideWindow then
        ns.GuideWindow.Update()
    end
end

-- Moves past every step that is done, in order. Not while «Back» holds the guide.
function Guide.Settle()
    if not state.route or state.held then
        return
    end
    local steps = Steps()
    local start = state.index
    while state.index <= #steps and StepDone(state.index) do
        state.index = state.index + 1
    end
    if state.index ~= start then
        Changed()
    end
end

function Guide.Skip()
    if not state.route then
        return
    end
    local steps = Steps()
    state.held = false
    if state.index <= #steps then
        state.skipped[state.index] = true
        state.index = state.index + 1
    end
    Guide.Settle()
    Changed()
end

function Guide.Back()
    if not state.route or state.index <= 1 then
        return
    end
    state.index = state.index - 1
    state.skipped[state.index] = nil
    state.held = true
    Changed()
end

-- Picks the route and finds the position (login and /reload).
function Guide.Start()
    state.started = true
    state.held = false
    state.key = Guide.StartFor(PlayerString(UnitRace, 2), PlayerString(UnitFactionGroup, 1))
    local data = ns.RouteData
    state.route = state.key and data and data.routes and data.routes[state.key] or nil
    if data and data.routes then
        -- Only this character's route is needed: the others are let go (about 2.5 MB of memory).
        data.routes = { [state.key or ""] = state.route }
    end
    if not state.route then
        Changed()
        return
    end
    LoadSaved()
    state.index = Guide.Position()
    Changed()
end

-- The first quest log update after login: the game knows the quests now.
local function Reposition()
    if state.route and not state.positioned and not state.held then
        state.positioned = true
        state.index = Guide.Position()
        Changed()
    end
end

---------------------------------------------------------------------------
-- What the window shows
---------------------------------------------------------------------------

local function Escape(text)
    return (text:gsub("|", "||"))
end

-- At most `max` bytes of a text, cut on a character boundary, with "..." when cut.
local function Short(text, max)
    if #text <= max then
        return text
    end
    local n = max - 3
    while n > 0 do
        local b = text:byte(n + 1)
        if b and b >= 0x80 and b < 0xC0 then
            n = n - 1
        else
            break
        end
    end
    return text:sub(1, n) .. "..."
end
Guide.Short = Short

local function QuestName(id)
    local data = ns.RouteData
    return data and data.quests[id] or string.format(L["QUEST_N"], id)
end

-- "A", "A and B", "A, B and C".
local function List(names)
    if #names <= 1 then
        return names[1] or ""
    end
    return string.format(L["LIST_AND"], table.concat(names, ", ", 1, #names - 1), names[#names])
end

local MAX_LINE = 160

-- The words of a step: what to do, and the /way line under it.
function Guide.StepText(step)
    local data = ns.RouteData
    local names = {}
    for i, id in ipairs(step[5]) do
        names[i] = QuestName(id)
    end
    local quests = List(names)
    local who = step[6] ~= 0 and data.texts[step[6]] or nil
    local note = step[8] ~= 0 and data.texts[step[8]] or nil
    local kind = step[1]
    local text
    if kind == ACCEPT then
        text = who and string.format(L["STEP_ACCEPT_FROM"], quests, who) or string.format(L["STEP_ACCEPT"], quests)
    elseif kind == TURNIN then
        text = who and string.format(L["STEP_TURNIN_TO"], quests, who) or string.format(L["STEP_TURNIN"], quests)
    elseif kind == OBJECTIVE then
        text = note and string.format(L["STEP_OBJECTIVE_FOR"], note, quests) or string.format(L["STEP_OBJECTIVE"], quests)
    elseif kind == TRAVEL then
        text = note or L["STEP_TRAVEL"]
    else
        text = note or L["STEP_GRIND"]
    end
    local zone = data.zones[step[2]] or string.format(L["MAP_N"], step[2])
    local way = string.format(L["WAY"], zone, step[3], step[4])
    return Escape(Short(text, MAX_LINE)), Escape(way)
end

-- Everything the window needs, or a message when there is no route.
function Guide.View()
    if not state.route then
        return { message = L["NO_ROUTE"] }
    end
    local steps = Steps()
    local view = {
        start = START_LABELS[state.key] or state.key,
        unconfirmed = state.route.confirmed == false,
        index = state.index,
        total = #steps,
        held = state.held,
        rows = {},
    }
    if state.index > #steps then
        view.message = string.format(L["ROUTE_DONE"], state.route.levelEnd)
        return view
    end
    for i = state.index, math.min(state.index + Guide.SHOWN - 1, #steps) do
        local text, way = Guide.StepText(steps[i])
        view.rows[#view.rows + 1] = { n = i, kind = steps[i][1], level = steps[i][7], text = text, way = way }
    end
    return view
end

-- The current step (for the waypoint), or nil.
function Guide.Current()
    local steps = Steps()
    return state.route and steps[state.index] or nil
end

---------------------------------------------------------------------------
-- Events: one frame, a table of handlers (docs/wow-addon-rules.md 5)
---------------------------------------------------------------------------

local handlers = {}

function handlers.PLAYER_ENTERING_WORLD()
    if not state.started then
        Guide.Start()
        if ns.GuideWindow then
            ns.GuideWindow.Restore()
        end
    else
        Guide.Settle() -- a zone change through a loading screen
    end
end

function handlers.QUEST_ACCEPTED()
    Guide.Settle()
end

function handlers.QUEST_TURNED_IN(questId)
    local id = Int(questId)
    if id and id > 0 then
        state.turnedIn[id] = true
    end
    Guide.Settle()
end

function handlers.QUEST_LOG_UPDATE()
    if not state.route then
        return
    end
    if not state.positioned then
        Reposition()
    end
    local step = Guide.Current()
    -- Frequent: only the steps the quest log can finish are looked at.
    if step and (step[1] == OBJECTIVE or step[1] == ACCEPT) then
        Guide.Settle()
    end
end

function handlers.UNIT_QUEST_LOG_CHANGED(unit)
    if unit == "player" then
        handlers.QUEST_LOG_UPDATE()
    end
end

function handlers.QUEST_REMOVED()
    Guide.Settle()
end

local function ZoneChanged()
    local step = Guide.Current()
    if step and step[1] == TRAVEL then
        Guide.Settle()
    end
end
handlers.ZONE_CHANGED_NEW_AREA = ZoneChanged
handlers.ZONE_CHANGED = ZoneChanged
handlers.ZONE_CHANGED_INDOORS = ZoneChanged

function handlers.PLAYER_LEVEL_UP(level)
    local n = Int(level)
    if n and n > 0 and n <= 255 then
        state.level = n
    end
    Guide.Settle()
end

function handlers.PLAYER_REGEN_ENABLED()
    if ns.GuideWindow then
        ns.GuideWindow.CombatEnded()
    end
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(_, event, ...)
    local handler = handlers[event]
    if handler then
        handler(...)
    end
end)
-- An event name the client does not know raises an error, so each is tried alone.
for event in pairs(handlers) do
    pcall(frame.RegisterEvent, frame, event)
end

-- /wowchar guide
function Guide.Toggle()
    if not state.started then
        Guide.Start()
    end
    if ns.GuideWindow then
        ns.GuideWindow.Toggle()
    end
end
