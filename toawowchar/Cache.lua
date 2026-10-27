local _, ns = ...

local CACHE_VERSION = ns.CACHE_VERSION
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
local session = ns.session
local scan = ns.scan
local Cache = ns.Cache
local Read = ns.Read
local Snapshot = ns.Snapshot
local Int = ns.Int
local InRange = ns.InRange
local CleanTime = ns.CleanTime
local CleanText = ns.CleanText
local Fit = ns.Fit
local Now = ns.Now
local InCombat = ns.InCombat
local SortedKeys = ns.SortedKeys
local CleanCount = ns.CleanCount
local Points = ns.Points
local RealmName = ns.RealmName
local DB = ns.DB
local CollectEquipped = ns.CollectEquipped
local CollectBags = ns.CollectBags
local CollectProfessions = ns.CollectProfessions
local Section = ns.Section
local StorePlayer = ns.StorePlayer

---------------------------------------------------------------------------
-- Cache (SavedVariables: toawowcharDB.realms[realm][name], see DB in Core.lua)
---------------------------------------------------------------------------
-- The table is only a cache. The addon never needs it: when toawowcharDB is
-- nil or not a table, or when the client does not save it, everything below works
-- on a table that lives for this play session. A record read from the saved file
-- is rebuilt field by field the first time it is used (Cache.Clean): only whole
-- numbers in range, strings cut at their caps, lists cut at the caps of the
-- export. So a file that was edited or damaged cannot make a bigger export than
-- the live game could.
--
-- A record (version 1):
--   bank      { at, source = "tabs"|"classic", items = {ids, sorted}, cut }
--   warbank   { at, items = {ids, sorted}, cut }
--   recipes   { [skillLine] = { at, name, cut, recipes = { [recipeId] = { {itemId, count}, ... } } } }
--   flights   { at, ids = {taxi node ids, sorted} }
--   quests    { at, ids = {completed quest ids, sorted}, cut }
--   legacy    { at, points = { available, cap, spent }, trees = { { tree, spent, nodes = { {node, rank, entry} } } } }
--   equipped  { at, items = { { slot, itemId, enchantId, gemIds, suffixId, bonusIds } } }
--   bags      { at, ids = {item ids, sorted}, cut }
--   professions { at, list = { { name, skillLineId, rank, maxRank } } }
--   player    { at, money, level, xp, xpMax, rested }
-- Caches are only ever MERGED into (recipes, flight paths and completed quests
-- keep everything seen before); the bank, the warband bank, Legacy, the equipped
-- items, the bags, the professions and the player's numbers are replaced by a
-- complete new read. The last four are kept current by game events (see
-- Snapshot) and are the part of the cache that /wowchar uses only when the game
-- gives nothing now (professions, player); equipped and bags are always read live.

local checked = setmetatable({}, { __mode = "k" })
local fallbackRecord

-- A sorted list of the distinct whole numbers 1..MAX_ID found in a list or set.
-- Second result: true when cut at `cap`.
local function CleanIds(raw, cap)
    local set = {}
    if type(raw) == "table" then
        local looked = 0
        for _, value in pairs(raw) do
            looked = looked + 1
            if looked > cap * 4 + 16 then
                break
            end
            local id = Int(value)
            if id and id >= 1 and id <= MAX_ID then
                set[id] = true
            end
        end
    end
    return SortedKeys(set, cap)
end

local function CleanReagents(raw)
    local out = {}
    if type(raw) == "table" then
        for _, pair in ipairs(raw) do
            if #out >= CAPS.reagentsPerRecipe then
                break
            end
            if type(pair) == "table" then
                local item, count = Int(pair[1]), Int(pair[2])
                if item and item >= 1 and item <= MAX_ID and count and count >= 1 and count <= MAX_REAGENT_COUNT then
                    out[#out + 1] = { item, count }
                end
            end
        end
    end
    return out
end

-- Trait nodes { {node, rank, entry}, ... }, at most CAPS.nodesPerTree.
local function CleanNodes(raw)
    local out = {}
    if type(raw) == "table" then
        for _, triple in ipairs(raw) do
            if #out >= CAPS.nodesPerTree then
                break
            end
            if type(triple) == "table" then
                local node, rank, entry = Int(triple[1]), Int(triple[2]), Int(triple[3]) or 0
                if node and node >= 1 and node <= MAX_ID and rank and rank >= 1 and rank <= MAX_TRAIT_RANK and entry >= 0 and entry <= MAX_ID then
                    out[#out + 1] = { node, rank, entry }
                end
            end
        end
    end
    return out
end

local function CleanLegacy(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local at = CleanTime(raw.at)
    if not at or type(raw.trees) ~= "table" then
        return nil
    end
    local clean = { at = at, trees = {} }
    if type(raw.points) == "table" then
        clean.points = Points(CleanCount(raw.points.available), CleanCount(raw.points.cap), CleanCount(raw.points.spent))
    end
    for _, tree in ipairs(raw.trees) do
        if #clean.trees >= CAPS.legacyTrees then
            break
        end
        if type(tree) == "table" then
            local id = Int(tree.tree)
            if id and id >= 1 and id <= MAX_ID then
                clean.trees[#clean.trees + 1] = { tree = id, spent = CleanCount(tree.spent) or 0, nodes = CleanNodes(tree.nodes) }
            end
        end
    end
    return clean
end

-- A list of whole numbers in their order (the order of bonus ids matters), each
-- between min and MAX_ID, at most `cap` of them.
local function CleanOrdered(raw, cap, min)
    local out = {}
    if type(raw) == "table" then
        for _, value in ipairs(raw) do
            if #out >= cap then
                break
            end
            local id = Int(value)
            if id and id >= min and id <= MAX_ID then
                out[#out + 1] = id
            end
        end
    end
    return out
end

local function CleanEquipped(raw)
    local out = {}
    if type(raw) == "table" then
        for _, item in ipairs(raw) do
            if #out >= LAST_EQUIPMENT_SLOT then
                break
            end
            if type(item) == "table" then
                local slot, itemId = Int(item.slot), Int(item.itemId)
                if slot and slot >= 1 and slot <= LAST_EQUIPMENT_SLOT and itemId and itemId >= 1 and itemId <= MAX_ID then
                    out[#out + 1] = {
                        slot = slot,
                        itemId = itemId,
                        enchantId = InRange(item.enchantId, 0, MAX_ID) or 0,
                        gemIds = CleanOrdered(item.gemIds, MAX_GEMS, 1),
                        suffixId = InRange(item.suffixId, 0, MAX_ID) or 0,
                        bonusIds = CleanOrdered(item.bonusIds, MAX_BONUS_IDS, 1),
                    }
                end
            end
        end
    end
    return out
end

local function CleanProfessionList(raw)
    local out = {}
    if type(raw) == "table" then
        for _, row in ipairs(raw) do
            if #out >= MAX_PROFESSIONS then
                break
            end
            local name = type(row) == "table" and Fit(row.name, BOUNDS.professionName) or nil
            if name then
                out[#out + 1] = {
                    name = name,
                    skillLineId = InRange(row.skillLineId, 0, BOUNDS.count),
                    rank = InRange(row.rank, 0, BOUNDS.count),
                    maxRank = InRange(row.maxRank, 0, BOUNDS.count),
                }
            end
        end
    end
    return out
end

-- The player's numbers, each only when it is inside its bound; nil when none is.
local function CleanPlayer(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local at = CleanTime(raw.at)
    if not at then
        return nil
    end
    local clean = {
        at = at,
        money = InRange(raw.money, 0, BOUNDS.money),
        level = InRange(raw.level, 1, BOUNDS.level),
        xp = InRange(raw.xp, 0, BOUNDS.counter),
        xpMax = InRange(raw.xpMax, 0, BOUNDS.counter),
        rested = InRange(raw.rested, 0, BOUNDS.counter),
    }
    if clean.money == nil and clean.level == nil and clean.xp == nil and clean.xpMax == nil and clean.rested == nil then
        return nil
    end
    return clean
end

-- Rebuilds a record from whatever the saved file held.
function Cache.Clean(raw)
    local rec = { v = CACHE_VERSION, recipes = {} }
    if type(raw) ~= "table" then
        return rec
    end

    if type(raw.bank) == "table" then
        local at = CleanTime(raw.bank.at)
        local items, cut = CleanIds(raw.bank.items, MAX_IDS)
        if at and #items > 0 then
            rec.bank = { at = at, source = raw.bank.source == "classic" and "classic" or "tabs", items = items, cut = cut or raw.bank.cut == true }
        end
    end
    if type(raw.warbank) == "table" then
        local at = CleanTime(raw.warbank.at)
        local items, cut = CleanIds(raw.warbank.items, MAX_IDS)
        if at and #items > 0 then
            rec.warbank = { at = at, items = items, cut = cut or raw.warbank.cut == true }
        end
    end

    if type(raw.recipes) == "table" then
        local lines = 0
        for rawLine, entry in pairs(raw.recipes) do
            local line = Int(rawLine)
            if line and line >= 1 and line <= MAX_ID and type(entry) == "table" and lines < CAPS.recipeLines then
                local at = CleanTime(entry.at)
                if at and type(entry.recipes) == "table" then
                    local clean = { at = at, name = CleanText(entry.name, CAPS.nameText), recipes = {}, cut = entry.cut == true }
                    local count = 0
                    for rawId, reagents in pairs(entry.recipes) do
                        local id = Int(rawId)
                        if id and id >= 1 and id <= MAX_ID then
                            if count < CAPS.recipesPerLine then
                                clean.recipes[id] = CleanReagents(reagents)
                                count = count + 1
                            else
                                clean.cut = true
                            end
                        end
                    end
                    rec.recipes[line] = clean
                    lines = lines + 1
                end
            end
        end
    end

    if type(raw.flights) == "table" then
        local at = CleanTime(raw.flights.at)
        local ids = CleanIds(raw.flights.ids, CAPS.flightPaths)
        if at and #ids > 0 then
            rec.flights = { at = at, ids = ids }
        end
    end
    if type(raw.quests) == "table" then
        local at = CleanTime(raw.quests.at)
        local ids, cut = CleanIds(raw.quests.ids, CAPS.questsDone)
        if at and #ids > 0 then
            rec.quests = { at = at, ids = ids, cut = cut or raw.quests.cut == true }
        end
    end
    rec.legacy = CleanLegacy(raw.legacy)

    if type(raw.equipped) == "table" then
        local at = CleanTime(raw.equipped.at)
        if at then
            rec.equipped = { at = at, items = CleanEquipped(raw.equipped.items) }
        end
    end
    if type(raw.bags) == "table" then
        local at = CleanTime(raw.bags.at)
        if at then
            local ids, cut = CleanIds(raw.bags.ids, MAX_IDS)
            rec.bags = { at = at, ids = ids, cut = cut or raw.bags.cut == true }
        end
    end
    if type(raw.professions) == "table" then
        local at = CleanTime(raw.professions.at)
        if at then
            rec.professions = { at = at, list = CleanProfessionList(raw.professions.list) }
        end
    end
    rec.player = CleanPlayer(raw.player)
    return rec
end

-- This character's record. Always a table: a play-session table when the saved
-- one cannot be used. The saved variable is looked up on every call (DB, never kept),
-- because the client assigns the saved file's table after this file ran.
function Cache.Get()
    local name = UnitName and UnitName("player")
    if type(name) ~= "string" or name == "" then
        fallbackRecord = fallbackRecord or Cache.Clean(nil)
        return fallbackRecord
    end
    local db = DB()
    local realm = RealmName() or "?"
    local realms = db.realms[realm]
    if type(realms) ~= "table" then
        realms = {}
        db.realms[realm] = realms
    end
    local rec = realms[name]
    if type(rec) ~= "table" or not checked[rec] then
        rec = Cache.Clean(rec)
        checked[rec] = true
        realms[name] = rec
    end
    return rec
end

-- /wowchar reset: forgets this character's cache and what was captured in this
-- play session.
function Cache.Reset()
    local name = UnitName and UnitName("player")
    if type(name) == "string" and name ~= "" then
        local realms = DB().realms[RealmName() or "?"]
        if type(realms) == "table" then
            realms[name] = nil
        end
    end
    fallbackRecord = nil
    session.live = {}
    session.bankDirty, session.warbankDirty = false, false
    session.recipesPending = false
    Snapshot.Reset()
end

---------------------------------------------------------------------------
-- Snapshot: the cache kept current by game events
---------------------------------------------------------------------------
-- The equipped items, the bags, the completed quests, the professions and the
-- player's numbers are read from the game whenever they change, so SavedVariables
-- holds a current copy when the character logs out, whether or not /wowchar was
-- ever typed. The events and what each one refreshes:
--   PLAYER_EQUIPMENT_CHANGED  equipped
--   BAG_UPDATE_DELAYED        bags (the bank is scanned as before while it is open)
--   QUEST_TURNED_IN           quests (the turned-in id is added at once) and player
--   SKILL_LINES_CHANGED       professions
--   PLAYER_MONEY              player (gold)
--   PLAYER_XP_UPDATE          player (XP)
--   PLAYER_LEVEL_UP           player, read LEVEL_UP_DELAY seconds after the event:
--                             some clients still answer the old level and XP max
--                             while the event fires (Snapshot.LevelUp)
-- The cache also keeps the bank, the warband bank, the recipes and the flight paths
-- (written by their own captures, each with a chat line) and Legacy. Legacy has no
-- capture of its own and says nothing in the chat: Read.Legacy saves it whenever
-- /wowchar reads it. The whole list is ADDON_CACHED_SECTIONS in wowchar's
-- app/shared/addon-sections.ts (copied to test/contract.json), and a Lua test pins
-- it to the sections this file writes into toawowcharDB.
-- `equipped` and `bags` are kept but the export does not read them back yet: a
-- /wowchar always reads both live (docs/addon-export-format-3.md). They are not dead
-- data: they stay for a later phase and for the page's list of what the addon keeps.
-- At most one rebuild of a section per SNAPSHOT_INTERVAL seconds: the first event
-- rebuilds at once, the ones that follow inside the interval share ONE rebuild
-- when the interval is over (so the last change is never lost). In combat nothing
-- is read: the section waits for PLAYER_REGEN_ENABLED and is then rebuilt once.
-- A snapshot never says anything in the chat.

-- Seconds between two rebuilds of one section.
local SNAPSHOT_INTERVAL = 5

-- Seconds after PLAYER_LEVEL_UP before the player part is read.
local LEVEL_UP_DELAY = 1

-- The order the deferred sections are rebuilt in when combat ends.
local SNAPSHOT_SECTIONS = { "equipped", "bags", "quests", "professions", "player" }

-- section -> { last = unix time of its last rebuild, timer = true while a rebuild
-- is scheduled, deferred = true when combat held a rebuild back }
local snapshotState = {}
for _, name in ipairs(SNAPSHOT_SECTIONS) do
    snapshotState[name] = { timer = false, deferred = false }
end
-- Bumped by /wowchar reset: a rebuild scheduled before it does nothing.
local snapshotGeneration = 0

local snapshotRebuild = {}

function snapshotRebuild.equipped(rec, at)
    local items = CollectEquipped()
    if not scan.secretSeen then
        rec.equipped = { at = at, items = items }
    end
end

function snapshotRebuild.bags(rec, at)
    -- The bags are read like the bank is: the cut flag is the snapshot's own.
    local previous = scan.truncated
    scan.truncated = false
    local ids = CollectBags()
    local cut = scan.truncated
    scan.truncated = previous
    if not scan.secretSeen then
        table.sort(ids)
        rec.bags = { at = at, ids = ids, cut = cut }
    end
end

function snapshotRebuild.quests(rec, at)
    Section(Read.QuestsDone, rec, at)
end

function snapshotRebuild.professions(rec, at)
    local list, ok = CollectProfessions()
    if ok and not scan.secretSeen then
        rec.professions = { at = at, list = list }
    end
end



function snapshotRebuild.player(rec, at)
    scan.secretSeen = false
    local ok, section = pcall(Read.Player)
    if ok and not scan.secretSeen then
        StorePlayer(rec, at, section)
    end
end

-- Rebuilds one section now (or marks it deferred in combat).
function Snapshot.Run(section)
    local state = snapshotState[section]
    if InCombat() then
        state.deferred = true
        return
    end
    state.deferred = false
    state.last = Now()
    local at = CleanTime(state.last)
    if not at then
        return
    end
    scan.secretSeen = false
    pcall(snapshotRebuild[section], Cache.Get(), at)
end

-- An event asks for a rebuild: now, or once at the end of the interval.
function Snapshot.Request(section)
    local state = snapshotState[section]
    if state.timer then
        return
    end
    if InCombat() then
        state.deferred = true
        return
    end
    local wait = state.last and (state.last + SNAPSHOT_INTERVAL - Now()) or 0
    if wait > 0 and C_Timer and C_Timer.After then
        if wait > SNAPSHOT_INTERVAL then
            wait = SNAPSHOT_INTERVAL -- the clock went back
        end
        local generation = snapshotGeneration
        state.timer = true
        C_Timer.After(wait, function()
            if generation ~= snapshotGeneration then
                return
            end
            state.timer = false
            Snapshot.Run(section)
        end)
        return
    end
    Snapshot.Run(section)
end

-- Combat ended: every section that was held back is rebuilt once.
function Snapshot.CombatEnded()
    for _, section in ipairs(SNAPSHOT_SECTIONS) do
        if snapshotState[section].deferred then
            snapshotState[section].deferred = false
            Snapshot.Request(section)
        end
    end
end

-- A level-up: the player part is read LEVEL_UP_DELAY seconds later, through
-- Snapshot.Request, so the throttle and the combat rule still hold. A reset in
-- between cancels it. A client without C_Timer reads at once.
function Snapshot.LevelUp()
    if C_Timer and C_Timer.After then
        local generation = snapshotGeneration
        C_Timer.After(LEVEL_UP_DELAY, function()
            if generation == snapshotGeneration then
                Snapshot.Request("player")
            end
        end)
        return
    end
    Snapshot.Request("player")
end

-- A quest was turned in: its id goes into the completed quests at once (the game's
-- list may not have it yet). Only when the list was read before: a cache with one
-- id would look like a complete one.
function Snapshot.TurnedIn(questId)
    local id = InRange(questId, 1, MAX_ID)
    local rec = Cache.Get()
    if not (id and rec.quests) then
        return
    end
    local set = { [id] = true }
    for _, known in ipairs(rec.quests.ids) do
        set[known] = true
    end
    local ids, cut = SortedKeys(set, CAPS.questsDone)
    rec.quests = { at = rec.quests.at, ids = ids, cut = cut or rec.quests.cut }
end

function Snapshot.Reset()
    snapshotGeneration = snapshotGeneration + 1
    for _, name in ipairs(SNAPSHOT_SECTIONS) do
        snapshotState[name] = { timer = false, deferred = false }
    end
end
