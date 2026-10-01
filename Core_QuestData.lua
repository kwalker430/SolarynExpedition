--[[---------------------------------------------------------------------------
    Solaryn's Expedition — quest log reading.

    The single place that talks to C_QuestLog. Everything downstream (route
    planner, suggester, panel) consumes the normalised `QuestEntry` records this
    produces, so API quirks and caching delays are handled once.

    C_QuestLog.GetQuestObjectives is documented as needing up to three calls to
    fully cache a quest's data, so objectives are fetched lazily and cached with
    a "settled" flag rather than assumed correct on first read.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.QuestData = {}

local QuestData = ns.QuestData

-- Cache of resolved quest records, keyed by questID.
-- entry = {
--   questID, title, level, questLogIndex, isHeader, frequency, isTask,
--   isStory, isComplete, hasObjectives, objectives = {...}, settled = bool,
--   maps = { [uiMapID] = true }, turnsIn = { uiMapID, ... },
-- }
local cache = {}
QuestData.cache = cache

-- Bumped whenever the quest log or the player's zone changes. Objectives and
-- locations are cached per generation: re-read after any change, but only
-- once per burst of lookups. (They used to be read once per session, so
-- progress and completion never updated after the first read.)
local generation = 1

function QuestData:Invalidate()
    generation = generation + 1
end

function QuestData:Generation() return generation end

---------------------------------------------------------------------------
-- Quest log snapshot
---------------------------------------------------------------------------
--- Read the whole quest log into normalised records.
-- Returns (list, byID). Entries that are headers are flagged, not dropped, so
-- the panel can group them.
function QuestData:Scan()
    if not ns.Has.numQuestEntries then return {}, {} end

    local list, byID = {}, {}

    local numShown, _ = ns.Try("C_QuestLog", "GetNumQuestLogEntries")
    numShown = ns.SafeNum(numShown) or 0

    for i = 1, numShown do
        local info
        if ns.Has.questInfo then
            info = ns.Try("C_QuestLog", "GetInfo", i)
        end
        if type(info) ~= "table" then info = {} end

        local questID = ns.SafeNum(info.questID)
        if questID then
            local entry = cache[questID]
            if not entry then
                entry = { questID = questID }
                cache[questID] = entry
            end

            entry.questLogIndex = i
            entry.title = info.title or entry.title or ("quest " .. questID)
            entry.level = ns.SafeNum(info.level) or entry.level
            entry.isHeader = info.isHeader and true or false
            entry.isCollapsed = info.isCollapsed and true or false
            entry.frequency = ns.SafeNum(info.frequency) or 0
            entry.isTask = info.isTask and true or false
            entry.isBounty = info.isBounty and true or false
            entry.isStory = info.isStory and true or false
            entry.isHidden = info.isHidden and true or false
            entry.questClassification = info.questClassification
            entry.suggestedGroup = ns.SafeNum(info.suggestedGroup)
            entry.inLog = true

            table.insert(list, entry)
            byID[questID] = entry
        end
    end

    -- Mark anything previously cached that is no longer in the log.
    local seen = {}
    for _, e in ipairs(list) do seen[e.questID] = true end
    for id, e in pairs(cache) do
        if not seen[id] then
            e.inLog = false
            e.settled = nil
        end
    end

    return list, byID
end

---------------------------------------------------------------------------
-- Completion state
---------------------------------------------------------------------------
--- Has this quest ever been completed (flagged)?
function QuestData:IsCompleted(questID)
    if not ns.Has.questFlagged then return false end
    return ns.Try("C_QuestLog", "IsQuestFlaggedCompleted", questID) and true or false
end

--- Are all objectives complete? Distinguishes "ready to hand in" from
-- "partially done", which is the difference between the top two suggestions.
function QuestData:IsComplete(questID)
    local e = cache[questID]
    if not e then return false end
    -- Ask the client directly when it can tell us; it also covers quests
    -- with no objectives ("talk to X") that objective-counting can't.
    if ns.Has.questIsComplete then
        local done = ns.Try("C_QuestLog", "IsComplete", questID)
        if done ~= nil then return done and true or false end
    end
    -- Read objectives through Objectives() so they are fresh. Reading the raw
    -- cache here made every quest look unfinished until something else had
    -- happened to load its objectives.
    local objs = self:Objectives(questID)
    if not objs or #objs == 0 then return false end
    for _, o in ipairs(objs) do
        if not o.finished then return false end
    end
    return true
end

--- Fraction of objectives finished (0..1), or nil when there are none.
function QuestData:Progress(questID)
    local e = cache[questID]
    if not e or not e.objectives or #e.objectives == 0 then return nil end
    local done, total = 0, 0
    for _, o in ipairs(e.objectives) do
        total = total + 1
        if o.finished then done = done + 1 end
    end
    if total == 0 then return nil end
    return done / total
end

---------------------------------------------------------------------------
-- Objectives (lazy, with client-cache settling)
---------------------------------------------------------------------------
--- Get the objective list for a quest, reading from the client if needed.
-- Re-read once per generation (see Invalidate), or when forced.
function QuestData:Objectives(questID, force)
    local e = cache[questID]
    if not e then return {} end
    if e.objectives and e.objGen == generation and not force then return e.objectives end
    if not ns.Has.questObjectives then return {} end

    local objs = ns.Try("C_QuestLog", "GetQuestObjectives", questID)
    local out = {}

    -- The client's own cache may not have warmed yet. If it returns nothing,
    -- mark unsettled and let the next scan retry rather than caching an empty
    -- list as truth.
    if type(objs) ~= "table" then
        e.settled = false
        return e.objectives or {}
    end

    for _, o in ipairs(objs) do
        if type(o) == "table" then
            table.insert(out, {
                text = ns.SafeStr(o.text),
                type = o.type or "unknown",
                finished = o.finished and true or false,
                numFulfilled = ns.SafeNum(o.numFulfilled) or 0,
                numRequired = ns.SafeNum(o.numRequired) or 0,
                objectiveType = ns.SafeNum(o.objectiveType),
            })
        end
    end

    -- Empty is legitimate for some quests, but only trust it once the record
    -- has been read at least twice (matching the documented cache behaviour).
    e.objectives = out
    e.objGen = generation
    e.settled = true
    e.readCount = (e.readCount or 0) + 1

    return out
end

--- Objectives that still need doing.
function QuestData:PendingObjectives(questID)
    local out = {}
    for _, o in ipairs(self:Objectives(questID)) do
        if not o.finished then table.insert(out, o) end
    end
    return out
end

--- Text of the next thing to do.
-- The client already renders objective text with its counts ("Boars: 3/10")
-- for most objectives, so only append counts when the text lacks them —
-- otherwise you get "Boars: 3/10 (3/10)".
function QuestData:NextObjectiveText(questID)
    local pending = self:PendingObjectives(questID)
    if #pending == 0 then return nil end
    local o = pending[1]
    local text = o.text

    -- Skip the suffix if the text already contains an "a/b" progress pair.
    if text:find("%d+/%d+") then
        return text
    end
    if o.numRequired and o.numRequired > 0 and o.numRequired ~= 1 then
        return string.format("%s (%d/%d)", text, o.numFulfilled, o.numRequired)
    end
    return text
end

---------------------------------------------------------------------------
-- Locations
---------------------------------------------------------------------------
-- Every source is optional and probed (ns.Has). They are tried together and
-- the most specific answer wins:
--
--   poi         C_QuestLog.GetQuestsOnMap(map): the markers the world map
--               draws. Covers objectives AND the hand-in marker of a finished
--               quest, but only on maps we ask about.
--   waypoint    C_QuestLog.GetNextWaypoint(quest): the client's own "go here
--               next", on whatever map that is.
--   mapWaypoint C_QuestLog.GetNextWaypointForMap(quest, map): answers only
--               when the objective is on a DIFFERENT map (routing via a
--               boat, portal, etc.), so it's a fallback, never the main source.
--   task        C_TaskQuest.GetQuestLocation(quest, map) for task quests.
--
-- Coordinates stay in the client's 0-1 map space throughout.
QuestData.lastSources = {}          -- [questID] = source name, for /sol where

local MAPTYPE_ZONE = 3

--- Maps worth asking about: where the player is, the zones above and below
-- it, and the neighbouring zones on the same continent (quests often send
-- you next door).
local function candidateMaps()
    local maps, order = {}, {}
    local function add(id)
        if id and not maps[id] then maps[id] = true; table.insert(order, id) end
    end

    local playerMap = ns:PlayerMapID()
    if not playerMap then return order end
    add(playerMap)

    local id = playerMap
    for _ = 1, 4 do
        local z = ns.ZoneData:Get(id)
        local parent = z and (z.parentMapID or z.mapParentID)
        local pz = parent and ns.ZoneData:Get(parent)
        -- Stop below the world/cosmic level; those maps carry no quest markers.
        if not parent or not pz or (pz.mapType or 0) <= 1 then break end
        add(parent)
        id = parent
    end

    for _, z in ipairs(ns.ZoneData:Children(playerMap)) do add(z.mapID) end
    local zone = ns.ZoneData:WorldAncestor(playerMap)
    if zone then
        add(zone)
        for _, z in ipairs(ns.ZoneData:Neighbours(zone)) do add(z.mapID) end
    end
    return order
end

-- POI index for the current generation: [questID] = { {uiMapID,x,y}, ... }.
local poiIndex, poiGen, poiMap

local function buildPoiIndex()
    local playerMap = ns:PlayerMapID()
    if poiIndex and poiGen == generation and poiMap == playerMap then return poiIndex end
    poiIndex, poiGen, poiMap = {}, generation, playerMap
    if not ns.Has.questsOnMap then return poiIndex end

    for _, mapID in ipairs(candidateMaps()) do
        local list = ns.Try("C_QuestLog", "GetQuestsOnMap", mapID)
        if type(list) == "table" then
            for _, info in ipairs(list) do
                local qid = type(info) == "table" and ns.SafeNum(info.questID)
                local x, y = ns.SafeNum(info.x), ns.SafeNum(info.y)
                if qid and x and y then
                    poiIndex[qid] = poiIndex[qid] or {}
                    table.insert(poiIndex[qid], { uiMapID = mapID, x = x, y = y, source = "poi" })
                end
            end
        end
    end
    return poiIndex
end

--- How useful a map is for a pin: the player's own map, then zones, then
--- anything else (continents last).
local function specificity(mapID, playerMap)
    if mapID == playerMap then return 0 end
    local z = ns.ZoneData:Get(mapID)
    local t = z and (z.mapType or z.type)
    if t == MAPTYPE_ZONE then return 1 end
    if t and t > MAPTYPE_ZONE then return 2 end
    return 3
end

local SOURCE_RANK = { override = 0, poi = 1, waypoint = 2, task = 3, mapWaypoint = 4 }

--- All map positions the client knows for a quest's current step.
-- Returns a list of { uiMapID, x, y, world, questID, source }, best first.
function QuestData:Waypoints(questID)
    local e = cache[questID]
    if e and e.waypoints and e.wpGen == generation and e.wpMap == ns:PlayerMapID() then
        return e.waypoints
    end

    local out, seen = {}, {}
    local function add(mapID, x, y, source)
        mapID, x, y = ns.SafeNum(mapID), ns.SafeNum(x), ns.SafeNum(y)
        if not (mapID and x and y) then return end
        local key = mapID .. ":" .. source
        if seen[key] then return end
        seen[key] = true
        table.insert(out, { uiMapID = mapID, x = x, y = y, questID = questID, source = source })
    end

    -- 1. World-map quest markers.
    for _, p in ipairs(buildPoiIndex()[questID] or {}) do add(p.uiMapID, p.x, p.y, "poi") end

    -- 2. The client's own next waypoint, on any map.
    if ns.Has.nextWaypointAny then
        local mapID, x, y = ns.Try("C_QuestLog", "GetNextWaypoint", questID)
        add(mapID, x, y, "waypoint")
    end

    -- 3. The quest's own map, if the client names one and we haven't
    --    already got a marker there.
    local maps = candidateMaps()
    if ns.Has.questUiMapID then
        local qMap = ns.SafeNum(ns.Try("_G", "GetQuestUiMapID", questID))
        if qMap and qMap > 0 then
            table.insert(maps, 1, qMap)
            if ns.Has.questsOnMap and not seen[qMap .. ":poi"] then
                local list = ns.Try("C_QuestLog", "GetQuestsOnMap", qMap)
                for _, info in ipairs(type(list) == "table" and list or {}) do
                    if type(info) == "table" and info.questID == questID then
                        add(qMap, info.x, info.y, "poi")
                    end
                end
            end
        end
    end

    -- 4. Task quests, then cross-map routing, only if nothing better turned up.
    if #out == 0 then
        for _, mapID in ipairs(maps) do
            if ns.Has.taskQuestLocation then
                local x, y = ns.Try("C_TaskQuest", "GetQuestLocation", questID, mapID)
                add(mapID, x, y, "task")
            end
            if ns.Has.nextWaypoint then
                local x, y = ns.Try("C_QuestLog", "GetNextWaypointForMap", questID, mapID)
                add(mapID, x, y, "mapWaypoint")
            end
        end
    end

    local playerMap = ns:PlayerMapID()
    table.sort(out, function(a, b)
        local sa, sb = specificity(a.uiMapID, playerMap), specificity(b.uiMapID, playerMap)
        if sa ~= sb then return sa < sb end
        local ra, rb = SOURCE_RANK[a.source] or 9, SOURCE_RANK[b.source] or 9
        if ra ~= rb then return ra < rb end
        return a.uiMapID < b.uiMapID
    end)

    for _, wp in ipairs(out) do
        wp.world = ns:WorldPos(wp.uiMapID, wp.x, wp.y)
    end

    self.lastSources[questID] = out[1] and out[1].source or nil
    if e then
        e.waypoints, e.wpGen, e.wpMap = out, generation, playerMap
    end
    return out
end

--- Primary objective location for a quest, or nil.
function QuestData:PrimaryWaypoint(questID)
    local wps = self:Waypoints(questID)
    if #wps == 0 then return nil end
    return wps[1]
end

--- Which map a quest's current objective is on, or nil.
function QuestData:ObjectiveMap(questID)
    local wp = self:PrimaryWaypoint(questID)
    return wp and wp.uiMapID or nil
end

--- Turn-in location for a finished quest. Once every objective is done, the
-- client's marker and next waypoint for the quest point at the NPC who takes
-- it, so this is simply the finished quest's primary location.
function QuestData:TurnInLocation(questID)
    if not self:IsComplete(questID) then return nil end
    -- No marker from the client: fall back to the NPC we've seen take this
    -- quest, or the one who gave it (learned in Core_QuestGivers).
    return self:PrimaryWaypoint(questID)
        or (ns.QuestGivers and ns.QuestGivers:TurnInLocation(questID))
end

---------------------------------------------------------------------------
-- Usable quest items
---------------------------------------------------------------------------
-- Container functions moved into C_Container in newer clients; accept both.
local function containerFn(name)
    local cc = _G.C_Container
    if type(cc) == "table" and type(cc[name]) == "function" then return cc[name] end
    return type(_G[name]) == "function" and _G[name] or nil
end

local function itemFn(name)
    local ci = _G.C_Item
    if type(ci) == "table" and type(ci[name]) == "function" then return ci[name] end
    return type(_G[name]) == "function" and _G[name] or nil
end

--- True if the item has a "Use:" effect (otherwise a button is pointless).
local function itemUsable(itemID)
    local getSpell = itemFn("GetItemSpell")
    if not getSpell then return true end      -- can't tell: assume usable
    return getSpell(itemID) ~= nil
end

function QuestData:ItemName(itemID)
    local byID = itemFn("GetItemNameByID")
    local name = byID and byID(itemID)
    if not name and type(_G.GetItemInfo) == "function" then name = _G.GetItemInfo(itemID) end
    return name
end

--- Usable quest items in the player's bags:
--- list of { itemID, bag, slot, questID (or nil) }.
function QuestData:BagQuestItems()
    local numSlots, getID, getQuest =
        containerFn("GetContainerNumSlots"), containerFn("GetContainerItemID"), containerFn("GetContainerItemQuestInfo")
    local out = {}
    if not (numSlots and getID and getQuest) then return out end
    for bag = 0, (ns.SafeNum(_G.NUM_BAG_SLOTS) or 4) do
        for slot = 1, (ns.SafeNum(numSlots(bag)) or 0) do
            local itemID = ns.SafeNum(getID(bag, slot))
            if itemID then
                -- Newer clients return a table, older ones (isQuestItem, questID, isActive).
                local a, b = getQuest(bag, slot)
                local isQuestItem, questID
                if type(a) == "table" then isQuestItem, questID = a.isQuestItem, a.questID
                else isQuestItem, questID = a, b end
                if (isQuestItem or questID) and itemUsable(itemID) then
                    table.insert(out, { itemID = itemID, bag = bag, slot = slot, questID = ns.SafeNum(questID) })
                end
            end
        end
    end
    return out
end

--- The item to use for a quest, or nil: { itemID, source }. Sources, best
--- first: the quest log's own item (what Blizzard's tracker shows), a bag
--- item the client ties to this quest, then a usable quest item whose name
--- appears in the quest's objectives.
function QuestData:QuestItem(questID, bagItems)
    if not questID then return nil end
    local special = _G.GetQuestLogSpecialItemInfo
    if type(special) == "function" and ns.Has.logIndexForQuest then
        local index = ns.SafeNum(ns.Try("C_QuestLog", "GetLogIndexForQuestID", questID))
        local link = index and special(index)
        local itemID = type(link) == "string" and tonumber(link:match("item:(%d+)"))
        if itemID then return { itemID = itemID, source = "quest log" } end
    end

    bagItems = bagItems or self:BagQuestItems()
    for _, it in ipairs(bagItems) do
        if it.questID == questID then return { itemID = it.itemID, source = "bag" } end
    end

    local texts = {}
    for _, o in ipairs(self:Objectives(questID)) do texts[#texts + 1] = (o.text or ""):lower() end
    local all = table.concat(texts, "\n")
    if all ~= "" then
        for _, it in ipairs(bagItems) do
            local name = self:ItemName(it.itemID)
            if name and name ~= "" and all:find(name:lower(), 1, true) then
                return { itemID = it.itemID, source = "objective" }
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Distance to a quest
---------------------------------------------------------------------------
--- Yards from the player to a quest's current objective, or nil.
function QuestData:ObjectiveDistance(questID)
    local wp = self:PrimaryWaypoint(questID)
    if not wp then return nil end
    local pp = ns:PlayerPosition(wp.uiMapID)
    if not pp then return nil end
    return ns:DistanceBetween(pp, wp)
end

---------------------------------------------------------------------------
-- Follow-up discovery
---------------------------------------------------------------------------
-- When you complete a quest the client fires QUEST_TURNED_IN; the quest that
-- becomes available in its place is the follow-up. We observe that transition
-- rather than shipping a chain database, then record it so chains survive.
local pendingLink = {}

--- Remember that `turnedInID` was just handed in, so the next quest accepted
-- can be linked to it.
function QuestData:NoteTurnIn(turnedInID)
    pendingLink[turnedInID] = true
end

--- Called when a quest is accepted: if it follows a quest we just turned in,
--- record the chain link permanently.
function QuestData:NoteAccepted(questID)
    local d = _G.SolarynDB
    if not d then return end
    for turnedInID in pairs(pendingLink) do
        if turnedInID ~= questID then
            ns.Chains:Link(turnedInID, questID)
        end
        pendingLink[turnedInID] = nil
    end
    -- Don't let a stale pending set leak if no quest was accepted.
    ns:Count(pendingLink)
end

function QuestData:ClearPendingLinks()
    pendingLink = {}
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
-- Registered here, in the first module to load that reads quests, so the
-- cache is invalidated before any later module's handler re-reads it.
local function invalidate() QuestData:Invalidate() end
for _, event in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED",
                         "QUEST_TURNED_IN", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED",
                         "PLAYER_ENTERING_WORLD" }) do
    ns:RegisterEvent(event, invalidate, QuestData)
end

---------------------------------------------------------------------------
-- Module registration
---------------------------------------------------------------------------
ns:RegisterModule("QuestData", QuestData)