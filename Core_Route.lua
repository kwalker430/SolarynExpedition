--[[---------------------------------------------------------------------------
    Solaryn's Expedition — route planner.

    Builds an ordered list of stops from the quest log, chains objectives into
    a walkable sequence, and can drop map pins / set a waypoint for the next
    stop. Stored per character in SolarynCharDB.route.

    The router is deliberately simple: nearest-neighbour over objective waypoints
    using continent-space distance. With a typical 15-quest log on one or two
    maps this is effectively optimal and costs nothing, and unlike a real
    travelling-salesman solve it stays instant when the log changes on zone change
    or objective completion.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.Route = {}

local Route = ns.Route

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------
local function routeDB()
    local c = _G.SolarynCharDB
    return c and c.route
end

function Route:Get()
    return routeDB() or { stops = {}, built = 0 }
end

function Route:Save(state)
    local c = _G.SolarynCharDB
    if c then c.route = state end
end

function Route:Clear()
    self:Save({ stops = {}, built = 0 })
    ns:Fire("route_changed")
end

---------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------
--- Resolve the ordered objective positions for one quest.
-- Yields a list of { kind="turnin"|"objective", questID, uiMapID, x, y, world }.
local function QuestStops(questID)
    local QuestData = ns.QuestData
    local stops = {}

    local pending = QuestData:PendingObjectives(questID)
    local hasPending = #pending > 0
    local isComplete = QuestData:IsComplete(questID)

    -- Turn-in handling covers two different cases:
    --   * the quest is finished, so the ONLY stop is the turn-in NPC
    --   * the quest is unfinished, so we stop at the NPC first (useful when
    --     objectives backtrack through the same hub) before the objectives
    -- Either way the turn-in is worth a stop, and a finished quest is the
    -- single most valuable stop on the route.
    if ns.Settings().includeTurnIns and (hasPending or isComplete) then
        local turnIn = QuestData:TurnInLocation(questID)
        if turnIn then
            table.insert(stops, {
                kind = "turnin",
                questID = questID,
                uiMapID = turnIn.uiMapID,
                x = turnIn.x, y = turnIn.y,
                world = turnIn.world,
                npcName = turnIn.npcName,
            })
        end
    end

    if hasPending then
        local wps = QuestData:Waypoints(questID)
        -- An override, when present, replaces the client's positions entirely.
        local resolved, overridden = ns.Overrides:ResolveObjectives(questID, wps)
        for _, wp in ipairs(resolved) do
            if type(wp) == "table" and wp.uiMapID and wp.x and wp.y then
                table.insert(stops, {
                    kind = "objective",
                    questID = questID,
                    uiMapID = wp.uiMapID,
                    x = wp.x, y = wp.y,
                    world = wp.world,
                    overridden = overridden or nil,
                })
            end
        end
    end

    return stops
end

--- Order stops into a walking route, nearest-next from `from`.
-- Hand-ins are weighed as farther than they are (settings.batchTurnIns), so
-- the route finishes the objectives around you before walking back to hand
-- in, the way you'd quest an area by hand. A hand-in that's almost on top of
-- you (NEAR_HANDIN_YARDS) costs nothing extra: grab it on the way.
--
-- Objectives are also weighed by how far the quest's level is from yours
-- (settings.routeLevelWeight per level), so quests at your level come first
-- and ones well above it drift to the end. Levels below yours count half:
-- those quests are safe, just worth less. Hand-ins aren't weighed by level;
-- the dangerous part is already done.
local NEAR_HANDIN_YARDS = 75
local HANDIN_WEIGHT_BATCHED, HANDIN_WEIGHT_EAGER = 3.0, 1.15

local function levelFactor(stop, playerLevel, perLevel)
    local ql = tonumber(stop.questLevel)
    if not ql or not playerLevel or perLevel <= 0 then return 1 end
    local gap = ql - playerLevel
    if gap < 0 then gap = -gap / 2 end
    return 1 + gap * perLevel
end
Route.LevelFactor = levelFactor

local function orderStops(stops, from)
    local settings = ns.Settings()
    local weight = settings.batchTurnIns and HANDIN_WEIGHT_BATCHED or HANDIN_WEIGHT_EAGER
    local playerLevel = ns.UnitLevelSafe()
    local perLevel = tonumber(settings.routeLevelWeight) or 0
    local pool, ordered = {}, {}
    for i, st in ipairs(stops) do pool[i] = st end
    local cur = from
    while #pool > 0 do
        local bestIdx, bestCost = 1, math.huge
        for i, st in ipairs(pool) do
            local d = (cur and ns:DistanceBetween(cur, st)) or 1e9
            if st.kind == "turnin" then
                if d > NEAR_HANDIN_YARDS then d = d * weight end
            else
                d = d * levelFactor(st, playerLevel, perLevel)
            end
            if d < bestCost then bestIdx, bestCost = i, d end
        end
        local chosen = table.remove(pool, bestIdx)
        table.insert(ordered, chosen)
        cur = chosen
    end
    for i, st in ipairs(ordered) do st.index = i end
    return ordered
end
Route.OrderStops = orderStops

local QuestSortScore   -- defined below Build

--- Build a route from the current quest log.
-- Returns a state table: { stops = {...}, built = time(), questIDs = {...} }
function Route:Build(opts)
    local settings = ns.Settings()
    opts = opts or {}
    local limit = opts.limit or settings.maxRouteQuests

    local QuestData = ns.QuestData
    local entries = QuestData:Scan()

    -- Collect candidate quests, skipping headers and anything suppressed.
    -- Dungeon quests stay out unless asked for: they can't be done on the way.
    -- Once one is complete its hand-in is an ordinary stop, so it comes back.
    local candidates = {}
    for _, e in ipairs(entries) do
        if not e.isHeader and not e.isHidden then
            local skipDungeon = e.isDungeon and not settings.includeDungeons
                and not QuestData:IsComplete(e.questID)
            if not (settings.ignoreTasks and e.isTask) and not skipDungeon then
                table.insert(candidates, e)
            end
        end
    end

    -- Keep only quests we can actually locate.
    local located = {}
    for _, e in ipairs(candidates) do
        local stops = QuestStops(e.questID)
        if #stops > 0 then
            e._stops = stops
            table.insert(located, e)
        end
    end

    if #located == 0 then
        self:Save({ stops = {}, built = time(), questIDs = {} })
        ns:Fire("route_changed")
        return self:Get()
    end

    -- Order quests by proximity to the player, so the route starts nearby.
    local pp = ns:PlayerPosition(ns:PlayerMapID())
    table.sort(located, function(a, b)
        return QuestSortScore(a, pp) > QuestSortScore(b, pp)
    end)

    local allStops = {}
    local questIDs = {}
    for _, e in ipairs(located) do
        if #questIDs < limit then
            for _, s in ipairs(e._stops) do
                s.title = e.title
                s.questLevel = e.level
                s.isTask = e.isTask
                table.insert(allStops, s)
            end
            table.insert(questIDs, e.questID)
        end
    end

    -- Order the individual stops into a walking route from the player.
    local ordered = orderStops(allStops, pp)

    -- While guiding, stops already reached stay done: they go first and the
    -- guide resumes after them. (Opening the panel rebuilds a stale route, and
    -- without this, accepting a quest sent you back to a stop you'd reached.)
    local prev = self:Get()
    local wasGuiding = prev.guiding
    local visited = wasGuiding and prev.visited or nil
    local current = 1
    if visited then
        local done, rest = {}, {}
        for _, st in ipairs(ordered) do
            table.insert(visited[Route.StopKey(st)] and done or rest, st)
        end
        current = #done + 1
        ordered = done                       -- (same table: count taken above)
        for _, st in ipairs(rest) do table.insert(ordered, st) end
        for i, st in ipairs(ordered) do st.index = i end
    end

    local state = {
        stops = ordered,
        built = time(),
        questIDs = questIDs,
        total = #ordered,
        current = current,
        guiding = wasGuiding or nil,
        visited = visited,
    }
    self:Save(state)
    if wasGuiding and ordered[current] then self:SetWaypointTo(ordered[current]) end
    ns:Fire("route_changed")
    return state
end

-- Ranking helper used inside Build. Declared here so it can reference the
-- suggester weights without creating a load-order dependency.
function QuestSortScore(entry, playerPos)   -- the local declared above
    local settings = ns.Settings()
    local score = 0

    -- Turn-in-ready quests jump the queue.
    if ns.QuestData:IsComplete(entry.questID) then
        score = score + settings.wTurnIn
    end

    -- Distance penalty.
    local d = ns.QuestData:ObjectiveDistance(entry.questID)
    if d and playerPos then
        score = score - (d / 1000) * settings.wDistance
    elseif d then
        score = score - (d / 1000) * settings.wDistance
    end

    -- Level fit.
    if entry.level and ns.UnitLevelSafe then
        local fit = 1 - math.min(1, math.abs(entry.level - ns.UnitLevelSafe()) / 10)
        score = score + fit * settings.wLevel
    end

    if entry.isStory then score = score + settings.wStory end
    if entry.isTask then score = score + settings.wTask end

    return score
end

---------------------------------------------------------------------------
-- Querying
---------------------------------------------------------------------------
function Route:Count()
    return #(self:Get().stops or {})
end

--- The stop the player is heading to (the first unfinished one).
function Route:Next()
    local state = self:Get()
    local stops = state.stops
    if not stops or #stops == 0 then return nil end
    return stops[state.current or 1]
end

--- Index of the stop the player is heading to.
function Route:CurrentIndex()
    return self:Get().current or 1
end

function Route:IsGuiding()
    return self:Get().guiding and true or false
end

function Route:At(i)
    local stops = self:Get().stops
    if not stops then return nil end
    return stops[i]
end

--- Rebuild only if the log looks meaningfully different since the last build.
function Route:IsStale()
    local state = self:Get()
    if not state.built then return true end
    if not ns.QuestData:Scan() then return true end
    -- Cheap fingerprint: sorted list of quest IDs in the log.
    local ids = {}
    for _, e in ipairs(ns.QuestData:Scan()) do
        if not e.isHeader then table.insert(ids, e.questID) end
    end
    table.sort(ids)
    local fp = table.concat(ids, ",")
    if fp ~= state.fingerprint then return true end
    return false
end

function Route:StampFingerprint()
    local state = self:Get()
    local ids = {}
    for _, e in ipairs(ns.QuestData:Scan()) do
        if not e.isHeader then table.insert(ids, e.questID) end
    end
    table.sort(ids)
    state.fingerprint = table.concat(ids, ",")
    self:Save(state)
end

---------------------------------------------------------------------------
-- Waypoint + map pin control
---------------------------------------------------------------------------
--- Set the client map waypoint to a route stop.
--- Point the client waypoint at a stop, without touching guide state.
function Route:SetWaypointTo(stop)
    if not stop or not stop.uiMapID or not stop.x then return false end
    if ns.Has.canSetWaypoint and not ns.Try("C_Map", "CanSetUserWaypointOnMap", stop.uiMapID) then
        ns:Print("cannot place a waypoint on %s.", ns:MapName(stop.uiMapID))
        return false
    end
    return ns.MapPins:SetWaypoint(stop.uiMapID, stop.x, stop.y)
end

--- Stable identity for a stop across rebuilds.
function Route.StopKey(stop)
    return string.format("%s:%s:%.4f:%.4f", tostring(stop.questID), tostring(stop.kind),
        tonumber(stop.x) or 0, tonumber(stop.y) or 0)
end

--- Find a stop's position in the current route (stops are saved tables,
--- so match by content rather than identity).
local function indexOf(stops, stop)
    if stop.index and stops[stop.index] and stops[stop.index].questID == stop.questID
        and stops[stop.index].kind == stop.kind then
        return stop.index
    end
    for i, s in ipairs(stops) do
        if s == stop or (s.questID == stop.questID and s.kind == stop.kind and s.x == stop.x and s.y == stop.y) then
            return i
        end
    end
end

--- Set a waypoint to a stop. A stop on the route also starts the guide from
--- that stop, so the waypoint moves on by itself as you go.
function Route:GoToStop(stop)
    if not stop then return false end
    if not ns.Has.setUserWaypoint then
        ns:Print("waypoint API unavailable in this build.")
        return false
    end
    local ok = self:SetWaypointTo(stop)
    if not ok then return false end

    local state = self:Get()
    local i = indexOf(state.stops or {}, stop)
    if i and ns.Settings().autoAdvance then
        state.current, state.guiding = i, true
        self:Save(state)
        ns:Fire("route_changed")
    end
    return true
end

---------------------------------------------------------------------------
-- Guide: follow the route stop by stop
---------------------------------------------------------------------------
-- While guiding, the waypoint sits on the current stop. The guide moves on
-- when you arrive within settings.arriveRadius yards, or, with
-- settings.advanceWhenDone, only once the stop's quest work is finished. A
-- stop whose quest is finished or gone from the log is always skipped,
-- whichever mode is on.

--- True once nothing is left to do at this stop.
function Route:IsStopDone(stop)
    local e = stop and ns.QuestData.cache[stop.questID]
    if not e or e.inLog == false then return true end     -- turned in or abandoned
    if stop.kind == "objective" then
        return ns.QuestData:IsComplete(stop.questID)
    end
    return false                                          -- turn-in: done once it leaves the log
end

--- Yards from the player to a stop, or nil.
function Route:DistanceTo(stop)
    if not stop then return nil end
    local pp = ns:PlayerPosition(stop.uiMapID) or ns:PlayerPosition(ns:PlayerMapID())
    return ns:DistanceBetween(pp, stop)
end

local function playCue()
    local kit = _G.SOUNDKIT
    if type(_G.PlaySound) == "function" and type(kit) == "table" and kit.MAP_PING then
        pcall(_G.PlaySound, kit.MAP_PING)
    end
end

--- Start (or restart) the guide at a stop index (default: the current one).
function Route:Guide(index)
    local state = self:Get()
    local stops = state.stops or {}
    if #stops == 0 then
        ns:Print("no route to follow. Build one first.")
        return false
    end
    state.current = math.max(1, math.min(#stops, index or state.current or 1))
    -- A new guide starts with a clean slate of reached stops.
    if not state.guiding then state.visited = nil end
    state.guiding = true
    self:Save(state)
    -- Skip anything already finished before pointing the way.
    if self:IsStopDone(stops[state.current]) then
        return self:Advance("done")
    end
    local stop = stops[state.current]
    self:SetWaypointTo(stop)
    ns:Print("guiding: stop %d of %d — %s (%s)", state.current, #stops,
        ns:Truncate(stop.title or "?", 30), ns:MapName(stop.uiMapID))
    ns:Fire("route_changed")
    return true
end

function Route:StopGuiding()
    local state = self:Get()
    state.guiding, state.visited = nil, nil
    self:Save(state)
    ns:Fire("route_changed")
end

--- Move to the next unfinished stop. `reason` is "arrived", "done" or
--- "skipped", for the chat message.
function Route:Advance(reason)
    local state = self:Get()
    local stops = state.stops or {}
    local from = stops[state.current or 1]
    if from then
        state.visited = state.visited or {}
        state.visited[Route.StopKey(from)] = true
    end
    local i = (state.current or 1) + 1
    while stops[i] and self:IsStopDone(stops[i]) do i = i + 1 end

    if not stops[i] then
        state.current = #stops + 1
        state.guiding, state.visited = nil, nil
        self:Save(state)
        if ns.Settings().clearWaypointOnArrive then ns.MapPins:ClearWaypoint() end
        ns:Print("route complete!")
        playCue()
        ns:Fire("route_changed")
        return false
    end

    state.current = i
    self:Save(state)
    local stop = stops[i]
    self:SetWaypointTo(stop)
    local verb = reason == "arrived" and "arrived" or reason == "skipped" and "skipped" or "done"
    ns:Print("%s — next stop %d of %d: %s (%s)", verb, i, #stops,
        ns:Truncate(stop.title or "?", 30), ns:MapName(stop.uiMapID))
    playCue()
    ns:Fire("route_changed")
    return true
end

--- Check the current stop and advance if it's reached or finished.
-- `questChanged` is true when called for a quest event, which is the only
-- time completion needs re-checking; the frequent position ticks only
-- measure distance.
--- Re-plan the stops not yet reached, from where the player is now.
-- Stops before the current one (already done) keep their places.
function Route:Replan()
    local state = self:Get()
    local stops = state.stops or {}
    local cur = state.current or 1
    local head, tail = {}, {}
    for i, st in ipairs(stops) do
        table.insert(i < cur and head or tail, st)
    end
    local pp = ns:PlayerPosition(ns:PlayerMapID())
    for _, st in ipairs(orderStops(tail, pp)) do table.insert(head, st) end
    for i, st in ipairs(head) do st.index = i end
    state.stops = head
    self:Save(state)
end

--- A quest finished mid-route has no hand-in stop yet (those are only added
-- for quests already complete when the route was built). Swap the finished
-- quest's remaining objective stops for its hand-in, then re-plan the rest of
-- the route: the hand-in lands where it fits best, usually after the other
-- objectives nearby rather than straight away.
-- Returns `addedTitles` (list of quest titles whose hand-in was added), or nil.
function Route:PromoteTurnIns()
    local state = self:Get()
    local stops = state.stops or {}
    local cur = state.current or 1
    local hasTurnIn = {}
    for _, st in ipairs(stops) do
        if st.kind == "turnin" then hasTurnIn[st.questID] = true end
    end

    local finished = {}
    for i = cur, #stops do
        local st = stops[i]
        if st.kind == "objective" and not hasTurnIn[st.questID] and not finished[st.questID]
            and ns.QuestData:IsComplete(st.questID) then
            local t = ns.QuestData:TurnInLocation(st.questID)
            if t then finished[st.questID] = { from = st, at = t } end
        end
    end
    if not next(finished) then return nil end

    local kept, added = {}, {}
    for i, st in ipairs(stops) do
        if not (i >= cur and st.kind == "objective" and finished[st.questID]) then
            table.insert(kept, st)
        end
    end
    for questID, f in pairs(finished) do
        table.insert(kept, {
            kind = "turnin", questID = questID, title = f.from.title,
            questLevel = f.from.questLevel, isTask = f.from.isTask,
            uiMapID = f.at.uiMapID, x = f.at.x, y = f.at.y, world = f.at.world,
            npcName = f.at.npcName,
        })
        table.insert(added, f.from.title or "?")
    end
    state.stops = kept
    self:Save(state)
    self:Replan()
    return added
end

function Route:CheckProgress(questChanged)
    local state = self:Get()
    if not state.guiding or not ns.Settings().autoAdvance then return end
    local stop = (state.stops or {})[state.current or 1]
    if not stop then return end

    -- Re-read the log first so a quest that just left it is seen as gone,
    -- whichever module's event handler happened to run first.
    if questChanged then
        ns.QuestData:Scan()
        local added = self:PromoteTurnIns()
        if added then
            state = self:Get()
            stop = state.stops[state.current or 1]
            for _, title in ipairs(added) do
                ns:Print("%s complete — hand-in added to the route.", ns:Truncate(title, 30))
            end
            if stop and not self:IsStopDone(stop) then
                self:SetWaypointTo(stop)
                ns:Print("next: stop %d — %s (%s)", state.current or 1,
                    ns:Truncate(stop.title or "?", 30), ns:MapName(stop.uiMapID))
                ns:Fire("route_changed")
                return
            end
            ns:Fire("route_changed")
        end
    end
    if questChanged and self:IsStopDone(stop) then
        return self:Advance("done")
    end
    -- Arrival only counts when the player opted into advancing on arrival;
    -- by default a stop is finished by finishing its quest work.
    if not ns.Settings().advanceWhenDone then
        local d = self:DistanceTo(stop)
        if d and d <= (ns.Settings().arriveRadius or 30) then
            return self:Advance("arrived")
        end
    end
end

--- Jump the world map to a stop's location.
function Route:ShowOnMap(stop)
    if not stop then return false end
    return ns.MapPins:OpenAt(stop.uiMapID, stop.x, stop.y)
end

--- Map pins for the whole route, so the map shows the full plan at a glance.
function Route:Pins()
    local out = {}
    local stops = self:Get().stops
    for _, s in ipairs(stops or {}) do
        table.insert(out, {
            uiMapID = s.uiMapID,
            position = { x = s.x, y = s.y },
            texture = s.kind == "turnin" and "Interface\\TargetingFrame\\UI-HitMarker" or nil,
            isMini = false,
            isMiniMap = false,
            alpha = 1,
            label = s.title,
        })
    end
    return out
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local function onQuestLogChanged()
    ns.QuestData:ClearPendingLinks()
end

ns:RegisterEvent("QUEST_LOG_UPDATE", onQuestLogChanged, Route)

-- Keeping the route current. Every quest event funnels into one debounced
-- Sync: if the set of quests in the log, or which of them are complete, has
-- changed since the last sync (a quest accepted, finished, handed in or
-- abandoned), the route is rebuilt from where the player stands. Objective
-- progress alone ("4/8") doesn't rebuild. While guiding, Build keeps the
-- stops already reached, so the guide carries on from the re-optimised route;
-- then the current stop is checked for completion as before.
local lastSyncPrint

--- "questID:complete" for every quest in the log, sorted.
local function logFingerprint()
    local parts = {}
    for _, e in ipairs(ns.QuestData:Scan()) do
        if not e.isHeader then
            parts[#parts + 1] = e.questID .. (ns.QuestData:IsComplete(e.questID) and ":c" or ":o")
        end
    end
    table.sort(parts)
    return table.concat(parts, ","), #parts
end

function Route:Sync()
    local print, count = logFingerprint()
    local changed = print ~= lastSyncPrint
    lastSyncPrint = print

    if changed and ns.Settings().autoRebuild and count > 0 then
        local before = self:Next()
        local beforeKey = before and Route.StopKey(before)
        self:Build()
        self:StampFingerprint()
        local after = self:Next()
        if self:IsGuiding() and after and Route.StopKey(after) ~= beforeKey and not self:IsStopDone(after) then
            ns:Print("route updated — next: %s (%s)", ns:Truncate(after.title or "?", 30), ns:MapName(after.uiMapID))
        end
    end
    self:CheckProgress(true)
end

--- Forget the last synced quest log (tests; also forces the next Sync to rebuild).
function Route:ResetSync() lastSyncPrint = nil end

local function onQuestEvent()
    ns:Debounce("route-sync", 0.4, function() Route:Sync() end)
end
for _, event in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED" }) do
    ns:RegisterEvent(event, onQuestEvent, Route)
end

-- Arrival: a light position check twice a second, only while guiding.
local GUIDE_INTERVAL = 0.5
local guideElapsed = 0
local guideTicker = CreateFrame("Frame")
guideTicker:SetScript("OnUpdate", function(_, elapsed)
    guideElapsed = guideElapsed + (elapsed or 0)
    if guideElapsed < GUIDE_INTERVAL then return end
    guideElapsed = 0
    if not ns.playerName then return end
    local ok, err = pcall(Route.CheckProgress, Route, false)
    if not ok then ns:Debug("guide tick failed: %s", tostring(err)) end
end)
Route.guideTicker = guideTicker
return Route