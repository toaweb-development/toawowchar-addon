-- The words the addon shows the player, in English: the chat lines, the export window and its
-- messages (docs/wow-addon-rules.md, 9: user-facing text goes through a locale table). The other
-- files read them as L["KEY"]; a test checks that every key they use is here. Never put a word of
-- the export text here: the export is data for wowchar, not words for the player.
local _, ns = ...

local L = {}
ns.L = L

-- Chat (each line follows the "toawowchar:" label).
L["SAVED_BANK_AND_WARBANK"] = "saved the bank and the warband bank."
L["SAVED_WARBANK"] = "saved the warband bank."
L["SAVED_BANK"] = "saved the bank."
L["SAVED_RECIPES"] = "saved %d %s %s." -- count, profession name, RECIPE or RECIPES
L["PROFESSION"] = "profession"
L["RECIPE"] = "recipe"
L["RECIPES"] = "recipes"
L["SAVED_FLIGHT_PATHS"] = "saved %d %s." -- count, FLIGHT_PATH or FLIGHT_PATHS
L["FLIGHT_PATH"] = "flight path"
L["FLIGHT_PATHS"] = "flight paths"
L["RESET_DONE"] = "cleared the saved data of this character."
L["OPENS_AFTER_COMBAT"] = "in combat. The export window opens when combat ends."

-- A part that hit an error (Core.lua, Part): it is off until /reload; the export is not a part.
L["PART_OFF"] = "the %s hit an error and is turned off for this session: %s" -- PART_GUIDE or PART_WAYPOINT, the error
L["PART_IS_OFF"] = "the %s is turned off for this session after an error. /reload turns it on again."
L["PART_GUIDE"] = "guide"
L["PART_WAYPOINT"] = "waypoint"
L["PART_COLLECT"] = "quest data collection"
L["UNKNOWN_ERROR"] = "unknown error"

-- The export window.
L["EXPORT_TITLE"] = "wowchar export"
L["EXPORT_HEADER"] = "Export text (selected: press Ctrl+C to copy)"
L["PASTE_HINT"] = "Paste it on wowchar.toaweb.com > My characters"
L["SELECT_ALL"] = "Select all"
L["CLOSE"] = "Close"
L["LEVEL_N"] = "level %s"
L["SIZE_LINE"] = "%s characters (%.1f KB), format %d."

-- The checklist: one row per section, then its state.
L["ROW_EQUIPPED"] = "Equipped items"
L["ROW_BAGS"] = "Bags"
L["ROW_BANK"] = "Bank"
L["ROW_WARBANK"] = "Warband bank"
L["ROW_PROFESSIONS"] = "Professions"
L["ROW_RECIPES"] = "Recipes"
L["ROW_QUESTS_DONE"] = "Completed quests"
L["ROW_QUEST_LOG"] = "Quest log"
L["ROW_REPUTATION"] = "Reputation"
L["ROW_PLAYER"] = "Gold, level, XP"
L["ROW_TALENTS"] = "Talents"
L["ROW_LEGACY"] = "Legacy"
L["ROW_FLIGHT_PATHS"] = "Flight paths"
L["ROW_HONOR"] = "Honor rank (season)"
L["ROW_CLASS_SPELLS"] = "Class spells"
L["READ_NOW"] = "read now"
L["SAVED_AGO"] = "saved %s" -- one of the four below
L["JUST_NOW"] = "just now"
L["MIN_AGO"] = "%d min ago"
L["H_AGO"] = "%d h ago"
L["D_AGO"] = "%d d ago"

-- What to do about a missing section (the codes are REASONS in Core.lua).
L["WHY_OPEN_BANK"] = "open your bank"
L["WHY_OPEN_PROFESSION_WINDOW"] = "open a profession window"
L["WHY_OPEN_FLIGHT_MAP"] = "open a flight map"
L["WHY_NOT_LOADED"] = "not loaded yet, try again"
L["WHY_IN_COMBAT"] = "hidden in combat"
L["WHY_NOT_AVAILABLE"] = "not in this game version"
L["WHY_TOO_LARGE"] = "left out: text too long"

-- Messages under the export text.
L["NO_NAME"] = "Could not read the character's name."
L["EXPORT_FAILED"] = "The export could not be made."
L["TOO_LONG"] = "The export is longer than wowchar takes even without the extra sections."
L["LEFT_OUT"] = "Left out to keep it short: %s." -- the section names, ", " between them
L["LISTS_CUT"] = "Some lists were cut at their limit."

-- The leveling guide (Guide.lua, UI/GuideWindow.lua).
L["GUIDE_TITLE"] = "Leveling guide"
L["ROUTE_NAME"] = "%s route" -- the start (START_*)
L["STEP_COUNT"] = "%d / %d" -- step, steps
L["SKYBORNE_NOTE"] = "Unconfirmed start. Zephras Isle is our best guess until launch."
L["HELD"] = "(held: press Skip to go on)"
L["BACK"] = "Back"
L["SKIP"] = "Skip"
L["HIDE"] = "Hide"
L["NO_ROUTE"] = "There is no leveling route for this character's race yet."
L["ROUTE_DONE"] = "Route finished: it ends at level %d."
L["ZONE_LINE"] = "%s \194\183 %s" -- subzone, zone
L["LEVEL"] = "Level %d"
L["START_HUMAN"] = "Human"
L["START_DWARF_GNOME"] = "Dwarf and Gnome"
L["START_NIGHTELF"] = "Night Elf"
L["START_SKYBORNE_A"] = "High Order Skyborne"
L["START_ORC_TROLL"] = "Orc and Troll"
L["START_UNDEAD"] = "Undead"
L["START_TAUREN"] = "Tauren"
L["START_SKYBORNE_H"] = "Windshaper Skyborne"
L["KIND_ACCEPT"] = "ACCEPT"
L["KIND_OBJECTIVE"] = "OBJECTIVE"
L["KIND_TURNIN"] = "TURN IN"
L["KIND_TRAVEL"] = "TRAVEL"
L["KIND_GRIND"] = "GRIND"
L["STEP_TRAVEL"] = "Travel to the next zone"
L["STEP_GRIND"] = "Kill monsters until the next level"
L["NEXT_LINE"] = "%s \194\183 %s" -- quests, NPC or objective
L["OBJECTIVE_LINE"] = "\226\128\162 %s" -- the quest log's objective text ("Kobold Vermin slain: 4/10")
L["COORDS"] = "%.1f, %.1f"
L["YARDS"] = "%d yd"
L["TRAVEL_HINT"] = "The guide moves on when you arrive"
L["GRIND_XP"] = "About %s XP \194\183 or run a dungeon" -- the route's XP ("2,412")
L["GRIND_LEVEL"] = "Grind to level %d \194\183 or run a dungeon"
L["IN_COMBAT"] = "In combat: updates when combat ends"
L["LIST_AND"] = "%s and %s"
L["QUEST_N"] = "Quest %d"
