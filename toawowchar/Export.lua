local _, ns = ...

local L = ns.L

local FORMAT_VERSION = ns.FORMAT_VERSION
local ADDON_VERSION = ns.ADDON_VERSION
local MAX_EXPORT_LENGTH = ns.MAX_EXPORT_LENGTH
local ADDON_BODY_MAX = ns.ADDON_BODY_MAX
local BODY_WRAPPER = ns.BODY_WRAPPER
local CAPS = ns.CAPS
local BOUNDS = ns.BOUNDS
local MAX_IDS = ns.MAX_IDS
local MAX_PROFESSIONS = ns.MAX_PROFESSIONS
local LAST_EQUIPMENT_SLOT = ns.LAST_EQUIPMENT_SLOT
local MAX_BONUS_IDS = ns.MAX_BONUS_IDS
local MAX_GEMS = ns.MAX_GEMS
local MAX_ID = ns.MAX_ID
local MAX_REAGENT_COUNT = ns.MAX_REAGENT_COUNT
local MAX_TRAIT_RANK = ns.MAX_TRAIT_RANK
local PVP_RANK_FACTION_ID = ns.PVP_RANK_FACTION_ID
local LEGACY_TREES = ns.LEGACY_TREES
local session = ns.session
local scan = ns.scan
local Cache = ns.Cache
local Read = ns.Read
local Capture = ns.Capture
local UI = ns.UI
local Int = ns.Int
local InRange = ns.InRange
local CleanTime = ns.CleanTime
local CountOrZero = ns.CountOrZero
local CleanText = ns.CleanText
local Fit = ns.Fit
local Now = ns.Now
local InCombat = ns.InCombat
local Say = ns.Say
local SortedKeys = ns.SortedKeys
local SameSet = ns.SameSet
local Live = ns.Live
local Cached = ns.Cached
local Missing = ns.Missing
local With = ns.With
local CleanCount = ns.CleanCount
local Points = ns.Points
local RealmName = ns.RealmName
local Encode = ns.Encode

---------------------------------------------------------------------------
-- Collecting
---------------------------------------------------------------------------

-- Adds an item id to a list once; stops at MAX_IDS.
local function AddId(list, seen, id)
    if type(id) ~= "number" or id <= 0 or seen[id] then
        return
    end
    if #list >= MAX_IDS then
        scan.truncated = true
        return
    end
    seen[id] = true
    list[#list + 1] = id
end

-- Adds the item ids of one container to a list. `last`, when given, is set to
-- the bag and slot of the last slot that held an item (the bank guard below
-- looks at it again). Returns false when the container cannot be read or has
-- no slots (a bank tab that was not bought has none).
local function ScanContainer(bag, list, seen, last)
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo) then
        return false
    end
    local numSlots = C_Container.GetContainerNumSlots(bag)
    if not numSlots or numSlots <= 0 then
        return false
    end
    for slot = 1, numSlots do
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then
            AddId(list, seen, info.itemID)
            if last then
                last.bag, last.slot = bag, slot
            end
        end
    end
    return true
end

---------------------------------------------------------------------------
-- Item strings
---------------------------------------------------------------------------

-- A whole number from 0 to MAX_ID, or nil. Item strings are text between colons;
-- an empty or odd field is "no value".
local function ToId(text)
    local n = tonumber(text)
    if n and n == math.floor(n) and n >= 0 and n <= MAX_ID then
        return n
    end
    return nil
end

-- Reads the numbers out of an item link by fixed position, like the item link
-- layout on warcraft.wiki.gg/wiki/ItemLink: after "item:" come
--   1 item id, 2 enchant id, 3-6 gem ids, 7 suffix id (negative for a random
--   suffix, written here as its absolute value), 8 unique id, 9 level,
--   10 spec, 11 flags, 12 context, 13 number of bonus ids, then that many ids.
-- Only digits, "-" and ":" are taken from the link (the pattern below), so
-- nothing else in the text, such as the item name, is ever read.
-- Returns a table { itemId, enchantId, suffixId, gemIds, bonusIds }, or nil when
-- there is no valid item id. Missing or odd fields count as 0 or are left out;
-- a short item string gives short results. Never raises.
local function ParseItemString(link)
    if type(link) ~= "string" then
        return nil
    end
    local str = link:match("|Hitem:([%-%d:]+)")
    if not str then
        return nil
    end
    -- Split on ":" keeping empty fields, so the positions stay right.
    local parts = {}
    local pos = 1
    while true do
        local colon = str:find(":", pos, true)
        if not colon then
            parts[#parts + 1] = str:sub(pos)
            break
        end
        parts[#parts + 1] = str:sub(pos, colon - 1)
        pos = colon + 1
    end

    local itemId = ToId(parts[1])
    if not itemId or itemId <= 0 then
        return nil
    end

    local gemIds = {}
    for i = 3, 6 do
        local gem = ToId(parts[i])
        if gem and gem > 0 and #gemIds < MAX_GEMS then
            gemIds[#gemIds + 1] = gem
        end
    end

    local suffix = tonumber(parts[7])
    suffix = suffix and ToId(math.abs(suffix)) or 0

    local bonusIds = {}
    local count = tonumber(parts[13])
    if count and count == math.floor(count) and count > 0 then
        local last = math.min(13 + count, #parts)
        for i = 14, last do
            local bonus = ToId(parts[i])
            if bonus and bonus > 0 and #bonusIds < MAX_BONUS_IDS then
                bonusIds[#bonusIds + 1] = bonus
            end
        end
    end

    return {
        itemId = itemId,
        enchantId = ToId(parts[2]) or 0,
        suffixId = suffix,
        gemIds = gemIds,
        bonusIds = bonusIds,
    }
end

local function CollectEquipped()
    local equipped = {}
    for slot = 1, LAST_EQUIPMENT_SLOT do
        -- An id the server would refuse leaves the slot out.
        local apiId = InRange(GetInventoryItemID("player", slot), 1, MAX_ID)
        if apiId and #equipped < MAX_IDS then
            -- The numbers come from the item string; the API id stands in when the
            -- client has no link yet (the item is not cached).
            local parsed = ParseItemString(GetInventoryItemLink("player", slot))
            if parsed then
                equipped[#equipped + 1] = {
                    slot = slot,
                    itemId = parsed.itemId,
                    enchantId = parsed.enchantId,
                    gemIds = parsed.gemIds,
                    suffixId = parsed.suffixId,
                    bonusIds = parsed.bonusIds,
                }
            else
                equipped[#equipped + 1] = {
                    slot = slot,
                    itemId = apiId,
                    enchantId = 0,
                    gemIds = {},
                    suffixId = 0,
                    bonusIds = {},
                }
            end
        end
    end
    return equipped
end

local function CollectBags()
    local list, seen = {}, {}
    -- Backpack (0), the four bag slots (1-4), and the reagent bag (5) if it has slots.
    for bag = 0, 5 do
        ScanContainer(bag, list, seen)
    end
    return list
end

---------------------------------------------------------------------------
-- The bank
---------------------------------------------------------------------------

-- The bank guard. A bank scan only counts if the bank was still open when it
-- ended: the last slot that had an item must still show an item, and the bank
-- must not have been closed (BANKFRAME_CLOSED). When the bank closes during a
-- scan, the game returns nothing for its slots, so the scan would be partial
-- and must not replace the list from the last full scan.
local function BankStillOpen(last)
    if not session.bankOpen or not last.bag then
        return false
    end
    if C_Container.GetContainerItemLink then
        local ok, link = pcall(C_Container.GetContainerItemLink, last.bag, last.slot)
        return ok and link ~= nil
    end
    local ok, info = pcall(C_Container.GetContainerItemInfo, last.bag, last.slot)
    return ok and info ~= nil
end

-- Reads the bank and the warband bank. Only works while the bank is open, so it
-- runs on BANKFRAME_OPENED (and when bags change while it is open) and the
-- result is kept in the cache record (and so in SavedVariables).
--
-- Two kinds of character bank exist in the client's code, and which one World of
-- Warcraft: Forever uses is not known until launch
-- (docs/forever-addon-research.md Q2, launch checklist items 8 and 9):
--   "tabs"    the character bank tabs, Enum.BagIndex.CharacterBankTab_1..9
--   "classic" the older bank: the main bank container plus the bank bags
-- The tabs are tried first. Only when none of them can be read does the classic
-- bank get a turn. The export says which one it was (bankSource), so the first
-- real export shows which path ran. Every global and enum below may be missing;
-- a missing one is skipped, never an error.
--
-- The warband bank is Enum.BagIndex.AccountBankTab_1, _2, ... up to the first
-- one that does not exist. It goes in its own list (warbank) with the same
-- guard. A tab with no slots gives nothing.
--
-- A scan that found no item at all replaces nothing (there is no slot to check
-- the bank against), so the previous list and its "seen" flag stay.
local function ScanBank()
    local previous = scan.truncated

    -- Character bank.
    scan.truncated = false
    local list, seen, last = {}, {}, {}
    local source = nil

    if Enum and Enum.BagIndex then
        for tab = 1, 9 do
            local bag = Enum.BagIndex["CharacterBankTab_" .. tab]
            if bag ~= nil and ScanContainer(bag, list, seen, last) then
                source = "tabs"
            end
        end
    end

    if not source then
        -- The main bank container: the enum value if there is one, else the global.
        local main = Enum and Enum.BagIndex and Enum.BagIndex.Bank
        if main == nil then
            main = BANK_CONTAINER
        end
        if type(main) == "number" and ScanContainer(main, list, seen, last) then
            source = "classic"
        end
        -- The bank bag slots come right after the player's own bag slots.
        if type(NUM_BAG_SLOTS) == "number" and type(NUM_BANKBAGSLOTS) == "number" then
            for bag = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do
                if ScanContainer(bag, list, seen, last) then
                    source = "classic"
                end
            end
        end
    end
    local cut = scan.truncated

    -- Warband bank.
    scan.truncated = false
    local wlist, wseen, wlast = {}, {}, {}
    local wsource = false
    if Enum and Enum.BagIndex and Enum.BagIndex.AccountBankTab_1 ~= nil then
        for tab = 1, 50 do
            local bag = Enum.BagIndex["AccountBankTab_" .. tab]
            if bag == nil then
                break
            end
            if ScanContainer(bag, wlist, wseen, wlast) then
                wsource = true
            end
        end
    end
    local wcut = scan.truncated
    scan.truncated = previous

    -- Nothing readable, or the bank closed during the scan: keep what was there.
    local rec = Cache.Get()
    local now = Now()
    if source and BankStillOpen(last) then
        table.sort(list)
        if not rec.bank or not SameSet(rec.bank.items, list) then
            session.bankDirty = true
        end
        rec.bank = { at = now, source = source, items = list, cut = cut }
        session.live.bank = now
    end
    if wsource and BankStillOpen(wlast) then
        table.sort(wlist)
        if not rec.warbank or not SameSet(rec.warbank.items, wlist) then
            session.warbankDirty = true
        end
        rec.warbank = { at = now, items = wlist, cut = wcut }
        session.live.warbank = now
    end
end

---------------------------------------------------------------------------
-- Professions, spec, region, race, faction
---------------------------------------------------------------------------

-- The professions: name, skill line, rank and max rank. Second result: false when
-- the game has no such function (the section is then missing).
local function CollectProfessions()
    local result = {}
    if not (GetProfessions and GetProfessionInfo) then
        return result, false
    end
    -- GetProfessions returns up to six indexes and nil for an empty slot, so
    -- they go in a table and are read by position, not with #. The skill line is
    -- the 7th return of GetProfessionInfo, proven in Forever's own UI
    -- (Blizzard_Professions/Camelot/Blizzard_ProfessionsFrame.lua:16 and :60). The
    -- ids 2937-2948 the owner mentioned (First Aid = 2942) have no source: no table
    -- of ids and names is kept here, the game's own name and id are sent.
    local indexes = { GetProfessions() }
    for position = 1, 6 do
        local index = indexes[position]
        if index and #result < MAX_PROFESSIONS then
            local rawName, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(index)
            -- A name the server would refuse leaves the profession out; the three numbers
            -- are optional, so one outside its bound is only left out of the row.
            local name = Fit(rawName, BOUNDS.professionName)
            if name then
                result[#result + 1] = {
                    name = name,
                    skillLineId = InRange(skillLine, 0, BOUNDS.count),
                    rank = InRange(rank, 0, BOUNDS.count),
                    maxRank = InRange(maxRank, 0, BOUNDS.count),
                }
            end
        end
    end
    return result, true
end

local function CollectSpec()
    local specId, specName
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization and C_SpecializationInfo.GetSpecializationInfo then
        pcall(function()
            local index = C_SpecializationInfo.GetSpecialization()
            if index then
                specId, specName = C_SpecializationInfo.GetSpecializationInfo(index)
            end
        end)
    end
    return specId, specName
end

-- GetCurrentRegion() numbers the five regions; anything else is not one of them.
local REGION_NAMES = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN" }

-- Returns region (a name from REGION_NAMES or nil), regionId (the number the
-- client reported, only when it is not one of the five) and portal (a string or
-- nil). Never raises.
local function CollectRegion()
    local id
    if GetCurrentRegion then
        local ok, value = pcall(GetCurrentRegion)
        if ok and type(value) == "number" then
            id = value
        end
    end
    local region = id and REGION_NAMES[id] or nil

    local portal
    if GetCVar then
        local ok, value = pcall(GetCVar, "portal")
        if ok then
            portal = Fit(value, BOUNDS.portal)
        end
    end

    if region then
        return region, nil, nil
    end
    return nil, InRange(id, 0, BOUNDS.count), portal
end

local function CollectRealm()
    return RealmName()
end

-- A string from a game function, or nil when the function is missing, raises, or
-- returns anything but a non-empty string. `index` picks which return value.
local function StringResult(fn, index)
    if not fn then
        return nil
    end
    local results = { pcall(fn, "player") }
    local value = results[index + 1] -- results[1] is pcall's own flag
    if results[1] and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

-- The race file token ("NightElf"), not the localized name: it does not change
-- with the client's language.
local function CollectRace()
    return StringResult(UnitRace, 2)
end

local function CollectFaction()
    return StringResult(UnitFactionGroup, 1)
end

local function IsHardcore()
    if C_GameRules and C_GameRules.IsHardcoreActive then
        local ok, value = pcall(C_GameRules.IsHardcoreActive)
        return ok and value and true or false
    end
    return false
end

---------------------------------------------------------------------------
-- Section readers
---------------------------------------------------------------------------
-- Each reader returns one section table: its source marker plus its data keys, or
-- Missing(reason). They run inside pcall (see Section), so a function the game
-- lacks, or one that raises, makes that section missing/not_available and never
-- stops the export. A reader that met a hidden (secret) value gives
-- missing/in_combat.

local function Section(reader, ...)
    scan.secretSeen = false
    local ok, section = pcall(reader, ...)
    if not ok or type(section) ~= "table" then
        return Missing("not_available")
    end
    if scan.secretSeen then
        return Missing("in_combat")
    end
    return section
end

-- Money, level, XP, XP max and rested XP.
-- UnitLevel, UnitXP and UnitXPMax carry no SecretReturns flag (UnitDocumentation.lua
-- :2474, :3474, :3489). GetMoney and GetXPExhaustion have no documentation entry;
-- Blizzard's own UI calls GetXPExhaustion (Blizzard_StatusTrackingBar/Shared/ExpBar.lua:128,
-- nil when the character is not rested). Every value goes through Int(), which also
-- turns a hidden value into "in_combat" when the game has issecretvalue.
function Read.Player()
    local section = Live(nil)
    local any = false
    local function put(key, fn, min, max, ...)
        if fn then
            local ok, value = pcall(fn, ...)
            value = ok and Int(value) or nil
            if value and value >= min and value <= max then
                section[key] = value
                any = true
            end
        end
    end
    put("money", GetMoney, 0, BOUNDS.money)
    put("level", UnitLevel, 1, BOUNDS.level, "player")
    put("xp", UnitXP, 0, BOUNDS.counter, "player")
    put("xpMax", UnitXPMax, 0, BOUNDS.counter, "player")
    if GetXPExhaustion then
        local ok, value = pcall(GetXPExhaustion)
        if ok then
            -- nil means "not rested". A value outside the bound is left out.
            section.rested = InRange(value or 0, 0, BOUNDS.counter)
        end
    end
    if not any then
        return Missing("not_available")
    end
    return section
end

-- The completed quest ids: the union of the game's list and the cache.
-- C_QuestLog.GetAllCompletedQuestIDs() -> number[] (QuestLogDocumentation.lua:116);
-- no event says when it is ready, and it may be EMPTY just after login. Completed
-- quests only ever grow, so an empty or short answer never removes anything: the
-- cache keeps every id ever seen, and with no cache an empty answer is
-- missing/not_loaded, never "no quests done".
function Read.QuestsDone(rec, now)
    local fn = C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs
    local live
    if fn then
        local ok, list = pcall(fn)
        if ok and type(list) == "table" then
            live = list
        end
    end
    if live then
        local set = {}
        if rec.quests then
            for _, id in ipairs(rec.quests.ids) do
                set[id] = true
            end
        end
        local fresh, looked = 0, 0
        for _, value in pairs(live) do
            looked = looked + 1
            if looked > CAPS.questsDone * 4 then
                break
            end
            local id = Int(value)
            if id and id >= 1 and id <= MAX_ID then
                fresh = fresh + 1
                set[id] = true
            end
        end
        if fresh > 0 then
            local ids, cut = SortedKeys(set, CAPS.questsDone)
            rec.quests = { at = now, ids = ids, cut = cut or (rec.quests and rec.quests.cut) or false }
            session.live.questsDone = now
        end
    end
    if session.live.questsDone and rec.quests then
        if rec.quests.cut then
            scan.cutSections = true
        end
        return With(Live(session.live.questsDone), { ids = rec.quests.ids })
    end
    if rec.quests then
        if rec.quests.cut then
            scan.cutSections = true
        end
        return With(Cached(rec.quests.at), { ids = rec.quests.ids })
    end
    if not fn then
        return Missing("not_available")
    end
    return Missing("not_loaded")
end

-- The quest log: each quest's id, whether all its objectives are done, and its
-- objectives (text, have, need, done).
-- C_QuestLog.GetNumQuestLogEntries() -> numShownEntries, numQuests (:303);
-- GetInfo(index) -> QuestInfo (:191, struct :1547); GetQuestObjectives(questID)
-- -> {text, type, finished, numFulfilled, numRequired}[] (:477, struct :1581,
-- MayReturnNothing); IsComplete(questID) (:734).
-- Collapsed zone headers hide their quests from the numbered entries. The addon
-- does NOT expand them (that would change the player's quest log window): it counts
-- the quests it could see and sends `hidden`, the number of quests the log has
-- that it could not list. Hidden, task and world quests rows are not listed.
function Read.QuestLog()
    local Q = C_QuestLog
    if not (Q and Q.GetNumQuestLogEntries and Q.GetInfo and Q.GetQuestObjectives) then
        return Missing("not_available")
    end
    local shown, total = Q.GetNumQuestLogEntries()
    shown = Int(shown)
    if not shown then
        return Missing("not_loaded")
    end
    total = Int(total)
    local quests, seen, looked = {}, 0, 0
    for index = 1, shown do
        local info = Q.GetInfo(index)
        if type(info) == "table" and not info.isHeader then
            seen = seen + 1
            local id = Int(info.questID)
            if id and id >= 1 and id <= MAX_ID and not info.isHidden and not info.isTask then
                looked = looked + 1
                if #quests >= CAPS.questLog then
                    scan.cutSections = true
                else
                    local objectives = {}
                    local ok, list = pcall(Q.GetQuestObjectives, id)
                    if ok and type(list) == "table" then
                        for _, objective in ipairs(list) do
                            if #objectives >= CAPS.objectivesPerQuest then
                                scan.cutSections = true
                                break
                            end
                            if type(objective) == "table" then
                                -- A count outside 0..BOUNDS.counter leaves that objective out.
                                local have = CountOrZero(objective.numFulfilled, BOUNDS.counter)
                                local need = CountOrZero(objective.numRequired, BOUNDS.counter)
                                if have and need then
                                    objectives[#objectives + 1] = {
                                        text = CleanText(objective.text, CAPS.objectiveText) or "",
                                        have = have,
                                        need = need,
                                        done = objective.finished and true or false,
                                    }
                                end
                            end
                        end
                    end
                    local complete = false
                    if Q.IsComplete then
                        local okc, value = pcall(Q.IsComplete, id)
                        complete = okc and value and true or false
                    end
                    quests[#quests + 1] = { id = id, done = complete, objectives = objectives }
                end
            end
        end
    end
    local hidden = 0
    if total and total > seen then
        hidden = math.min(total - seen, BOUNDS.hiddenQuests)
    end
    return With(Live(nil), { quests = quests, hidden = hidden })
end

-- Reputation: faction id, reaction, standing, where the reaction starts, where the
-- next one starts, name. C_Reputation.GetNumFactions() (ReputationInfoDocumentation.lua:117),
-- GetFactionDataByIndex(i) -> FactionData (:63, struct :341-361: factionID, name,
-- reaction, currentStanding, currentReactionThreshold, nextReactionThreshold,
-- isHeader, isHeaderWithRep, isCollapsed). Rows under a collapsed header are not
-- listed, so when the game has both ExpandAllFactionHeaders and CollapseFactionHeader
-- the headers are opened for the read and the ones the player had collapsed are
-- collapsed again afterwards (from the bottom up, so indexes stay right). Headers
-- that sat inside a collapsed header are not known to have been collapsed and stay
-- open. Without both functions nothing is touched and the rows that are visible
-- are read.
function Read.Reputation()
    local R = C_Reputation
    if not (R and R.GetNumFactions and R.GetFactionDataByIndex) then
        return Missing("not_available")
    end

    local function rows()
        local count = Int(R.GetNumFactions()) or 0
        local list = {}
        for index = 1, count do
            local data = R.GetFactionDataByIndex(index)
            if type(data) == "table" then
                list[#list + 1] = { index = index, data = data }
            end
        end
        return list
    end

    local first = rows()
    local collapsed, anyCollapsed = {}, false
    for _, row in ipairs(first) do
        local id = Int(row.data.factionID)
        if row.data.isHeader and row.data.isCollapsed and id then
            collapsed[id] = true
            anyCollapsed = true
        end
    end

    local list = first
    local expanded = false
    if anyCollapsed and R.ExpandAllFactionHeaders and R.CollapseFactionHeader then
        expanded = true
        pcall(R.ExpandAllFactionHeaders)
        local ok, all = pcall(rows)
        if ok then
            list = all
        end
    end

    local out, seen = {}, {}
    for _, row in ipairs(list) do
        local d = row.data
        local id = Int(d.factionID)
        if id and id >= 1 and id <= MAX_ID and not seen[id] and (not d.isHeader or d.isHeaderWithRep) then
            local reaction = Int(d.reaction)
            local standing = Int(d.currentStanding)
            local floor = Int(d.currentReactionThreshold)
            local ceiling = Int(d.nextReactionThreshold)
            local name = CleanText(d.name, CAPS.nameText)
            -- A row with a value outside the server's bounds is left out (and not counted).
            if reaction and standing and floor and ceiling and name and name ~= ""
                and reaction >= 0 and reaction <= BOUNDS.reaction
                and standing >= -BOUNDS.counter and standing <= BOUNDS.counter
                and floor >= -BOUNDS.counter and floor <= BOUNDS.counter
                and ceiling >= -BOUNDS.counter and ceiling <= BOUNDS.counter then
                if #out >= CAPS.factions then
                    scan.cutSections = true
                else
                    seen[id] = true
                    out[#out + 1] = { id, reaction, standing, floor, ceiling, name }
                end
            end
        end
    end

    if expanded then
        for position = #list, 1, -1 do
            local id = Int(list[position].data.factionID)
            if id and collapsed[id] and list[position].data.isHeader then
                pcall(R.CollapseFactionHeader, list[position].index)
            end
        end
    end

    if #out == 0 then
        return Missing("not_loaded")
    end
    return With(Live(nil), { factions = out })
end

-- Trait nodes the character has ranks in: { {node, rank, entry}, ... }.
-- C_Traits.GetTreeNodes(treeID) -> nodeID[] (SharedTraitsDocumentation.lua:586,
-- it lists the nodes of ALL specs, so only nodes with activeRank > 0 are kept);
-- C_Traits.GetNodeInfo(configID, nodeID) -> TraitNodeInfo (:370-385, struct
-- :1093: activeRank, activeEntry = TraitEntryRankInfo { entryID, rank } or nil).
local function TreeNodes(configID, treeID)
    local nodes = {}
    local ok, ids = pcall(C_Traits.GetTreeNodes, treeID)
    if not ok or type(ids) ~= "table" then
        return nodes
    end
    local looked = 0
    for _, nodeId in ipairs(ids) do
        looked = looked + 1
        if looked > 4000 then
            break
        end
        local okInfo, info = pcall(C_Traits.GetNodeInfo, configID, nodeId)
        if okInfo and type(info) == "table" then
            local rank = Int(info.activeRank)
            local node = Int(nodeId)
            if node and node >= 1 and node <= MAX_ID and rank and rank > 0 then
                -- The entry is 0 when the node has none; a rank or an entry outside the
                -- bounds leaves the node out.
                local entry = 0
                if type(info.activeEntry) == "table" then
                    entry = CountOrZero(info.activeEntry.entryID, MAX_ID)
                end
                if rank <= MAX_TRAIT_RANK and entry then
                    if #nodes >= CAPS.nodesPerTree then
                        scan.cutSections = true
                        break
                    end
                    nodes[#nodes + 1] = { node, rank, entry }
                end
            end
        end
    end
    return nodes
end

-- Talents: C_ClassTalents.GetActiveConfigID() (nilable; ClassTalentsDocumentation.lua:73)
-- -> C_Traits.GetConfigInfo(configID).treeIDs (SharedTraitsDocumentation.lua:201-216)
-- -> the nodes of each tree. C_TraitConfig is an empty namespace and is not used.
function Read.Talents()
    if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GetConfigInfo
        and C_Traits.GetTreeNodes and C_Traits.GetNodeInfo) then
        return Missing("not_available")
    end
    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then
        return Missing("not_loaded")
    end
    local info = C_Traits.GetConfigInfo(configID)
    if type(info) ~= "table" or type(info.treeIDs) ~= "table" then
        return Missing("not_loaded")
    end
    local trees = {}
    for _, treeId in ipairs(info.treeIDs) do
        local tree = Int(treeId)
        if tree and tree >= 1 and tree <= MAX_ID then
            if #trees >= CAPS.talentTrees then
                scan.cutSections = true
                break
            end
            trees[#trees + 1] = { tree = tree, nodes = TreeNodes(configID, tree) }
        end
    end
    if #trees == 0 then
        return Missing("not_loaded")
    end
    return With(Live(nil), { trees = trees })
end

-- Legacy: points available / cap / spent and the ranks in the three trees.
-- configID = C_Traits.GetConfigIDByTreeID(tree) (MayReturnNothing; Blizzard_LegacySystem/
-- Blizzard_LegacySystemUtil.lua:43); C_Traits.GetTreeCurrencyInfo(configID, tree, false)[1]
-- -> quantity (available), maxQuantity (cap, nilable), spent, spentInTree (SharedTraitsDocumentation.lua:537,
-- struct :1188; the UI reads tree 1187 as the shared pool, Blizzard_LegacySystemUtil.lua:41-60).
-- Whether Legacy is account-wide is not proven in the source, so it is cached per
-- character like the rest. The challenges are achievements, listed only through the
-- achievement UI's filtered view (Blizzard_LegacyChallenges.lua:85, 285-309, async,
-- "wait for ACHIEVEMENT_SEARCH_UPDATED") and no root category id is in the source,
-- so there is no reliable list: the challenges are always missing/not_available in
-- 0.4.0.
function Read.Legacy(rec, now)
    local function fromCache()
        if rec.legacy then
            return With(Cached(rec.legacy.at), {
                points = rec.legacy.points,
                trees = rec.legacy.trees,
                challenges = Missing("not_available"),
            })
        end
        return nil
    end

    if not (C_Traits and C_Traits.GetConfigIDByTreeID and C_Traits.GetTreeNodes and C_Traits.GetNodeInfo) then
        return fromCache() or Missing("not_available")
    end

    local consts = Constants and Constants.LegacyConsts
    local ids = {
        consts and consts.LEGACY_TREE_PROFESSIONS_ID or LEGACY_TREES[1],
        consts and consts.LEGACY_TREE_ADVENTURE_ID or LEGACY_TREES[2],
        consts and consts.LEGACY_TREE_PROGRESSION_ID or LEGACY_TREES[3],
    }

    local trees, points = {}, nil
    for _, treeId in ipairs(ids) do
        local tree = Int(treeId)
        local okConfig, configID = pcall(C_Traits.GetConfigIDByTreeID, treeId)
        if tree and okConfig and configID and #trees < CAPS.legacyTrees then
            local spentInTree = 0
            if C_Traits.GetTreeCurrencyInfo then
                local okCurrency, currency = pcall(C_Traits.GetTreeCurrencyInfo, configID, treeId, false)
                local first = okCurrency and type(currency) == "table" and currency[1] or nil
                if type(first) == "table" then
                    -- Points outside the bound are left out of `points` (each is optional);
                    -- a tree whose own count is outside it is left out.
                    spentInTree = CountOrZero(first.spentInTree, BOUNDS.counter)
                    if not points then
                        points = Points(CleanCount(first.quantity), CleanCount(first.maxQuantity), CleanCount(first.spent))
                    end
                end
            end
            if spentInTree then
                trees[#trees + 1] = { tree = tree, spent = spentInTree, nodes = TreeNodes(configID, treeId) }
            end
        end
    end

    if #trees == 0 then
        -- Not loaded yet (no config for any tree): the last good read, if any.
        return fromCache() or Missing("not_loaded")
    end
    rec.legacy = { at = now, points = points, trees = trees }
    session.live.legacy = now
    return With(Live(now), { points = points, trees = trees, challenges = Missing("not_available") })
end

-- The season's PvP rank. Forever has no Classic honor rank (UnitPVPRank and
-- GetPVPRankInfo are not in its API); its PvP rank is the renown level of major
-- faction 2800 (Camelot/PVPRankFrame.lua:1, :91), per season, 0 = unranked.
-- C_MajorFactions.GetMajorFactionProgressionInfo(2800) -> renownLevel, maxLevel
-- (MajorFactionsDocumentation.lua:56, struct :287-297). There is no "highest ever"
-- value, so the keys say "season".
function Read.Honor()
    if not (C_MajorFactions and C_MajorFactions.GetMajorFactionProgressionInfo) then
        return Missing("not_available")
    end
    local factionId = type(PVP_RANK_POINTS_FACTION_ID) == "number" and PVP_RANK_POINTS_FACTION_ID or PVP_RANK_FACTION_ID
    local data = C_MajorFactions.GetMajorFactionProgressionInfo(factionId)
    if type(data) ~= "table" then
        return Missing("not_loaded")
    end
    local rank = Int(data.renownLevel)
    if not rank or rank < 0 or rank > BOUNDS.honorRank then
        return Missing("not_available")
    end
    -- The season's maximum is optional: outside the bound it is left out.
    local maxRank = InRange(data.maxLevel, 0, BOUNDS.honorRank)
    return With(Live(nil), { seasonRank = rank, seasonMax = maxRank })
end

-- The spells the class knows, from the spell book (not the trainer window, which
-- only lists what that trainer teaches). C_SpellBook.GetNumSpellBookSkillLines()
-- (SpellBookDocumentation.lua:137), GetSpellBookSkillLineInfo(i) (:486, struct
-- :1028: name, itemIndexOffset, numSpellBookItems, isGuild, shouldHide),
-- GetSpellBookItemInfo(slot, Enum.SpellBookSpellBank.Player) (:290, struct :1012:
-- spellID, actionID, itemType, isOffSpec). Skipped: guild and hidden lines, lines
-- named like a profession the character has (profession spells), off-spec items,
-- anything that is not a spell (flyouts, future spells) and entries without a
-- spellID. The id sent is the spellID.
function Read.ClassSpells(professionNames)
    local B = C_SpellBook
    if not (B and B.GetNumSpellBookSkillLines and B.GetSpellBookSkillLineInfo and B.GetSpellBookItemInfo) then
        return Missing("not_available")
    end
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
    local lines = Int(B.GetNumSpellBookSkillLines())
    if not lines or lines < 1 then
        return Missing("not_loaded")
    end
    local set, count = {}, 0
    for line = 1, lines do
        local info = B.GetSpellBookSkillLineInfo(line)
        if type(info) == "table" and not info.isGuild and not info.shouldHide and not professionNames[info.name or ""] then
            local offset = Int(info.itemIndexOffset) or 0
            local number = Int(info.numSpellBookItems) or 0
            for slot = offset + 1, offset + math.min(number, 1000) do
                local item = B.GetSpellBookItemInfo(slot, bank)
                if type(item) == "table" and not item.isOffSpec and (spellType == nil or item.itemType == spellType) then
                    local id = Int(item.spellID)
                    if id and id >= 1 and id <= MAX_ID and not set[id] then
                        count = count + 1
                        if count > CAPS.classSpells then
                            scan.cutSections = true
                        else
                            set[id] = true
                        end
                    end
                end
            end
        end
    end
    if count == 0 then
        return Missing("not_loaded")
    end
    local list = SortedKeys(set, CAPS.classSpells)
    return With(Live(nil), { ids = list })
end

-- The recipes of every profession read so far (cache record + this session).
-- Live when a profession window was read in this play session, cache otherwise,
-- missing/open_profession_window when none ever was. Each profession carries the
-- time its recipes were last read.
function Read.Recipes(rec)
    local lines = {}
    local newest = 0
    for line, entry in pairs(rec.recipes) do
        -- A profession whose read time the server would refuse is left out.
        if CleanTime(entry.at) then
            local recipes = {}
            for id, reagents in pairs(entry.recipes) do
                recipes[#recipes + 1] = { id, reagents }
            end
            table.sort(recipes, function(a, b) return a[1] < b[1] end)
            lines[#lines + 1] = { line = line, name = entry.name, at = entry.at, recipes = recipes }
            if entry.at > newest then
                newest = entry.at
            end
            if entry.cut then
                scan.cutSections = true
            end
        end
    end
    if #lines == 0 then
        local T = C_TradeSkillUI
        if not (T and T.GetRecipeSchematic) then
            return Missing("not_available")
        end
        return Missing("open_profession_window")
    end
    table.sort(lines, function(a, b) return a.line < b.line end)
    if session.live.recipes then
        return With(Live(session.live.recipes), { lines = lines })
    end
    return With(Cached(newest), { lines = lines })
end

function Read.FlightPaths(rec)
    if not rec.flights then
        if not (C_TaxiMap and (C_TaxiMap.GetAllTaxiNodes or C_TaxiMap.GetTaxiNodesForMap)) then
            return Missing("not_available")
        end
        return Missing("open_flight_map")
    end
    if session.live.flights then
        return With(Live(session.live.flights), { ids = rec.flights.ids })
    end
    return With(Cached(rec.flights.at), { ids = rec.flights.ids })
end

---------------------------------------------------------------------------
-- Captures: what the game only lets the addon read while a window is open. They
-- run on events, do nothing in combat, never print more than one line and put
-- what they read in the cache record (merged, never replaced).
---------------------------------------------------------------------------

local function Plural(count, one, many)
    return count == 1 and one or many
end

-- Recipes and reagents of the profession whose window is open.
-- C_TradeSkillUI.GetBaseProfessionInfo() -> ProfessionInfo (TradeSkillUIDocumentation.lua:130;
-- the UI takes parentProfessionID or professionID as the skill line,
-- Blizzard_Professions/ProfessionsTemplates/Blizzard_Professions.lua:1678-1681);
-- GetAllRecipeIDs() exists only in the community API list (the generated docs do not
-- have it), so GetFilteredRecipeIDs() (used at Blizzard_Professions.lua:847; it follows
-- the window's search and filters) is the fallback; GetRecipeInfo(id).learned (:639);
-- GetRecipeSchematic(id, false).reagentSlotSchematics[] (:753): for each slot
-- reagents[1].itemID and quantityRequired. Skipped: slots that are not required
-- (optional and finishing reagents), slots whose first reagent is a currency (no
-- itemID), and quality tiers other than the first. Other people's windows are skipped
-- with the test Blizzard's own UI uses (Blizzard_Professions.lua:281, :378):
-- IsTradeSkillLinked, IsTradeSkillGuild, IsTradeSkillGuildMember, and IsNPCCrafting.
function Capture.Recipes()
    session.recipesPending = false
    if InCombat() then
        return
    end
    local T = C_TradeSkillUI
    if not (T and T.GetBaseProfessionInfo and T.GetRecipeInfo and T.GetRecipeSchematic) then
        return
    end
    for _, name in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember" }) do
        local fn = _G[name]
        if fn then
            local ok, value = pcall(fn)
            if ok and value then
                return
            end
        end
    end
    if T.IsNPCCrafting then
        local ok, value = pcall(T.IsNPCCrafting)
        if ok and value then
            return
        end
    end

    scan.secretSeen = false
    local okBase, base = pcall(T.GetBaseProfessionInfo)
    if not okBase or type(base) ~= "table" then
        return
    end
    local line = Int(base.parentProfessionID)
    if not line or line <= 0 then
        line = Int(base.professionID)
    end
    if not line or line < 1 or line > MAX_ID then
        return
    end
    local professionName = CleanText(base.professionName, CAPS.nameText)

    -- The ids: everything the window knows, else what its filters show.
    local ids
    for _, fnName in ipairs({ "GetAllRecipeIDs", "GetFilteredRecipeIDs" }) do
        local fn = T[fnName]
        if fn and not (type(ids) == "table" and #ids > 0) then
            local ok, list = pcall(fn)
            if ok and type(list) == "table" then
                ids = list
            end
        end
    end
    if type(ids) ~= "table" or #ids == 0 or scan.secretSeen then
        return
    end

    local rec = Cache.Get()
    local now = Now()
    local entry = rec.recipes[line]
    if not entry then
        local lines = 0
        for _ in pairs(rec.recipes) do
            lines = lines + 1
        end
        if lines >= CAPS.recipeLines then
            return
        end
        entry = { at = now, name = professionName, recipes = {}, cut = false }
        rec.recipes[line] = entry
    end

    local known = 0
    for _ in pairs(entry.recipes) do
        known = known + 1
    end
    local added = 0
    local required = Enum and Enum.CraftingReagentType
    local looked = 0
    for _, rawId in ipairs(ids) do
        looked = looked + 1
        if looked > CAPS.recipesPerLine * 4 then
            break
        end
        local id = Int(rawId)
        if id and id >= 1 and id <= MAX_ID then
            local existing = entry.recipes[id]
            if existing == nil or #existing == 0 then
                local okInfo, info = pcall(T.GetRecipeInfo, id)
                if okInfo and type(info) == "table" and info.learned then
                    if existing == nil and known >= CAPS.recipesPerLine then
                        entry.cut = true
                    else
                        local reagents = {}
                        local okSchematic, schematic = pcall(T.GetRecipeSchematic, id, false)
                        if okSchematic and type(schematic) == "table" and type(schematic.reagentSlotSchematics) == "table" then
                            for _, slot in ipairs(schematic.reagentSlotSchematics) do
                                if type(slot) == "table" and #reagents < CAPS.reagentsPerRecipe and slot.required ~= false then
                                    local skip = required and (slot.reagentType == required.Finishing or slot.reagentType == required.Modifying)
                                    local first = type(slot.reagents) == "table" and slot.reagents[1] or nil
                                    local item = type(first) == "table" and Int(first.itemID) or nil
                                    local count = Int(slot.quantityRequired)
                                    -- A count outside 1..MAX_REAGENT_COUNT leaves that reagent out.
                                    if not skip and item and item >= 1 and item <= MAX_ID and count and count >= 1 and count <= MAX_REAGENT_COUNT then
                                        reagents[#reagents + 1] = { item, count }
                                    end
                                end
                            end
                        end
                        if existing == nil then
                            known = known + 1
                            added = added + 1
                        end
                        entry.recipes[id] = reagents
                    end
                end
            end
        end
    end

    if scan.secretSeen then
        return
    end
    entry.at = now
    entry.name = professionName or entry.name
    session.live.recipes = now
    if added > 0 then
        Say(string.format(L["SAVED_RECIPES"], known, entry.name or L["PROFESSION"], Plural(known, L["RECIPE"], L["RECIPES"])))
    end
end

-- Debounced: the window fires its list update many times while it loads or is
-- filtered. Without C_Timer the capture runs at once.
function Capture.ScheduleRecipes()
    if session.recipesPending then
        return
    end
    if C_Timer and C_Timer.After then
        session.recipesPending = true
        C_Timer.After(0.6, Capture.Recipes)
    else
        Capture.Recipes()
    end
end

-- Flight paths known, while a flight map is open.
-- Forever (game type "camelot") does not load Blizzard's TaxiFrame that uses
-- NumTaxiNodes/TaxiNodeName/TaxiNodeGetType (Blizzard_UIPanels_Game.toc:133-136),
-- so those globals are not used. C_TaxiMap.GetAllTaxiNodes(uiMapID) -> {nodeID, name,
-- state} where state is Enum.FlightPathState (Current 0, Reachable 1: known; Unreachable
-- 2) (TaxiMapDocumentation.lua:11-24), and GetTaxiNodesForMap(uiMapID) -> {nodeID,
-- isUndiscovered} (:26-39). The map to ask about: GetTaxiMapID() (the flight map being
-- shown) when the game has it, else the player's map and its parents. Stable
-- nodeIDs are merged into the cache, never removed.
function Capture.Flights()
    if InCombat() then
        return
    end
    local T = C_TaxiMap
    if not (T and (T.GetAllTaxiNodes or T.GetTaxiNodesForMap)) then
        return
    end
    scan.secretSeen = false
    local maps, seenMap = {}, {}
    local function addMap(value)
        local id = Int(value)
        if id and id > 0 and not seenMap[id] and #maps < 8 then
            seenMap[id] = true
            maps[#maps + 1] = id
        end
    end
    if GetTaxiMapID then
        local ok, value = pcall(GetTaxiMapID)
        if ok then
            addMap(value)
        end
    end
    if C_Map and C_Map.GetBestMapForUnit then
        local ok, value = pcall(C_Map.GetBestMapForUnit, "player")
        if ok then
            addMap(value)
            local current = Int(value)
            for _ = 1, 5 do
                if not (current and C_Map.GetMapInfo) then
                    break
                end
                local okInfo, info = pcall(C_Map.GetMapInfo, current)
                current = okInfo and type(info) == "table" and Int(info.parentMapID) or nil
                if current and current > 0 then
                    addMap(current)
                else
                    break
                end
            end
        end
    end

    local state = Enum and Enum.FlightPathState
    local currentState = state and state.Current or 0
    local reachableState = state and state.Reachable or 1
    local found = {}
    for _, map in ipairs(maps) do
        if T.GetAllTaxiNodes then
            local ok, nodes = pcall(T.GetAllTaxiNodes, map)
            if ok and type(nodes) == "table" then
                for _, node in ipairs(nodes) do
                    if type(node) == "table" and (node.state == currentState or node.state == reachableState) then
                        local id = Int(node.nodeID)
                        if id and id >= 1 and id <= MAX_ID then
                            found[id] = true
                        end
                    end
                end
            end
        end
        if T.GetTaxiNodesForMap then
            local ok, nodes = pcall(T.GetTaxiNodesForMap, map)
            if ok and type(nodes) == "table" then
                for _, node in ipairs(nodes) do
                    if type(node) == "table" and node.isUndiscovered == false then
                        local id = Int(node.nodeID)
                        if id and id >= 1 and id <= MAX_ID then
                            found[id] = true
                        end
                    end
                end
            end
        end
    end
    if scan.secretSeen or next(found) == nil then
        return
    end

    local rec = Cache.Get()
    local now = Now()
    local before = rec.flights and rec.flights.ids or {}
    local all = {}
    for _, id in ipairs(before) do
        all[id] = true
    end
    local added = 0
    for id in pairs(found) do
        if not all[id] then
            all[id] = true
            added = added + 1
        end
    end
    local ids = SortedKeys(all, CAPS.flightPaths)
    rec.flights = { at = now, ids = ids }
    session.live.flights = now
    if added > 0 then
        Say(string.format(L["SAVED_FLIGHT_PATHS"], #ids, Plural(#ids, L["FLIGHT_PATH"], L["FLIGHT_PATHS"])))
    end
end


-- The player's numbers go in the cache record as the Player reader gives them.
local function StorePlayer(rec, at, section)
    if type(section) == "table" and section.source == "live" then
        rec.player = {
            at = at, money = section.money, level = section.level,
            xp = section.xp, xpMax = section.xpMax, rested = section.rested,
        }
    end
end

---------------------------------------------------------------------------
-- The payload
---------------------------------------------------------------------------

-- What the window shows about the character (set by BuildPayload).
ns.view = {}

-- Returns the payload table, or nil and a short reason.
local function BuildPayload()
    -- The name is the one value the export cannot do without: a name the server
    -- would refuse (never a real one, they are 2 to 12 letters) makes no export.
    local name = Fit(UnitName("player"), BOUNDS.characterName)
    if not name then
        return nil, L["NO_NAME"]
    end
    local region, regionId, portal = CollectRegion()

    local _, rawClassFile, rawClassId = UnitClass("player")
    local classFile = Fit(rawClassFile, BOUNDS.classFile)
    local classId = InRange(rawClassId, 0, BOUNDS.count)
    local _, build, _, interface = GetBuildInfo()
    local specId, rawSpecName = CollectSpec()
    local specName = Fit(rawSpecName, BOUNDS.specName)
    local level = InRange(UnitLevel("player"), 1, BOUNDS.level)
    local realm = Fit(CollectRealm(), BOUNDS.realm)

    local now = Now()
    local rec = Cache.Get()
    scan.cutSections = false

    -- The bank lists come from the cache record: the last full scan, read in this
    -- play session (live) or an earlier one (cache). Nothing is sent as bank
    -- contents when the bank was never read.
    local bank, bankSeen, bankSource = {}, false, nil
    local bankCut = false
    if rec.bank then
        for i = 1, #rec.bank.items do
            bank[i] = rec.bank.items[i]
        end
        bankSeen, bankSource, bankCut = true, rec.bank.source, rec.bank.cut
    end
    local warbank, warbankSeen = {}, false
    local warbankCut = false
    if rec.warbank then
        for i = 1, #rec.warbank.items do
            warbank[i] = rec.warbank.items[i]
        end
        warbankSeen, warbankCut = true, rec.warbank.cut
    end

    -- Bags are read now; the bank lists were cut at the time they were scanned.
    scan.secretSeen = false
    local bags = CollectBags()
    local bagsCut = scan.truncated
    local equipped = CollectEquipped()
    local professions, professionsOk = CollectProfessions()
    local stamp = CleanTime(now)

    -- What was read is also the newest cache copy of those parts (unless the game hid
    -- a value). The professions come from the cache when the game has no such function.
    if stamp and not scan.secretSeen then
        rec.equipped = { at = stamp, items = equipped }
        local sorted = {}
        for i = 1, #bags do
            sorted[i] = bags[i]
        end
        table.sort(sorted)
        rec.bags = { at = stamp, ids = sorted, cut = bagsCut }
        if professionsOk then
            rec.professions = { at = stamp, list = professions }
        end
    end
    local professionsCached = false
    if not professionsOk and rec.professions then
        professions, professionsOk, professionsCached = {}, true, true
        for i, row in ipairs(rec.professions.list) do
            professions[i] = row
        end
    end
    local professionNames = {}
    for _, profession in ipairs(professions) do
        professionNames[profession.name] = true
    end

    local sections = {
        equipped = Live(nil),
        bags = Live(nil),
        bank = rec.bank and (session.live.bank and Live(session.live.bank) or Cached(rec.bank.at))
            or Missing(C_Container and "open_bank" or "not_available"),
        -- A client with no warband bank tabs (Enum.BagIndex.AccountBankTab_1) has no such bank to open.
        warbank = rec.warbank and (session.live.warbank and Live(session.live.warbank) or Cached(rec.warbank.at))
            or Missing(C_Container and Enum and Enum.BagIndex and Enum.BagIndex.AccountBankTab_1 ~= nil and "open_bank" or "not_available"),
        professions = professionsOk and (professionsCached and Cached(rec.professions.at) or Live(nil)) or Missing("not_available"),
        recipes = Section(Read.Recipes, rec),
        questsDone = Section(Read.QuestsDone, rec, now),
        questLog = Section(Read.QuestLog),
        reputation = Section(Read.Reputation),
        player = Section(Read.Player),
        talents = Section(Read.Talents),
        legacy = Section(Read.Legacy, rec, now),
        flightPaths = Section(Read.FlightPaths, rec),
        honor = Section(Read.Honor),
        classSpells = Section(Read.ClassSpells, professionNames),
    }

    -- The player's numbers: kept in the cache when read, taken from it when the game gives none now.
    if sections.player.source == "live" then
        if stamp then
            StorePlayer(rec, stamp, sections.player)
        end
    elseif rec.player then
        sections.player = With(Cached(rec.player.at), {
            money = rec.player.money, level = rec.player.level, xp = rec.player.xp,
            xpMax = rec.player.xpMax, rested = rec.player.rested,
        })
    end

    -- The flags and the sections must agree (the server checks it): a bank section
    -- that could not be made (missing) has no list and is not «seen».
    if sections.bank.source == "missing" then
        bank, bankSeen, bankSource = {}, false, nil
    end
    if sections.warbank.source == "missing" then
        warbank, warbankSeen = {}, false
    end

    local cut = scan.truncated or bankCut or warbankCut or scan.cutSections

    -- The window shows the names in the player's language (the first returns).
    ns.view = {
        name = name,
        level = UnitLevel("player"),
        race = StringResult(UnitRace, 1) or CollectRace(),
        class = StringResult(UnitClass, 1) or classFile,
        realm = realm,
    }

    return {
        format = FORMAT_VERSION,
        addonVersion = ADDON_VERSION,
        client = { build = build, interface = interface },
        capturedAt = CleanTime(now), -- nil (left out) when the clock gives a time the server would refuse
        identity = {
            name = name,
            region = region, -- nil leaves the key out
            regionId = regionId,
            portal = portal,
            realm = realm, -- nil leaves the key out
            guid = UnitGUID("player"),
            classFile = classFile,
            classID = classId,
            race = CollectRace(), -- nil leaves the key out
            faction = CollectFaction(), -- nil leaves the key out
            level = level,
            specID = specId,
            specName = specName,
            hardcore = IsHardcore(),
        },
        equipped = equipped,
        bags = bags,
        bank = bank,
        bankSeen = bankSeen,
        bankSource = bankSeen and bankSource or nil, -- left out when the bank was not seen
        warbank = warbank,
        warbankSeen = warbankSeen,
        truncated = cut or nil, -- true only when a list was cut; nil leaves the key out
        professions = professions,
        sections = sections,
    }
end

-- The new sections, lowest priority first: the order they are left out of a text
-- that is longer than the server takes (docs/addon-export-format-3.md).
local DROP_ORDER = { "classSpells", "flightPaths", "legacy", "talents", "honor", "reputation", "questLog", "recipes" }

-- The size of the request body the browser makes of a text: the text itself plus the
-- JSON escape of each " and \ (a backslash more), plus the wrapper. Control characters
-- cannot be in the text: Encode has written them as \n, \u00XX and so on already.
local function BodyLength(text)
    local _, escapes = text:gsub('["\\]', "")
    return #text + escapes + BODY_WRAPPER
end

-- True when the text is inside the server's length limit and its body inside the route's.
local function Fits(text)
    return #text <= MAX_EXPORT_LENGTH and BodyLength(text) <= ADDON_BODY_MAX
end

local function Run()
    scan.truncated = false
    local payload, reason = BuildPayload()
    if not payload then
        UI.Show(nil, nil, reason)
        return
    end
    local text, encodeReason = Encode(payload)
    if not text then
        UI.Show(nil, nil, encodeReason)
        return
    end

    -- A seam for the tests: the sizes at each step, "" for none left out yet.
    local trace = {}
    if type(ns) == "table" then
        ns.fitTrace = trace
    end
    trace[1] = { "", #text, BodyLength(text) }

    local dropped = {}
    for _, name in ipairs(DROP_ORDER) do
        if Fits(text) then
            break
        end
        payload.sections[name] = Missing("too_large")
        dropped[#dropped + 1] = name
        text = Encode(payload)
        if not text then
            break
        end
        trace[#trace + 1] = { name, #text, BodyLength(text) }
    end
    if not text or not Fits(text) then
        UI.Show(nil, payload, L["TOO_LONG"])
        return
    end

    local message
    if #dropped > 0 then
        message = string.format(L["LEFT_OUT"], table.concat(dropped, ", "))
    end
    if payload.truncated then
        message = (message and (message .. " ") or "") .. L["LISTS_CUT"]
    end
    UI.Show(text, payload, message)
end

ns.ParseItemString = ParseItemString
ns.CollectEquipped = CollectEquipped
ns.CollectBags = CollectBags
ns.CollectProfessions = CollectProfessions
ns.Section = Section
ns.StorePlayer = StorePlayer
ns.ScanBank = ScanBank
ns.Run = Run
