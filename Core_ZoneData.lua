--[[---------------------------------------------------------------------------
    Solaryn's Expedition — zone enumeration, level banding, and unlock hints.

    Zones come from the client's own map tree (C_Map.GetMapChildrenInfo, with
    GetMapInfo for anything the walk misses), so this file needs no zone
    database of its own. What it adds is the judgement layer the suggester
    and tracker need: which maps are real outdoor zones worth counting, how a
    map's level range compares to the player, and which adjacent zones sit at a
    similar level (so "next zone" suggestions are sane).
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.ZoneData = {}

local ZoneData = ns.ZoneData

local ALL_MAPS

---------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------
-- The client exposes no "list every map" call, so the zone list is built by
-- walking the map tree (see walkMapTree) via GetMapChildrenInfo.
-- Enum.UIMapType values are what that call returns:
--   0 Cosmic  1 World  2 Continent  3 Zone  4 Dungeon  5 Micro  6 Orphan
local COSMIC, AZEROTH = 946, 947

--- Walk the client's map tree. Cosmic (946) is the root on modern clients,
-- but Classic-era clients may not expose it, so we also walk Azeroth (947)
-- and every map above the player's current one. Each walk merges into the
-- same table, so whichever root exists fills it in.
local function walkMapTree()
    local tree = {}
    if not ns.Has.mapChildrenInfo then return tree end

    local seen = {}
    local function walk(mapID, depth)
        if seen[mapID] or depth > 5 then return end
        seen[mapID] = true

        local children = ns.Try("C_Map", "GetMapChildrenInfo", mapID)
        if type(children) ~= "table" then return end
        for _, child in ipairs(children) do
            local id = ns.SafeNum(child.mapID)
            if id and not seen[id] then
                local parent = ns.SafeNum(child.parentMapID) or mapID
                tree[id] = {
                    mapID = id,
                    name = child.name or ("map " .. tostring(id)),
                    mapType = ns.SafeNum(child.mapType),
                    parentMapID = (parent ~= 0) and parent or nil,
                }
                walk(id, depth + 1)
            end
        end
    end

    local roots = { COSMIC, AZEROTH }
    -- The player's own ancestry, top-most last.
    local id, guard = ns:PlayerMapID(), 0
    while id and id ~= 0 and guard < 8 do
        guard = guard + 1
        table.insert(roots, id)
        local info = ns.Has.mapInfo and ns.Try("C_Map", "GetMapInfo", id)
        id = type(info) == "table" and ns.SafeNum(info.parentMapID) or nil
    end
    -- Walk from the top of the player's ancestry down, then the fixed roots.
    for i = #roots, 1, -1 do walk(roots[i], 0) end
    return tree
end

--- A map the tree walk didn't reach, straight from GetMapInfo.
local function lookupMap(mapID)
    if not ns.Has.mapInfo or not mapID then return nil end
    local info = ns.Try("C_Map", "GetMapInfo", mapID)
    if type(info) ~= "table" then return nil end
    local parent = ns.SafeNum(info.parentMapID)
    return {
        mapID = mapID,
        name = info.name or ("map " .. tostring(mapID)),
        mapType = ns.SafeNum(info.mapType),
        parentMapID = (parent and parent ~= 0) and parent or nil,
    }
end

--- Snapshot the client's map tree once per session.
function ZoneData:Load()
    ALL_MAPS = walkMapTree()
    if ns:Count(ALL_MAPS) == 0 then
        ns:Debug("map tree empty; zone suggestions limited")
        return
    end

    -- Publish names for MapName() so tooltips and the status line read well.
    ns._mapNames = ns._mapNames or {}
    for mapID, z in pairs(ALL_MAPS) do
        ns._mapNames[mapID] = z.name
    end

    ns:Debug("loaded %d maps (%d world zones)",
        ns:Count(ALL_MAPS), #self:WorldZones())
end

function ZoneData:Maps() return ALL_MAPS or {} end

--- Ensure the map tree is loaded. Safe to call repeatedly — this is the lazy
-- path so that whichever module needs zones first triggers the load, rather
-- than depending on Init calling Load at exactly the right moment.
function ZoneData:EnsureLoaded()
    -- A walk that found fewer than a handful of zones probably ran before the
    -- player's map was known; retry until it finds a real tree.
    if ALL_MAPS and #self:WorldZones() >= 3 then return true end
    self:Load()
    return ALL_MAPS ~= nil and ns:Count(ALL_MAPS) > 0
end

function ZoneData:Get(mapID)
    if not ALL_MAPS then self:Load() end
    if not mapID then return nil end
    local z = ALL_MAPS and ALL_MAPS[mapID]
    if not z then
        -- Not reached by the tree walk: ask the client about this one map
        -- and remember it, so classification never depends on the walk.
        z = lookupMap(mapID)
        if z and ALL_MAPS then ALL_MAPS[mapID] = z end
    end
    return z
end

function ZoneData:Name(mapID)
    local z = self:Get(mapID)
    return z and z.name or ns:MapName(mapID)
end

---------------------------------------------------------------------------
-- Classification
---------------------------------------------------------------------------
-- Enum.UIMapType, which is what GetMapChildrenInfo / GetMapInfo return.
--   0 Cosmic  1 World  2 Continent  3 Zone  4 Dungeon  5 Micro  6 Orphan
-- Only mapType 3 (Zone) counts as a world zone. Dungeons, raids, scenarios and
-- micro maps are excluded from coverage tracking and "go explore" suggestions:
-- their discovery value is per-character and resets per instance, which makes
-- them noise in an outdoor zone stat.
local UIMAP_TYPE_ZONE = 3
local UIMAP_TYPE_DUNGEON = 4
local UIMAP_TYPE_CONTINENT = 2

--- True if this map is worth counting as a world zone.
function ZoneData:IsWorldZone(mapID)
    local z = self:Get(mapID)
    if not z then return false end
    return z.mapType == UIMAP_TYPE_ZONE
end

--- True if this map is an instance (dungeon/raid/scenario).
function ZoneData:IsInstance(mapID)
    local z = self:Get(mapID)
    return z and z.mapType == UIMAP_TYPE_DUNGEON or false
end

--- True if this map is a continent rather than a specific zone.
function ZoneData:IsContinent(mapID)
    local z = self:Get(mapID)
    return z and z.mapType == UIMAP_TYPE_CONTINENT or false
end

--- All world-zone maps, sorted by name.
function ZoneData:WorldZones()
    if not ALL_MAPS then self:Load() end
    local out = {}
    for mapID, z in pairs(ALL_MAPS or {}) do
        if self:IsWorldZone(mapID) then table.insert(out, z) end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- Child maps of a continent/zone, excluding instance maps.
function ZoneData:Children(mapID)
    local out = {}
    for _, z in pairs(ALL_MAPS or {}) do
        local parent = z.parentMapID or z.mapParentID
        if parent == mapID and self:IsWorldZone(z.mapID) then
            table.insert(out, z)
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- Nearest world zone ancestor of a map (handles being inside a sub-map).
function ZoneData:WorldAncestor(mapID)
    local seen = {}
    local id = mapID
    while id and not seen[id] do
        seen[id] = true
        local z = self:Get(id)
        if z and self:IsWorldZone(id) then return id end
        id = z and (z.parentMapID or z.mapParentID) or nil
    end
    return nil
end

---------------------------------------------------------------------------
-- Zone level ranges
---------------------------------------------------------------------------
-- Source order:
--   1. C_Map.GetMapLevels(map): the client's own range, when it has one.
--   2. CLASSIC_ZONES below: the original Classic ranges, keyed by zone NAME
--      (English client), so it still applies if Forever renumbers its maps,
--      and never applies to a zone it doesn't recognise.
-- faction: "Alliance"/"Horde" for that faction's home zones, nil if contested.
local CLASSIC_ZONES = {
    -- Eastern Kingdoms
    ["Elwynn Forest"]        = { 1, 10, "Alliance" },
    ["Dun Morogh"]           = { 1, 10, "Alliance" },
    ["Tirisfal Glades"]      = { 1, 10, "Horde" },
    ["Westfall"]             = { 10, 20, "Alliance" },
    ["Loch Modan"]           = { 10, 20, "Alliance" },
    ["Silverpine Forest"]    = { 10, 20, "Horde" },
    ["Redridge Mountains"]   = { 15, 25, "Alliance" },
    ["Duskwood"]             = { 18, 30, "Alliance" },
    ["Wetlands"]             = { 20, 30 },
    ["Hillsbrad Foothills"]  = { 20, 30 },
    ["Alterac Mountains"]    = { 30, 40 },
    ["Arathi Highlands"]     = { 30, 40 },
    ["Stranglethorn Vale"]   = { 30, 45 },
    ["Badlands"]             = { 35, 45 },
    ["Swamp of Sorrows"]     = { 35, 45 },
    ["The Hinterlands"]      = { 40, 50 },
    ["Searing Gorge"]        = { 43, 50 },
    ["Blasted Lands"]        = { 45, 55 },
    ["Burning Steppes"]      = { 50, 58 },
    ["Western Plaguelands"]  = { 51, 58 },
    ["Eastern Plaguelands"]  = { 53, 60 },
    ["Deadwind Pass"]        = { 55, 60 },
    -- Kalimdor
    ["Durotar"]              = { 1, 10, "Horde" },
    ["Mulgore"]              = { 1, 10, "Horde" },
    ["Teldrassil"]           = { 1, 10, "Alliance" },
    ["The Barrens"]          = { 10, 25, "Horde" },
    ["Darkshore"]            = { 10, 20, "Alliance" },
    ["Stonetalon Mountains"] = { 15, 27 },
    ["Ashenvale"]            = { 18, 30 },
    ["Thousand Needles"]     = { 25, 35 },
    ["Desolace"]             = { 30, 40 },
    ["Dustwallow Marsh"]     = { 35, 45 },
    ["Feralas"]              = { 40, 50 },
    ["Tanaris"]              = { 40, 50 },
    ["Azshara"]              = { 45, 55 },
    ["Felwood"]              = { 48, 55 },
    ["Un'Goro Crater"]       = { 48, 55 },
    ["Moonglade"]            = { 55, 60 },
    ["Silithus"]             = { 55, 60 },
    ["Winterspring"]         = { 55, 60 },
}
ZoneData.CLASSIC_ZONES = CLASSIC_ZONES

--- Level range for a zone: { min, max, faction, source }, or nil if unknown
--- (cities, instances, zones we have no data for).
function ZoneData:LevelRange(mapID)
    local zone = self:WorldAncestor(mapID) or mapID
    if not zone then return nil end
    local name = self:Name(zone)
    local known = name and CLASSIC_ZONES[name]

    if ns.Has.mapLevels then
        local lo, hi = ns.Try("C_Map", "GetMapLevels", zone)
        lo, hi = ns.SafeNum(lo), ns.SafeNum(hi)
        if lo and hi and lo > 0 and hi >= lo then
            return { min = lo, max = hi, faction = known and known[3], source = "client" }
        end
    end
    if known then
        return { min = known[1], max = known[2], faction = known[3], source = "classic" }
    end
    return nil
end

--- How a zone suits a player level: "high" (too dangerous yet), "ok",
--- "late" (in range but nearly outgrown), or "low" (outgrown).
function ZoneData:LevelStatus(range, level)
    if not range or not level then return nil end
    if level < range.min - 1 then return "high" end
    if level > range.max then return "low" end
    if level >= range.max - 1 then return "late" end
    return "ok"
end

--- How well a zone's level range matches the player (0..1).
function ZoneData:LevelFit(mapID, playerLevel)
    local r = self:LevelRange(mapID)
    if not r or not playerLevel then return 0.5 end   -- unknown: neutral
    if playerLevel < r.min then
        return math.max(0, 1 - (r.min - playerLevel) / 10)
    elseif playerLevel > r.max then
        return math.max(0, 1 - (playerLevel - r.max) / 10)
    end
    return 1
end

--- Kept for SavedVariables compatibility; exploration still records the
--- levels you were at in each zone, though ranges now come from LevelRange.
function ZoneData:NoteLevel(mapID, level)
    local c = _G.SolarynCharDB
    if not c or not mapID or not level then return end
    local zone = self:WorldAncestor(mapID) or mapID
    c.zoneLevels = c.zoneLevels or {}
    local lvl = c.zoneLevels[zone] or {}
    c.zoneLevels[zone] = lvl
    lvl[level] = (lvl[level] or 0) + 1
end

---------------------------------------------------------------------------
-- Continents and progression
---------------------------------------------------------------------------
local UIMAP_TYPE_CONTINENT_ = 2

--- The continent a map sits on (Eastern Kingdoms, Kalimdor, ...), or nil.
function ZoneData:Continent(mapID)
    local id, guard = mapID, 0
    while id and guard < 8 do
        guard = guard + 1
        local z = self:Get(id)
        if not z then return nil end
        if z.mapType == UIMAP_TYPE_CONTINENT_ then return id end
        id = z.parentMapID or z.mapParentID
    end
    return nil
end

--- Yards from the player to the middle of a zone, or nil (e.g. another
--- continent, where world coordinates aren't comparable).
function ZoneData:DistanceToZone(mapID)
    local here = ns:PlayerPosition(ns:PlayerMapID())
    local centre = ns:WorldPos(mapID, 0.5, 0.5)
    if not (here and here.world and centre) then return nil end
    if here.world.continentID and centre.continentID and here.world.continentID ~= centre.continentID then
        return nil
    end
    return ns:WorldDist(here.world, centre)
end

local function playerFaction()
    if type(_G.UnitFactionGroup) ~= "function" then return nil end
    local f = _G.UnitFactionGroup("player")
    return (f == "Alliance" or f == "Horde") and f or nil
end

--- Where to level on the player's current continent.
-- Returns {
--   continent = mapID, level = n,
--   current = { mapID, name, range, status } or nil,
--   next = { { mapID, name, range, distance, status, faction }, ... } best first,
-- }
-- A next zone is one on this continent whose range still has room for the
-- player (at least two levels of headroom, starting no more than two levels
-- above them), not hostile-faction territory, ranked nearest first; zones
-- you're already in range for come before ones you'll grow into.
function ZoneData:Progression(maxResults)
    self:EnsureLoaded()
    local level = ns.UnitLevelSafe()
    local here = ns:PlayerMapID()
    local zone = here and self:WorldAncestor(here)
    local continent = here and self:Continent(here)
    local out = { continent = continent, level = level, next = {} }

    if zone then
        local r = self:LevelRange(zone)
        out.current = { mapID = zone, name = self:Name(zone), range = r, status = self:LevelStatus(r, level) }
    end
    if not continent or not level then return out end

    local faction = playerFaction()
    local candidates = {}
    for _, z in ipairs(self:Children(continent)) do
        local r = self:LevelRange(z.mapID)
        if z.mapID ~= zone and r
            and not (r.faction and faction and r.faction ~= faction)
            and r.min <= level + 2 and r.max >= level + 2 then
            table.insert(candidates, {
                mapID = z.mapID, name = z.name, range = r, faction = r.faction,
                status = self:LevelStatus(r, level),
                distance = self:DistanceToZone(z.mapID),
                inRange = level >= r.min,
            })
        end
    end
    table.sort(candidates, function(a, b)
        if a.inRange ~= b.inRange then return a.inRange end
        if a.distance and b.distance and a.distance ~= b.distance then return a.distance < b.distance end
        if (a.distance ~= nil) ~= (b.distance ~= nil) then return a.distance ~= nil end
        return a.range.min < b.range.min
    end)
    for i = 1, math.min(maxResults or 3, #candidates) do out.next[i] = candidates[i] end
    return out
end

---------------------------------------------------------------------------
-- Adjacency / "next zone" candidates
---------------------------------------------------------------------------
-- Zones reachable from `mapID` without a flight path, i.e. siblings that share
-- a parent. Used to propose the natural next zone rather than an arbitrary
-- level-appropriate one somewhere else in the world.
function ZoneData:Neighbours(mapID)
    local z = self:Get(mapID)
    if not z then return {} end
    local parent = z.parentMapID or z.mapParentID
    if not parent then
        -- Top-level map: fall back to its children.
        return self:Children(mapID)
    end
    local out = {}
    for _, sibling in ipairs(self:Children(parent)) do
        if sibling.mapID ~= mapID then table.insert(out, sibling) end
    end
    return out
end
