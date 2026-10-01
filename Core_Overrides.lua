--[[---------------------------------------------------------------------------
    Solaryn's Expedition — hand-verified overrides and quest chain knowledge.

    The addon reads objective positions from the client (C_QuestLog), which is
    accurate for most quests but wrong or missing in a few known cases: indoor
    instanced objectives, objectives that moved between map layers, and quests
    whose turn-in NPC sits somewhere the client doesn't flag.

    This file is the escape hatch. Everything here is user-editable data (it
    lives in SolarynDB.overrides, so it survives across characters), and
    every override is optional — the client is always the base.

    Coordinate convention: map coordinates are the same 0-1 fractions the
    client uses for C_Map.GetPlayerMapPosition, so you can read any value
    straight off /dump without conversion. 0.5,0.5 is the centre of the map.
    (Coordinate addons display these multiplied by 100.)
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.Overrides = {}

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------
local function db()
    return _G.SolarynDB
end

--- Get the override record for a quest ID, or nil.
function ns.Overrides:Get(questID)
    local d = db()
    if not d then return nil end
    return d.overrides[questID]
end

--- Write an override record. `record` is stored verbatim; the panel only ever
--- writes fields it validated, so nothing executable ends up in SavedVariables.
function ns.Overrides:Set(questID, record)
    local d = db()
    if not d or not questID then return false end
    d.overrides[questID] = record
    return true
end

function ns.Overrides:Clear(questID)
    local d = db()
    if not d then return false end
    d.overrides[questID] = nil
    return true
end

function ns.Overrides:List()
    local d = db()
    if not d then return {} end
    return d.overrides
end

function ns.Overrides:Count()
    local d = db()
    if not d then return 0 end
    return ns:Count(d.overrides)
end

---------------------------------------------------------------------------
-- Resolution
---------------------------------------------------------------------------
--- The objective positions to use for a quest: override if present, else client.
-- Returns a list of { uiMapID, x, y, label, kind }.
function ns.Overrides:ResolveObjectives(questID, clientObjectives)
    local rec = self:Get(questID)
    if rec and rec.objectives and #rec.objectives > 0 then
        local out = {}
        for i, obj in ipairs(rec.objectives) do
            if type(obj) == "table" and obj.uiMapID and obj.x and obj.y then
                table.insert(out, {
                    uiMapID = obj.uiMapID,
                    x = obj.x,
                    y = obj.y,
                    label = obj.label or ("objective " .. i),
                    kind = "override",
                })
            end
        end
        if #out > 0 then return out, true end
    end
    return clientObjectives, false
end

--- Turn-in location for a quest: override if present.
function ns.Overrides:ResolveTurnIn(questID, clientTurnIn)
    local rec = self:Get(questID)
    if rec and rec.turnIn and rec.turnIn.uiMapID and rec.turnIn.x and rec.turnIn.y then
        return { uiMapID = rec.turnIn.uiMapID, x = rec.turnIn.x, y = rec.turnIn.y }, true
    end
    return clientTurnIn, false
end

---------------------------------------------------------------------------
-- Built-in hand-verified corrections
---------------------------------------------------------------------------
-- Shipped as defaults, copied into SavedVariables on first load so the user
-- can inspect and edit them. Kept intentionally tiny: only spots we know the
-- client gets wrong. Format:
--   [questID] = {
--     turnIn = { uiMapID = <id>, x = <0-1>, y = <0-1>, name = "NPC" },
--     objectives = { { uiMapID = <id>, x = <0-1>, y = <0-1>, label = "..." } },
--     note = "why this override exists",
--   }
ns.Overrides.DEFAULTS = {
    -- Filled in as quests are confirmed wrong on a live character. Structure
    -- documented above so entries are trivial to add.
}

--- Seed SavedVariables with the shipped defaults (idempotent).
function ns.Overrides:Seed()
    local d = db()
    if not d then return end
    d.overrides = d.overrides or {}
    for questID, rec in pairs(self.DEFAULTS) do
        if d.overrides[questID] == nil then
            d.overrides[questID] = ns:Copy(rec)
        end
    end
end

---------------------------------------------------------------------------
-- Quest chain knowledge
---------------------------------------------------------------------------
-- Follow-up quests. The client exposes quest chains indirectly (a quest
-- returns its follow-up when offered), which only works once you've seen it.
-- Recording chains here lets the route planner and suggester prefer the next
-- link in a story you've already started, instead of treating every quest in
-- the log as an isolated item.
--
-- quests = { [fromQuestID] = { followUpID, followUpID, ... } }
ns.Chains = {}

--- Seed with any chains the user has recorded.
function ns.Chains:Seed()
    local d = db()
    if not d then return end
    d.chains = d.chains or {}
end

--- Record that `followUpID` follows `fromQuestID`. Idempotent.
function ns.Chains:Link(fromQuestID, followUpID)
    local d = db()
    if not d or not fromQuestID or not followUpID then return false end
    d.chains = d.chains or {}
    local list = d.chains[fromQuestID]
    if not list then
        list = {}
        d.chains[fromQuestID] = list
    end
    for _, id in ipairs(list) do
        if id == followUpID then return false end
    end
    table.insert(list, followUpID)
    return true
end

--- Follow-up IDs for a quest (may be empty).
function ns.Chains:FollowUps(questID)
    local d = db()
    if not d or not d.chains then return {} end
    return d.chains[questID] or {}
end

--- Quests whose follow-up is `questID` — i.e. what could lead here.
function ns.Chains:Predecessors(questID)
    local out = {}
    local d = db()
    if not d or not d.chains then return out end
    for from, list in pairs(d.chains) do
        for _, id in ipairs(list) do
            if id == questID then
                table.insert(out, from)
                break
            end
        end
    end
    return out
end

--- Depth of a chain from its recorded roots, used to rank story continuity.
-- Returns a map questID -> depth. Chains are shallow by design; the recursion
-- is bounded by the number of recorded links so a cycle can't hang the client.
function ns.Chains:Depths(maxDepth)
    local d = db()
    local depths = {}
    if not d or not d.chains then return depths end
    maxDepth = maxDepth or 8

    -- Reverse map: followUpID -> originating questID (first writer wins).
    local roots = {}
    for from, list in pairs(d.chains) do
        for _, id in ipairs(list) do
            if roots[id] == nil then roots[id] = from end
        end
    end

    local function walk(id, depth, seen)
        if depth > maxDepth or seen[id] then return end
        seen[id] = true
        local d0 = depths[id]
        if d0 == nil or depth < d0 then
            depths[id] = depth
            local parent = roots[id]
            if parent then walk(parent, depth + 1, seen) end
        end
    end

    for id in pairs(roots) do
        walk(id, 0, {})
    end
    return depths
end