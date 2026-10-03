--[[---------------------------------------------------------------------------
    Solaryn's Expedition — options window.

    Controls are bound straight to ns.Settings(), so changes take effect on the
    next suggestion rebuild with no save step (SavedVariables persist on logout
    /reload, which is how the client works).

    Sections are ordered by how often people change them: display first, then
    route and tracking, then the suggestion weights, which expose the
    suggester's scoring model directly.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.Options = {}

local Options = ns.Options
local Widgets = ns.Widgets

local frame
local controls = {}          -- every control with a Refresh(), for "reset to defaults"

local OPTIONS_WIDTH = 380
local OPTIONS_HEIGHT = 540
local PAD = 12

-- Settings that "Reset to defaults" leaves alone: window positions and the
-- minimap angle are layout, not preferences.
local KEEP_ON_RESET = {
    panelPoint = true, panelSize = true, optionsPoint = true, hudPoint = true,
    minimapPos = true, panelOpen = true,
}

local function weightFmt(v) return string.format("%.2f", v) end

--- Tell whatever depends on a changed setting to update.
local function onSettingChanged(key, v)
    if key == "minimapButton" then ns.MinimapButton:Update() end
    if key:match("^hud") and ns.HUD then ns.HUD:Refresh() end
    if key == "mapPins" then
        if v then ns.MapPins:DrawRoute() else ns.MapPins:ClearRoute() end
    end
    if (key == "includeDungeons" or key == "routeLevelWeight") and ns.Route:Count() > 0 then
        ns:Debounce("options-route", 0.3, function() ns.Route:Build() end)
    end
    if key:match("^w%u") or key == "suggestLimit" or key == "ignoreTasks" or key == "sortByDistance"
        or key == "includeDungeons" then
        ns.Suggest:Recompute()
    end
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------
local function buildOptions()
    frame = Widgets:Window("SolarynExpeditionOptions", {
        title = "Solaryn's Expedition — Options",
        width = OPTIONS_WIDTH, height = OPTIONS_HEIGHT,
        posKey = "optionsPoint",
        default = { "CENTER", 220, 0 },
    })

    local scroll, inner = Widgets:Scroll(frame)
    scroll:SetPoint("TOPLEFT", PAD, -(Widgets.TITLE_HEIGHT + 8))
    scroll:SetPoint("BOTTOMRIGHT", -(PAD + 20), 8)
    inner:SetWidth(OPTIONS_WIDTH - 2 * PAD - 20)
    frame.inner = inner

    local y = 0

    local function place(widget, height, gapAfter)
        widget:SetPoint("TOPLEFT", inner, "TOPLEFT", 0, -y)
        widget:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -4, -y)
        y = y + height + (gapAfter or 2)
    end

    local function section(label, blurb)
        if y > 0 then y = y + 10 end
        local fs = Widgets:Line(inner, label, "GameFontNormal")
        fs:SetTextColor(ns.Colors.header.r, ns.Colors.header.g, ns.Colors.header.b)
        place(fs, 16, 2)
        local rule = Widgets:Divider(inner)
        place(rule, 1, 6)
        if blurb then
            local note = Widgets:Text(inner, blurb, "GameFontHighlightSmall")
            note:SetTextColor(ns.Colors.dim.r, ns.Colors.dim.g, ns.Colors.dim.b)
            if type(note.SetWordWrap) == "function" then note:SetWordWrap(true) end
            place(note, 26, 4)
        end
    end

    local function checkbox(label, key, tip)
        local s = ns.Settings
        local holder = Widgets:Check(inner, label,
            function() return s()[key] end,
            function(v)
                s()[key] = v
                onSettingChanged(key, v)
            end, tip)
        place(holder, 26, 0)
        table.insert(controls, holder)
    end

    local function slider(label, key, minVal, maxVal, step, fmt, tip)
        local s = ns.Settings
        local holder = Widgets:Slider(inner, label, minVal, maxVal, step,
            function() return s()[key] or minVal end,
            function(v)
                s()[key] = v
                onSettingChanged(key, v)
            end,
            fmt, tip)
        place(holder, 44, 2)
        table.insert(controls, holder)
    end

    ------------------------------------------------------------------
    section("Display")
    checkbox("Show minimap button", "minimapButton",
        "The gold-ringed button on the minimap. /sol still works without it.")
    checkbox("Lock panel position", "panelLocked",
        "Stop the panel from being dragged by its title bar.")
    checkbox("Show route pins on the map", "mapPins",
        "Draw every route stop on the world map.")
    checkbox("Show a message at login", "showLoginMessage")

    ------------------------------------------------------------------
    section("Route")
    checkbox("Keep the route up to date automatically", "autoRebuild",
        "Rebuild whenever you accept, finish, hand in or drop a quest. While guiding, finished stops stay done and the rest is re-planned from where you are.")
    checkbox("Build a route automatically when the panel opens", "autoPickRoute",
        "Only rebuilds when your quest log has changed since the last build.")
    checkbox("Finish nearby objectives before handing in", "batchTurnIns",
        "Hand-ins wait until the quests around you are done, unless one is right on your way. Off: hand in as soon as a quest is complete.")
    slider("Prefer quests at my level", "routeLevelWeight", 0, 0.5, 0.05,
        function(v) return v == 0 and "off" or string.format("+%d%%/lv", math.floor(v * 100 + 0.5)) end,
        "Each level a quest is above you makes its objectives count as this much farther away (levels below count half), so quests at your level come first. Quests 3 or more levels above you are marked with (!).")
    checkbox("Include dungeon and raid quests", "includeDungeons",
        "Off: quests tagged Dungeon or Raid are left out of the route and the Next tab until they're ready to hand in, since they're done inside an instance with a group.")
    checkbox("Include hand-in stops", "includeTurnIns",
        "Add a stop at the quest giver for quests you can turn in.")
    checkbox("Move on to the next stop automatically", "autoAdvance",
        "While following the route, the waypoint moves to the next stop when you reach this one.")
    checkbox("Wait until the quest work is done", "advanceWhenDone",
        "On: move on when the objective is complete (or the quest handed in). Off: move on as soon as you arrive at a stop.")
    slider("Arrival distance", "arriveRadius", 10, 100, 5,
        function(v) return string.format("%d yd", v) end,
        "How close to a stop counts as arriving (used only when not waiting for the quest work).")
    checkbox("Clear the waypoint when the route is finished", "clearWaypointOnArrive")
    slider("Quests per route", "maxRouteQuests", 1, 30, 1,
        function(v) return string.format("%d", v) end,
        "The route includes at most this many quests, nearest first.")

    ------------------------------------------------------------------
    section("Route tracker")
    checkbox("Show the on-screen tracker while guiding", "hud",
        "A compact list of the current stop, its objectives and what's next, like the quest tracker.")
    checkbox("Also show it when a route exists but isn't being followed", "hudAlways")
    checkbox("Lock the tracker in place", "hudLocked")
    checkbox("Show buttons for quest items", "questItemButtons",
        "Click to use the guided quests' items from your bags. Bind \"Use quest item\" under Key Bindings > AddOns.")
    slider("Upcoming stops listed", "hudUpcoming", 0, 6, 1,
        function(v) return string.format("%d", v) end)
    slider("Tracker size", "hudScale", 0.7, 1.5, 0.05,
        function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end)

    checkbox("Show quest info in mob and NPC tooltips", "questTooltips",
        "Hovering something a quest needs adds the quest and your progress to its tooltip.")

    ------------------------------------------------------------------
    section("Exploration tracking")
    checkbox("Track exploration", "trackingEnabled",
        "Sample your position while you travel to estimate how much of each zone you've seen.")
    slider("Sample every", "sampleInterval", 5, 120, 5,
        function(v) return string.format("%d sec", v) end,
        "How often your position is recorded. Shorter is more precise and costs slightly more.")
    slider("Grid detail", "gridResolution", 4, 16, 2,
        function(v) return string.format("%d×%d", v, v) end,
        "Each zone is split into this grid. Finer grids track coverage more precisely but store more data.")

    ------------------------------------------------------------------
    section("Suggestions",
        "With distance ranking off, these weights decide the order. 0 means ignore a factor.")
    slider("Suggestions to show", "suggestLimit", 1, 10, 1,
        function(v) return string.format("%d", v) end)
    checkbox("Rank by distance (nearest first)", "sortByDistance",
        "Order the Next tab purely by how far away each quest is. Turn off to rank with the weights below.")
    checkbox("Push daily and task quests down", "ignoreTasks")
    slider("Prefer nearby", "wDistance", 0, 3, 0.05, weightFmt,
        "Higher values push far-away objectives down the list.")
    slider("Prefer quests at my level", "wLevel", 0, 3, 0.05, weightFmt)
    slider("Prefer my current zone", "wSameMap", 0, 3, 0.05, weightFmt)
    slider("Hand-in bonus", "wTurnIn", 0, 3, 0.05, weightFmt,
        "Finished quests are always listed first. This orders them among themselves.")
    slider("Story quest bonus", "wStory", 0, 3, 0.05, weightFmt)
    slider("Task quest penalty", "wTask", -2, 0, 0.05, weightFmt,
        "Negative values push task quests down.")
    slider("Suggest unexplored areas", "wExplored", 0, 3, 0.05, weightFmt)

    ------------------------------------------------------------------
    section("Maintenance")
    local rowA = CreateFrame("Frame", nil, inner)
    place(rowA, 24, 6)
    local resetDefaults = Widgets:Button(rowA, "Reset to defaults", 150, 22, function()
        Options:ResetToDefaults()
    end)
    resetDefaults:SetPoint("LEFT", 0, 0)
    Widgets:TooltipLines(resetDefaults, "Reset to defaults",
        { "Restore every option above. Window positions are kept." })

    local rebuild = Widgets:Button(rowA, "Rebuild route", 120, 22, function()
        ns.Route:Build()
        ns.Route:StampFingerprint()
        ns:Print("route rebuilt.")
    end)
    rebuild:SetPoint("LEFT", resetDefaults, "RIGHT", 6, 0)

    local rowB = CreateFrame("Frame", nil, inner)
    place(rowB, 24, 6)
    local resetZones = Widgets:Button(rowB, "Reset zone data", 150, 22, function()
        ns.Explored:ResetAll()
    end)
    resetZones:SetPoint("LEFT", 0, 0)
    Widgets:TooltipLines(resetZones, "Reset zone data",
        { "Forget exploration data for every zone on this character." })

    local clearOverrides = Widgets:Button(rowB, "Clear pins", 120, 22, function()
        local d = _G.SolarynDB
        if not d then return end
        d.overrides = {}
        ns:Print("all quest overrides cleared.")
    end)
    clearOverrides:SetPoint("LEFT", resetZones, "RIGHT", 6, 0)
    Widgets:TooltipLines(clearOverrides, "Clear pins",
        { "Remove every objective position recorded with /sol pin (all characters)." })

    inner:SetHeight(y + 12)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function Options:ResetToDefaults()
    local s = ns.Settings()
    for k, v in pairs(ns.Defaults.settings) do
        if not KEEP_ON_RESET[k] then s[k] = v end
    end
    for _, c in ipairs(controls) do c.Refresh() end
    ns.MinimapButton:Update()
    ns.Suggest:Recompute()
    ns:Print("options reset to defaults.")
end

function Options:Toggle(force)
    if not frame then buildOptions() end
    local wantShow = force
    if wantShow == nil then wantShow = not frame:IsShown() end
    if wantShow then
        for _, c in ipairs(controls) do c.Refresh() end
        frame:Show()
    else
        frame:Hide()
    end
end

function Options:GetFrame() return frame end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function Options:Initialize()
    if not frame then buildOptions() end
end

function Options:OnLogin()
    -- Roll forward any settings added in a newer version.
    ns.Settings()
end

ns:RegisterModule("Options", Options)

return Options
