--[[---------------------------------------------------------------------------
    Solaryn's Expedition — quest givers, learned by talking to them.

    The client only reveals what an NPC offers once you open its gossip or
    quest window. Every time you do, we remember it, account-wide so every
    character benefits:

      SolarynDB.npcs[npcID] = {
        name, mapID, x, y, seen,             -- where you stood when talking
        offers = { [questID] = { title, level, trivial, repeatable } },
        takes  = { [questID] = title },      -- quests this NPC accepts back
      }
      SolarynDB.questGivers[questID] = npcID  -- who gave you a quest

    Uses: NPC tooltips list what an NPC offers before you accept, and the
    guide gets a hand-in location when the client has no turn-in marker
    (the NPC known to take the quest, else the one who gave it).

    NPCs are identified by the creature ID in their GUID. Unit data can be
    secret in combat, so everything from a unit goes through ns.IsSafe.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.QuestGivers = {}

local QG = ns.QuestGivers

local function db()
    local d = _G.SolarynDB
    if not d then return nil end
    d.npcs = d.npcs or {}
    d.questGivers = d.questGivers or {}
    return d
end

---------------------------------------------------------------------------
-- Identity
---------------------------------------------------------------------------
--- Creature/object ID from a GUID like "Creature-0-1465-0-2105-448-000043F59F".
function QG.IDFromGUID(guid)
    if not ns.IsSafe(guid) or type(guid) ~= "string" then return nil end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if kind == "Creature" or kind == "Vehicle" or kind == "GameObject" then
        return tonumber(id), kind
    end
    return nil
end

--- The NPC you're talking to (unit "npc"), or nil: id, name.
local function currentNPC()
    if type(_G.UnitGUID) ~= "function" then return nil end
    local id = QG.IDFromGUID(_G.UnitGUID("npc"))
    if not id then return nil end
    local name = type(_G.UnitName) == "function" and _G.UnitName("npc") or nil
    if not ns.IsSafe(name) or type(name) ~= "string" then name = nil end
    return id, name
end

--- Get (or create) the record for the NPC you're talking to, stamped with
--- where you're standing.
local function touchNPC()
    local d = db()
    local id, name = currentNPC()
    if not d or not id then return nil end
    local rec = d.npcs[id] or { offers = {}, takes = {} }
    d.npcs[id] = rec
    rec.name = name or rec.name
    rec.seen = time()
    local mapID = ns:PlayerMapID()
    local pos = mapID and ns:PlayerPosition(mapID)
    if pos then rec.mapID, rec.x, rec.y = mapID, pos.x, pos.y end
    return rec, id
end

---------------------------------------------------------------------------
-- Learning
---------------------------------------------------------------------------
local function remember(rec, questID, title, level, trivial, repeatable)
    questID = ns.SafeNum(questID)
    if not rec or not questID then return end
    rec.offers[questID] = {
        title = ns.IsSafe(title) and title or nil,
        level = ns.SafeNum(level),
        trivial = trivial and true or nil,
        repeatable = repeatable and true or nil,
    }
end

-- Gossip window (NPCs with several options).
local function onGossipShow()
    local rec = touchNPC()
    if not rec then return end
    local G = _G.C_GossipInfo
    if type(G) == "table" and type(G.GetAvailableQuests) == "function" then
        for _, q in ipairs(G.GetAvailableQuests() or {}) do
            remember(rec, q.questID, q.title, q.questLevel, q.isTrivial, q.repeatable)
        end
        for _, q in ipairs((type(G.GetActiveQuests) == "function" and G.GetActiveQuests()) or {}) do
            local id = ns.SafeNum(q.questID)
            if id then rec.takes[id] = ns.IsSafe(q.title) and q.title or true end
        end
    end
end

-- Quest greeting (an NPC with only quests, no gossip).
local function onQuestGreeting()
    local rec = touchNPC()
    if not rec then return end
    local n = ns.SafeNum(type(_G.GetNumAvailableQuests) == "function" and _G.GetNumAvailableQuests()) or 0
    for i = 1, n do
        local trivial, _, repeatable, _, questID
        if type(_G.GetAvailableQuestInfo) == "function" then
            trivial, _, repeatable, _, questID = _G.GetAvailableQuestInfo(i)
        end
        local title = type(_G.GetAvailableTitle) == "function" and _G.GetAvailableTitle(i)
        local level = type(_G.GetAvailableLevel) == "function" and _G.GetAvailableLevel(i)
        remember(rec, questID, title, level, trivial, repeatable)
    end
    local m = ns.SafeNum(type(_G.GetNumActiveQuests) == "function" and _G.GetNumActiveQuests()) or 0
    for i = 1, m do
        local id = type(_G.GetActiveQuestID) == "function" and ns.SafeNum(_G.GetActiveQuestID(i))
        local title = type(_G.GetActiveTitle) == "function" and _G.GetActiveTitle(i)
        if id then rec.takes[id] = ns.IsSafe(title) and title or true end
    end
end

-- A single quest offered straight away (quest detail window).
local pendingGiver
local function onQuestDetail()
    local rec, npcID = touchNPC()
    local questID = type(_G.GetQuestID) == "function" and ns.SafeNum(_G.GetQuestID())
    if not rec or not questID then return end
    local title = type(_G.GetTitleText) == "function" and _G.GetTitleText()
    local existing = rec.offers[questID]
    remember(rec, questID, title, existing and existing.level, existing and existing.trivial, existing and existing.repeatable)
    pendingGiver = { questID = questID, npcID = npcID }
end

-- Accepting it: remember who gave it (the usual hand-in fallback).
local function onQuestAccepted(_, a, b)
    -- QUEST_ACCEPTED is (questLogIndex, questID) on older clients, (questID) on newer.
    local questID = ns.SafeNum(b) or ns.SafeNum(a)
    local d = db()
    if d and pendingGiver and pendingGiver.questID == questID then
        d.questGivers[questID] = pendingGiver.npcID
    end
    pendingGiver = nil
end

-- Hand-in windows: this NPC takes the quest back.
local function onQuestProgressOrComplete()
    local rec = touchNPC()
    local questID = type(_G.GetQuestID) == "function" and ns.SafeNum(_G.GetQuestID())
    if not rec or not questID then return end
    local title = type(_G.GetTitleText) == "function" and _G.GetTitleText()
    rec.takes[questID] = ns.IsSafe(title) and title or true
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------
function QG:NPC(npcID) local d = db(); return d and d.npcs[npcID] end

--- True when this character can't take the quest any more: done, or
--- already in the log.
local function unavailable(questID)
    if ns.QuestData.cache[questID] and ns.QuestData.cache[questID].inLog then return true end
    return ns.QuestData:IsCompleted(questID)
end

--- What an NPC offers that this character can still accept, sorted by level:
--- list of { questID, title, level, trivial }.
function QG:Offers(npcID)
    local rec = self:NPC(npcID)
    local out = {}
    for questID, q in pairs(rec and rec.offers or {}) do
        if q.repeatable or not unavailable(questID) then
            table.insert(out, { questID = questID, title = q.title, level = q.level, trivial = q.trivial })
        end
    end
    table.sort(out, function(a, b)
        if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) < (b.level or 0) end
        return (a.title or "") < (b.title or "")
    end)
    return out
end

--- Quests in your log this NPC is known to take back (or gave you).
function QG:HandIns(npcID)
    local rec, d = self:NPC(npcID), db()
    local out = {}
    for _, e in ipairs(ns.QuestData:Scan()) do
        if not e.isHeader then
            local takes = rec and rec.takes[e.questID]
            local gave = d and d.questGivers[e.questID] == npcID
            if takes or gave then
                table.insert(out, { questID = e.questID, title = e.title,
                    complete = ns.QuestData:IsComplete(e.questID), confirmed = takes ~= nil })
            end
        end
    end
    return out
end

--- Where to hand a quest in when the client gives no marker: the NPC known
--- to take it, else the one who gave it (usually the same person).
function QG:TurnInLocation(questID)
    local d = db()
    if not d then return nil end
    local best, approximate
    for _, rec in pairs(d.npcs) do
        if rec.takes and rec.takes[questID] and rec.mapID then best = rec; break end
    end
    if not best then
        local giver = d.questGivers[questID] and d.npcs[d.questGivers[questID]]
        if giver and giver.mapID then best, approximate = giver, true end
    end
    if not best then return nil end
    return {
        uiMapID = best.mapID, x = best.x, y = best.y,
        world = ns:WorldPos(best.mapID, best.x, best.y),
        source = "npc", npcName = best.name, approximate = approximate,
    }
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local function safe(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then ns:Debug("quest givers: %s", tostring(err)) end
    end
end
ns:RegisterEvent("GOSSIP_SHOW", safe(onGossipShow), QG)
ns:RegisterEvent("QUEST_GREETING", safe(onQuestGreeting), QG)
ns:RegisterEvent("QUEST_DETAIL", safe(onQuestDetail), QG)
ns:RegisterEvent("QUEST_ACCEPTED", safe(onQuestAccepted), QG)
ns:RegisterEvent("QUEST_PROGRESS", safe(onQuestProgressOrComplete), QG)
ns:RegisterEvent("QUEST_COMPLETE", safe(onQuestProgressOrComplete), QG)

return QG
