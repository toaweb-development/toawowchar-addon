local _, ns = ...

local L = ns.L

local FORMAT_VERSION = ns.FORMAT_VERSION
local UI = ns.UI
local Now = ns.Now

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
-- A frame made from Blizzard's own templates, no libraries:
--   BasicFrameTemplateWithInset   title bar, close button and the inset
--   InputScrollFrameTemplate      the scrolling text box (child .EditBox)
--   UIPanelButtonTemplate         the two buttons
-- Each is made inside pcall and has a fallback (a BackdropTemplate frame, a
-- UIPanelScrollFrameTemplate with an EditBox), so a client where a template is
-- missing or renamed still gets a working window. Size 620 x 470, centred, draggable
-- by any part of the frame, closed by Escape (UISpecialFrames, when the client has
-- it), Close and the title bar's X.
--
-- Layout (all offsets from the frame's edges, y downward):
--   title            the template's title text, "wowchar export", primary colour
--   character line   TOPLEFT 16,-34: name (accent), "level L Race Class - Realm"
--   divider          1 px line, primary at 60 percent, y -58
--   checklist        two columns from y -66, 18 px a row, 8 + 7 rows:
--                       <icon> <section>  <state in words>
--   export header    y -214: "Export text (selected: press Ctrl+C to copy)"
--   text box         TOPLEFT 16,-234, 568 x 130 (scrolls)
--   size line        BOTTOMLEFT 16,72: characters, KB, format, cut warnings
--   paste line       BOTTOMLEFT 16,54: "Paste it on wowchar.toaweb.com > My characters"
--   buttons          "Select all" BOTTOMLEFT 16,14; "Close" BOTTOMRIGHT -16,14; 110 x 24
-- Colours: background #131129, primary #8B7CFF (title, divider, "saved earlier"),
-- accent #5FD4E6 (name, "read now"), muted violet #9A97B8 for hints, soft red
-- #FF7A8A for what is missing.
-- The icons in the checklist are Blizzard's ready-check textures, drawn with |T..|t in
-- the window's text only (never in the export): Ready (read now), Waiting (saved
-- earlier), NotReady (missing). The state is also in words on every row, so a client
-- without those textures loses nothing.

local WINDOW_WIDTH, WINDOW_HEIGHT = 620, 470
local ICON_LIVE = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t"
local ICON_CACHE = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:14|t"
local ICON_MISSING = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t"
local COLOR_LIVE, COLOR_CACHE, COLOR_MISSING, COLOR_HINT = "ff5FD4E6", "ff8B7CFF", "ffFF7A8A", "ff9A97B8"

-- The rows of the checklist: section, label, column. Left column first.
local ROWS = {
    { "equipped", L["ROW_EQUIPPED"] },
    { "bags", L["ROW_BAGS"] },
    { "bank", L["ROW_BANK"] },
    { "warbank", L["ROW_WARBANK"] },
    { "professions", L["ROW_PROFESSIONS"] },
    { "recipes", L["ROW_RECIPES"] },
    { "questsDone", L["ROW_QUESTS_DONE"] },
    { "questLog", L["ROW_QUEST_LOG"] },
    { "reputation", L["ROW_REPUTATION"] },
    { "player", L["ROW_PLAYER"] },
    { "talents", L["ROW_TALENTS"] },
    { "legacy", L["ROW_LEGACY"] },
    { "flightPaths", L["ROW_FLIGHT_PATHS"] },
    { "honor", L["ROW_HONOR"] },
    { "classSpells", L["ROW_CLASS_SPELLS"] },
}

-- What to do about a missing section, in words (the codes are in REASONS).
local WHY_TEXT = {
    open_bank = L["WHY_OPEN_BANK"],
    open_profession_window = L["WHY_OPEN_PROFESSION_WINDOW"],
    open_flight_map = L["WHY_OPEN_FLIGHT_MAP"],
    not_loaded = L["WHY_NOT_LOADED"],
    in_combat = L["WHY_IN_COMBAT"],
    not_available = L["WHY_NOT_AVAILABLE"],
    too_large = L["WHY_TOO_LARGE"],
}

local function Ago(at)
    local seconds = Now() - at
    if seconds < 60 then
        return L["JUST_NOW"]
    elseif seconds < 3600 then
        return string.format(L["MIN_AGO"], math.floor(seconds / 60))
    elseif seconds < 86400 then
        return string.format(L["H_AGO"], math.floor(seconds / 3600))
    end
    return string.format(L["D_AGO"], math.floor(seconds / 86400))
end

local function Thousands(n)
    local text = string.format("%d", n)
    local out = text
    while true do
        local replaced
        out, replaced = out:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        if replaced == 0 then
            break
        end
    end
    return out
end

-- How much a section holds, for the checklist ("" when it has no count).
local function Detail(name, payload)
    local s = payload.sections[name]
    if s.source == "missing" then
        return ""
    end
    local count
    if name == "bank" then
        count = #payload.bank
    elseif name == "warbank" then
        count = #payload.warbank
    elseif name == "recipes" then
        count = 0
        for _, line in ipairs(s.lines) do
            count = count + #line.recipes
        end
    elseif name == "questsDone" or name == "flightPaths" or name == "classSpells" then
        count = #s.ids
    elseif name == "questLog" then
        count = #s.quests
    elseif name == "reputation" then
        count = #s.factions
    end
    if count then
        return " (" .. Thousands(count) .. ")"
    end
    return ""
end

-- The text of one checklist row.
local function RowText(name, label, payload)
    local s = payload.sections[name]
    local icon, color, state
    if s.source == "live" then
        icon, color, state = ICON_LIVE, COLOR_LIVE, L["READ_NOW"]
    elseif s.source == "cache" then
        icon, color, state = ICON_CACHE, COLOR_CACHE, string.format(L["SAVED_AGO"], Ago(s.at))
    else
        icon, color, state = ICON_MISSING, COLOR_MISSING, WHY_TEXT[s.why] or s.why
    end
    return icon .. " " .. label .. Detail(name, payload) .. "  |c" .. color .. state .. "|r"
end

local frame, editBox, currentText
local widgets = {}

-- The text box. InputScrollFrameTemplate (InputBoxTemplates.xml:72, child EditBox, key
-- value maxLetters = 0 for no limit) when the client has it; else the plain scroll
-- frame and edit box of 0.3.1.
local function CreateTextBox(parent)
    local ok, scroll = pcall(CreateFrame, "ScrollFrame", "toawowcharInput", parent, "InputScrollFrameTemplate")
    if ok and type(scroll) == "table" and type(scroll.EditBox) == "table" then
        scroll:SetPoint("TOPLEFT", 16, -234)
        scroll:SetSize(556, 130)
        if type(scroll.CharCount) == "table" then
            scroll.CharCount:Hide()
        end
        local box = scroll.EditBox
        box:SetWidth(530)
        box:SetMaxLetters(0)
        box:SetMaxBytes(0)
        return scroll, box, true
    end

    local plain = CreateFrame("ScrollFrame", "toawowcharScroll", parent, "UIPanelScrollFrameTemplate")
    plain:SetPoint("TOPLEFT", 16, -234)
    plain:SetSize(540, 130)
    local box = CreateFrame("EditBox", "toawowcharEditBox", plain)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject(ChatFontNormal)
    box:SetWidth(520)
    box:SetMaxLetters(0)
    box:SetMaxBytes(0)
    plain:SetScrollChild(box)
    return plain, box, false
end

function UI.Create()
    local templated = true
    local created, f = pcall(CreateFrame, "Frame", "toawowcharFrame", UIParent, "BasicFrameTemplateWithInset")
    if not created or type(f) ~= "table" then
        templated = false
        created, f = pcall(CreateFrame, "Frame", "toawowcharFrame", UIParent, "BackdropTemplate")
        if not created then
            f = CreateFrame("Frame", "toawowcharFrame", UIParent)
        end
        if f.SetBackdrop then
            f:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 32,
                insets = { left = 8, right = 8, top = 8, bottom = 8 },
            })
        end
    end
    f:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- Indigo (#131129) over the template's marble, inside its inset.
    local background = f:CreateTexture(nil, "BACKGROUND", nil, 3)
    background:SetColorTexture(0.0745, 0.0667, 0.1608, 1)
    if templated then
        background:SetPoint("TOPLEFT", 6, -26)
        background:SetPoint("BOTTOMRIGHT", -8, 6)
    else
        background:SetPoint("TOPLEFT", 10, -10)
        background:SetPoint("BOTTOMRIGHT", -10, 10)
    end

    -- Escape closes the window (when the client has the list; not verified on Forever).
    pcall(function()
        if type(UISpecialFrames) == "table" and tinsert then
            tinsert(UISpecialFrames, "toawowcharFrame")
        end
    end)

    local title = type(f.TitleText) == "table" and f.TitleText or nil
    if not title then
        title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -6)
    end
    title:SetText(L["EXPORT_TITLE"])
    title:SetTextColor(0.545, 0.486, 1)
    widgets.title = title

    local character = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
    character:SetPoint("TOPLEFT", 16, -34)
    character:SetPoint("TOPRIGHT", -16, -34)
    character:SetJustifyH("LEFT")
    widgets.character = character

    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.545, 0.486, 1, 0.6)
    divider:SetPoint("TOPLEFT", 16, -58)
    divider:SetPoint("TOPRIGHT", -16, -58)
    divider:SetHeight(1)

    widgets.rows = {}
    for i = 1, #ROWS do
        local text = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        local column = i <= 8 and 0 or 1
        local position = i <= 8 and i or i - 8
        text:SetPoint("TOPLEFT", 16 + column * 296, -66 - (position - 1) * 18)
        text:SetWidth(290)
        text:SetJustifyH("LEFT")
        widgets.rows[i] = text
    end

    local header = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("TOPLEFT", 16, -214)
    header:SetTextColor(0.373, 0.831, 0.902)
    header:SetText(L["EXPORT_HEADER"])
    widgets.header = header

    local _, edit = CreateTextBox(f)
    editBox = edit
    -- The text is for copying: typing in the box puts the original back. Hooked, not
    -- replaced, so the template's own scripts keep running.
    local function onChanged(self, userInput)
        if userInput and currentText and self:GetText() ~= currentText then
            self:SetText(currentText)
            self:HighlightText()
        end
    end
    local function onEscape(self)
        self:ClearFocus()
        f:Hide()
    end
    if edit.HookScript then
        edit:HookScript("OnTextChanged", onChanged)
        edit:HookScript("OnEscapePressed", onEscape)
    else
        edit:SetScript("OnTextChanged", onChanged)
        edit:SetScript("OnEscapePressed", onEscape)
    end

    local size = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    size:SetPoint("BOTTOMLEFT", 16, 72)
    size:SetPoint("BOTTOMRIGHT", -16, 72)
    size:SetJustifyH("LEFT")
    widgets.size = size

    local paste = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    paste:SetPoint("BOTTOMLEFT", 16, 54)
    paste:SetTextColor(0.545, 0.486, 1)
    paste:SetText(L["PASTE_HINT"])
    widgets.paste = paste

    local selectAll = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    selectAll:SetSize(110, 24)
    selectAll:SetPoint("BOTTOMLEFT", 16, 14)
    selectAll:SetText(L["SELECT_ALL"])
    selectAll:SetScript("OnClick", function()
        editBox:SetFocus()
        editBox:HighlightText()
    end)

    local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    close:SetSize(110, 24)
    close:SetPoint("BOTTOMRIGHT", -16, 14)
    close:SetText(L["CLOSE"])
    close:SetScript("OnClick", function()
        editBox:ClearFocus()
        f:Hide()
    end)

    -- However the window closes (Escape through UISpecialFrames, Close, or
    -- another addon), the box gives up the keyboard so typing reaches the game.
    f:SetScript("OnHide", function()
        editBox:ClearFocus()
    end)

    f:Hide()
    return f
end

-- Shows the window with the checklist and the export text, or with a message
-- (an error) and no text.
function UI.Show(text, payload, message)
    if not frame then
        frame = UI.Create()
    end
    currentText = text
    if payload then
        local line = "|cff5FD4E6" .. (ns.view.name or "?") .. "|r"
        local parts = {}
        if ns.view.level then parts[#parts + 1] = string.format(L["LEVEL_N"], ns.view.level) end
        if ns.view.race then parts[#parts + 1] = ns.view.race end
        if ns.view.class then parts[#parts + 1] = ns.view.class end
        if #parts > 0 then
            line = line .. "  " .. table.concat(parts, " ")
        end
        if ns.view.realm then
            line = line .. "  |c" .. COLOR_HINT .. "- " .. ns.view.realm .. "|r"
        end
        widgets.character:SetText(line)
        for i, row in ipairs(ROWS) do
            widgets.rows[i]:SetText(RowText(row[1], row[2], payload))
        end
    else
        widgets.character:SetText("")
        for i = 1, #ROWS do
            widgets.rows[i]:SetText("")
        end
    end

    local sizeText = message or ""
    if text then
        sizeText = string.format(L["SIZE_LINE"], Thousands(#text), #text / 1024, FORMAT_VERSION)
        if message then
            sizeText = sizeText .. " " .. message
        end
    end
    widgets.size:SetText("|c" .. COLOR_HINT .. sizeText .. "|r")

    editBox:SetText(text or "")
    frame:Show()
    if text then
        editBox:HighlightText()
        editBox:SetFocus()
    end
end
