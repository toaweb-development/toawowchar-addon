-- Exercises the shipped TOC modules under Lua 5.1. Assertions use independent cardinal
-- screen directions, never a copy of Navigation.Geometry's formula.
local scenario = arg[1]
local Env = dofile("test/lua/wow-env.lua")
local secret = setmetatable({}, { __index = function() error("indexed a secret") end })
local secretTable = setmetatable({}, { __index = function() error("indexed a secret table") end })
issecretvalue = function(v) return rawequal(v, secret) end
issecrettable = function(v) return rawequal(v, secretTable) end
local state = { map = 1, world = 1, facing = 0, inside = false, kind = "none", player = { x = .5, y = .5 }, reads = 0, conversions = 0 }
CreateVector2D = function(x, y) return { x = x, y = y } end
GetPlayerFacing = function() return state.facing end
IsInInstance = function() return state.inside, state.kind end
C_Map = {
    GetBestMapForUnit = function() return state.map end,
    GetPlayerMapPosition = function() state.reads = state.reads + 1; return state.player end,
    GetWorldPosFromMapPos = function(map, v)
        state.conversions = state.conversions + 1
        if state.throw then error("position denied") end
        if state.worldVector then return state.world, state.worldVector end
        return map == 2 and 2 or state.world, { x = v.x * 1000, y = v.y * 1000 }
    end,
    HasUserWaypoint = function() return state.has ~= nil and state.has or state.waypoint ~= nil end,
    GetUserWaypoint = function() return state.waypoint end,
    CanSetUserWaypointOnMap = function() return true end,
    SetUserWaypoint = function(point) state.sets = (state.sets or 0) + 1; state.waypoint = point; return true end,
    ClearUserWaypoint = function() state.clears = (state.clears or 0) + 1; state.waypoint = nil end,
}
UiMapPoint = { CreateFromCoordinates = function(map, x, y) return { uiMapID = map, position = { x = x, y = y } } end }
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
Env.load()
local ns = Env.ns
local nav = ns.Navigation
local host = CreateFrame("Frame")
local arrow, text = host:CreateTexture(), host:CreateFontString()
host:Show()
nav.Attach(host, arrow, text)
local function sampler()
    for _, f in ipairs(Env.frames) do if f.parent == host then return f end end
    error("no sampler")
end
local function tick(elapsed)
    local f = sampler()
    if f.shown and f.scripts.OnUpdate then f.scripts.OnUpdate(f, elapsed or .05) end
end
local function start(map, x, y)
    nav.SetTarget(map or 1, x or 60, y or 50)
    nav.Refresh()
    tick()
end
local function unavailable()
    tick()
    assert(not arrow.shown and text.text == ns.L.NAV_UNAVAILABLE, "stale or missing unavailable output")
    assert(not nav.part.IsOff(), "expected unavailable data must not kill the part")
end
local function near(a, b) assert(math.abs(a - b) < 1e-8, tostring(a) .. " differs from " .. tostring(b)) end

if scenario == "geometry" then
    -- Targets N,W,S,E; facing N,W,S,E. Independent expected on-screen directions:
    -- up=0, left=+pi/2, down=pi, right=-pi/2. Compare sin/cos for equivalent wraparound.
    local targets = { { 100, 0 }, { 0, 100 }, { -100, 0 }, { 0, -100 } }
    local expected = { {0,1,2,-1}, {-1,0,1,2}, {2,-1,0,1}, {1,2,-1,0} }
    for face = 1, 4 do
        for target = 1, 4 do
            local a, d = nav.Geometry(targets[target][1], targets[target][2], (face - 1) * math.pi / 2)
            local e = expected[face][target] * math.pi / 2
            near(math.sin(a), math.sin(e)); near(math.cos(a), math.cos(e)); near(d, 100)
        end
    end
    local a = nav.Geometry(100, 0, 2 * math.pi - .01); near(a, .01)
    local rotation, yards = nav.Geometry(0, 0, 1); assert(rotation == nil and yards == 0)
    for _, bad in ipairs({ secret, -1, math.huge, 0/0, 7 }) do assert(nav.Geometry(1, 1, bad) == nil) end
    assert(nav.Geometry(math.huge, 0, 0) == nil)
    assert(nav.Geometry(100001, 0, 0) == nil)
    assert(nav.Geometry(0/0, 0, 0) == nil)
    assert(nav.Geometry(secret, 0, 0) == nil)
    start(); assert(arrow.atlas == "Navigation-Tracked-Arrow"); near(arrow.rotation, 0)
    state.player = { x = .6, y = .5 }; tick()
    assert(not arrow.shown and text.text == ns.L.NAV_ARRIVED)
elseif scenario == "invalid" then
    start(); assert(arrow.shown and text.text == "100 yd")
    for _, bad in ipairs({ secret, secretTable, {}, { x = secret, y = .5 }, { x = -1, y = .5 }, { x = math.huge, y = .5 }, { x = 0/0, y = .5 } }) do
        state.player = bad; unavailable()
    end
    state.player = nil; unavailable()
    state.player = { x = .5, y = .5 }
    for _, key in ipairs({ "map", "world", "facing", "inside", "kind" }) do
        local old = state[key]; state[key] = secret; unavailable(); state[key] = old
    end
    for _, bad in ipairs({ secret, secretTable, { x = secret, y = 0 }, { x = math.huge, y = 0 }, { x = 0/0, y = 0 } }) do
        state.worldVector = bad; unavailable()
    end
    state.worldVector = nil; state.throw = true; unavailable(); state.throw = false
    local api = C_Map.GetPlayerMapPosition; C_Map.GetPlayerMapPosition = nil; unavailable(); C_Map.GetPlayerMapPosition = api
    tick(); assert(arrow.shown and text.text == "100 yd")
    nav.SetTarget(secret, 60, 50); assert(not sampler().scripts.OnUpdate and not arrow.shown and text.text == "")
    start(1, -1, 50); assert(not sampler().scripts.OnUpdate)
    nav.SetTarget(1, 0/0, 50); assert(not sampler().scripts.OnUpdate)
elseif scenario == "transitions" then
    start(); local conversions = state.conversions
    tick(); assert(state.conversions == conversions + 1, "target should be cached")
    state.map = 3; tick(); assert(state.conversions == conversions + 3, "same target map transition must invalidate")
    state.world = 4; tick(); assert(arrow.shown and state.conversions == conversions + 5)
    for _, kind in ipairs({ "party", "raid", "pvp", "arena" }) do
        state.inside, state.kind = true, kind; unavailable()
    end
    state.inside, state.kind = false, "none"; tick(); assert(arrow.shown)
    start(2); assert(not arrow.shown and text.text == ns.L.NAV_UNAVAILABLE)
    start(1); assert(arrow.shown)
    Env.combat = true; Env.fire("PLAYER_REGEN_DISABLED")
    assert(not sampler().scripts.OnUpdate and not arrow.shown)
    Env.combat = false; Env.fire("PLAYER_REGEN_ENABLED"); tick(); assert(arrow.shown)
    Env.fire("PLAYER_ENTERING_WORLD"); tick(); assert(arrow.shown)
elseif scenario == "throttle" then
    nav.SetTarget(1, 60, 50); nav.Refresh()
    for _ = 1, 4 do tick(.01) end; assert(state.reads == 0)
    tick(.01); assert(state.reads == 1)
    tick(1); assert(state.reads == 2, "catch-up burst")
    tick(.01); assert(state.reads == 2, "retained backlog")
    host:Hide(); local reads = state.reads; tick(); assert(state.reads == reads and text.text == "")
    host:Show(); nav.Refresh(); tick(); assert(arrow.shown)
    ns.DB().settings.navigationEnabled = false; nav.Refresh(); tick()
    assert(not sampler().scripts.OnUpdate and text.text == "" and not arrow.shown)
    ns.DB().settings.navigationEnabled = true; nav.Refresh(); tick(); assert(arrow.shown)
    nav.part.Fail("test failure"); assert(not sampler().scripts.OnUpdate and not arrow.shown)
elseif scenario == "waypoint" then
    local foreign = { uiMapID = 1, position = { x = .2, y = .3 } }
    state.waypoint = foreign; start(); assert(text.text == "100 yd")
    assert(not ns.Waypoint.Set(1,60,50) and state.waypoint == foreign)
    state.waypoint = nil; assert(ns.Waypoint.Set(1,60,50)); assert(ns.Waypoint.Mine())
    state.waypoint = foreign; assert(ns.Waypoint.Mine() == nil)
    ns.Waypoint.Clear(); assert(state.waypoint == foreign and not state.clears)
    nav.Stop(); nav.Refresh(); tick(); assert(state.waypoint == foreign and text.text == "100 yd")
    state.waypoint = nil; tick(); assert(state.sets == 1, "automatically reacquired")
    assert(ns.Waypoint.Set(1,60,50)); state.waypoint = nil; assert(ns.Waypoint.Mine() == nil)
    state.waypoint = { uiMapID = 1, position = { x = .6, y = .5 } }; ns.Waypoint.Clear()
    assert(state.waypoint, "revoked claim reacquired identical tuple")
    for _, bad in ipairs({ secret, secretTable, { position = secretTable }, { uiMapID = secret, position = { x=.6,y=.5 } } }) do
        state.waypoint = nil; assert(ns.Waypoint.Set(1,60,50)); state.waypoint = bad
        assert(ns.Waypoint.Mine() == nil); ns.Waypoint.Clear(); assert(state.waypoint == bad)
    end
    state.has = secret; assert(not ns.Waypoint.Set(1,60,50))
elseif scenario == "settings" then
    toawowcharDB = { dbVersion = 3, guide = { shown = true }, realms = {}, settings = { navigationScale = math.huge, navigationEnabled = "bad" } }
    local db = ns.DB(); assert(db.settings.navigationScale == 1 and db.settings.navigationEnabled == true)
    assert(db.guide.shown and db.dbVersion == 3)
    for _, sample in ipairs({ { -5,.75 }, { 8,1.5 }, { .9,.9 }, { 0/0,1 }, { secret,1 } }) do
        db.settings.navigationScale = sample[1]; assert(ns.DB().settings.navigationScale == sample[2])
    end
    db.settings.navigationScale = 1.2; nav.ApplyScale(); near(host.scale, 1.2)
    Env.combat = true; db.settings.navigationScale = .8; nav.ApplyScale(); near(host.scale, 1.2)
    Env.combat = false; Env.fire("PLAYER_REGEN_ENABLED"); near(host.scale, .8)
    db.settings.navigationEnabled = false
    Env.relog(); Env.load(); local reloaded = Env.ns.DB()
    near(reloaded.settings.navigationScale, .8); assert(not reloaded.settings.navigationEnabled)
    assert(reloaded.settings.guideAtLogin == false and reloaded.guide.shown)
elseif scenario == "isolation" then
    start(); local before = ns.Serialize({ 1, 2, 3 })
    arrow.SetRotation = function() error("texture failed") end
    tick(); assert(nav.part.IsOff() and not sampler().scripts.OnUpdate and not arrow.shown)
    assert(not ns.Part("guide").IsOff() and not ns.Part("collect").IsOff())
    assert(ns.Serialize({ 1, 2, 3 }) == before)
    assert(Env.slash("/wowchar"), "export command failed after navigation failure")
else error("unknown navigation scenario") end
print("ok " .. scenario)
