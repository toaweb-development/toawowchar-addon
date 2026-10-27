-- luacheck for the addon (scripts/test.sh runs it in the image of test/Dockerfile; target: zero
-- warnings). The WoW client runs Lua 5.1. Not in the zip.
std = "lua51"
max_line_length = 150 -- the longest line today

-- The only globals the addon may write: its SavedVariables (the TOC's ## SavedVariables) and
-- the slash command.
globals = {
    "toawowcharDB",
    "SLASH_WOWCHAR1",
    "SLASH_WOWCHAR2",
    "SlashCmdList",
}

-- The game's API and constants the addon reads, exactly the ones its files use. A new
-- game call goes here in the same change (and is guarded in the Lua, AGENTS.md).
read_globals = {
    -- frames, chat and the UI
    "ChatFontNormal", "CreateColor", "CreateFrame", "DEFAULT_CHAT_FRAME", "GameTooltip",
    "InCombatLockdown", "UIParent", "UISpecialFrames",
    -- WoW's Lua aliases
    "time", "tinsert",
    -- the C_ namespaces
    "C_ClassColor", "C_ClassTalents", "C_Container", "C_GameRules", "C_MajorFactions", "C_Map", "C_Navigation", "C_QuestLog",
    "C_Reputation", "C_SpecializationInfo", "C_SpellBook", "C_SuperTrack", "C_TaxiMap", "C_Timer",
    "C_TradeSkillUI", "C_Traits",
    -- Blizzard's Lua objects (Blizzard_ObjectAPI)
    "UiMapPoint",
    -- tables of constants
    "Constants", "Enum",
    -- the player and the client
    "GetBuildInfo", "GetCVar", "GetCurrentRegion", "GetInventoryItemID", "GetInventoryItemLink",
    "GetMoney", "GetProfessionInfo", "GetProfessions", "GetRealmName", "GetTaxiMapID",
    "GetSubZoneText", "GetXPExhaustion", "GetZoneText", "issecretvalue",
    "UnitClass", "UnitFactionGroup", "UnitGUID", "UnitLevel", "UnitName", "UnitRace", "UnitXP",
    "UnitXPMax",
    -- global constants
    "BANK_CONTAINER", "NUM_BAG_SLOTS", "NUM_BANKBAGSLOTS", "PVP_RANK_POINTS_FACTION_ID", "RAID_CLASS_COLORS",
}

-- Generated data (scripts/fetch-routes.py): an objective note is one string on one line, up to
-- 4000 characters, so the line length is not checked there. Every other check still applies.
files["toawowchar/Data/Routes.lua"] = {
    max_line_length = false,
}
