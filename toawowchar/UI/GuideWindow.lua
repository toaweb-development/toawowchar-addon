-- The guide's window: the current step and the next two, each with its /way line, and the
-- buttons «Back», «Skip» and «Hide». Small, movable, made of a plain frame (BackdropTemplate
-- when the client has it) in the colours of the export window. /wowchar guide shows or hides it.
--
-- Saved (toawowcharDB.guide, Core.lua): `shown` and `point` (where it was dragged to).
-- Combat: no frame is made, shown, hidden, moved or written to while InCombatLockdown() is
-- true, except the hide when the guide turns off after an error (a plain frame, not
-- protected). What would change is remembered and done once on PLAYER_REGEN_ENABLED; a drag
-- does not start in combat. The waypoint is not a frame and follows the step at once.
-- Errors: every way in (the guide's events, /wowchar guide, the buttons, the drag) runs through
-- the guide's part; the waypoint is a part of its own (Waypoint.lua).
--
-- Frame API (Gethe/wow-ui-source, branch forever, ca8368f): CreateFrame, SetMovable,
-- EnableMouse, RegisterForDrag, StartMoving, StopMovingOrSizing, GetPoint, ClearAllPoints,
-- SetPoint, SetClampedToScreen, Show, Hide, IsShown (SimpleFrameAPIDocumentation.lua,
-- SimpleScriptRegionAPIDocumentation.lua, SimpleScriptRegionResizingAPIDocumentation.lua);
-- UIPanelButtonTemplate (Blizzard_SharedXML/Mainline/SharedUIPanelTemplates.xml:315),
-- BackdropTemplate (Blizzard_SharedXML/Backdrop.xml); InCombatLockdown
-- (RestrictedActionsDocumentation.lua:45).
local _, ns = ...

local L = ns.L
local DB = ns.DB
local InCombat = ns.InCombat
local Guide = ns.Guide
local Waypoint = ns.Waypoint
-- The guide's part (Core.lua, Part): the buttons and the drag run through it, like its events.
local part = ns.Part("guide", L["PART_GUIDE"])

local GuideWindow = {}
ns.GuideWindow = GuideWindow

local WIDTH, HEIGHT = 330, 250
-- Space between two rows (each row is anchored under the one before, so a long one pushes the next down).
local ROW_GAP = 6
local COLOR_ACCENT, COLOR_PRIMARY, COLOR_HINT, COLOR_WARN = "ff5FD4E6", "ff8B7CFF", "ff9A97B8", "ffFF7A8A"

local KIND_LABELS = {
    L["KIND_ACCEPT"], L["KIND_OBJECTIVE"], L["KIND_TURNIN"], L["KIND_TRAVEL"], L["KIND_GRIND"],
}

local ANCHORS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local frame
local widgets = {}
-- What combat held back: visible = true/false (show or hide when it ends), update = true.
local pending = {}
-- The step the waypoint was set for (route index), so a refresh does not set it again.
local waypointStep

local function Saved()
    return DB().guide
end

local function Colored(color, text)
    return "|c" .. color .. text .. "|r"
end

local function SavePoint()
    if not (frame and frame.GetPoint) then
        return
    end
    local ok, point, _, relativePoint, x, y = pcall(frame.GetPoint, frame, 1)
    if ok and ANCHORS[point] and ANCHORS[relativePoint] and type(x) == "number" and type(y) == "number" then
        Saved().point = { point, relativePoint, math.floor(x + 0.5), math.floor(y + 0.5) }
    end
end

-- The saved place, or the default (right of the centre), checked: a damaged file cannot put
-- the window somewhere odd.
local function Place()
    frame:ClearAllPoints()
    local p = Saved().point
    if type(p) == "table" and ANCHORS[p[1]] and ANCHORS[p[2]] and type(p[3]) == "number" and type(p[4]) == "number"
        and math.abs(p[3]) <= 5000 and math.abs(p[4]) <= 5000 then
        frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        frame:SetPoint("RIGHT", UIParent, "RIGHT", -60, 120)
    end
end

local function Button(parent, label, anchor, x, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(96, 22)
    button:SetPoint(anchor, x, 10)
    button:SetText(label)
    button:SetScript("OnClick", part.Wrap(onClick))
    return button
end

local function Create()
    -- No global name: nothing needs one (docs/wow-addon-rules.md 4).
    local ok, f = pcall(CreateFrame, "Frame", nil, UIParent, "BackdropTemplate")
    if not ok or type(f) ~= "table" then
        f = CreateFrame("Frame", nil, UIParent)
    end
    -- Hidden and known at once: if a later line raises, the guide's clean-up finds it and the
    -- half-made window is not left on the screen.
    f:Hide()
    frame = f
    f:SetSize(WIDTH, HEIGHT)
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", part.Wrap(function(self)
        if not InCombat() then
            self:StartMoving()
        end
    end))
    f:SetScript("OnDragStop", part.Wrap(function(self)
        self:StopMovingOrSizing()
        SavePoint()
    end))

    -- Indigo (#131129) at 90 percent, with a primary (#8B7CFF) line on top.
    local background = f:CreateTexture(nil, "BACKGROUND")
    background:SetColorTexture(0.0745, 0.0667, 0.1608, 0.9)
    background:SetAllPoints()
    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.545, 0.486, 1, 0.8)
    line:SetPoint("TOPLEFT", 0, 0)
    line:SetPoint("TOPRIGHT", 0, 0)
    line:SetHeight(2)

    local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetPoint("TOPRIGHT", -70, -10)
    title:SetJustifyH("LEFT")
    widgets.title = title

    local progress = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    progress:SetPoint("TOPRIGHT", -12, -12)
    progress:SetJustifyH("RIGHT")
    widgets.progress = progress

    widgets.rows = {}
    for i = 1, Guide.SHOWN do
        local row = f:CreateFontString(nil, "ARTWORK", i == 1 and "GameFontHighlight" or "GameFontHighlightSmall")
        if i == 1 then
            row:SetPoint("TOPLEFT", 12, -32)
        else
            row:SetPoint("TOPLEFT", widgets.rows[i - 1], "BOTTOMLEFT", 0, -ROW_GAP)
        end
        row:SetWidth(WIDTH - 24)
        row:SetJustifyH("LEFT")
        row:SetWordWrap(true)
        widgets.rows[i] = row
    end

    local message = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    message:SetPoint("TOPLEFT", 12, -40)
    message:SetWidth(WIDTH - 24)
    message:SetJustifyH("LEFT")
    widgets.message = message

    widgets.back = Button(f, L["BACK"], "BOTTOMLEFT", 10, function() Guide.Back() end)
    widgets.skip = Button(f, L["SKIP"], "BOTTOM", 0, function() Guide.Skip() end)
    widgets.hide = Button(f, L["HIDE"], "BOTTOMRIGHT", -10, function() GuideWindow.Hide() end)

    f:Hide()
    return f
end

-- Writes the view into the window (out of combat only).
local function Draw()
    local view = Guide.View()
    local title = L["GUIDE_TITLE"]
    if view.start then
        title = title .. "  " .. Colored(COLOR_PRIMARY, view.start)
    end
    if view.unconfirmed then
        title = title .. "  " .. Colored(COLOR_WARN, L["UNCONFIRMED_START"])
    end
    widgets.title:SetText(title)
    widgets.progress:SetText(view.total and Colored(COLOR_HINT, string.format(L["STEP_OF"], math.min(view.index, view.total), view.total)) or "")

    for i = 1, Guide.SHOWN do
        local row = view.rows and view.rows[i]
        if row then
            local label = KIND_LABELS[row.kind] or ""
            local way = row.way .. "  " .. string.format(L["LEVEL_N"], row.level)
            if i == 1 then
                local held = view.held and ("  " .. Colored(COLOR_WARN, L["HELD"])) or ""
                widgets.rows[i]:SetText(Colored(COLOR_ACCENT, label) .. "  " .. row.text .. held .. "\n" .. Colored(COLOR_HINT, way))
            else
                widgets.rows[i]:SetText(Colored(COLOR_HINT, label .. "  " .. row.text .. "\n" .. way))
            end
        else
            widgets.rows[i]:SetText("")
        end
    end
    widgets.message:SetText(view.message or "")
end

-- The waypoint follows the current step while the guide is meant to be shown: every step has
-- one at its place (travel and grind steps: the middle of their zone); none when the route is
-- done. A map the game refuses leaves no old marker behind: the guide's own is cleared.
local function UpdateWaypoint()
    local step = Guide.Current()
    if not (Saved().shown == true and step) then
        if waypointStep then
            Waypoint.Clear()
            waypointStep = nil
        end
        return
    end
    local index = Guide.state.index
    if waypointStep ~= index then
        waypointStep = index
        if not Waypoint.Set(step[2], step[3], step[4]) then
            Waypoint.Clear()
        end
    end
end

-- Shows or hides the frame now, or after combat.
local function Apply(visible)
    if InCombat() then
        pending.visible = visible
        return
    end
    pending.visible = nil
    if visible then
        frame = frame or Create()
        Place()
        Draw()
        frame:Show()
    elseif frame then
        frame:Hide()
    end
end

-- The step changed: redraw (or after combat) and move the waypoint.
function GuideWindow.Update()
    UpdateWaypoint()
    if not (frame and frame:IsShown()) and pending.visible ~= true then
        return
    end
    if InCombat() then
        pending.update = true
        return
    end
    if frame then
        Draw()
    end
end

function GuideWindow.Show()
    Saved().shown = true
    UpdateWaypoint()
    Apply(true)
end

function GuideWindow.Hide()
    Saved().shown = false
    UpdateWaypoint()
    Apply(false)
end

function GuideWindow.Toggle()
    if Saved().shown == true then
        GuideWindow.Hide()
    else
        GuideWindow.Show()
    end
end

-- Login and /reload: as it was saved (hidden unless it was shown).
function GuideWindow.Restore()
    if Saved().shown == true then
        GuideWindow.Show()
    end
end

function GuideWindow.CombatEnded()
    if pending.visible ~= nil then
        Apply(pending.visible)
    end
    if pending.update then
        pending.update = false
        if frame and frame:IsShown() then
            Draw()
        end
    end
end

-- For the tests.
function GuideWindow.Frame()
    return frame
end
