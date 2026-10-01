--[[---------------------------------------------------------------------------
    Solaryn's Expedition — main panel.

    Layout, top to bottom:

      title bar   drag handle, options cog, close
      where-am-I  current zone, level, and an exploration bar for this zone
      tabs        Next / Route / Zones, each showing its item count
      hint        one line saying what clicking a row does on this tab
      list        scrolling rows for the current tab
      footer      a short summary and this tab's action buttons

    Rows are pooled per kind and reused on every render, so frequent events
    (QUEST_LOG_UPDATE fires constantly) never leak frames. Every rebuild is
    driven by events rather than polling.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.Panel = {}

local Panel = ns.Panel
local Widgets = ns.Widgets
local Theme = Widgets.Theme

local TABS = {
    { key = "next",  label = "Next",
      hint = "Click: set waypoint  ·  Right-click: open map  ·  Shift-click: hide" },
    { key = "route", label = "Route",
      hint = "Click a stop to be guided from there  ·  Right-click: open map" },
    { key = "zones", label = "Zones",
      hint = "Where to level next  ·  Exploration includes what your map already shows" },
}

local KIND_LABEL = {
    turnout   = "HAND IN",
    objective = "QUEST",
    unlock    = "NEW ZONE",
    explore   = "EXPLORE",
}

local DEFAULT_W, DEFAULT_H = 380, 520
local INFO_H   = 52
local TAB_H    = 26
local HINT_H   = 18
local FOOTER_H = 36
local SUGGEST_ROW_H = 46
local ROUTE_ROW_H   = 40
local ZONE_ROW_H    = 44
local ROW_GAP = 2

local TOP_OF_TABS = Widgets.TITLE_HEIGHT + 1 + INFO_H
local TOP_OF_LIST = TOP_OF_TABS + TAB_H + HINT_H + 4

-- Frames. Early events (which can fire before Initialize builds the panel)
-- see nil here and no-op rather than crash.
local frame, header, content
local zoneText, levelText, exploreBar
local tabButtons = {}
local hintText, summaryText
local footerButtons = {}      -- [tabKey] = { button, ... } right-to-left
local emptyState

local currentTab = "next"
local lastSuggestions = {}
local panelBuilt = false
local refreshing = false
local resetArmed = false

--- True once buildPanel() has created the frames renderers attach to.
local function isBuilt()
    return panelBuilt and content ~= nil and content.inner ~= nil
end

local function dim(text) return Widgets.Colorize(text, ns.Colors.dim) end

--- Level colour relative to the player (see ns:LevelColor).
local function levelColor(level) return ns:LevelColor(level) end

-- How a zone's level range suits the player (see ZoneData:LevelStatus).
local STATUS_COLOR = {
    ok   = { r = 0.25, g = 0.80, b = 0.30 },
    late = { r = 1.00, g = 0.82, b = 0.00 },
    high = { r = 1.00, g = 0.35, b = 0.30 },
    low  = { r = 0.55, g = 0.55, b = 0.55 },
}
local function statusText(status, range, level)
    if status == "ok" then
        local left = range.max - level
        return string.format("Good level for you  ·  %d level%s of room left", left, left == 1 and "" or "s")
    elseif status == "late" then return "You're outgrowing this zone"
    elseif status == "high" then return "Above your level — dangerous mobs"
    elseif status == "low" then return "You've outgrown this zone"
    end
    return "No level data for this zone"
end
local function rangeText(range)
    return range and string.format("%d–%d", range.min, range.max) or "?"
end

--- Distance from the player to a location record, or nil.
local function distanceTo(loc)
    if not loc then return nil end
    local ok, d = pcall(function()
        return ns:DistanceBetween(ns:PlayerPosition(ns:PlayerMapID()), loc)
    end)
    return ok and type(d) == "number" and d or nil
end

---------------------------------------------------------------------------
-- Row pool
---------------------------------------------------------------------------
local pools = { suggestion = {}, route = {}, zone = {}, level = {}, header = {} }
local activeRows = {}

local function releaseRows()
    for _, row in ipairs(activeRows) do
        row:Hide()
        row:ClearAllPoints()
        table.insert(pools[row.poolKind], row)
    end
    activeRows = {}
end

--- A clickable full-width row with hover highlight and a data tooltip.
local function baseRow(kind, height)
    local row = CreateFrame("Button", nil, content.inner)
    row:SetHeight(height)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.poolKind = kind

    row.bg = Widgets:Fill(row, "BACKGROUND", Theme.rowAlt)
    row.bg:SetAllPoints()

    -- Emphasis for the row that is "the next thing to do".
    row.focus = Widgets:Fill(row, "BACKGROUND", ns.Colors.accent.r, ns.Colors.accent.g, ns.Colors.accent.b, 0.08)
    row.focus:SetAllPoints()
    row.focus:Hide()

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(Theme.rowHover[1], Theme.rowHover[2], Theme.rowHover[3], Theme.rowHover[4])

    row.bar = Widgets:Fill(row, "ARTWORK", 1, 1, 1, 1)
    row.bar:SetPoint("TOPLEFT", 0, 0)
    row.bar:SetPoint("BOTTOMLEFT", 0, 0)
    row.bar:SetWidth(3)

    row:SetScript("OnClick", function(self, button)
        if self.onClick then self.onClick(self.data, button) end
    end)
    row:SetScript("OnEnter", function(self)
        if self.tooltip then
            local t = self.tooltip(self.data)
            Widgets:ShowTooltip(self, t.title, t.lines, t.color)
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function acquire(kind, builder)
    local row = table.remove(pools[kind]) or builder()
    table.insert(activeRows, row)
    return row
end

--- Place rows top-down, full width, and size the scroll child to fit.
local function layoutRows()
    local y = 0
    for _, row in ipairs(activeRows) do
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content.inner, "TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", content.inner, "TOPRIGHT", 0, -y)
        row:Show()
        y = y + row:GetHeight() + ROW_GAP
    end
    return y
end

--- Resize the scroll child to fit its content and re-enable scrolling.
local function fitInner(height)
    if not isBuilt() then return end
    content.inner:SetHeight(math.max(1, math.floor(height)))
    if content.scroll.UpdateScrollChildRect then
        pcall(function() content.scroll:UpdateScrollChildRect() end)
    end
end

---------------------------------------------------------------------------
-- Row builders
---------------------------------------------------------------------------
local function buildSuggestionRow()
    local row = baseRow("suggestion", SUGGEST_ROW_H)

    row.meta = Widgets:Line(row, "", "GameFontHighlightSmall", "RIGHT")
    row.meta:SetPoint("TOPRIGHT", -8, -8)
    row.meta:SetWidth(70)

    row.level = Widgets:Line(row, "", "GameFontNormalSmall", "RIGHT")
    row.level:SetPoint("BOTTOMRIGHT", -8, 8)
    row.level:SetWidth(70)

    row.title = Widgets:Line(row, "", "GameFontHighlight")
    row.title:SetPoint("TOPLEFT", 12, -7)
    row.title:SetPoint("RIGHT", row.meta, "LEFT", -6, 0)

    row.sub = Widgets:Line(row, "", "GameFontNormalSmall")
    row.sub:SetPoint("BOTTOMLEFT", 12, 8)
    row.sub:SetPoint("RIGHT", row.level, "LEFT", -6, 0)

    row.onClick = function(s, button) Panel:OnSuggestionClick(s, button) end
    row.tooltip = function(s)
        return {
            title = s.title, color = s.color,
            lines = {
                s.detail or "",
                "Zone: " .. (s.uiMapID and ns:MapName(s.uiMapID) or "unknown"),
                s.level and ("Level " .. s.level) or nil,
                s.questID and ("Quest ID " .. s.questID) or nil,
                (s.x and s.y or not s.questID) and "" or "|cffff8040The client gave no map location for this quest.|r",
            },
        }
    end
    return row
end

local function fillSuggestionRow(row, s, index)
    row.data = s
    local c = s.color or ns.Colors.text
    row.bar:SetColorTexture(c.r, c.g, c.b, 0.9)
    if index == 1 then row.focus:Show() else row.focus:Hide() end

    row.title:SetText(s.title or "?")

    local detail = s.detail or ""
    -- Hand-in detail repeats the distance shown on the right; drop it.
    if s.kind == ns.SUGGEST.TURNOUT then detail = "Ready to hand in" end
    -- Zone suggestions (unlock/explore) are about a whole map, not a point,
    -- so only quests can be "missing" a location.
    local isQuest = s.kind == ns.SUGGEST.TURNOUT or s.kind == ns.SUGGEST.OBJECTIVE
    local missing = isQuest and not (s.x and s.y)
    if missing then detail = detail .. "  ·  no location" end
    row.sub:SetText(Widgets.Colorize(KIND_LABEL[s.kind] or "", c) .. "  " .. dim(detail))

    row.meta:SetText(s.distance and ns:FormatDistance(s.distance) or "")
    if s.level then
        local lc = levelColor(s.level)
        row.level:SetText("Lv " .. s.level)
        row.level:SetTextColor(lc.r, lc.g, lc.b)
    else
        row.level:SetText("")
    end

    row:SetAlpha(missing and 0.65 or 1)
end

local function buildRouteRow()
    local row = baseRow("route", ROUTE_ROW_H)

    row.num = Widgets:Text(row, "", "GameFontNormal", "CENTER")
    row.num:SetPoint("LEFT", 6, 0)
    row.num:SetWidth(24)

    row.meta = Widgets:Line(row, "", "GameFontHighlightSmall", "RIGHT")
    row.meta:SetPoint("TOPRIGHT", -8, -6)
    row.meta:SetWidth(70)

    row.tag = Widgets:Line(row, "", "GameFontNormalSmall", "RIGHT")
    row.tag:SetPoint("BOTTOMRIGHT", -8, 6)
    row.tag:SetWidth(70)

    row.title = Widgets:Line(row, "", "GameFontHighlight")
    row.title:SetPoint("TOPLEFT", 36, -6)
    row.title:SetPoint("RIGHT", row.meta, "LEFT", -6, 0)

    row.sub = Widgets:Line(row, "", "GameFontNormalSmall")
    row.sub:SetPoint("BOTTOMLEFT", 36, 6)
    row.sub:SetPoint("RIGHT", row.tag, "LEFT", -6, 0)

    row.onClick = function(stop, button)
        if button == "RightButton" then
            ns.MapPins:OpenAt(stop.uiMapID, stop.x, stop.y)
        else
            Panel:GoToStop(stop)
        end
    end
    row.tooltip = function(stop)
        return {
            title = stop.title or ("Quest " .. tostring(stop.questID)),
            lines = {
                stop.kind == "turnin" and ("Hand in this quest" .. (stop.npcName and (" to " .. stop.npcName) or ""))
                    or "Work on an objective",
                "Zone: " .. ns:MapName(stop.uiMapID),
                (stop.x and stop.y) and string.format("Position: %.1f, %.1f", stop.x * 100, stop.y * 100) or nil,
                stop.overridden and "Position comes from a manual /sol pin." or nil,
                "",
                "Click: guide from this stop",
            },
        }
    end
    return row
end

local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t"

local function fillRouteRow(row, stop, index)
    row.data = stop
    local isTurnIn = stop.kind == "turnin"
    local c = isTurnIn and ns.Colors.turnin or ns.Colors.quest
    row.bar:SetColorTexture(c.r, c.g, c.b, 0.9)

    local current = ns.Route:CurrentIndex()
    local isNext = index == current
    local isDone = index < current
    row:SetAlpha(isDone and 0.45 or 1)
    if isNext then row.focus:Show() else row.focus:Hide() end
    row.num:SetText(tostring(index))
    if isNext then
        row.num:SetTextColor(ns.Colors.accent.r, ns.Colors.accent.g, ns.Colors.accent.b)
    else
        row.num:SetTextColor(ns.Colors.dim.r, ns.Colors.dim.g, ns.Colors.dim.b)
    end

    row.title:SetText(stop.title or ("Quest " .. tostring(stop.questID)))
    local what = Widgets.Colorize(isTurnIn and "Hand in" or "Objective", c)
    local where = ns:MapName(stop.uiMapID)
    if stop.overridden then where = where .. "  ·  manual pin" end
    row.sub:SetText(what .. "  " .. dim(where))

    local d = distanceTo(stop)
    row.meta:SetText(d and ns:FormatDistance(d) or "")
    if isDone then
        row.tag:SetText(CHECK)
    elseif isNext then
        row.tag:SetText(Widgets.Colorize(ns.Route:IsGuiding() and "GUIDING" or "NEXT", ns.Colors.accent))
    else
        row.tag:SetText("")
    end
end

local function buildZoneRow()
    local row = baseRow("zone", ZONE_ROW_H)

    row.pct = Widgets:Line(row, "", "GameFontHighlight", "RIGHT")
    row.pct:SetPoint("TOPRIGHT", -8, -6)
    row.pct:SetWidth(60)

    row.name = Widgets:Line(row, "", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 12, -6)
    row.name:SetPoint("RIGHT", row.pct, "LEFT", -6, 0)

    row.progress = Widgets:ProgressBar(row, 6, ns.Colors.explore)
    row.progress:SetPoint("TOPLEFT", 12, -24)
    row.progress:SetPoint("TOPRIGHT", -8, -24)

    row.sub = Widgets:Line(row, "", "GameFontNormalSmall")
    row.sub:SetPoint("BOTTOMLEFT", 12, 4)
    row.sub:SetPoint("BOTTOMRIGHT", -8, 4)

    row.onClick = function(z) ns.MapPins:OpenAt(z.mapID) end
    row.tooltip = function(z)
        local ach = z.achievement
        local lines = {}
        if ach and (ach.total or 0) > 0 then
            table.insert(lines, string.format("%s  ·  %d of %d areas found%s", ach.name, ach.done, ach.total,
                ach.earned and "  |cff40ff40(earned)|r" or ""))
            if not ach.earned and #ach.missing > 0 then
                local shown = {}
                for i = 1, math.min(8, #ach.missing) do shown[i] = ach.missing[i] end
                table.insert(lines, "|cffffd100Still to find:|r " .. table.concat(shown, ", ")
                    .. (#ach.missing > 8 and ", ..." or ""))
            end
        else
            table.insert(lines, string.format("%s explored  ·  %d of %d map cells", ns:FormatPct(z.coverage),
                z.cells or 0, (z.gridRes or 8) ^ 2))
        end
        if z.fromClient then
            table.insert(lines, string.format("%d revealed on your world map, %d walked with the addon",
                z.revealedCells, z.visitedCells))
        end
        local areas = ns.Explored:AreaNames(z.mapID)
        if #areas > 0 then
            table.insert(lines, "")
            table.insert(lines, string.format("|cffffd100Discovered (%d):|r", #areas))
            local shown = {}
            for i = 1, math.min(10, #areas) do shown[i] = areas[i] end
            table.insert(lines, table.concat(shown, ", ") .. (#areas > 10 and ", ..." or ""))
        end
        if not z.trusted then
            table.insert(lines, "Not enough samples yet for a reliable figure.")
        end
        table.insert(lines, "")
        if not ach then
            table.insert(lines, "|cff808080No exploration achievement found for this zone, so this is a map-grid estimate; water and impassable edges keep it below 100%.|r")
        end
        table.insert(lines, "Click: open this zone's map")
        return { title = z.name, lines = lines }
    end
    return row
end

local function fillZoneRow(row, z, isCurrent)
    row.data = z
    local c = ns.Colors.explore
    row.bar:SetColorTexture(c.r, c.g, c.b, isCurrent and 0.9 or 0.35)
    if isCurrent then row.focus:Show() else row.focus:Hide() end

    row.name:SetText(z.name or ("Map " .. tostring(z.mapID)))
    row.pct:SetText(ns:FormatPct(z.coverage))
    row.progress:SetValue(z.coverage or 0)

    local parts = {}
    local ach = z.achievement
    if ach and ach.earned then
        table.insert(parts, Widgets.Colorize("Fully explored", STATUS_COLOR.ok))
    elseif ach and (ach.total or 0) > 0 then
        table.insert(parts, string.format("%d of %d areas found", ach.done, ach.total))
    elseif (z.areaCount or 0) > 0 then
        table.insert(parts, string.format("%d area%s discovered", z.areaCount, z.areaCount == 1 and "" or "s"))
    else
        table.insert(parts, string.format("%d cells", z.cells or 0))
    end
    if not z.trusted then table.insert(parts, "gathering data") end
    if isCurrent then table.insert(parts, Widgets.Colorize("you are here", ns.Colors.accent)) end
    row.sub:SetText(dim(table.concat(parts, "  ·  ")))
end

--- Section heading inside the list (not clickable).
local function buildHeaderRow()
    local row = CreateFrame("Frame", nil, content.inner)
    row:SetHeight(22)
    row.poolKind = "header"
    row.text = Widgets:Line(row, "", "GameFontNormalSmall")
    row.text:SetPoint("BOTTOMLEFT", 4, 4)
    row.text:SetPoint("BOTTOMRIGHT", -4, 4)
    row.text:SetTextColor(ns.Colors.header.r, ns.Colors.header.g, ns.Colors.header.b)
    row.rule = Widgets:Divider(row)
    row.rule:SetPoint("BOTTOMLEFT", 0, 0)
    row.rule:SetPoint("BOTTOMRIGHT", 0, 0)
    return row
end

local function addHeader(text, note)
    local row = acquire("header", buildHeaderRow)
    row.text:SetText(note and (text .. "   " .. dim(note)) or text)
    return row
end

--- One zone in "Where to level": your zone or a recommended next one.
local function buildLevelRow()
    local row = baseRow("level", 40)

    row.range = Widgets:Line(row, "", "GameFontHighlight", "RIGHT")
    row.range:SetPoint("TOPRIGHT", -8, -6)
    row.range:SetWidth(70)

    row.name = Widgets:Line(row, "", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 12, -6)
    row.name:SetPoint("RIGHT", row.range, "LEFT", -6, 0)

    row.sub = Widgets:Line(row, "", "GameFontNormalSmall")
    row.sub:SetPoint("BOTTOMLEFT", 12, 6)
    row.sub:SetPoint("BOTTOMRIGHT", -8, 6)

    row.onClick = function(z) ns.MapPins:OpenAt(z.mapID) end
    row.tooltip = function(z)
        local level = ns.UnitLevelSafe()
        local lines = {
            z.range and string.format("Levels %d–%d", z.range.min, z.range.max) or "Level range unknown",
            z.range and level and statusText(z.status, z.range, level) or nil,
            z.distance and (ns:FormatDistance(z.distance) .. " away") or nil,
            z.range and (z.range.faction and (z.range.faction .. " territory") or "Contested") or nil,
            z.range and z.range.source == "classic" and "|cff808080Range from Classic zone data|r" or nil,
            "",
            "Click: open this zone's map",
        }
        return { title = z.name, lines = lines, color = STATUS_COLOR[z.status] }
    end
    return row
end

local function fillLevelRow(row, z, isCurrent)
    row.data = z
    local c = STATUS_COLOR[z.status] or ns.Colors.dim
    row.bar:SetColorTexture(c.r, c.g, c.b, 0.9)
    if isCurrent then row.focus:Show() else row.focus:Hide() end
    row.name:SetText(z.name or "?")
    row.range:SetText(rangeText(z.range))
    row.range:SetTextColor(c.r, c.g, c.b)

    local level = ns.UnitLevelSafe()
    local parts = {}
    if isCurrent then
        table.insert(parts, Widgets.Colorize("You are here", ns.Colors.accent))
        table.insert(parts, z.range and level and statusText(z.status, z.range, level) or "No level data")
    else
        if z.distance then table.insert(parts, ns:FormatDistance(z.distance) .. " away") end
        if z.range and level and level < z.range.min then
            table.insert(parts, string.format("opens up at %d", z.range.min))
        end
        table.insert(parts, z.range.faction and (z.range.faction == "Alliance" and "Alliance" or "Horde") or "Contested")
    end
    row.sub:SetText(dim(table.concat(parts, "  ·  ")))
end

---------------------------------------------------------------------------
-- Empty state
---------------------------------------------------------------------------
local function showEmpty(titleText, bodyText, actionLabel, action)
    emptyState:ClearAllPoints()
    emptyState:SetPoint("TOPLEFT", content.inner, "TOPLEFT", 0, -24)
    emptyState:SetPoint("TOPRIGHT", content.inner, "TOPRIGHT", 0, -24)
    emptyState.title:SetText(titleText)
    emptyState.body:SetText(bodyText)
    if actionLabel then
        emptyState.action:SetText(actionLabel)
        emptyState.action:SetScript("OnClick", action)
        emptyState.action:Show()
    else
        emptyState.action:Hide()
    end
    emptyState:Show()
    fitInner(140)
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------
local function renderNext()
    if #lastSuggestions == 0 then
        showEmpty("Nothing to suggest right now",
            "Accept a quest and its next objective will appear here, ranked by distance, level and value.")
        return
    end
    for i, s in ipairs(lastSuggestions) do
        fillSuggestionRow(acquire("suggestion", buildSuggestionRow), s, i)
    end
    fitInner(layoutRows())
end

local function renderRoute()
    local stops = ns.Route:Get().stops or {}
    if #stops == 0 then
        showEmpty("No route yet",
            "Build a route to order your quest objectives and hand-ins into one walkable path.",
            "Build route", function() Panel:BuildRoute() end)
        return
    end
    for i, stop in ipairs(stops) do
        fillRouteRow(acquire("route", buildRouteRow), stop, i)
    end
    fitInner(layoutRows())
end

local function renderZones()
    -- Where to level: your zone, then the nearest zones that fit your level.
    local prog = ns.ZoneData:Progression(3)
    local continentName = prog.continent and ns.ZoneData:Name(prog.continent)
    addHeader("WHERE TO LEVEL", continentName)
    if prog.current then
        fillLevelRow(acquire("level", buildLevelRow), prog.current, true)
    end
    for _, z in ipairs(prog.next) do
        fillLevelRow(acquire("level", buildLevelRow), z, false)
    end
    if #prog.next == 0 then
        addHeader(dim(prog.continent and "No other zone here fits your level right now."
            or "Not on a continent map (instance or city)."))
    end

    -- Exploration coverage.
    local zones = ns.Explored:All()
    addHeader("EXPLORED", #zones > 0 and string.format("%d zone%s", #zones, #zones == 1 and "" or "s") or nil)
    if #zones == 0 then
        addHeader(dim("Nothing yet. Coverage builds as you travel."))
    end
    local here = ns:PlayerMapID()
    local hereZone = here and ns.ZoneData:WorldAncestor(here)
    for _, z in ipairs(zones) do
        fillZoneRow(acquire("zone", buildZoneRow), z, z.mapID == hereZone)
    end
    fitInner(layoutRows())
end

---------------------------------------------------------------------------
-- Header info, tabs and footer
---------------------------------------------------------------------------
local function updateInfo()
    local mapID = ns:PlayerMapID()
    local zone = mapID and ns.ZoneData:WorldAncestor(mapID) or mapID
    zoneText:SetText(zone and ns.ZoneData:Name(zone) or "Unknown location")
    local level = ns.UnitLevelSafe()
    local range = zone and ns.ZoneData:LevelRange(zone)
    if range then
        local c = STATUS_COLOR[ns.ZoneData:LevelStatus(range, level)] or ns.Colors.dim
        levelText:SetText("Levels " .. rangeText(range))
        levelText:SetTextColor(c.r, c.g, c.b)
    else
        levelText:SetText("You: " .. tostring(level or "?"))
        levelText:SetTextColor(ns.Colors.dim.r, ns.Colors.dim.g, ns.Colors.dim.b)
    end

    local cov = mapID and ns.Explored:Coverage(mapID)
    if cov then
        local detail = ns.Explored:Detail(mapID)
        exploreBar:SetValue(cov)
        exploreBar:SetAlpha(1)
        local ach = detail.achievement
        if ach and ach.earned then
            exploreBar.label:SetText("Fully explored")
        elseif ach and (ach.total or 0) > 0 then
            exploreBar.label:SetText(string.format("%s explored  ·  %d of %d areas", ns:FormatPct(cov), ach.done, ach.total))
        elseif detail.trusted then
            exploreBar.label:SetText(string.format("%s of this zone explored", ns:FormatPct(cov)))
        else
            exploreBar.label:SetText(string.format("%s explored  ·  gathering data", ns:FormatPct(cov)))
        end
    else
        exploreBar:SetValue(0)
        exploreBar:SetAlpha(0.6)
        exploreBar.label:SetText("Exploration isn't tracked here")
    end
end

local function tabCount(key)
    if key == "next" then return #lastSuggestions end
    if key == "route" then return ns.Route:Count() end
    return #ns.Explored:All()
end

local function updateTabs()
    for _, tab in ipairs(TABS) do
        local b = tabButtons[tab.key]
        local selected = tab.key == currentTab
        local n = tabCount(tab.key)
        b.text:SetText(tab.label .. (n > 0 and ("  " .. dim(tostring(n))) or ""))
        if selected then
            b.text:SetTextColor(ns.Colors.accent.r, ns.Colors.accent.g, ns.Colors.accent.b)
            b.underline:Show()
            b.bg:SetAlpha(1)
        else
            b.text:SetTextColor(0.75, 0.75, 0.75)
            b.underline:Hide()
            b.bg:SetAlpha(0.4)
        end
    end
    for _, tab in ipairs(TABS) do
        if tab.key == currentTab then hintText:SetText(tab.hint) end
    end
end

local function updateFooter()
    for key, list in pairs(footerButtons) do
        for _, b in ipairs(list) do
            if key == currentTab then b:Show() else b:Hide() end
        end
    end
    -- The summary fills whatever space this tab's buttons leave, so it clips
    -- instead of running under them on a narrow panel.
    local buttons = footerButtons[currentTab] or {}
    local leftmost = buttons[#buttons]
    summaryText:ClearAllPoints()
    summaryText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 12)
    if leftmost then
        summaryText:SetPoint("RIGHT", leftmost, "LEFT", -6, 0)
    else
        summaryText:SetPoint("RIGHT", frame, "RIGHT", -24, 0)
    end

    local text = ""
    if currentTab == "next" then
        text = string.format("%d suggestion%s", #lastSuggestions, #lastSuggestions == 1 and "" or "s")
    elseif currentTab == "route" then
        local state = ns.Route:Get()
        local n = #(state.stops or {})
        local cur = math.min(state.current or 1, n)
        if n == 0 then
            text = "no stops"
        elseif (state.current or 1) > n then
            text = "route complete"
        else
            text = string.format("stop %d of %d", cur, n)
        end
        local go = footerButtons.route and footerButtons.route.go
        if go then
            go:SetText(state.guiding and "Stop guide" or "Start guide")
            if n > 0 then go:Enable() else go:Disable() end
        end
    else
        local s = ns.Explored:Summary()
        text = string.format("%d zone%s  ·  %d cells", s.zones, s.zones == 1 and "" or "s", s.totalCells)
        local reset = footerButtons.zones and footerButtons.zones.reset
        if reset then reset:SetText(resetArmed and "Confirm reset" or "Reset all") end
    end
    summaryText:SetText(text)
end

--- Spread the tab buttons evenly across the current panel width.
local function layoutTabs()
    local w = (frame:GetWidth() or DEFAULT_W) - 16
    local each = w / #TABS
    for i, tab in ipairs(TABS) do
        local b = tabButtons[tab.key]
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", frame, "TOPLEFT", 8 + (i - 1) * each, -TOP_OF_TABS)
        b:SetSize(each - 2, TAB_H)
    end
end

--- Footer buttons for a tab, laid out right-to-left.
local function addFooterButtons(tabKey, specs)
    local list = {}
    local anchor
    for i = #specs, 1, -1 do
        local spec = specs[i]
        local b = Widgets:Button(frame, spec.label, spec.width or 84, 22, spec.onClick)
        if anchor then
            b:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
        else
            b:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -22, 7)
        end
        if spec.tip then Widgets:TooltipLines(b, spec.label, { spec.tip }) end
        b:Hide()
        anchor = b
        table.insert(list, b)
        if spec.name then list[spec.name] = b end
    end
    footerButtons[tabKey] = list
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------
local function buildPanel()
    frame = Widgets:Window("SolarynExpeditionPanel", {
        title = "Solaryn's Expedition",
        icon = "Interface\\Icons\\INV_Misc_Map_01",
        width = DEFAULT_W, height = DEFAULT_H,
        posKey = "panelPoint", sizeKey = "panelSize",
        default = { "CENTER", -250, 60 },
        resizable = true, minW = 320, minH = 320, maxW = 720, maxH = 1000,
        isLocked = function() return ns.Settings().panelLocked end,
    })
    header = frame.titleBar

    -- Keep the button beside the close X, in the title bar.
    local cog = Widgets:IconButton(header, "Interface\\Buttons\\UI-OptionsButton", 16,
        "Options", { "Route size, tracking, and suggestion weights." },
        function() Panel:ToggleOptions() end)
    cog:SetPoint("RIGHT", frame.closeButton, "LEFT", -4, 0)

    ------------------------------------------------------------------
    -- Where-am-I strip
    ------------------------------------------------------------------
    local info = CreateFrame("Frame", nil, frame)
    info:SetPoint("TOPLEFT", 1, -(Widgets.TITLE_HEIGHT + 1))
    info:SetPoint("TOPRIGHT", -1, -(Widgets.TITLE_HEIGHT + 1))
    info:SetHeight(INFO_H)
    local infoBg = Widgets:Fill(info, "BACKGROUND", Theme.sectionBg)
    infoBg:SetAllPoints()

    levelText = Widgets:Line(info, "", "GameFontNormalSmall", "RIGHT")
    levelText:SetPoint("TOPRIGHT", -10, -9)
    levelText:SetWidth(96)

    -- Hover the strip for what the zone's level means for you and where next.
    info:EnableMouse(true)
    info:SetScript("OnEnter", function(self)
        local prog = ns.ZoneData:Progression(1)
        local cur, level = prog.current, ns.UnitLevelSafe()
        local lines = {}
        if cur and cur.range then
            table.insert(lines, string.format("Levels %d–%d  ·  you are %s", cur.range.min, cur.range.max, tostring(level or "?")))
            table.insert(lines, statusText(cur.status, cur.range, level or 0))
        else
            table.insert(lines, "No level data for this area.")
        end
        local nxt = prog.next[1]
        if nxt then
            table.insert(lines, "")
            table.insert(lines, string.format("Next: %s (%s)%s", nxt.name, rangeText(nxt.range),
                nxt.distance and ("  ·  " .. ns:FormatDistance(nxt.distance)) or ""))
        end
        Widgets:ShowTooltip(self, cur and cur.name or "Here", lines, cur and STATUS_COLOR[cur.status])
    end)
    info:SetScript("OnLeave", function() GameTooltip:Hide() end)

    zoneText = Widgets:Line(info, "", "GameFontHighlightLarge")
    zoneText:SetPoint("TOPLEFT", 10, -7)
    zoneText:SetPoint("RIGHT", levelText, "LEFT", -6, 0)

    exploreBar = Widgets:ProgressBar(info, 14, ns.Colors.explore)
    exploreBar:SetPoint("BOTTOMLEFT", 10, 8)
    exploreBar:SetPoint("BOTTOMRIGHT", -10, 8)

    ------------------------------------------------------------------
    -- Tabs
    ------------------------------------------------------------------
    for _, tab in ipairs(TABS) do
        local b = CreateFrame("Button", nil, frame)
        b.bg = Widgets:Fill(b, "BACKGROUND", Theme.sectionBg)
        b.bg:SetAllPoints()
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.06)
        b.underline = Widgets:Fill(b, "ARTWORK", ns.Colors.accent.r, ns.Colors.accent.g, ns.Colors.accent.b, 1)
        b.underline:SetPoint("BOTTOMLEFT", 0, 0)
        b.underline:SetPoint("BOTTOMRIGHT", 0, 0)
        b.underline:SetHeight(2)
        b.text = Widgets:Line(b, tab.label, "GameFontNormal", "CENTER")
        b.text:SetPoint("LEFT", 4, 1)
        b.text:SetPoint("RIGHT", -4, 1)
        b:SetScript("OnClick", function() Panel:SetTab(tab.key) end)
        tabButtons[tab.key] = b
    end
    layoutTabs()

    local tabRule = Widgets:Divider(frame)
    tabRule:SetPoint("TOPLEFT", 8, -(TOP_OF_TABS + TAB_H))
    tabRule:SetPoint("TOPRIGHT", -8, -(TOP_OF_TABS + TAB_H))

    hintText = Widgets:Line(frame, "", "GameFontDisableSmall")
    hintText:SetPoint("TOPLEFT", 12, -(TOP_OF_TABS + TAB_H + 4))
    hintText:SetPoint("TOPRIGHT", -12, -(TOP_OF_TABS + TAB_H + 4))

    ------------------------------------------------------------------
    -- List
    ------------------------------------------------------------------
    content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", 8, -TOP_OF_LIST)
    content:SetPoint("BOTTOMRIGHT", -8, FOOTER_H)

    local scroll, inner = Widgets:Scroll(content)
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -20, 0)
    content.scroll = scroll
    content.inner = inner

    emptyState = CreateFrame("Frame", nil, inner)
    emptyState:SetHeight(120)
    emptyState.title = Widgets:Text(emptyState, "", "GameFontNormal", "CENTER")
    emptyState.title:SetPoint("TOPLEFT", 16, 0)
    emptyState.title:SetPoint("TOPRIGHT", -16, 0)
    emptyState.body = Widgets:Text(emptyState, "", "GameFontHighlightSmall", "CENTER")
    emptyState.body:SetPoint("TOPLEFT", emptyState.title, "BOTTOMLEFT", 0, -8)
    emptyState.body:SetPoint("TOPRIGHT", emptyState.title, "BOTTOMRIGHT", 0, -8)
    emptyState.body:SetTextColor(ns.Colors.dim.r, ns.Colors.dim.g, ns.Colors.dim.b)
    emptyState.action = Widgets:Button(emptyState, "", 120, 24)
    emptyState.action:SetPoint("TOP", emptyState.body, "BOTTOM", 0, -12)
    emptyState:Hide()

    ------------------------------------------------------------------
    -- Footer
    ------------------------------------------------------------------
    local footRule = Widgets:Divider(frame)
    footRule:SetPoint("BOTTOMLEFT", 8, FOOTER_H - 1)
    footRule:SetPoint("BOTTOMRIGHT", -8, FOOTER_H - 1)

    summaryText = Widgets:Line(frame, "", "GameFontNormalSmall")
    summaryText:SetTextColor(ns.Colors.dim.r, ns.Colors.dim.g, ns.Colors.dim.b)

    addFooterButtons("next", {
        { label = "Refresh", width = 80, tip = "Re-rank suggestions from your current position.",
          onClick = function() ns.Suggest:Recompute(); Panel:Refresh() end },
    })
    addFooterButtons("route", {
        { name = "go", label = "Start guide", width = 90,
          tip = "Follow the route: the waypoint moves to the next stop each time you arrive.",
          onClick = function()
              if ns.Route:IsGuiding() then ns.Route:StopGuiding() else ns.Route:Guide() end
          end },
        { label = "Rebuild", width = 70, tip = "Re-order the route from where you are now.",
          onClick = function() Panel:BuildRoute() end },
        { label = "Clear", width = 56, tip = "Remove the route and its map pins.",
          onClick = function() ns.Route:Clear(); ns.MapPins:ClearRoute(); Panel:Refresh() end },
    })
    addFooterButtons("zones", {
        { name = "reset", label = "Reset all", width = 100,
          tip = "Forget exploration data for every zone on this character. Click twice to confirm.",
          onClick = function()
              if resetArmed then
                  resetArmed = false
                  ns.Explored:ResetAll()
              else
                  resetArmed = true
              end
              Panel:Refresh()
          end },
    })

    -- Rows anchor to both edges of the scroll child, which tracks the scroll
    -- frame's width, so a resize only needs the tabs re-spread; no re-render
    -- on every frame of the drag.
    frame:SetScript("OnSizeChanged", function()
        if isBuilt() then layoutTabs() end
    end)
    frame:SetScript("OnShow", function() ns.Settings().panelOpen = true end)
    frame:SetScript("OnHide", function()
        ns.Settings().panelOpen = false
        resetArmed = false
    end)

    panelBuilt = true
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function Panel:SetTab(key)
    -- Guard against an unknown key so a bad caller can't throw.
    local valid = false
    for _, tab in ipairs(TABS) do
        if tab.key == key then valid = true break end
    end
    if not valid then
        ns:Debug("SetTab: unknown tab '%s'", tostring(key))
        return
    end
    if key ~= currentTab then resetArmed = false end
    currentTab = key
    if isBuilt() and content.scroll.SetVerticalScroll then
        pcall(content.scroll.SetVerticalScroll, content.scroll, 0)
    end
    Panel:Refresh()
end

--- Accessors used by the options code and by the test suite.
function Panel:GetFrame() return frame end
function Panel:GetHeader() return header end
function Panel:GetContent() return content end
function Panel:GetTabButton(key) return tabButtons[key] end
function Panel:ActiveRows() return activeRows end

--- Currently displayed tab ("next", "route", or "zones").
function Panel:CurrentTab() return currentTab end

function Panel:Refresh()
    if not frame or not frame:IsShown() then return end
    if not isBuilt() then return end
    -- Re-entrancy guard. A render that re-entered Refresh (e.g. via an event
    -- fired during rendering) recursed until the C stack overflowed.
    if refreshing then return end
    refreshing = true

    local ok, err = pcall(function()
        -- One quiet compute per refresh feeds both the tab count and the list.
        lastSuggestions = ns.Suggest:ComputeQuietly() or {}
        releaseRows()
        emptyState:Hide()
        updateInfo()
        updateTabs()
        updateFooter()
        if currentTab == "next" then renderNext()
        elseif currentTab == "route" then renderRoute()
        else renderZones() end
    end)

    refreshing = false
    Panel.lastError = (not ok) and tostring(err) or nil
    if not ok then ns:Debug("panel render error: %s", tostring(err)) end
end

function Panel:Toggle(force)
    -- Build on demand: the minimap button and slash command can both reach here
    -- before/without Initialize having run, and a half-built panel is worse
    -- than one built slightly late.
    if not isBuilt() then buildPanel() end
    if not frame then return end

    local wantShow = force
    if wantShow == nil then wantShow = not frame:IsShown() end
    if wantShow then
        if ns.Settings().autoPickRoute and ns.Route:IsStale() then
            ns.Route:Build()
            ns.Route:StampFingerprint()
        end
        frame:Show()
        Panel:SetTab(currentTab)
    else
        frame:Hide()
    end
end

function Panel:BuildRoute()
    ns.Route:Build()
    ns.Route:StampFingerprint()
    if ns.Settings().mapPins then ns.MapPins:DrawRoute() end
    Panel:SetTab("route")
end

function Panel:GoToStop(stop)
    if not stop then return end
    local ok = ns.Route:GoToStop(stop)
    if ok then
        ns:Print("waypoint set: %s (%s)", ns:Truncate(stop.title or "?", 30), ns:MapName(stop.uiMapID))
    end
end

function Panel:OnSuggestionClick(s, button)
    if button == "RightButton" then
        if s.uiMapID then ns.MapPins:OpenAt(s.uiMapID, s.x, s.y) end
        return
    end
    if IsShiftKeyDown() then
        if s.questID then
            ns.Suggest:Hide(s.questID)
            Panel:Refresh()
        end
        return
    end
    if not s.questID and s.uiMapID and not (s.x and s.y) then
        -- A zone suggestion: show the zone itself.
        ns.MapPins:OpenAt(s.uiMapID)
        return
    end
    if s.x and s.y and s.uiMapID then
        ns.MapPins:SetWaypoint(s.uiMapID, s.x, s.y)
        ns:Print("waypoint set: %s", ns:Truncate(s.title, 30))
    else
        ns:Print("no known location for '%s'.", ns:Truncate(s.title, 24))
    end
end

function Panel:ToggleOptions()
    if not ns.Options then
        ns:Print("options panel not available.")
        return
    end
    ns.Options:Toggle()
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function Panel:Initialize()
    if panelBuilt then return end
    buildPanel()
end

function Panel:OnLogin()
    if ns.Settings().panelOpen then
        Panel:Toggle(true)
    end
end

-- Several of these fire together (a quest log update also recomputes
-- suggestions, which fires suggestions_updated), so coalesce into one render.
local function onDataChanged()
    if frame and frame:IsShown() then
        ns:Debounce("panel", 0.1, function() Panel:Refresh() end)
    end
end

ns:RegisterEvent("route_changed", onDataChanged, Panel)
ns:RegisterEvent("suggestions_updated", onDataChanged, Panel)
ns:RegisterEvent("explored_changed", onDataChanged, Panel)
ns:RegisterEvent("QUEST_LOG_UPDATE", onDataChanged, Panel)
ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", onDataChanged, Panel)
ns:RegisterEvent("QUEST_ACCEPTED", onDataChanged, Panel)
ns:RegisterEvent("QUEST_TURNED_IN", onDataChanged, Panel)
ns:RegisterEvent("PLAYER_LEVEL_UP", onDataChanged, Panel)

ns:RegisterModule("Panel", Panel)

return Panel
