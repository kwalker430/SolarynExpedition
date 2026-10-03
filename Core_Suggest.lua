--[[---------------------------------------------------------------------------
    Solaryn's Expedition — "what should I do next".

    Produces a ranked list of concrete next actions, not a restatement of the
    quest log. Four kinds, in rough priority order:

      TURNOUT   a quest is finished and needs handing in (pure XP/money you are
                leaving on the table)
      OBJECTIVE a quest with a known, reachable next objective
      UNLOCK    a neighbouring zone you have barely touched, at your level
      EXPLORE   a known zone with uncovered ground nearby

    Scoring is a weighted sum over the tunables in ns.Defaults.settings, so the
    panel's sliders change behaviour without any code changes here.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.Suggest = {}

local Suggest = ns.Suggest

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
--- Ranked suggestions. Returns a list of:
--   { kind, title, detail, questID, uiMapID, x, y, world, distance, score, color }
--
-- Sets _computing while it runs so the notifications it emits can't trigger a
-- re-render that calls back into Compute (which recursed to a C stack overflow).
function Suggest:Compute()
    local settings = ns.Settings()
    local limit = settings.suggestLimit or 5
    local out = {}

    -- Re-entrancy guard: if Compute is somehow entered while already running,
    -- return the previous result rather than recursing.
    if Suggest._computing then
        return Suggest.last or {}
    end
    Suggest._computing = true

    -- Make sure the map tree exists before we classify anything against it.
    if ns.ZoneData and ns.ZoneData.EnsureLoaded then ns.ZoneData:EnsureLoaded() end

    local playerLevel = ns.UnitLevelSafe()
    local playerMap = ns:PlayerMapID()
    local playerPos = ns:PlayerPosition(playerMap)

    ------------------------------------------------------------------
    -- Turn-ins
    ------------------------------------------------------------------
    for _, e in ipairs(ns.QuestData:Scan()) do
        if not e.isHeader and not e.isHidden then
            if ns.QuestData:IsComplete(e.questID) then
                local turnIn = ns.QuestData:TurnInLocation(e.questID)
                local dist = turnIn and ns:DistanceBetween(playerPos, turnIn) or nil
                table.insert(out, {
                    kind = ns.SUGGEST.TURNOUT,
                    title = e.title,
                    detail = "Ready to hand in" .. (dist and (" — " .. ns:FormatDistance(dist)) or ""),
                    questID = e.questID,
                    uiMapID = turnIn and turnIn.uiMapID or playerMap,
                    x = turnIn and turnIn.x or nil,
                    y = turnIn and turnIn.y or nil,
                    world = turnIn and turnIn.world or nil,
                    distance = dist,
                    level = e.level,
                    -- Turn-ins are almost always the right next action: they end
                    -- a quest you already paid travel for.
                    score = 1000 + settings.wTurnIn,
                    color = ns.Colors.turnin,
                })
            end
        end
    end

    ------------------------------------------------------------------
    -- Objectives
    ------------------------------------------------------------------
    local chainDepths = ns.Chains:Depths()

    for _, e in ipairs(ns.QuestData:Scan()) do
        if not e.isHeader and not e.isHidden and not ns.QuestData:IsComplete(e.questID) then
            if not (settings.ignoreTasks and e.isTask)
                and not (e.isDungeon and not settings.includeDungeons) then
                -- Quests with no known location are still listed (ranked
                -- lower): silently dropping them hid most of the quest log
                -- whenever the client gave no marker.
                local wp = ns.QuestData:PrimaryWaypoint(e.questID)
                local dist = wp and ns:DistanceBetween(playerPos, wp) or nil

                local score = 0
                score = score + 100                      -- above unlocks/explore
                if dist then
                    score = score - (dist / 1000) * settings.wDistance
                else
                    score = score - 50                   -- unknown location: deprioritise
                end
                if wp and wp.uiMapID == playerMap then
                    score = score + settings.wSameMap
                end
                if e.level and playerLevel then
                    score = score + (1 - math.min(1, math.abs(e.level - playerLevel) / 10)) * settings.wLevel
                end
                if e.isStory then score = score + settings.wStory end
                if e.isTask then score = score + settings.wTask end

                -- Continuity: quests later in a chain you've started are
                -- usually the intended order, so nudge them up.
                if chainDepths[e.questID] then
                    score = score + 1
                end

                local pending = ns.QuestData:NextObjectiveText(e.questID)

                table.insert(out, {
                    kind = ns.SUGGEST.OBJECTIVE,
                    title = e.title,
                    detail = pending or "In progress",
                    questID = e.questID,
                    uiMapID = wp and wp.uiMapID or nil,
                    x = wp and wp.x or nil, y = wp and wp.y or nil,
                    world = wp and wp.world or nil,
                    distance = dist,
                    level = e.level,
                    score = score,
                    color = ns.Colors.quest,
                })
            end
        end
    end

    ------------------------------------------------------------------
    -- Unlocks: neighbouring zones worth moving to
    ------------------------------------------------------------------
    -- Only when it matters: you've outgrown this zone (or nearly), or it's
    -- too dangerous for you yet. Then name the nearest zone that fits.
    local prog = ns.ZoneData:Progression(1)
    local cur = prog.current
    local needsMove = cur and cur.status and cur.status ~= "ok"
    local target = prog.next[1]
    if needsMove and target then
        local why = cur.status == "high" and string.format("%s is above your level", cur.name)
            or string.format("you're outgrowing %s", cur.name)
        table.insert(out, {
            kind = ns.SUGGEST.UNLOCK,
            title = target.name,
            detail = string.format("Levels %d–%d  ·  %s", target.range.min, target.range.max, why),
            uiMapID = target.mapID,
            distance = target.distance,
            level = target.range.min,
            score = 10 + (cur.status == "low" and 5 or 0),
            color = ns.Colors.unlock,
        })
    end

    ------------------------------------------------------------------
    -- Explore: current zone, uncovered ground
    ------------------------------------------------------------------
    if playerMap and settings.trackingEnabled then
        local cov = ns.Explored:Coverage(playerMap)
        if cov and cov < 0.85 then
            table.insert(out, {
                kind = ns.SUGGEST.EXPLORE,
                title = ns.ZoneData:Name(playerMap),
                detail = string.format("Only %s of this zone explored", ns:FormatPct(cov)),
                uiMapID = playerMap,
                distance = nil,
                score = 5 + cov * 3,
                color = ns.Colors.explore,
            })
        end
    end

    ------------------------------------------------------------------
    -- User overrides win, then sort
    ------------------------------------------------------------------
    local char = ns.CharDB()
    local overrides = char and char.suggestOverrides or {}

    for _, s in ipairs(out) do
        if s.questID and overrides[s.questID] == "hide" then
            s.hidden = true
        elseif s.questID and overrides[s.questID] == "top" then
            s.score = s.score + 5000
            s.pinned = true
        end
    end

    local visible = {}
    for _, s in ipairs(out) do
        if not s.hidden then table.insert(visible, s) end
    end

    if settings.sortByDistance then
        -- Nearest first. Pinned quests stay on top, quests come before zone
        -- suggestions, and quests with no known location follow the located
        -- ones; ties fall back to the weighted score.
        table.sort(visible, function(a, b)
            if (a.pinned or false) ~= (b.pinned or false) then return a.pinned or false end
            local qa, qb = a.questID ~= nil, b.questID ~= nil
            if qa ~= qb then return qa end
            local da, db = a.distance, b.distance
            if da and db then
                if da ~= db then return da < db end
            elseif da or db then
                return da ~= nil
            end
            return a.score > b.score
        end)
    else
        table.sort(visible, function(a, b) return a.score > b.score end)
    end

    for i = #visible, 1, -1 do
        if i > limit then table.remove(visible, i) end
    end

    Suggest.last = visible

    -- Order matters: _computing must stay TRUE across the notification, so a
    -- listener that calls Compute() hits the re-entrancy guard and returns the
    -- cached result instead of starting a fresh compute that fires again.
    -- Clearing it before Fire() left exactly the loop that overflowed the C stack.
    local shouldNotify = not Suggest._suppressNotify
    Suggest._suppressNotify = false

    if shouldNotify then
        local ok, err = pcall(function() ns:Fire("suggestions_updated", visible) end)
        if not ok then ns:Debug("suggestion listener error: %s", tostring(err)) end
    end

    Suggest._computing = false
    return visible
end

--- Recompute and notify.
-- Call this when something real changed (quest log, zone, settings). The panel
-- calls Compute() directly while drawing, which must not re-notify.
function Suggest:Recompute()
    if Suggest._computing then return Suggest.last or {} end
    Suggest._suppressNotify = false
    return self:Compute()
end

--- Recompute without notifying listeners (used during a render).
function Suggest:ComputeQuietly()
    Suggest._suppressNotify = true
    local ok, res = pcall(self.Compute, self)
    Suggest._suppressNotify = false
    if ok then return res end
    return Suggest.last or {}
end

--- Hide a quest from suggestions (persisted per character).
function Suggest:Hide(questID)
    local char = ns.CharDB()
    if not char then return end
    char.suggestOverrides = char.suggestOverrides or {}
    char.suggestOverrides[questID] = "hide"
    self:Recompute()
end

--- Pin a quest to the top of the list.
function Suggest:PinTop(questID)
    local char = ns.CharDB()
    if not char then return end
    char.suggestOverrides = char.suggestOverrides or {}
    char.suggestOverrides[questID] = "top"
    self:Recompute()
end

--- Clear any override on a quest.
function Suggest:ClearOverride(questID)
    local char = ns.CharDB()
    if not char then return end
    char.suggestOverrides = char.suggestOverrides or {}
    char.suggestOverrides[questID] = nil
    self:Recompute()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local function onChanged()
    -- A real change trigger (quest log, zone, login): recompute and notify so
    -- any visible panel updates.
    ns:Debounce("suggest", 0.25, function() Suggest:Recompute() end)
end

ns:RegisterEvent("QUEST_LOG_UPDATE", onChanged, Suggest)
ns:RegisterEvent("QUEST_TURNED_IN", onChanged, Suggest)
ns:RegisterEvent("QUEST_ACCEPTED", onChanged, Suggest)
ns:RegisterEvent("PLAYER_ENTERING_WORLD", onChanged, Suggest)
return Suggest