--[[---------------------------------------------------------------------------
    Solaryn's Expedition — constants and default settings.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.ADDON_NAME = ADDON_NAME
ns.VERSION = ns.version   -- read from the TOC in Init.lua

ns.Colors = {
    accent      = { r = 1.00, g = 0.82, b = 0.00 },
    good        = { r = 0.30, g = 0.90, b = 0.40 },
    warn        = { r = 1.00, g = 0.70, b = 0.20 },
    bad         = { r = 1.00, g = 0.35, b = 0.30 },
    quest       = { r = 0.35, g = 0.80, b = 1.00 },
    turnin      = { r = 0.40, g = 0.95, b = 0.55 },
    explore     = { r = 0.75, g = 0.60, b = 1.00 },
    unlock      = { r = 1.00, g = 0.85, b = 0.45 },
    dim         = { r = 0.62, g = 0.62, b = 0.62 },
    text        = { r = 0.92, g = 0.92, b = 0.92 },
    header      = { r = 0.78, g = 0.66, b = 0.36 },
}

-- Suggestion kinds, in panel display order.
ns.SUGGEST = {
    TURNOUT  = "turnout",
    OBJECTIVE = "objective",
    UNLOCK   = "unlock",
    EXPLORE  = "explore",
}

ns.Defaults = {
    settings = {
        -- Panel / minimap
        panelLocked = false,
        minimapButton = true,
        minimapPos = 220,           -- degrees around the minimap ring
        showLoginMessage = true,

        -- Route
        maxRouteQuests = 12,
        autoPickRoute = true,       -- auto-fill route when panel opens
        autoRebuild = true,         -- rebuild when a quest is accepted, finished, handed in or dropped
        includeTurnIns = true,      -- insert turn-in stops before objectives
        mapPins = true,             -- draw route pins on the world map
        clearWaypointOnArrive = true, -- clear our waypoint when the route is finished
        autoAdvance = true,         -- guide: move the waypoint on to the next stop
        advanceWhenDone = true,     -- guide: move on when the quest work is done, not on arrival
        batchTurnIns = true,        -- route: finish nearby objectives before walking back to hand in
        routeLevelWeight = 0.15,    -- route: extra distance per level a quest is away from yours (0 = ignore level)
        includeDungeons = false,    -- route: include dungeon and raid quests
        arriveRadius = 30,          -- guide: yards from a stop that count as "there"

        -- Route tracker (on-screen HUD)
        hud = true,                 -- show the tracker while guiding
        hudAlways = false,          -- ...and whenever a route exists
        hudLocked = false,
        hudUpcoming = 3,            -- upcoming stops listed under the current one
        hudScale = 1.0,
        hudCollapsed = false,
        questItemButtons = true,    -- buttons for the guided quests' usable items
        questTooltips = true,       -- quest info in mob/NPC/object tooltips

        -- Zone tracking
        trackingEnabled = true,
        sampleInterval = 30,        -- seconds between movement samples
        gridResolution = 8,         -- NxN cells per map for coverage estimate

        -- Suggestions
        suggestLimit = 5,
        sortByDistance = true,      -- Next tab: nearest quest first (else weighted score)
        ignoreTasks = true,         -- deprioritise daily/task quests
        wDistance = 1.00,           -- farther = worse
        wLevel    = 0.80,           -- quest level far from player = worse
        wSameMap  = 0.60,           -- in the current zone = better
        wTurnIn   = 1.50,           -- ready to hand in = much better
        wStory    = 0.40,           -- story quests = better
        wTask     = -0.30,          -- tasks = worse (negative weight allowed)
        wExplored = 0.50,           -- suggest unexplored parts of known zones
    },
}

---------------------------------------------------------------------------
-- Settings access
---------------------------------------------------------------------------
--- Current settings table, merging in defaults for any key added after the
-- user's SavedVariables were written (so new options never read as nil).
function ns.Settings()
    local db = _G.SolarynDB
    if not db then
        -- Pre-ADDON_LOADED callers (rare) get the defaults rather than a nil error.
        return ns.Defaults.settings
    end
    db.settings = db.settings or {}
    local s = db.settings
    for k, v in pairs(ns.Defaults.settings) do
        if s[k] == nil then s[k] = v end
    end
    return s
end

--- Per-character data table, or nil before login.
function ns.CharDB()
    return _G.SolarynCharDB
end

--- Player level as a plain number, or nil.
function ns.UnitLevelSafe()
    local lvl = UnitLevel("player")
    return type(lvl) == "number" and lvl or nil
end

-- A quest this many levels above you gets a caution mark.
ns.CAUTION_LEVELS = 3

--- Levels a quest is above the player when that's enough to warrant caution
-- (ns.CAUTION_LEVELS or more), else nil.
function ns.LevelCaution(level)
    local p = ns.UnitLevelSafe()
    if type(level) ~= "number" or not p then return nil end
    local over = level - p
    return over >= ns.CAUTION_LEVELS and over or nil
end

--- Short warning text for a quest well above the player's level, or nil.
function ns.CautionText(level)
    local over = ns.LevelCaution(level)
    if not over then return nil end
    local c = over >= 5 and ns.Colors.bad or ns.Colors.warn
    return string.format("|cff%02x%02x%02x(!) Lv %d, %d above you|r",
        c.r * 255, c.g * 255, c.b * 255, level, over)
end

-- Yards -> readable distance. 1 mile = 1760 yards.
ns.YARDS_PER_MILE = 1760

-- Distance (in yards) beyond which we stop calling something "nearby".
ns.NEAR_DISTANCE = 800
