--[[---------------------------------------------------------------------------
    Solaryn's Expedition — shared helpers: capability probing, secret-value guards,
    distance math, formatting, and data structure utilities.

    Everything here is deliberately defensive. WoW: Forever is in beta and its
    API surface is still moving, so the addon must degrade rather than error
    when an optional API is absent.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

---------------------------------------------------------------------------
-- Capability probing
---------------------------------------------------------------------------
ns.Has = {}

local CAPS = {
    questObjectives   = { "C_QuestLog", "GetQuestObjectives" },
    questInfo         = { "C_QuestLog", "GetInfo" },
    questTitle        = { "C_QuestLog", "GetTitleForLogIndex" },
    numQuestEntries   = { "C_QuestLog", "GetNumQuestLogEntries" },
    questFlagged      = { "C_QuestLog", "IsQuestFlaggedCompleted" },
    logIndexForQuest  = { "C_QuestLog", "GetLogIndexForQuestID" },
    -- Confirmed present on Forever 1.60.1: this is the one call that gives us
    -- a real objective coordinate, which is why the addon needs no quest DB.
    nextWaypoint      = { "C_QuestLog", "GetNextWaypointForMap" },
    allCompletedQuests= { "C_QuestLog", "GetAllCompletedQuestIDs" },
    -- Location sources, best first. GetQuestsOnMap is what the world map
    -- itself draws quest markers from (turn-in markers included);
    -- GetNextWaypointForMap only answers when the objective is on ANOTHER map.
    questsOnMap       = { "C_QuestLog", "GetQuestsOnMap" },
    nextWaypointAny   = { "C_QuestLog", "GetNextWaypoint" },
    questUiMapID      = { "_G", "GetQuestUiMapID" },
    taskQuestLocation = { "C_TaskQuest", "GetQuestLocation" },
    questIsComplete   = { "C_QuestLog", "IsComplete" },
    questTagInfo      = { "C_QuestLog", "GetQuestTagInfo" },
    questTagInfoOld   = { "_G", "GetQuestTagInfo" },
    uiMapPoint        = { "UiMapPoint", "CreateFromCoordinates" },
    setUserWaypoint   = { "C_Map", "SetUserWaypoint" },
    clearUserWaypoint = { "C_Map", "ClearUserWaypoint" },
    canSetWaypoint    = { "C_Map", "CanSetUserWaypointOnMap" },
    playerMapPos      = { "C_Map", "GetPlayerMapPosition" },
    worldPosFromMap   = { "C_Map", "GetWorldPosFromMapPos" },
    -- There is NO C_Map.GetAllMapInfo. Zone enumeration is done by walking the
    -- map tree from the Cosmic root with GetMapChildrenInfo.
    mapChildrenInfo  = { "C_Map", "GetMapChildrenInfo" },
    mapInfo           = { "C_Map", "GetMapInfo" },
    bestMapForUnit    = { "C_Map", "GetBestMapForUnit" },
    mapGroupID        = { "C_Map", "GetMapGroupID" },
    mapGroupMembers   = { "C_Map", "GetMapGroupMembersInfo" },
    areaInfo          = { "C_Map", "GetAreaInfo" },
    mapWorldSize      = { "C_Map", "GetMapWorldSize" },
    mapLevels         = { "C_Map", "GetMapLevels" },
    -- The world map's fog of war: which spots on a map are already revealed.
    exploredAreasAtPos = { "C_MapExplorationInfo", "GetExploredAreaIDsAtPosition" },
}

function ns:ProbeCapabilities()
    for cap, path in pairs(CAPS) do
        local tbl = _G[path[1]]
        ns.Has[cap] = (type(tbl) == "table" or type(tbl) == "function")
            and type(tbl[path[2]]) == "function"
    end
end

--- Call an optional-namespace function without risking a taint/error storm.
--   ns.Try("C_Map", "SetUserWaypoint", point)
--
-- IMPORTANT: this preserves ALL return values, not just the first. Several
-- client APIs return multiple values (e.g. C_Map.GetWorldPosFromMapPos returns
-- continentID, worldPosition), and collapsing those to the first value turns a
-- coordinate into a bare number that later code tries to index.
function ns.Try(namespace, fnName, ...)
    local tbl = _G[namespace]
    if type(tbl) ~= "table" and type(tbl) ~= "function" then return nil end
    local fn = tbl[fnName]
    if type(fn) ~= "function" then return nil end
    return fn(...)
end

---------------------------------------------------------------------------
-- Secret values
---------------------------------------------------------------------------
-- Midnight's secret values can make ordinary numbers unusable in arithmetic
-- (or in string concatenation). Quest data is not combat data and should never
-- be secret, but the guard costs nothing and prevents an unrecoverable
-- error-spam loop if that ever changes.

--- True if `v` is a normal (non-secret) value safe to compute with.
function ns.IsSafe(v)
    -- Check secrecy FIRST: even comparing a secret value (v == nil) is an
    -- error in clients with secret values. issecretvalue itself is safe.
    local isSecret = _G.issecretvalue
    if type(isSecret) == "function" then
        local ok, res = pcall(isSecret, v)
        if not ok or res then return false end
    end
    if v == nil then return false end
    return true
end

--- Coerce to a number, or nil if the value is missing/secret/non-numeric.
function ns.SafeNum(v)
    if type(v) ~= "number" then return nil end
    if not ns.IsSafe(v) then return nil end
    return v
end

--- tostring that never throws on a secret value.
function ns.SafeStr(v)
    if v == nil then return "" end
    if not ns.IsSafe(v) then return "?" end
    return tostring(v)
end

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------
local PREFIX = "|cff82c8ffSolaryn|r: "

function ns:Print(fmt, ...)
    local msg = select("#", ...) > 0 and (fmt:format(...)) or fmt
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

function ns:Debug(fmt, ...)
    local db = _G.SolarynDB
    if not (db and db.settings and db.settings.debug) then return end
    local msg = select("#", ...) > 0 and (fmt:format(...)) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("|cff888888[Solaryn dbg]|r " .. msg)
end

function ns:Error(fmt, ...)
    local msg = select("#", ...) > 0 and (fmt:format(...)) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("|cffff6060Solaryn error|r: " .. msg)
end

---------------------------------------------------------------------------
-- Table utilities
---------------------------------------------------------------------------
function ns:Count(t)
    local n = 0
    if type(t) == "table" then
        for _ in pairs(t) do n = n + 1 end
    end
    return n
end

--- Shallow copy.
function ns:Copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

--- Sorted list of keys, optionally filtered. `cmp(a,b)` orders values.
function ns:SortedKeys(t, cmp, filter)
    local keys = {}
    for k in pairs(t) do
        if not filter or filter(k, t[k]) then
            table.insert(keys, k)
        end
    end
    table.sort(keys, cmp)
    return keys
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------
--- Human distance: 640 yd / 1.2 mi
-- Yards stay in yards well past a quarter mile; "0.1 mi" is useless when
-- you're deciding whether to walk or ride.
local YARD_CUTOFF = 1200

function ns:FormatDistance(yards)
    local y = ns.SafeNum(yards)
    if not y then return "?" end
    if y < YARD_CUTOFF then
        return string.format("%d yd", y)
    end
    return string.format("%.1f mi", y / ns.YARDS_PER_MILE)
end

--- Truncate with ellipsis, guarding against secret input.
function ns:Truncate(s, max)
    s = ns.SafeStr(s)
    if not max or #s <= max then return s end
    return s:sub(1, max - 1) .. "\226\128\166"
end

function ns:FormatPct(fraction)
    local f = ns.SafeNum(fraction)
    if not f then return "?" end
    return string.format("%d%%", math.floor(f * 100 + 0.5))
end

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------
--- Euclidean distance between two 2D points given as {x=,y=}.
function ns:Dist2D(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

--- Extract x/y from a position that may be a Vector2DMixin, a plain
-- {x=,y=} table, or a bare (x, y) multi-return.
-- Both shapes occur in the map APIs, so accept all three.
function ns:VecXY(v, y2)
    if v == nil then return nil end

    -- Vector2DMixin: pos:GetXY()
    if type(v) == "table" then
        local getter = rawget(v, "GetXY") or v.GetXY
        if type(getter) == "function" then
            local ok, x, y = pcall(getter, v)
            if ok then return x, y end
        end
        return v.x, v.y
    end

    -- Bare number pair from a multi-return, e.g. GetWorldPosFromMapPos.
    if type(v) == "number" and type(y2) == "number" then
        return v, y2
    end

    return nil
end

--- Current best map for the player, or nil.
function ns:PlayerMapID()
    if not ns.Has.bestMapForUnit then return nil end
    return ns.SafeNum(ns.Try("C_Map", "GetBestMapForUnit", "player"))
end

--- Current map coordinates (0-1 fractions) and continent position for the player.
function ns:PlayerPosition(mapID)
    if not mapID or not ns.Has.playerMapPos then return nil end
    local pos = ns.Try("C_Map", "GetPlayerMapPosition", mapID, "player")
    local x, y = ns:VecXY(pos)
    if not x or not y then return nil end
    return { uiMapID = mapID, x = x, y = y, world = ns:WorldPos(mapID, x, y) }
end

--- Continent-space position (used for real yard distances).
-- C_Map.GetWorldPosFromMapPos(uiMapID, pos) returns TWO values:
--   continentID, worldPosition
-- Taking only the first gives a bare number (the continent ID), not a vector —
-- so both return values must be captured here.
function ns:WorldPos(mapID, x, y)
    if not ns.Has.worldPosFromMap then return nil end
    local continentID, world = ns.Try("C_Map", "GetWorldPosFromMapPos", mapID, { x = x, y = y })
    if not world then return nil end
    local wx, wy = ns:VecXY(world)
    if not wx then return nil end
    return { x = wx, y = wy, continentID = ns.SafeNum(continentID) }
end

--- Yards between two continent positions.
function ns:WorldDist(a, b)
    if not a or not b then return nil end
    local ax, ay = ns.SafeNum(a.x), ns.SafeNum(a.y)
    local bx, by = ns.SafeNum(b.x), ns.SafeNum(b.y)
    if not (ax and ay and bx and by) then return nil end
    return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

--- Yards between two map positions on the same map.
function ns:MapDist(a, b)
    if not a or not b or a.uiMapID ~= b.uiMapID then return nil end
    -- Map coords are fractions of the map; GetMapWorldSize gives the map's
    -- size in yards, which turns them into real distances.
    if ns.Has.mapWorldSize then
        local w, h = ns.Try("C_Map", "GetMapWorldSize", a.uiMapID)
        w, h = ns.SafeNum(w), ns.SafeNum(h)
        if w and h and w > 0 and h > 0 and a.x and b.x then
            return math.sqrt(((a.x - b.x) * w) ^ 2 + ((a.y - b.y) * h) ^ 2)
        end
    end
    local d = ns:Dist2D(a.x, a.y, b.x, b.y)
    if not d then return nil end
    return d * 100  -- nominal scale; only used when no real size is known
end

--- Best available distance in yards between two points, or nil.
function ns:DistanceBetween(a, b)
    if not a or not b then return nil end
    return ns:WorldDist(a.world, b.world) or (a.uiMapID == b.uiMapID and ns:MapDist(a, b) or nil)
end

---------------------------------------------------------------------------
-- Zones
---------------------------------------------------------------------------
--- Name of a map ID, or "map <id>" when unknown.
function ns:MapName(mapID)
    if not mapID then return "?" end
    if ns.Has.mapInfo then
        local info = ns.Try("C_Map", "GetMapInfo", mapID)
        if info and type(info) == "table" and info.name then return info.name end
    end
    ns._mapNames = ns._mapNames or {}
    return ns._mapNames[mapID] or ("map " .. tostring(mapID))
end

--- Cache every map name once by walking the client's map tree.
-- The client has no "give me every map" call, so we start at the Cosmic root
-- (uiMapID 946) and recurse through GetMapChildrenInfo. Cheap enough to do
-- once at login, and it means no zone table to maintain in the addon.
function ns:CacheMapNames()
    if not ns.Has.mapChildrenInfo then return end

    local COSMIC = 946
    ns._mapNames = {}
    ns._mapTree = {}

    local seen = {}
    local function walk(mapID, depth)
        if seen[mapID] or depth > 4 then return end
        seen[mapID] = true

        local children = ns.Try("C_Map", "GetMapChildrenInfo", mapID)
        if type(children) ~= "table" then return end
        for _, child in ipairs(children) do
            local id = ns.SafeNum(child.mapID)
            if id and not seen[id] then
                if child.name then ns._mapNames[id] = child.name end
                ns._mapTree[id] = {
                    mapID = id,
                    name = child.name,
                    mapType = ns.SafeNum(child.mapType),
                    parentMapID = mapID,
                }
                walk(id, depth + 1)
            end
        end
    end

    walk(COSMIC, 0)
    ns:Debug("cached %d maps by name", ns:Count(ns._mapNames))
end

---------------------------------------------------------------------------
-- Debounce
---------------------------------------------------------------------------
local pendingCalls = {}

--- Run fn once, `delay` seconds after the last of a burst of calls with the
-- same key. QUEST_LOG_UPDATE can fire several times a second (every kill,
-- every loot); without this each one triggered full quest-log rescans.
-- Without C_Timer (e.g. the offline tests) fn runs immediately.
function ns:Debounce(key, delay, fn)
    local timer = _G.C_Timer
    if type(timer) ~= "table" or type(timer.After) ~= "function" then
        fn()
        return
    end
    if pendingCalls[key] then return end
    pendingCalls[key] = true
    timer.After(delay or 0.2, function()
        pendingCalls[key] = nil
        local ok, err = pcall(fn)
        if not ok then ns:Debug("deferred %s failed: %s", tostring(key), tostring(err)) end
    end)
end

---------------------------------------------------------------------------
-- Quest difficulty colour
---------------------------------------------------------------------------
--- Colour for a quest level relative to the player, matching the quest log:
--- red (far above), orange, yellow (about right), green, grey (trivial).
function ns:LevelColor(level)
    if type(level) ~= "number" then return ns.Colors.dim end
    if type(_G.GetQuestDifficultyColor) == "function" then
        local ok, c = pcall(_G.GetQuestDifficultyColor, level)
        if ok and type(c) == "table" and c.r then return c end
    end
    local p = ns.UnitLevelSafe()
    if not p then return ns.Colors.dim end
    local d = level - p
    if d >= 5 then return { r = 1.00, g = 0.10, b = 0.10 } end
    if d >= 3 then return { r = 1.00, g = 0.50, b = 0.25 } end
    if d >= -2 then return { r = 1.00, g = 0.82, b = 0.00 } end
    if d >= -8 then return { r = 0.25, g = 0.75, b = 0.25 } end
    return { r = 0.50, g = 0.50, b = 0.50 }
end
