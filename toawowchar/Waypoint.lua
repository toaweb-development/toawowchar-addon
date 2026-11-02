-- Optional native map pin, explicitly requested by the player; no distance reads.
local _, ns = ...

local L = ns.L
local part = ns.Part("waypoint", L["PART_WAYPOINT"])

local Waypoint = {}
ns.Waypoint = Waypoint

-- { uiMapID, x, y } (x and y 0 to 1) of the waypoint this addon set last, or nil. Only that
-- one is ever cleared: a waypoint the player placed on the map is theirs.
local mine

local function Available()
    return C_Map and C_Map.SetUserWaypoint and C_Map.ClearUserWaypoint
        and UiMapPoint and UiMapPoint.CreateFromCoordinates and true or false
end

-- No engine identity token exists. Matching coordinates are best-effort ownership only;
-- observing any replacement/removal/unknown state irrevocably releases our claim.
local function IsMine()
    if not mine then return false end
    local nav = ns.Navigation
    if not (C_Map and C_Map.HasUserWaypoint and C_Map.GetUserWaypoint) then mine = nil; return false end
    local okHas, has = pcall(C_Map.HasUserWaypoint)
    if not okHas or ns.IsSecret(has) or type(has) ~= "boolean" or not has then mine = nil; return false end
    local ok, point = pcall(C_Map.GetUserWaypoint)
    if not ok or not nav.PlainTable(point) then mine = nil; return false end
    local position = point.position
    if not nav.PlainTable(position) then mine = nil; return false end
    local map, x, y = point.uiMapID, position.x, position.y
    if not nav.Number(map, 1, 2147483647) or not nav.Number(x, 0, 1) or not nav.Number(y, 0, 1)
        or map ~= mine[1] or x ~= mine[2] or y ~= mine[3] then
        mine = nil; return false
    end
    return true
end

-- Only the Map pin button calls Set. Never overwrite a foreign or unknown waypoint.
local function Set(uiMapId, x, y)
    local nav = ns.Navigation
    if not Available() or not nav.Number(uiMapId, 1, 2147483647) or uiMapId ~= math.floor(uiMapId)
        or not nav.Number(x, 0, 100) or not nav.Number(y, 0, 100) or nav.Combat() then return false end
    local own = IsMine()
    if not C_Map.HasUserWaypoint then return false end
    local okHas, has = pcall(C_Map.HasUserWaypoint)
    if not okHas or ns.IsSecret(has) or type(has) ~= "boolean" or (has and not own) then return false end
    if C_Map.CanSetUserWaypointOnMap then
        local ok, can = pcall(C_Map.CanSetUserWaypointOnMap, uiMapId)
        if not ok or ns.IsSecret(can) or type(can) ~= "boolean" or not can then return false end
    else return false end
    local okPoint, point = pcall(UiMapPoint.CreateFromCoordinates, uiMapId, x / 100, y / 100)
    if not okPoint or not nav.PlainTable(point) then return false end
    local okSet, wasSet = pcall(C_Map.SetUserWaypoint, point)
    if not okSet or ns.IsSecret(wasSet) or type(wasSet) ~= "boolean" or not wasSet then return false end
    mine = { uiMapId, x / 100, y / 100 }
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
    return true
end

local function Clear()
    if IsMine() and C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
    mine = nil
end

-- Through the part; a result of nothing (off, or an error) counts as not set.
function Waypoint.Set(uiMapId, x, y)
    return part.Call(Set, uiMapId, x, y) == true
end

Waypoint.Clear = part.Wrap(Clear)

-- Turned off by an error: the marker this addon set is cleared if it can still be.
part.OnFail(function()
    local ok, own = pcall(IsMine)
    mine = nil
    if ok and own then
        pcall(C_Map.ClearUserWaypoint)
    end
end)

-- For the tests: the waypoint this addon thinks it set.
function Waypoint.Mine()
    return part.Call(IsMine) and mine or nil
end
