--[[---------------------------------------------------------------------------
    Solaryn's Expedition — explored-zone tracking.

    Coverage is estimated by sampling the player's position on a grid rather
    than by walking the map's zone mask. That keeps this addon free of any
    per-zone data file: it works on any zone Forever ships, including new ones,
    with no maintenance when Blizzard adds content.

    Sampling is throttled (settings.sampleInterval) and quantised to a grid, so
    the SavedVariables file stays small no matter how long you play. Each zone
    needs at least `minSamples` distinct cells before its coverage figure is
    trusted — otherwise a freshly-arrived character would read as "0% explored"
    and the suggester would push you to explore a zone you're standing in.

    The client's own fog of war is merged in too (ImportFromClient): every
    grid cell whose centre the world map shows as revealed counts, so zones
    explored before the addon was installed show real coverage from the start.

    Data: charDB.zones[mapID] = {
--       cells = { ["x,y"] = count },   -- distinct cells visited
--       hits  = n,                      -- total samples taken
--       firstSeen = time, lastSeen = time,
--       levelSamples = { [level] = n }, -- feeds the zone level band
--       revealed = { ["x,y"] = true },  -- cells the client's map shows revealed
--       areas = { [areaID] = true },    -- discovered sub-areas (Goldshire, ...)
--     }
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.Explored = {}

local Explored = ns.Explored

local function charDB()
    return _G.SolarynCharDB
end

local function zoneRecord(mapID, create)
    local c = charDB()
    if not c then return nil end
    c.zones = c.zones or {}
    local rec = c.zones[mapID]
    if not rec and create then
        rec = { cells = {}, hits = 0, firstSeen = 0, lastSeen = 0, levelSamples = {} }
        c.zones[mapID] = rec
    end
    return rec
end

---------------------------------------------------------------------------
-- Sampling
---------------------------------------------------------------------------
local accumulator = 0
local lastMap = nil

local function sample()
    local settings = ns.Settings()
    if not settings.trackingEnabled then return end

    local playerMap = ns:PlayerMapID()
    if not playerMap then return end

    -- Count the outdoor zone you're in, even from a town or cave sub-map;
    -- instances (no zone above them) are skipped.
    local mapID = ns.ZoneData:WorldAncestor(playerMap)
    if not mapID then return end

    local pos = ns:PlayerPosition(mapID)
    if not pos then return end

    local x, y = ns.SafeNum(pos.x), ns.SafeNum(pos.y)
    if not (x and y) then return end

    local rec = zoneRecord(mapID, true)
    if not rec then return end

    -- Quantise to the configured grid. Resolution 8 -> 64 possible cells.
    local res = math.max(2, math.min(64, ns.SafeNum(settings.gridResolution) or 8))
    -- Client map coordinates are fractions 0-1 (not 0-100).
    if x < 0 or x > 1 or y < 0 or y > 1 then return end
    local gx = math.min(res, math.floor(x * res) + 1)
    local gy = math.min(res, math.floor(y * res) + 1)
    rec.cells[gx .. "," .. gy] = (rec.cells[gx .. "," .. gy] or 0) + 1

    rec.hits = rec.hits + 1
    rec.lastSeen = time()
    if rec.firstSeen == 0 then rec.firstSeen = rec.lastSeen end

    -- Feed the level-band inference in Core_ZoneData.
    local lvl = ns.UnitLevelSafe()
    if lvl then
        rec.levelSamples[lvl] = (rec.levelSamples[lvl] or 0) + 1
        ns.ZoneData:NoteLevel(mapID, lvl)
    end

    lastMap = mapID
end

---------------------------------------------------------------------------
-- Public sampling API
---------------------------------------------------------------------------
--- Take a sample immediately, bypassing the throttle.
--- Used by /sol zone refresh, by the panel when it opens, and by tests.
function Explored:SampleNow()
    accumulator = 0
    sample()
    ns:Fire("explored_changed")
end

---------------------------------------------------------------------------
-- Import from the client's fog of war
---------------------------------------------------------------------------
local function gridRes()
    return math.max(2, math.min(64, ns.SafeNum(ns.Settings().gridResolution) or 8))
end

local function mapPoint(x, y)
    if type(_G.CreateVector2D) == "function" then return _G.CreateVector2D(x, y) end
    return { x = x, y = y }
end

--- Read which grid cells of a zone the world map shows as revealed, and
--- which named areas they belong to. Recomputed from scratch each time, so
--- it always matches the client (and the current grid resolution).
-- Returns true if the client could answer.
function Explored:ImportFromClient(mapID)
    if not mapID or not ns.ZoneData:IsWorldZone(mapID) then return false end
    Explored.ImportAchievement(mapID)
    if not ns.Has.exploredAreasAtPos then return false end

    local res = gridRes()
    local revealed, areas, n = {}, {}, 0
    for gx = 1, res do
        for gy = 1, res do
            local ids = ns.Try("C_MapExplorationInfo", "GetExploredAreaIDsAtPosition",
                mapID, mapPoint((gx - 0.5) / res, (gy - 0.5) / res))
            if type(ids) == "table" and #ids > 0 then
                revealed[gx .. "," .. gy] = true
                n = n + 1
                for _, id in ipairs(ids) do
                    id = ns.SafeNum(id)
                    if id then areas[id] = true end
                end
            end
        end
    end

    local rec = zoneRecord(mapID, n > 0)
    if rec then
        rec.revealed = n > 0 and revealed or nil
        rec.areas = n > 0 and areas or nil
        rec.importedAt = time()
    end
    return true
end

--- Import every world zone. Cheap enough to run once at login (one call per
--- grid cell, ~64 per zone at the default resolution).
-- Returns the number of zones that had revealed ground.
function Explored:ImportAll()
    local found = 0
    for _, z in ipairs(ns.ZoneData:WorldZones()) do
        self:ImportFromClient(z.mapID)
        local rec = zoneRecord(z.mapID, false)
        if rec and (rec.revealed or rec.achievement) then found = found + 1 end
    end
    ns:Fire("explored_changed")
    return found
end

---------------------------------------------------------------------------
-- Exploration achievements
---------------------------------------------------------------------------
-- "Explore <Zone>" achievements list every discoverable area of a zone as a
-- criterion, each marked found or not. That is the true denominator the fog
-- of war can't give us, and an earned achievement means the zone is done.
--
-- Achievements are found by scanning the achievement categories for
-- "Explore <zone name>"; the IDs below are a fallback for clients without the
-- category API, and each is used only if its name checks out.
local KNOWN_EXPLORE_IDS = {
    ["Elwynn Forest"] = 776, ["Dun Morogh"] = 627, ["Loch Modan"] = 779, ["Westfall"] = 802,
    ["Redridge Mountains"] = 780, ["Duskwood"] = 778, ["Wetlands"] = 841, ["Tirisfal Glades"] = 768,
    ["Silverpine Forest"] = 769, ["Hillsbrad Foothills"] = 772, ["Arathi Highlands"] = 761,
    ["Alterac Mountains"] = 760, ["The Hinterlands"] = 773, ["Stranglethorn Vale"] = 781,
    ["Badlands"] = 765, ["Swamp of Sorrows"] = 782, ["Searing Gorge"] = 774, ["Burning Steppes"] = 775,
    ["Blasted Lands"] = 766, ["Deadwind Pass"] = 777, ["Western Plaguelands"] = 770,
    ["Eastern Plaguelands"] = 771, ["Durotar"] = 728, ["Mulgore"] = 736, ["The Barrens"] = 750,
    ["Teldrassil"] = 842, ["Darkshore"] = 844, ["Ashenvale"] = 845, ["Thousand Needles"] = 846,
    ["Stonetalon Mountains"] = 847, ["Desolace"] = 848, ["Feralas"] = 849, ["Dustwallow Marsh"] = 850,
    ["Tanaris"] = 851, ["Azshara"] = 852, ["Felwood"] = 853, ["Un'Goro Crater"] = 854,
    ["Moonglade"] = 855, ["Silithus"] = 856, ["Winterspring"] = 857,
}

local achievementByZone        -- [lowercased zone name] = achievementID

local function exploreZoneName(achievementName)
    return type(achievementName) == "string" and achievementName:match("^Explore (.+)$") or nil
end

local function buildAchievementIndex()
    achievementByZone = {}
    if type(_G.GetAchievementInfo) ~= "function" then return end
    if type(_G.GetCategoryList) == "function" and type(_G.GetCategoryNumAchievements) == "function" then
        for _, cat in ipairs(_G.GetCategoryList() or {}) do
            local n = ns.SafeNum((_G.GetCategoryNumAchievements(cat, true))) or 0
            for i = 1, n do
                local id, name = _G.GetAchievementInfo(cat, i)
                local zone = exploreZoneName(name)
                if id and zone then achievementByZone[zone:lower()] = id end
            end
        end
    end
    for zone, id in pairs(KNOWN_EXPLORE_IDS) do
        if not achievementByZone[zone:lower()] then
            local _, name = _G.GetAchievementInfo(id)
            if exploreZoneName(name) and exploreZoneName(name):lower() == zone:lower() then
                achievementByZone[zone:lower()] = id
            end
        end
    end
end

--- Forget the zone -> achievement index (rebuilt on next use).
function Explored:ResetAchievementIndex() achievementByZone = nil end

--- The zone's exploration achievement and progress, or nil:
--- { id, name, earned, done, total, missing = { area names not yet found } }.
function Explored:Achievement(mapID)
    if not achievementByZone then buildAchievementIndex() end
    local zoneName = ns.ZoneData:Name(mapID)
    local id = zoneName and achievementByZone[zoneName:lower()]
    if not id then return nil end

    local _, name, _, completed, _, _, _, _, _, _, _, _, wasEarnedByMe = _G.GetAchievementInfo(id)
    if not name then return nil end
    -- Prefer "earned by this character"; older clients lack that return.
    local earned
    if wasEarnedByMe ~= nil then earned = wasEarnedByMe and true or false
    else earned = completed and true or false end

    local total, done, missing = 0, 0, {}
    if type(_G.GetAchievementNumCriteria) == "function" and type(_G.GetAchievementCriteriaInfo) == "function" then
        total = ns.SafeNum(_G.GetAchievementNumCriteria(id)) or 0
        for i = 1, total do
            local areaName, _, found = _G.GetAchievementCriteriaInfo(id, i)
            if found then done = done + 1
            elseif type(areaName) == "string" then table.insert(missing, areaName) end
        end
    end
    if earned then done = total end
    return { id = id, name = name, earned = earned, done = done, total = total, missing = missing }
end

--- Refresh the stored achievement snapshot for a zone. Creates a record when
--- there's progress, so zones explored long ago show up.
local function importAchievement(mapID)
    local ach = Explored:Achievement(mapID)
    local rec = zoneRecord(mapID, ach ~= nil and (ach.earned or ach.done > 0))
    if rec then rec.achievement = ach end
end
Explored.ImportAchievement = importAchievement

---------------------------------------------------------------------------
-- Coverage
---------------------------------------------------------------------------
-- Minimum distinct cells before we trust a coverage number from movement
-- sampling alone: low enough to report partial coverage while genuinely
-- walking around, high enough that standing still isn't enough. Revealed
-- cells from the client are trusted outright.
local MIN_CELLS_FOR_TRUST = 6

--- Distinct cells covered: walked through, revealed by the client, or both.
local function cellCounts(rec)
    local visited, revealed, union = 0, 0, 0
    for _ in pairs(rec.cells or {}) do visited = visited + 1; union = union + 1 end
    for key in pairs(rec.revealed or {}) do
        revealed = revealed + 1
        if not (rec.cells and rec.cells[key]) then union = union + 1 end
    end
    return union, visited, revealed
end

local function hasData(rec)
    return rec and ((rec.hits or 0) > 0 or rec.revealed ~= nil
        or (rec.achievement and (rec.achievement.earned or rec.achievement.done > 0)))
end

--- Achievement progress as a fraction, or nil when there's no achievement.
local function achievementFraction(rec)
    local a = rec and rec.achievement
    if not a then return nil end
    if a.earned then return 1 end
    if (a.total or 0) > 0 then return a.done / a.total end
    return nil
end

--- Coverage fraction (0..1) for a map, or nil if we know nothing about it.
-- Water and impassable edges can never be revealed, so a fully explored
-- zone reads somewhat below 1.
function Explored:Coverage(mapID)
    local rec = zoneRecord(mapID, false)
    if not hasData(rec) then return nil end
    -- The zone's exploration achievement is the in-game truth (and has the
    -- real number of areas), so it wins over the grid estimate.
    local fromAchievement = achievementFraction(rec)
    if fromAchievement then return fromAchievement end
    local union, _, revealed = cellCounts(rec)
    if revealed == 0 and union < MIN_CELLS_FOR_TRUST then return 0 end
    local res = gridRes()
    return math.min(1, union / (res * res))
end

--- Names of the discovered areas in a zone, sorted.
function Explored:AreaNames(mapID)
    local rec = zoneRecord(mapID, false)
    local out = {}
    for id in pairs(rec and rec.areas or {}) do
        local name = ns.Try("C_Map", "GetAreaInfo", id)
        if type(name) == "string" and name ~= "" then table.insert(out, name) end
    end
    table.sort(out)
    return out
end

--- Coverage plus the raw numbers, for the panel.
function Explored:Detail(mapID)
    local rec = zoneRecord(mapID, false)
    if not rec then
        return { mapID = mapID, name = ns.ZoneData:Name(mapID), coverage = 0, cells = 0, hits = 0,
                 visitedCells = 0, revealedCells = 0, areaCount = 0, trusted = false }
    end
    local union, visited, revealed = cellCounts(rec)
    return {
        mapID = mapID,
        name = ns.ZoneData:Name(mapID),
        coverage = self:Coverage(mapID) or 0,
        cells = union,
        visitedCells = visited,
        revealedCells = revealed,
        areaCount = ns:Count(rec.areas or {}),
        hits = rec.hits or 0,
        gridRes = gridRes(),
        firstSeen = rec.firstSeen,
        lastSeen = rec.lastSeen,
        trusted = revealed > 0 or union >= MIN_CELLS_FOR_TRUST or rec.achievement ~= nil,
        fromClient = revealed > 0,
        achievement = rec.achievement,
    }
end

--- Every zone with any exploration data, most-covered first.
function Explored:All()
    local c = charDB()
    if not c or not c.zones then return {} end
    local out = {}
    for mapID, rec in pairs(c.zones) do
        if hasData(rec) then table.insert(out, self:Detail(mapID)) end
    end
    table.sort(out, function(a, b) return a.coverage > b.coverage end)
    return out
end

--- Summary across all visited zones.
function Explored:Summary()
    local all = self:All()
    local totalCells, totalTrusted = 0, 0
    for _, z in ipairs(all) do
        totalCells = totalCells + z.cells
        if z.trusted then totalTrusted = totalTrusted + 1 end
    end
    return {
        zones = #all,
        trustedZones = totalTrusted,
        totalCells = totalCells,
        current = lastMap,
        currentCoverage = lastMap and self:Coverage(lastMap) or nil,
    }
end

---------------------------------------------------------------------------
-- Maintenance
---------------------------------------------------------------------------
--- Reset tracking for one zone (e.g. after a patch moves the map).
function Explored:ResetZone(mapID)
    local c = charDB()
    if not c or not c.zones then return end
    c.zones[mapID] = nil
    ns:Fire("explored_changed")
end

--- Reset all tracking for this character.
function Explored:ResetAll()
    local c = charDB()
    if not c then return end
    c.zones = {}
    ns:Print("exploration data cleared.")
    ns:Fire("explored_changed")
end

---------------------------------------------------------------------------
-- Ticking
---------------------------------------------------------------------------
local function onTick(_, elapsed)
    if not ns.playerName then return end
    accumulator = accumulator + elapsed
    local interval = ns.SafeNum(ns.Settings().sampleInterval) or 30
    if accumulator < interval then return end
    accumulator = 0
    sample()
end

local ticker = CreateFrame("Frame")

function Explored:Initialize()
    ticker:SetScript("OnUpdate", function(self, elapsed)
        onTick(self, elapsed)
    end)
end

--- The ticker runs from OnUpdate, so it's only worth running when the panel
--- or a suggestion is actually visible — otherwise we sample on a timer
--- instead and stop burning frames.
function Explored:OnLogin()
    -- Immediate sample so the panel has data the moment it opens.
    sample()
    -- Pull in everything the world map already shows as explored. Deferred
    -- a moment so the client's map data is settled after login.
    ns:Debounce("explore-import-all", 3, function() Explored:ImportAll() end)
end

-- Discovering a new area happens on a sub-zone change; re-read the current
-- zone's fog of war then (cheap: one zone).
local function onAreaChanged()
    ns:Debounce("explore-import", 1, function()
        local here = ns:PlayerMapID()
        local zone = here and ns.ZoneData:WorldAncestor(here)
        if zone and Explored:ImportFromClient(zone) then ns:Fire("explored_changed") end
    end)
end
ns:RegisterEvent("ZONE_CHANGED", onAreaChanged, Explored)
-- Achievement progress: a new area found, or the whole zone completed.
ns:RegisterEvent("CRITERIA_UPDATE", onAreaChanged, Explored)
ns:RegisterEvent("ACHIEVEMENT_EARNED", function()
    ns:Debounce("explore-import-all", 1, function() Explored:ImportAll() end)
end, Explored)
ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", onAreaChanged, Explored)
ns:RegisterEvent("ZONE_CHANGED_INDOORS", onAreaChanged, Explored)

ns:RegisterModule("Explored", Explored)

return Explored