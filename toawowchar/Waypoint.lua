-- The game's own waypoint for the guide: a user waypoint on the step's map, super-tracked so
-- the game draws its navigation marker and the arrow at the screen edge. No arrow of our own.
--
-- API (Gethe/wow-ui-source, branch forever, ca8368f, build 1.60.1.70532; Blizzard_APIDocumentationGenerated):
--   C_Map.CanSetUserWaypointOnMap(uiMapID) -> canSet        MapDocumentation.lua:11
--   C_Map.SetUserWaypoint(point) -> wasSet                   MapDocumentation.lua:599
--   C_Map.ClearUserWaypoint()                                MapDocumentation.lua:26
--   C_Map.HasUserWaypoint() -> hasUserWaypoint               MapDocumentation.lua:524
--   C_Map.GetUserWaypoint() -> point (may return nothing)    MapDocumentation.lua:454
--   C_SuperTrack.SetSuperTrackedUserWaypoint(superTracked)   SuperTrackManagerDocumentation.lua:169
--   UiMapPoint.CreateFromCoordinates(mapID, x, y, z)         Blizzard_ObjectAPI/Mainline/UiMapPoint.lua:3
--     -> { uiMapID, position = CreateVector2D(x, y), z }; x and y are 0 to 1.
-- Blizzard's own map pin does the same in this order (Blizzard_SharedMapDataProviders/
-- WaypointLocationDataProvider.lua:86-101): it checks CanSetUserWaypointOnMap, sets the
-- waypoint and turns super-tracking on separately. None of these is protected or needs a
-- hardware event. Every call is feature-detected and inside pcall: without them the guide
-- still shows its steps, only without the marker.
local _, ns = ...

local Waypoint = {}
ns.Waypoint = Waypoint

-- { uiMapID, x, y } (x and y 0 to 1) of the waypoint this addon set last, or nil. Only that
-- one is ever cleared: a waypoint the player placed on the map is theirs.
local mine

local SAME = 0.0005

local function Available()
    return C_Map and C_Map.SetUserWaypoint and C_Map.ClearUserWaypoint
        and UiMapPoint and UiMapPoint.CreateFromCoordinates and true or false
end

-- Sets the waypoint at x, y (map percent, 0 to 100) on uiMapId and super-tracks it. Returns
-- true when the game took it.
function Waypoint.Set(uiMapId, x, y)
    if not Available() or type(uiMapId) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then
        return false
    end
    if C_Map.CanSetUserWaypointOnMap then
        local ok, can = pcall(C_Map.CanSetUserWaypointOnMap, uiMapId)
        if not ok or not can then
            return false
        end
    end
    local okPoint, point = pcall(UiMapPoint.CreateFromCoordinates, uiMapId, x / 100, y / 100)
    if not okPoint or type(point) ~= "table" then
        return false
    end
    local okSet, wasSet = pcall(C_Map.SetUserWaypoint, point)
    if not okSet or wasSet == false then
        return false
    end
    mine = { uiMapId, x / 100, y / 100 }
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
    return true
end

-- True when the game's user waypoint is still the one this addon set.
local function IsMine()
    if not mine then
        return false
    end
    if not (C_Map.HasUserWaypoint and C_Map.GetUserWaypoint) then
        return false -- the game cannot say whose it is: leave it
    end
    local okHas, has = pcall(C_Map.HasUserWaypoint)
    if not okHas or not has then
        return false
    end
    local ok, point = pcall(C_Map.GetUserWaypoint)
    if not ok or type(point) ~= "table" or type(point.position) ~= "table" then
        return false
    end
    local px, py = point.position.x, point.position.y
    return point.uiMapID == mine[1] and type(px) == "number" and type(py) == "number"
        and math.abs(px - mine[2]) < SAME and math.abs(py - mine[3]) < SAME
end

-- Clears the waypoint, but only when it is the one this addon set.
function Waypoint.Clear()
    if IsMine() and C_Map and C_Map.ClearUserWaypoint then
        pcall(C_Map.ClearUserWaypoint)
    end
    mine = nil
end

-- For the tests: the waypoint this addon thinks it set.
function Waypoint.Mine()
    return mine
end
