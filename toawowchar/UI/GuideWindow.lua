-- The guide's window, «the panel»: a header (crest, route name, step count and the Back, Skip
-- and Hide buttons), the zone line, the current step (icon, kind, quest, NPC, objectives,
-- coordinates and the distance), the next two steps on one line each, and a bar for how far
-- through the route. 300 px wide; the height follows the content. Made of the game's own
-- frames, fonts and atlases. /wowchar guide shows or hides it.
--
-- Saved (toawowcharDB.guide, Core.lua): `shown` and `point` (where it was dragged to).
-- Combat: no frame is made, shown, moved, sized or redrawn while InCombatLockdown() is true.
-- Two writes are allowed then, both to plain (not protected) regions: the coordinate line
-- says «In combat: updates when combat ends» when combat starts (and the distance empties),
-- and the window hides when the guide turns off after an error. Also in combat, and not
-- frames of ours: the game's GameTooltip on hovering a button; Back and Skip still work
-- (they move the waypoint, and the window catches up after combat). What would change is remembered and done once on
-- PLAYER_REGEN_ENABLED; a drag does not start in combat. The waypoint is not a frame and
-- follows the step at once.
-- Errors: every way in (the guide's events, /wowchar guide, the buttons, the drag, the
-- tooltips, the distance timer) runs through the guide's part; the waypoint is its own part.
--
-- Verified for Forever (Gethe/wow-ui-source, branch forever, ca8368f, build 1.60.1.70532):
--   Frames: CreateFrame, SetMovable, EnableMouse, RegisterForDrag, StartMoving,
--     StopMovingOrSizing, GetPoint, ClearAllPoints, SetPoint, SetClampedToScreen, SetSize,
--     SetHeight, Show, Hide, IsShown (SimpleFrameAPIDocumentation.lua, SimpleScriptRegion*).
--   Textures: SetAtlas, SetColorTexture, SetGradient(orientation, minColor, maxColor)
--     (SimpleTextureBaseAPIDocumentation.lua:368, :439), SetVertexColor
--     (SimpleRegionAPIDocumentation.lua), CreateColor (Blizzard_SharedXMLBase/Color.lua:3).
--   Status bars: SetStatusBarTexture (SimpleStatusBarAPIDocumentation.lua:318; Blizzard passes
--     an atlas name, Blizzard_UnitFrame/Mainline/AlternatePowerBarBase.lua:217),
--     SetMinMaxValues, SetValue.
--   Buttons: SetNormalAtlas, SetHighlightAtlas(atlas, blendMode) (SimpleButtonAPIDocumentation.lua:370).
--   Font strings: SetWordWrap, SetMaxLines (SimpleFontStringAPIDocumentation.lua).
--   BackdropTemplate: SetBackdrop, SetBackdropBorderColor (Blizzard_SharedXML/Backdrop.lua:336,
--     :429) with the tooltip border file Interface\Tooltips\UI-Tooltip-Border (Backdrop.lua:134,
--     BACKDROP_TUTORIAL_16_16; Forever has no BACKDROP_TOOLTIP_* table).
--   Fonts (Blizzard_Fonts_Shared/Shared/FontStyles.xml): GameFontNormal :50,
--     GameFontNormalSmall :56, GameFontHighlight :62, GameFontHighlightSmall :92,
--     GameFontDisableSmall :112, GameFontHighlightOutline :257, GameFontHighlightMedium :260.
--   Atlases, each used by Blizzard's own code in that branch:
--     QuestNormal                 Blizzard_SharedMapDataProviders/QuestOfferDataProvider.xml:18
--     UI-QuestIcon-TurnIn-Normal  Blizzard_POIButton/POIButton.lua:237
--     Navigation-Tracked-Icon     Blizzard_QuestNavigation/SuperTrackedFrame.xml:9
--     poi-traveldirections-arrow  Blizzard_UIPanels_Game/Mainline/QuestMapFrame.xml:750
--     countdown-swords            Blizzard_FrameXML/Timer.lua:348
--     common-icon-backarrow, common-icon-forwardarrow
--                                 Blizzard_TransformManipulator/Blizzard_ScaleControlFrame.xml:84, :93
--     common-icon-redx            Blizzard_CharacterCreate/Mainline/Blizzard_CharacterCreate.xml:536
--     common-icon-checkmark       Blizzard_UIWidgets/Blizzard_UIWidgetTemplateBase.xml:184
--     UI-HUD-ExperienceBar-Fill-Experience  Blizzard_StatusTrackingBar/Mainline/ExpBarOverrides.lua:2
--   Atlas markup |A:name:h:w:x:y:r:g:b|a: Blizzard_SharedXMLBase/TextureUtil.lua:289.
--   Class colour: C_ClassColor.GetClassColor (ClassColorDocumentation.lua:11), else
--     RAID_CLASS_COLORS (Blizzard_SharedXML/ClassColors.lua:1); UnitClass (UnitDocumentation.lua:911).
--   Distance: C_Navigation.GetDistance and GetTargetState (InGameNavigationDocumentation.lua:11,
--     :57; Blizzard reads them
--     the same way, Blizzard_QuestNavigation/SuperTrackedFrame.lua:202), only while the game
--     super-tracks this addon's waypoint (C_SuperTrack.IsSuperTrackingUserWaypoint,
--     SuperTrackManagerDocumentation.lua:128). Read on C_Timer.NewTicker
--     (UITimerDocumentation.lua:22) every DISTANCE_SECONDS, never on OnUpdate; the ticker
--     stops when the window hides, in combat and when the guide turns off.
--   Tooltips: GameTooltip (Blizzard_GameTooltip/Mainline/GameTooltip.xml:249), SetOwner, SetText, Hide.
--   Zone: GetSubZoneText, GetZoneText (ZoneScriptDocumentation.lua:43, :52).
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

---------------------------------------------------------------------------
-- The look: every size, colour and atlas in one place
---------------------------------------------------------------------------

local WIDTH = 300
local PAD = 10
local ICON = 26
local SMALL_ICON = 16
local BUTTON = 16
local TEXT_X = PAD + 4 + ICON + 8      -- the current step's text column
local NEXT_X = PAD + 4 + SMALL_ICON + 8
local LINE = {                         -- the height each line takes
    header = 30, rule = 6, note = 26, zone = 16, message = 28,
    kind = 12, title = 16, detail = 13, objective = 13, coords = 13, bar = 9,
    following = 18, progress = 5,
}
local BLOCK_PAD = 6                    -- above and below the current step
local DISTANCE_SECONDS = 0.5           -- the distance is read at most twice a second

-- Colours for |c markup (alpha, red, green, blue), and as 0..1 numbers for textures.
local COLOR = {
    hint = "ff9d9d9d",        -- grey: the step count, the kind, the next steps, done objectives
    subzone = "ffffe8a6",     -- light gold
    npc = "ffffff9a",         -- light yellow
    coords = "ff71d5ff",      -- light blue
    warn = "ffff9933",        -- orange: the Skyborne line, «held»
}
local RGB = {
    background = { 0, 0, 0, 0.8 },
    border = { 0.6, 0.6, 0.6, 1 },
    rule = { 1, 1, 1, 0.15 },
    gold = { 1, 0.82, 0 },
    gradientFrom = { 1, 0.82, 0, 0.18 },
    gradientTo = { 1, 0.82, 0, 0 },
    lightBlue = { 0.443, 0.835, 1 },
    track = { 0, 0, 0, 0.5 },
    crestFallback = { 0.5, 0.5, 0.5 },
}
local CHECK_RGB = { 64, 255, 64 }      -- the green check's tint in atlas markup (0..255)

-- The icon of each step kind (Guide.KINDS), and its tint (nil: the atlas's own colours).
local KIND_ICONS = {
    [Guide.KINDS.accept] = { atlas = "QuestNormal" },
    [Guide.KINDS.turnin] = { atlas = "UI-QuestIcon-TurnIn-Normal" },
    [Guide.KINDS.objective] = { atlas = "Navigation-Tracked-Icon" },
    [Guide.KINDS.travel] = { atlas = "poi-traveldirections-arrow", tint = RGB.lightBlue },
    [Guide.KINDS.grind] = { atlas = "countdown-swords", tint = RGB.gold },
}
local KIND_LABELS = {
    [Guide.KINDS.accept] = L["KIND_ACCEPT"],
    [Guide.KINDS.objective] = L["KIND_OBJECTIVE"],
    [Guide.KINDS.turnin] = L["KIND_TURNIN"],
    [Guide.KINDS.travel] = L["KIND_TRAVEL"],
    [Guide.KINDS.grind] = L["KIND_GRIND"],
}
local BUTTON_ATLAS = { back = "common-icon-backarrow", skip = "common-icon-forwardarrow", hide = "common-icon-redx" }
local CHECK_ATLAS = "common-icon-checkmark"
local BAR_ATLAS = "UI-HUD-ExperienceBar-Fill-Experience"
local BORDER_FILE = "Interface\\Tooltips\\UI-Tooltip-Border"

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
-- The distance ticker, and whether the current step has a place to measure to.
local ticker
local measuring = false

local function Saved()
    return DB().guide
end

local function Colored(color, text)
    return "|c" .. color .. text .. "|r"
end

-- A text from the game, safe for a font string: every | doubled.
local function Escape(text)
    return (text:gsub("|", "||"))
end

local function CheckMark()
    return string.format("|A:%s:12:12:0:0:%d:%d:%d|a", CHECK_ATLAS, CHECK_RGB[1], CHECK_RGB[2], CHECK_RGB[3])
end

---------------------------------------------------------------------------
-- Making the frame
---------------------------------------------------------------------------

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

-- A line of text, left aligned: one line only (the game cuts it with an ellipsis), or up to
-- `lines` lines for a sentence that must be read whole (the Skyborne note, the message).
local function Text(parent, font, width, lines)
    local fs = parent:CreateFontString(nil, "ARTWORK", font)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap((lines or 1) > 1)
    fs:SetMaxLines(lines or 1)
    if width then
        fs:SetWidth(width)
    end
    return fs
end

local function Bar(parent, width, height)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetSize(width, height)
    bar:SetStatusBarTexture(BAR_ATLAS)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(unpack(RGB.track))
    track:SetAllPoints()
    return bar
end

local function ShowTooltip(self)
    if GameTooltip and GameTooltip.SetOwner then
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(self.label)
    end
end

local function HideTooltip()
    if GameTooltip and GameTooltip.Hide then
        GameTooltip:Hide()
    end
end

-- A small icon button with its word as the tooltip (as Blizzard's character creation does
-- with common-icon-redx: the atlas as the normal texture and, added, as the highlight).
local function IconButton(parent, atlas, label, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(BUTTON, BUTTON)
    button:SetNormalAtlas(atlas)
    button:SetHighlightAtlas(atlas, "ADD")
    button.label = label
    button:SetScript("OnClick", part.Wrap(onClick))
    button:SetScript("OnEnter", part.Wrap(ShowTooltip))
    button:SetScript("OnLeave", part.Wrap(HideTooltip))
    return button
end

-- The crest: a class-coloured square (the addon has no icon of its own).
local function ClassColor()
    local classFile
    if UnitClass then
        local ok, _, file = pcall(UnitClass, "player")
        classFile = ok and type(file) == "string" and file or nil
    end
    if not classFile then
        return RGB.crestFallback
    end
    if C_ClassColor and C_ClassColor.GetClassColor then
        local ok, color = pcall(C_ClassColor.GetClassColor, classFile)
        if ok and type(color) == "table" and color.GetRGB then
            return { color:GetRGB() }
        end
    end
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if type(c) == "table" and type(c.r) == "number" then
        return { c.r, c.g, c.b }
    end
    return RGB.crestFallback
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
    f:SetSize(WIDTH, 120)
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

    -- Black at 80 percent inside the tooltip's thin border.
    if f.SetBackdrop and f.SetBackdropBorderColor then
        f:SetBackdrop({ edgeFile = BORDER_FILE, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        f:SetBackdropBorderColor(unpack(RGB.border))
    end
    local background = f:CreateTexture(nil, "BACKGROUND")
    background:SetColorTexture(unpack(RGB.background))
    background:SetPoint("TOPLEFT", 3, -3)
    background:SetPoint("BOTTOMRIGHT", -3, 3)

    -- Header: crest, route name, step count, the three buttons, and a thin line under it.
    local crest = f:CreateTexture(nil, "ARTWORK")
    crest:SetSize(14, 14)
    crest:SetPoint("TOPLEFT", PAD, -PAD)
    crest:SetColorTexture(unpack(ClassColor()))
    widgets.crest = crest

    widgets.hide = IconButton(f, BUTTON_ATLAS.hide, L["HIDE"], function() GuideWindow.Hide() end)
    widgets.hide:SetPoint("TOPRIGHT", -PAD + 2, -PAD + 1)
    widgets.skip = IconButton(f, BUTTON_ATLAS.skip, L["SKIP"], function() Guide.Skip() end)
    widgets.skip:SetPoint("RIGHT", widgets.hide, "LEFT", -4, 0)
    widgets.back = IconButton(f, BUTTON_ATLAS.back, L["BACK"], function() Guide.Back() end)
    widgets.back:SetPoint("RIGHT", widgets.skip, "LEFT", -4, 0)

    widgets.count = Text(f, "GameFontDisableSmall")
    widgets.count:SetJustifyH("RIGHT")
    widgets.count:SetPoint("RIGHT", widgets.back, "LEFT", -8, 0)

    widgets.title = Text(f, "GameFontNormal")
    widgets.title:SetPoint("LEFT", crest, "RIGHT", 6, 0)
    widgets.title:SetPoint("RIGHT", widgets.count, "LEFT", -6, 0)

    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(unpack(RGB.rule))
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", PAD, -LINE.header)
    rule:SetPoint("TOPRIGHT", -PAD, -LINE.header)

    widgets.note = Text(f, "GameFontNormalSmall", WIDTH - 2 * PAD, 2)
    widgets.zone = Text(f, "GameFontDisableSmall", WIDTH - 2 * PAD - 60)
    widgets.level = Text(f, "GameFontDisableSmall")
    widgets.level:SetJustifyH("RIGHT")

    -- The current step: a faint gold gradient from the left behind it.
    widgets.glow = f:CreateTexture(nil, "BORDER")
    widgets.glow:SetColorTexture(1, 1, 1, 1)
    if widgets.glow.SetGradient and CreateColor then
        widgets.glow:SetGradient("HORIZONTAL", CreateColor(unpack(RGB.gradientFrom)), CreateColor(unpack(RGB.gradientTo)))
    end
    widgets.icon = f:CreateTexture(nil, "ARTWORK")
    widgets.icon:SetSize(ICON, ICON)
    local column = WIDTH - TEXT_X - PAD
    widgets.kind = Text(f, "GameFontDisableSmall", column)
    widgets.quest = Text(f, "GameFontHighlightMedium", column)
    widgets.detail = Text(f, "GameFontNormalSmall", column)
    widgets.objectives = {}
    for i = 1, Guide.MAX_OBJECTIVES do
        widgets.objectives[i] = Text(f, "GameFontHighlightSmall", column)
    end
    widgets.coords = Text(f, "GameFontHighlightSmall")
    widgets.distance = Text(f, "GameFontHighlightOutline")
    widgets.distance:SetPoint("LEFT", widgets.coords, "RIGHT", 8, 0)
    widgets.xp = Bar(f, column, 5)
    widgets.message = Text(f, "GameFontHighlight", WIDTH - 2 * PAD, 2)

    -- The next two steps.
    widgets.following = {}
    for i = 1, Guide.SHOWN - 1 do
        local icon = f:CreateTexture(nil, "ARTWORK")
        icon:SetSize(SMALL_ICON, SMALL_ICON)
        widgets.following[i] = { icon = icon, text = Text(f, "GameFontDisableSmall", WIDTH - NEXT_X - PAD) }
    end

    -- How far through the route.
    widgets.progress = Bar(f, WIDTH - 2 * PAD, LINE.progress)
    return f
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function At(region, x, y)
    region:ClearAllPoints()
    region:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
    region:Show()
end

local function SetIcon(texture, kind)
    local icon = KIND_ICONS[kind]
    if not icon then
        texture:Hide()
        return
    end
    texture:SetAtlas(icon.atlas)
    local tint = icon.tint or { 1, 1, 1 }
    texture:SetVertexColor(tint[1], tint[2], tint[3])
end

local function HasPlace(current)
    local kinds = Guide.KINDS
    return current.kind == kinds.accept or current.kind == kinds.objective or current.kind == kinds.turnin
end

-- Yards to this addon's waypoint while the game super-tracks it, as text; "" otherwise.
local function Distance()
    if not (C_Navigation and C_Navigation.GetDistance and Waypoint.Mine()) then
        return ""
    end
    if C_SuperTrack and C_SuperTrack.IsSuperTrackingUserWaypoint then
        local ok, tracked = pcall(C_SuperTrack.IsSuperTrackingUserWaypoint)
        if not ok or not tracked then
            return ""
        end
    end
    -- As Blizzard's marker does (Blizzard_QuestNavigation/SuperTrackedFrame.lua:80): no distance
    -- while the game's navigation target is Invalid (0) or Disabled (3)
    -- (InGameNavigationDocumentation.lua:118, NavigationState).
    if C_Navigation.GetTargetState then
        local okState, navState = pcall(C_Navigation.GetTargetState)
        if not okState or ns.IsSecret(navState) or navState == 0 or navState == 3 then
            return ""
        end
    end
    local ok, d = pcall(C_Navigation.GetDistance)
    if not ok or ns.IsSecret(d) or type(d) ~= "number" or d < 0 or d > 100000 then
        return ""
    end
    return string.format(L["YARDS"], math.floor(d + 0.5))
end

local function UpdateDistance()
    if not (frame and frame:IsShown()) or InCombat() then
        return
    end
    widgets.distance:SetText(measuring and Distance() or "")
end

local function StopTicker()
    if ticker then
        pcall(ticker.Cancel, ticker)
        ticker = nil
    end
end

local function StartTicker()
    if ticker or not measuring or InCombat() or not (frame and frame:IsShown()) then
        return
    end
    if C_Timer and C_Timer.NewTicker then
        local ok, t = pcall(C_Timer.NewTicker, DISTANCE_SECONDS, part.Wrap(UpdateDistance))
        ticker = ok and type(t) == "table" and t or nil
    end
end

-- Writes the view into the window and sizes it (out of combat only).
local function Draw()
    local view = Guide.View()

    -- Header.
    widgets.title:SetText(view.start and string.format(L["ROUTE_NAME"], view.start) or L["GUIDE_TITLE"])
    widgets.count:SetText(view.total and Colored(COLOR.hint, string.format(L["STEP_COUNT"], math.min(view.index, view.total), view.total)) or "")
    local y = -LINE.header - LINE.rule

    if view.unconfirmed then
        At(widgets.note, PAD, y)
        widgets.note:SetText(Colored(COLOR.warn, L["SKYBORNE_NOTE"]))
        y = y - LINE.note
    else
        widgets.note:SetText("")
        widgets.note:Hide()
    end

    -- Zone line: the subzone in light gold, «· zone», and the level on the right.
    local zone = view.zone and Escape(view.zone)
    local place = zone or ""
    if view.subzone and view.subzone ~= view.zone then
        local subzone = Colored(COLOR.subzone, Escape(view.subzone))
        place = zone and string.format(L["ZONE_LINE"], subzone, zone) or subzone
    end
    At(widgets.zone, PAD, y)
    widgets.zone:SetText(place)
    widgets.level:ClearAllPoints()
    widgets.level:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, y)
    widgets.level:SetText(view.level and view.level > 0 and string.format(L["LEVEL"], view.level) or "")
    y = y - LINE.zone

    -- The current step, or the message.
    local stepRegions = {
        widgets.glow, widgets.icon, widgets.kind, widgets.quest, widgets.detail,
        widgets.coords, widgets.distance, widgets.xp, widgets.message,
    }
    for _, region in ipairs(stepRegions) do
        region:Hide()
    end
    for _, fs in ipairs(widgets.objectives) do
        fs:SetText("")
        fs:Hide()
    end
    widgets.distance:SetText("")
    measuring = false

    local current = view.current
    if current then
        local top = y
        y = y - BLOCK_PAD
        At(widgets.icon, PAD + 4, y)
        SetIcon(widgets.icon, current.kind)
        At(widgets.kind, TEXT_X, y)
        local held = view.held and ("  " .. Colored(COLOR.warn, L["HELD"])) or ""
        widgets.kind:SetText(Colored(COLOR.hint, KIND_LABELS[current.kind] or "") .. held)
        y = y - LINE.kind
        At(widgets.quest, TEXT_X, y)
        widgets.quest:SetText(current.title)
        y = y - LINE.title
        if current.detail then
            At(widgets.detail, TEXT_X, y)
            widgets.detail:SetText(Colored(COLOR.npc, current.detail))
            y = y - LINE.detail
        end
        for i, objective in ipairs(current.objectives or {}) do
            local fs = widgets.objectives[i]
            At(fs, TEXT_X, y)
            if objective.done then
                fs:SetText(CheckMark() .. " " .. Colored(COLOR.hint, objective.text))
            else
                fs:SetText(string.format(L["OBJECTIVE_LINE"], objective.text))
            end
            y = y - LINE.objective
        end
        At(widgets.coords, TEXT_X, y)
        if HasPlace(current) then
            measuring = true
            widgets.coords:SetText(Colored(COLOR.coords, string.format(L["COORDS"], current.x, current.y)))
            widgets.distance:Show()
            widgets.distance:SetText(Distance())
        elseif current.grind then
            local g = current.grind
            widgets.coords:SetText(Colored(COLOR.hint, g.xp and string.format(L["GRIND_XP"], g.xp) or string.format(L["GRIND_LEVEL"], g.target)))
        else
            widgets.coords:SetText(Colored(COLOR.hint, L["TRAVEL_HINT"]))
        end
        y = y - LINE.coords
        if current.grind then
            At(widgets.xp, TEXT_X, y - 2)
            widgets.xp:SetValue(current.grind.fraction)
            y = y - LINE.bar
        end
        y = y - BLOCK_PAD
        widgets.glow:ClearAllPoints()
        widgets.glow:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, top)
        widgets.glow:SetSize(WIDTH - 6, top - y)
        widgets.glow:Show()
    elseif view.message then
        At(widgets.message, PAD, y - BLOCK_PAD)
        widgets.message:SetText(view.message)
        y = y - BLOCK_PAD - LINE.message - BLOCK_PAD
    end

    -- The next two steps.
    for i, row in ipairs(widgets.following) do
        local step = view.following and view.following[i]
        if step then
            At(row.icon, PAD + 4, y - 1)
            SetIcon(row.icon, step.kind)
            At(row.text, NEXT_X, y - 3)
            row.text:SetText(Colored(COLOR.hint, step.text))
            y = y - LINE.following
        else
            row.icon:Hide()
            row.text:SetText("")
            row.text:Hide()
        end
    end

    -- How far through the route; the height follows from all of it.
    if view.total and view.total > 0 then
        At(widgets.progress, PAD, y - 4)
        widgets.progress:SetValue(math.min((view.index - 1) / view.total, 1))
        y = y - 4 - LINE.progress
    else
        widgets.progress:Hide()
    end
    frame:SetHeight(-y + PAD)

    if measuring then
        StartTicker()
    else
        StopTicker()
    end
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
        frame:Show()
        Draw()
    elseif frame then
        StopTicker()
        frame:Hide()
    end
end

-- The step or what it shows changed: redraw (or after combat) and move the waypoint.
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

-- Combat starts: the layout stays; the coordinate line says it waits, the distance stops.
function GuideWindow.CombatStarted()
    StopTicker()
    if frame and frame:IsShown() and widgets.coords then
        widgets.coords:SetText(Colored(COLOR.hint, L["IN_COMBAT"]))
        widgets.distance:SetText("")
    end
end

-- Combat ended: what it held back, then a fresh draw (which starts the distance again).
function GuideWindow.CombatEnded()
    pending.update = false
    if pending.visible ~= nil then
        Apply(pending.visible) -- draws when it shows
    elseif frame and frame:IsShown() then
        Draw()
    end
end

-- The guide turned off after an error: no timer keeps running.
part.OnFail(StopTicker)

-- For the tests.
function GuideWindow.Frame()
    return frame
end

function GuideWindow.Widgets()
    return widgets
end
