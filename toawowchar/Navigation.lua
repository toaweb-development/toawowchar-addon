-- Addon-owned straight-line navigation; no native waypoint/supertrack reads.
-- Geometry evidence and intentionally omitted HBD runtime: docs/status/a-103.md.
local _, ns = ...

local L = ns.L
local part = ns.Part("navigation", L["PART_NAVIGATION"])
local Navigation = { part = part }
ns.Navigation = Navigation

local host, arrow, text, sampler
local targetMap, targetX, targetY
local cachedMap, cachedWorld, cachedNorth, cachedWest
local elapsedTotal = 0
local running = false
local lastText
local inputVector
local mapRestricted = false

local function Number(v, low, high)
    return not ns.IsSecret(v) and type(v) == "number" and v == v and v >= low and v <= high
end

-- Guard the container before even reading .x/.y. Secret-table API failure is closed.
local function PlainTable(v)
    if ns.IsSecret(v) or type(v) ~= "table" then return false end
    if issecrettable then
        local ok, secret = pcall(issecrettable, v)
        if not ok or ns.IsSecret(secret) or type(secret) ~= "boolean" or secret then return false end
    end
    return true
end
Navigation.PlainTable = PlainTable
Navigation.Number = Number

local function ID(v)
    return Number(v, 1, 2147483647) and v == math.floor(v)
end

local function Combat()
    if not InCombatLockdown then return false end
    local ok, value = pcall(InCombatLockdown)
    return not ok or ns.IsSecret(value) or type(value) ~= "boolean" or value
end

Navigation.Combat = Combat

local function Clear(message)
    if arrow then arrow:Hide() end
    if text and lastText ~= message then
        text:SetText(message)
        lastText = message
    end
end

local function Invalidate()
    cachedMap, cachedWorld, cachedNorth, cachedWest = nil, nil, nil, nil
end

local function Stop(message)
    if sampler and running then sampler:SetScript("OnUpdate", nil); sampler:Hide() end
    running = false
    elapsedTotal = 0
    Invalidate()
    Clear(message or "")
end
Navigation.Stop = part.Wrap(Stop)

-- C_Map world .x is north, .y west (HBD initialization swaps top/left).
-- Native Navigation-Tracked-Arrow points up at zero; positive rotation turns left.
-- Facing is radians counterclockwise from north. Never call atan2 at the origin.
local function Geometry(north, west, facing)
    if not Number(north, -100000, 100000) or not Number(west, -100000, 100000)
        or not Number(facing, 0, 2 * math.pi) then return nil end
    local distance = math.sqrt(north * north + west * west)
    if distance > 100000 then return nil end
    if distance == 0 then return nil, 0 end
    -- Lua 5.1 has no portable two-argument atan. Avoid a new WoW-only alias.
    local angle
    if north > 0 then angle = math.atan(west / north)
    elseif north < 0 then angle = math.atan(west / north) + math.pi
    elseif west > 0 then angle = math.pi / 2
    else angle = -math.pi / 2 end
    return (angle - facing + math.pi) % (2 * math.pi) - math.pi, distance
end
Navigation.Geometry = Geometry

local function World(map, vector)
    if not ID(map) or not PlainTable(vector) then return nil end
    if not Number(vector.x, 0, 1) or not Number(vector.y, 0, 1) then return nil end
    local ok, world, position = pcall(C_Map.GetWorldPosFromMapPos, map, vector)
    if not ok or not Number(world, 0, 2147483647) or world ~= math.floor(world) or not PlainTable(position) then return nil end
    if not Number(position.x, -1000000, 1000000) or not Number(position.y, -1000000, 1000000) then return nil end
    return world, position.x, position.y
end

-- Optional restriction API: event Activating precedes the query becoming true.
local function Restricted()
    if mapRestricted then return true end
    if not (C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive) then return false end
    local kind = Enum and Enum.AddOnRestrictionType and Enum.AddOnRestrictionType.Map
    if not Number(kind, 0, 100) then return true end
    local ok, active = pcall(C_RestrictedActions.IsAddOnRestrictionActive, kind)
    return not ok or ns.IsSecret(active) or type(active) ~= "boolean" or active
end

local function Sample()
    if Combat() then Stop(""); return end
    if Restricted() then Stop(L["NAV_UNAVAILABLE"]); return end
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and C_Map.GetWorldPosFromMapPos
        and GetPlayerFacing and IsInInstance and CreateVector2D) then
        Invalidate(); Clear(L["NAV_UNAVAILABLE"]); return
    end
    local okInstance, inside, instanceType = pcall(IsInInstance)
    if not okInstance or ns.IsSecret(inside) or type(inside) ~= "boolean" or ns.IsSecret(instanceType)
        or type(instanceType) ~= "string" or inside or instanceType ~= "none" then
        Invalidate(); Clear(L["NAV_UNAVAILABLE"]); return
    end
    local okMap, map = pcall(C_Map.GetBestMapForUnit, "player")
    if not okMap or not ID(map) then Invalidate(); Clear(L["NAV_UNAVAILABLE"]); return end
    local okPlayer, player = pcall(C_Map.GetPlayerMapPosition, map, "player")
    if not okPlayer then Invalidate(); Clear(L["NAV_UNAVAILABLE"]); return end
    local world, north, west = World(map, player)
    if not world then Invalidate(); Clear(L["NAV_UNAVAILABLE"]); return end
    if cachedMap ~= map or cachedWorld ~= world then
        Invalidate()
        if not inputVector then
            local ok, vector = pcall(CreateVector2D, targetX / 100, targetY / 100)
            if not ok or not PlainTable(vector) then Clear(L["NAV_UNAVAILABLE"]); return end
            inputVector = vector
        end
        local targetWorld, tn, tw = World(targetMap, inputVector)
        if targetWorld ~= world then Clear(L["NAV_UNAVAILABLE"]); return end
        cachedMap, cachedWorld, cachedNorth, cachedWest = map, world, tn, tw
    end
    local okFacing, facing = pcall(GetPlayerFacing)
    if not okFacing or not Number(facing, 0, 2 * math.pi) then Invalidate(); Clear(L["NAV_UNAVAILABLE"]); return end
    local rotation, yards = Geometry(cachedNorth - north, cachedWest - west, facing)
    if not yards then Invalidate(); Clear(L["NAV_UNAVAILABLE"]); return end
    if yards == 0 then Clear(L["NAV_ARRIVED"]); return end
    arrow:SetRotation(rotation)
    arrow:Show()
    local value = string.format(L["YARDS"], math.floor(yards + 0.5))
    if lastText ~= value then text:SetText(value); lastText = value end
end

-- No tables, closures, formatting or API position reads before the throttle.
local function OnUpdate(_, elapsed)
    if not Number(elapsed, 0, 60) then return end
    elapsedTotal = elapsedTotal + elapsed
    if elapsedTotal < 0.05 then return end
    elapsedTotal = 0 -- no catch-up bursts, even after a long frame
    part.Call(Sample)
end

local function Refresh()
    if not host then return end
    local settings = ns.DB().settings
    local okShown, shown = pcall(host.IsShown, host)
    if settings.navigationEnabled ~= true or not okShown or ns.IsSecret(shown) or type(shown) ~= "boolean"
        or not shown or not targetMap or Combat() then Stop(""); return end
    if Restricted() then Stop(L["NAV_UNAVAILABLE"]); return end
    if not running then
        running = true
        elapsedTotal = 0
        sampler:SetScript("OnUpdate", OnUpdate)
        sampler:Show()
    end
    -- Layout may have cleared the shared distance region. Repaint only at a sampled tick.
    lastText = nil
end
Navigation.Refresh = part.Wrap(Refresh)

Navigation.SetTarget = part.Wrap(function(map, x, y)
    if not ID(map) or not Number(x, 0, 100) or not Number(y, 0, 100) then
        targetMap, targetX, targetY, inputVector = nil, nil, nil, nil
        Stop(""); return
    end
    if targetMap ~= map or targetX ~= x or targetY ~= y then
        targetMap, targetX, targetY, inputVector = map, x, y, nil
        Invalidate()
        Clear("")
    end
end)

Navigation.ApplyScale = part.Wrap(function()
    if host and not Combat() then host:SetScale(ns.DB().settings.navigationScale) end
end)

Navigation.Attach = part.Wrap(function(frame, texture, distance)
    host, arrow, text = frame, texture, distance
    arrow:SetAtlas("Navigation-Tracked-Arrow")
    arrow:Hide()
    sampler = CreateFrame("Frame", nil, host)
    sampler:Hide()
    host:HookScript("OnHide", part.Wrap(function() Stop("") end))
    sampler:SetScript("OnEvent", part.Wrap(function(_, event, restrictionType, state)
        Invalidate()
        if event == "ADDON_RESTRICTION_STATE_CHANGED" then
            local kind = Enum and Enum.AddOnRestrictionType and Enum.AddOnRestrictionType.Map
            if not Number(kind, 0, 100) or not Number(restrictionType, 0, 100) then
                mapRestricted = true
            elseif restrictionType == kind then
                -- Pinned enum: Inactive=0, Activating=1, Active=2. Unknown is closed.
                mapRestricted = not Number(state, 0, 2) or state ~= 0
            end
            if mapRestricted then Stop(L["NAV_UNAVAILABLE"]); return end
        end
        if event == "PLAYER_REGEN_DISABLED" then Stop("")
        else Navigation.ApplyScale(); Refresh() end
    end))
    for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
        "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "ADDON_RESTRICTION_STATE_CHANGED" }) do
        pcall(sampler.RegisterEvent, sampler, event)
    end
end)

part.OnFail(function()
    if sampler then pcall(sampler.UnregisterAllEvents, sampler) end
    pcall(Stop, "")
end)
