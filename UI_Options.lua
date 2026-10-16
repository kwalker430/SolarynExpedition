--[[---------------------------------------------------------------------------
    Solaryn's Expedition — options window.

    A sidebar of categories on the left; the chosen category on the right as
    cards of rows, each with a plain-language description under its label so
    nothing needs a tooltip to make sense.

    Controls are bound straight to ns.Settings(), so changes take effect on the
    next suggestion rebuild with no save step (SavedVariables persist on logout
    /reload, which is how the client works).

    Categories are ordered by how often people change them: general and route
    first, the suggestion weights (which expose the scoring model directly)
    and maintenance last.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.Options = {}

local Options = ns.Options
local Widgets = ns.Widgets

local frame
local controls = {}          -- every control with a Refresh(), for "reset to defaults"
local pages, navButtons = {}, {}

local OPTIONS_WIDTH = 640
local OPTIONS_HEIGHT = 540
local NAV_W = 168
local FOOTER_H = 40
local PAGE_HEAD_H = 52
local CARD_GAP = 12
-- Rows span the content pane, less its padding, the card inset and the scrollbar.
local CONTENT_W = OPTIONS_WIDTH - NAV_W - 24 - 22

-- Settings that "Reset to defaults" leaves alone: window positions and the
-- minimap angle are layout, not preferences.
local KEEP_ON_RESET = {
    panelPoint = true, panelSize = true, optionsPoint = true, hudPoint = true,
    minimapPos = true, panelOpen = true, optionsCategory = true,
}

local function weightFmt(v) return string.format("%.2f", v) end
local function countFmt(v) return string.format("%d", v) end
local function yardsFmt(v) return string.format("%d yd", v) end
local function percentFmt(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end

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
-- Categories
---------------------------------------------------------------------------
-- Each category is { key, label, icon, blurb, build(page) }. A page offers
-- group(title), toggle(...), slider(...) and action(...).
local CATEGORIES = {
    { key = "general", label = "General", icon = "Interface\\Icons\\INV_Misc_Note_01",
      blurb = "The minimap button, the panel, map pins and tooltips.",
      build = function(p)
        p.group("Interface")
        p.toggle("Minimap button", "minimapButton",
            "The gold-ringed button on the minimap. /sol still works without it.")
        p.toggle("Lock the panel", "panelLocked",
            "Stop the panel from being dragged by its title bar.")
        p.toggle("Welcome message at login", "showLoginMessage",
            "One line in chat when you log in, with the command to open the panel.")
        p.group("World")
        p.toggle("Route pins on the world map", "mapPins",
            "Draw every route stop on the world map as a numbered pin. Hover for details, click to set a waypoint.")
        p.toggle("Quest info in tooltips", "questTooltips",
            "Mobs, NPCs and objects your quests need show the quest and your progress when you hover them.")
      end },

    { key = "route", label = "Route", icon = "Interface\\Icons\\INV_Misc_Map_01",
      blurb = "How your quest log becomes a walking route.",
      build = function(p)
        p.group("Building the route")
        p.toggle("Keep the route up to date", "autoRebuild",
            "Rebuild whenever you accept, finish, hand in or drop a quest, or make progress on one. Stops you've finished stay done.")
        p.toggle("Build when the panel opens", "autoPickRoute",
            "Only rebuilds if your quest log has changed since the last build.")
        p.toggle("Finish nearby objectives first", "batchTurnIns",
            "Hand-ins wait until the quests around you are done, unless one is right on your way.")
        p.toggle("Include hand-in stops", "includeTurnIns",
            "Add a stop at the quest giver for quests you can turn in.")
        p.toggle("Include dungeon and raid quests", "includeDungeons",
            "Off: quests done inside an instance stay off the route until they're ready to hand in.")
        p.slider("Prefer quests at my level", "routeLevelWeight", 0, 0.5, 0.05,
            function(v) return v == 0 and "off" or string.format("+%d%%/lv", math.floor(v * 100 + 0.5)) end,
            "Each level a quest is away from yours makes it count as this much farther. Quests 3+ levels above you are marked (!).")
        p.slider("Quests per route", "maxRouteQuests", 1, 30, 1, countFmt,
            "The route includes at most this many quests, nearest first.")

        p.group("Following the route")
        p.toggle("Move on automatically", "autoAdvance",
            "While guiding, the waypoint moves to the next stop by itself.")
        p.toggle("Wait until the quest work is done", "advanceWhenDone",
            "On: move on when the objective is complete or the quest handed in. Off: move on as soon as you arrive.")
        p.slider("Arrival distance", "arriveRadius", 10, 100, 5, yardsFmt,
            "How close to a stop counts as arriving. Only used when not waiting for the quest work.")
        p.slider("Search area", "areaRadius", 0, 150, 10,
            function(v) return v == 0 and "off" or yardsFmt(v) end,
            "Kill and collect quests: inside this radius the tracker says \"in the area\" instead of counting yards.")
        p.toggle("Clear the waypoint at the end", "clearWaypointOnArrive",
            "Remove the map waypoint once the last stop is done.")
      end },

    { key = "tracker", label = "Tracker", icon = "Interface\\Icons\\Ability_Tracking",
      blurb = "The on-screen route tracker beside the quest log.",
      build = function(p)
        p.group("When to show it")
        p.toggle("Show while guiding", "hud",
            "The current stop, its objectives, a direction arrow and what's next, like the quest tracker.")
        p.toggle("Show when paused too", "hudAlways",
            "Keep it up whenever a route exists, with a button to start the guide.")
        p.toggle("Lock in place", "hudLocked",
            "Stop the tracker from being dragged by its header.")
        p.group("Look")
        p.slider("Upcoming stops listed", "hudUpcoming", 0, 6, 1, countFmt,
            "How many stops after the current one are shown.")
        p.slider("Size", "hudScale", 0.7, 1.5, 0.05, percentFmt)
        p.slider("Background", "hudOpacity", 0, 1, 0.05, percentFmt,
            "How solid the tracker's background is. 0% leaves just the text and frame.")
        p.group("Quest items")
        p.toggle("Quest item buttons", "questItemButtons",
            "Buttons beside the tracker use the guided quests' items. Bind \"Use quest item\" under Key Bindings > AddOns.")
      end },

    { key = "exploration", label = "Exploration", icon = "Interface\\Icons\\INV_Misc_Spyglass_03",
      blurb = "How zone coverage is measured.",
      build = function(p)
        p.group("Tracking")
        p.toggle("Track exploration", "trackingEnabled",
            "Sample your position while you travel. Zones with an \"Explore\" achievement use its real list of areas instead.")
        p.slider("Sample every", "sampleInterval", 5, 120, 5,
            function(v) return string.format("%d sec", v) end,
            "Shorter is more precise and costs slightly more.")
        p.slider("Grid detail", "gridResolution", 4, 16, 2,
            function(v) return string.format("%d×%d", v, v) end,
            "Each zone is split into this grid. Finer grids are more precise but store more data.")
      end },

    { key = "suggestions", label = "Suggestions", icon = "Interface\\Icons\\INV_Scroll_03",
      blurb = "The order of the panel's Next tab.",
      build = function(p)
        p.group("Ranking")
        p.slider("Suggestions to show", "suggestLimit", 1, 10, 1, countFmt)
        p.toggle("Nearest first", "sortByDistance",
            "Order the Next tab purely by distance. Turn off to rank with the weights below.")
        p.toggle("Push daily and task quests down", "ignoreTasks",
            "Task quests drop below everything else.")
        p.group("Weights", "Only used with \"Nearest first\" off. 0 ignores a factor.")
        p.slider("Prefer nearby", "wDistance", 0, 3, 0.05, weightFmt,
            "Higher values push far-away objectives down the list.")
        p.slider("Prefer quests at my level", "wLevel", 0, 3, 0.05, weightFmt)
        p.slider("Prefer my current zone", "wSameMap", 0, 3, 0.05, weightFmt)
        p.slider("Hand-in bonus", "wTurnIn", 0, 3, 0.05, weightFmt,
            "Finished quests are always listed first; this orders them among themselves.")
        p.slider("Story quest bonus", "wStory", 0, 3, 0.05, weightFmt)
        p.slider("Task quest penalty", "wTask", -2, 0, 0.05, weightFmt,
            "Negative values push task quests down.")
        p.slider("Suggest unexplored areas", "wExplored", 0, 3, 0.05, weightFmt)
      end },

    { key = "maintenance", label = "Maintenance", icon = "Interface\\Icons\\Trade_Engineering",
      blurb = "Rebuild, reset and clear saved data.",
      build = function(p)
        p.group("Route")
        p.action("Rebuild the route", "Re-plan every stop from where you stand now.", "Rebuild", function()
            ns.Route:Build()
            ns.Route:StampFingerprint()
            ns:Print("route rebuilt.")
        end)
        p.group("Saved data")
        p.action("Reset options", "Restore every option to its default. Window positions are kept.", "Reset", function()
            Options:ResetToDefaults()
        end)
        p.action("Reset zone data", "Forget exploration data for every zone on this character. Your map and achievements are read back in.", "Reset zones", function()
            ns.Explored:ResetAll()
        end)
        p.action("Clear recorded positions", "Remove every objective and hand-in recorded with /sol pin (all characters).", "Clear pins", function()
            local d = _G.SolarynDB
            if not d then return end
            d.overrides = {}
            ns:Print("all recorded quest positions cleared.")
        end)
      end },
}
Options.CATEGORIES = CATEGORIES

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------
--- Build one category's scrolling page of cards.
local function buildPage(parent, cat)
    local scroll, inner = Widgets:Scroll(parent)
    scroll:SetPoint("TOPLEFT", 12, -PAGE_HEAD_H)
    scroll:SetPoint("BOTTOMRIGHT", -(12 + 20), 8)
    inner:SetWidth(CONTENT_W)

    local y = 0
    local card, cardTop, rowsInCard = nil, 0, 0

    local function closeCard()
        if card then
            card:SetPoint("TOPLEFT", inner, "TOPLEFT", 0, -cardTop)
            card:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -2, -cardTop)
            card:SetHeight(y - cardTop)
            card = nil
        end
    end

    local function place(widget, height)
        if rowsInCard > 0 then
            -- On the card, not the scroll child: the card would cover it.
            local rule = Widgets:Fill(card or inner, "ARTWORK", 1, 1, 1, 0.05)
            rule:SetHeight(1)
            rule:SetPoint("TOPLEFT", inner, "TOPLEFT", 10, -y)
            rule:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -12, -y)
        end
        widget:SetPoint("TOPLEFT", inner, "TOPLEFT", 0, -y)
        widget:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -2, -y)
        y = y + height
        rowsInCard = rowsInCard + 1
    end

    local p = {}
    function p.group(title, note)
        closeCard()
        if y > 0 then y = y + CARD_GAP end
        local head = Widgets:Heading(inner, title)
        head:SetPoint("TOPLEFT", inner, "TOPLEFT", 0, -y)
        head:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -2, -y)
        y = y + 22
        if note then
            local fs, h = Widgets:Note(inner, note, CONTENT_W - 8)
            fs:SetPoint("TOPLEFT", inner, "TOPLEFT", 4, -y)
            y = y + h + 6
        end
        card = Widgets:Card(inner)
        cardTop, rowsInCard = y, 0
    end

    function p.toggle(label, key, desc)
        local s = ns.Settings
        local row = Widgets:Check(inner, label,
            function() return s()[key] end,
            function(v)
                s()[key] = v
                onSettingChanged(key, v)
            end, nil, { desc = desc, width = CONTENT_W })
        row.key = key
        place(row, row.rowHeight)
        table.insert(controls, row)
    end

    function p.slider(label, key, minVal, maxVal, step, fmt, desc)
        local s = ns.Settings
        local row = Widgets:Slider(inner, label, minVal, maxVal, step,
            function() return s()[key] or minVal end,
            function(v)
                s()[key] = v
                onSettingChanged(key, v)
            end,
            fmt, nil, { desc = desc, width = CONTENT_W })
        row.key = key
        place(row, row.rowHeight)
        table.insert(controls, row)
    end

    function p.action(label, desc, buttonText, onClick)
        local row = Widgets:ActionRow(inner, label, desc, buttonText, onClick, { width = CONTENT_W })
        place(row, row.rowHeight)
    end

    cat.build(p)
    closeCard()
    inner:SetHeight(y + 12)
    scroll.inner = inner
    return scroll
end

local function selectCategory(key)
    local found = false
    for _, cat in ipairs(CATEGORIES) do
        if cat.key == key then found = true end
    end
    if not found then key = CATEGORIES[1].key end
    ns.Settings().optionsCategory = key

    for _, cat in ipairs(CATEGORIES) do
        local on = cat.key == key
        local b = navButtons[cat.key]
        local page = pages[cat.key]
        if on then page:Show() else page:Hide() end
        b.selected = on
        if on then b.bar:Show(); b.sel:Show() else b.bar:Hide(); b.sel:Hide() end
        local c = on and ns.Colors.accent or ns.Colors.text
        b.text:SetTextColor(c.r, c.g, c.b)
        b.icon:SetVertexColor(on and 1 or 0.7, on and 1 or 0.7, on and 1 or 0.7)
        if on then
            frame.pageTitle:SetText(cat.label)
            frame.pageBlurb:SetText(cat.blurb or "")
        end
    end
end

local function buildNavButton(nav, cat, i)
    local b = CreateFrame("Button", nil, nav)
    b:SetHeight(30)
    b:SetPoint("TOPLEFT", nav, "TOPLEFT", 6, -10 - (i - 1) * 32)
    b:SetPoint("TOPRIGHT", nav, "TOPRIGHT", -6, -10 - (i - 1) * 32)
    b:RegisterForClicks("LeftButtonUp")

    b.sel = Widgets:Fill(b, "BACKGROUND", Widgets.Theme.selected)
    b.sel:SetAllPoints()
    b.bar = Widgets:Fill(b, "ARTWORK", Widgets.Theme.gold)
    b.bar:SetWidth(2)
    b.bar:SetPoint("TOPLEFT", 0, 0)
    b.bar:SetPoint("BOTTOMLEFT", 0, 0)
    local hl = Widgets:Fill(b, "HIGHLIGHT", Widgets.Theme.rowHover)
    hl:SetAllPoints()

    local frameBox = Widgets:Fill(b, "ARTWORK", 0, 0, 0, 0.8)
    frameBox:SetSize(20, 20)
    frameBox:SetPoint("LEFT", 10, 0)
    b.icon = b:CreateTexture(nil, "OVERLAY")
    b.icon:SetSize(18, 18)
    b.icon:SetPoint("CENTER", frameBox, "CENTER", 0, 0)
    b.icon:SetTexture(cat.icon)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    b.text = Widgets:Line(b, cat.label, "GameFontHighlight")
    b.text:SetPoint("LEFT", frameBox, "RIGHT", 9, 0)
    b.text:SetPoint("RIGHT", -6, 0)

    b:SetScript("OnClick", function() selectCategory(cat.key) end)
    b.categoryKey = cat.key
    navButtons[cat.key] = b
    return b
end

local function buildOptions()
    frame = Widgets:Window("SolarynExpeditionOptions", {
        title = "Solaryn's Expedition",
        subtitle = "Options  ·  v" .. tostring(ns.version or "?"),
        icon = "Interface\\Icons\\INV_Misc_Map_01",
        width = OPTIONS_WIDTH, height = OPTIONS_HEIGHT,
        posKey = "optionsPoint",
        default = { "CENTER", 220, 0 },
    })

    -- Sidebar
    local nav = CreateFrame("Frame", nil, frame)
    nav:SetPoint("TOPLEFT", 3, -(Widgets.TITLE_HEIGHT + 3))
    nav:SetPoint("BOTTOMLEFT", 3, 3)
    nav:SetWidth(NAV_W)
    local navBg = Widgets:Fill(nav, "BACKGROUND", Widgets.Theme.nav)
    navBg:SetAllPoints()
    local navEdge = Widgets:Fill(nav, "BORDER", Widgets.Theme.divider)
    navEdge:SetWidth(1)
    navEdge:SetPoint("TOPRIGHT", 0, 0)
    navEdge:SetPoint("BOTTOMRIGHT", 0, 0)
    frame.nav = nav
    for i, cat in ipairs(CATEGORIES) do buildNavButton(nav, cat, i) end

    local help = Widgets:Text(nav, "Type |cffffd100/sol help|r for every command.", "GameFontDisableSmall")
    help:SetPoint("BOTTOMLEFT", 12, 12)
    help:SetPoint("BOTTOMRIGHT", -10, 12)
    if type(help.SetWordWrap) == "function" then help:SetWordWrap(true) end

    -- Content pane
    local pane = CreateFrame("Frame", nil, frame)
    pane:SetPoint("TOPLEFT", nav, "TOPRIGHT", 0, 0)
    pane:SetPoint("BOTTOMRIGHT", -3, FOOTER_H)
    frame.pane = pane

    frame.pageTitle = Widgets:Line(pane, "", "GameFontNormalLarge")
    frame.pageTitle:SetPoint("TOPLEFT", 14, -12)
    frame.pageTitle:SetPoint("TOPRIGHT", -14, -12)
    frame.pageBlurb = Widgets:Line(pane, "", "GameFontHighlightSmall")
    frame.pageBlurb:SetPoint("TOPLEFT", frame.pageTitle, "BOTTOMLEFT", 0, -4)
    frame.pageBlurb:SetPoint("TOPRIGHT", frame.pageTitle, "BOTTOMRIGHT", 0, -4)
    frame.pageBlurb:SetTextColor(ns.Colors.dim.r, ns.Colors.dim.g, ns.Colors.dim.b)
    local headRule = Widgets:Divider(pane)
    headRule:SetPoint("TOPLEFT", 12, -(PAGE_HEAD_H - 6))
    headRule:SetPoint("TOPRIGHT", -12, -(PAGE_HEAD_H - 6))

    for _, cat in ipairs(CATEGORIES) do
        local page = buildPage(pane, cat)
        page:Hide()
        pages[cat.key] = page
    end

    -- Footer
    local foot = CreateFrame("Frame", nil, frame)
    foot:SetPoint("BOTTOMLEFT", nav, "BOTTOMRIGHT", 0, 0)
    foot:SetPoint("BOTTOMRIGHT", -3, 3)
    foot:SetHeight(FOOTER_H - 3)
    local footRule = Widgets:Divider(foot)
    footRule:SetPoint("TOPLEFT", 0, 0)
    footRule:SetPoint("TOPRIGHT", 0, 0)
    local done = Widgets:Button(foot, "Done", 90, 22, function() frame:Hide() end, "primary")
    done:SetPoint("RIGHT", -12, 0)
    local reset = Widgets:Button(foot, "Reset to defaults", 130, 22, function() Options:ResetToDefaults() end)
    reset:SetPoint("RIGHT", done, "LEFT", -8, 0)
    Widgets:TooltipLines(reset, "Reset to defaults", { "Restore every option. Window positions are kept." })
    local saved = Widgets:Line(foot, "Changes apply straight away.", "GameFontDisableSmall")
    saved:SetPoint("LEFT", 14, 0)
    saved:SetPoint("RIGHT", reset, "LEFT", -8, 0)
    frame.footer = foot

    selectCategory(ns.Settings().optionsCategory)
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
    if ns.HUD then ns.HUD:Refresh() end
    ns:Print("options reset to defaults.")
end

--- Show one category ("general", "route", "tracker", ...).
function Options:SelectCategory(key)
    if not frame then buildOptions() end
    selectCategory(key)
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
function Options:GetControls() return controls end
function Options:GetNavButton(key) return navButtons[key] end
function Options:GetPage(key) return pages[key] end

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
