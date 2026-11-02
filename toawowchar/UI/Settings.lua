-- The settings panel (docs/wow-addon-rules.md 9): Options > AddOns > toawowchar, or /wowchar
-- settings. Two switches and a line with what the quest data collection has stored:
--   «Collect quest data»          toawowcharDB.settings.collect       (default on)
--   «Show the guide at login»     toawowcharDB.settings.guideAtLogin  (default off)
-- A switch writes the saved table at once; the line is counted each time the panel shows.
--
-- The panel is a part of its own (Core.lua, Part): an error turns off only the panel. The
-- settings themselves are plain values in the saved table, so the collection and the guide
-- read them with or without the panel.
--
-- API (Gethe/wow-ui-source, branch forever, ca8368f, build 1.60.1.70532):
--   Settings.RegisterCanvasLayoutCategory(frame, name) -> category, Settings.RegisterAddOnCategory,
--     Settings.OpenToCategory(categoryID) (Blizzard_Settings_Shared/Blizzard_Settings.lua:162,
--     :134, :144; not load on demand), category:GetID() (Blizzard_Category.lua:13).
--   UICheckButtonTemplate with its .Text (Blizzard_SharedXML/Shared/Button/CheckButtonTemplates.xml:50, :54),
--     SetChecked, GetChecked (SimpleCheckboxAPIDocumentation.lua:49, :10).
--   GameFontNormalLarge (Blizzard_Fonts_Shared/Shared/FontStyles.xml:172), GameFontHighlightSmall (:92).
--   PLAYER_LOGIN (SystemDocumentation.lua:153), PLAYER_REGEN_ENABLED, InCombatLockdown.
local _, ns = ...

local L = ns.L
local DB = ns.DB
local InCombat = ns.InCombat
local Say = ns.Say

local SettingsPanel = {}
ns.SettingsPanel = SettingsPanel

local part = ns.Part("settings", L["PART_SETTINGS"])
SettingsPanel.part = part

local panel
local category
local widgets = {}
local openAfterCombat = false

local function Refresh()
    local s = DB().settings
    widgets.collect:SetChecked(s.collect == true)
    widgets.guide:SetChecked(s.guideAtLogin == true)
    widgets.navigation:SetChecked(s.navigationEnabled == true)
    local quests, npcs, points = 0, 0, 0
    local collect = ns.Collect
    if collect and collect.Counts then
        local ok, q, n, p = pcall(collect.Counts)
        if ok then
            quests, npcs, points = q or 0, n or 0, p or 0
        end
    end
    widgets.stored:SetText(string.format(L["SETTINGS_STORED"], quests, npcs, points))
end
SettingsPanel.Refresh = Refresh

local function Checkbox(parent, label, y, key)
    local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    box:SetPoint("TOPLEFT", 16, y)
    box.Text:SetText(label)
    box:SetScript("OnClick", part.Wrap(function(self)
        DB().settings[key] = self:GetChecked() and true or false
        if key == "navigationEnabled" then ns.Navigation.Refresh() end
        if key == "collect" and ns.Collect and ns.Collect.Forget then
            ns.Collect.Forget()
        end
    end))
    return box
end

local function Create()
    local f = CreateFrame("Frame")
    f:Hide()
    panel = f
    local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(L["SETTINGS_TITLE"])
    widgets.collect = Checkbox(f, L["SETTINGS_COLLECT"], -48, "collect")
    widgets.guide = Checkbox(f, L["SETTINGS_GUIDE_AT_LOGIN"], -80, "guideAtLogin")
    widgets.navigation = Checkbox(f, L["SETTINGS_NAVIGATION"], -112, "navigationEnabled")
    local function ScaleButton(label, x, delta)
        local button = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        button:SetPoint("TOPLEFT", x, -152)
        button:SetSize(125, 24)
        button:SetText(label)
        button:SetScript("OnClick", part.Wrap(function()
            local settings = DB().settings
            settings.navigationScale = math.max(0.75, math.min(1.5, settings.navigationScale + delta))
            ns.Navigation.ApplyScale()
        end))
        return button
    end
    widgets.smaller = ScaleButton(L["SETTINGS_NAV_SMALLER"], 20, -0.1)
    widgets.larger = ScaleButton(L["SETTINGS_NAV_LARGER"], 155, 0.1)
    widgets.stored = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    widgets.stored:SetPoint("TOPLEFT", 20, -192)
    widgets.stored:SetJustifyH("LEFT")
    f:SetScript("OnShow", part.Wrap(Refresh))
    return f
end

-- Registers the panel with the game's settings (once, at login).
local function Register()
    if category or not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then
        return
    end
    Create()
    category = Settings.RegisterCanvasLayoutCategory(panel, L["SETTINGS_TITLE"])
    Settings.RegisterAddOnCategory(category)
end

local function Open()
    if not (category and Settings and Settings.OpenToCategory and category.GetID) then
        Say(L["SETTINGS_NONE"])
        return
    end
    if InCombat() then
        openAfterCombat = true
        Say(L["SETTINGS_AFTER_COMBAT"])
        return
    end
    Settings.OpenToCategory(category:GetID())
end

-- /wowchar settings
function SettingsPanel.Open()
    if part.IsOff() then
        part.SayOff()
        return
    end
    part.Call(Open)
end

-- For the tests.
function SettingsPanel.Frame()
    return panel, widgets, category
end

local frame
part.OnFail(function()
    if frame then
        pcall(frame.UnregisterAllEvents, frame)
    end
end)

part.Call(function()
    frame = CreateFrame("Frame")
    frame:SetScript("OnEvent", part.Wrap(function(_, event)
        if event == "PLAYER_LOGIN" then
            Register()
        elseif event == "PLAYER_REGEN_ENABLED" and openAfterCombat then
            openAfterCombat = false
            Open()
        end
    end))
    pcall(frame.RegisterEvent, frame, "PLAYER_LOGIN")
    pcall(frame.RegisterEvent, frame, "PLAYER_REGEN_ENABLED")
end)
