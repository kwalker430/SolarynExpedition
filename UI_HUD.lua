--[[---------------------------------------------------------------------------
    Solaryn's Expedition — route tracker (on-screen HUD).

    A compact, always-on-screen view of the guide, in the spirit of the
    client's objective tracker:

      ROUTE  3/8                       [>>] [x] [-]
      (arrow) Kobold Camp Cleanup
              Elwynn Forest  ·  220 yd
              - Kobold Vermin: 4/8
      4. A Threat Within  ·  Hand in       410 yd
      5. Westfall Plots                    1.2 mi

    The header drags it (unless locked) and opens the panel on click. The
    arrow points at the current stop relative to the way you're facing. It
    can only do that while you and the stop are on the same map, because map
    coordinates are the one space where "north" is certain.

    Rebuilt on route/quest events; distance and arrow refresh on a light
    ticker while shown.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.HUD = {}

local HUD = ns.HUD
local Widgets = ns.Widgets

local WIDTH = 250
local MAX_OBJECTIVE_LINES = 4
local MAX_UPCOMING = 6
local TICK = 0.2

-- Key Bindings > AddOns: "Use quest item" clicks the first item button.
_G.BINDING_HEADER_SOLARYNEXPEDITION = "Solaryn's Expedition"
_G["BINDING_NAME_CLICK SolarynExpeditionQuestItemButton1:LeftButton"] = "Use quest item (guided quest)"

local MAX_ITEM_BUTTONS = 3
local itemButtons = {}
local itemsPending = false     -- an update waiting for combat to end

local frame, header, body
local titleText, countText, skipButton, stopButton, collapseButton
local arrow, stopTitle, stopWhere, objectiveLines = nil, nil, nil, {}
local upcomingRows = {}
local currentBlock, startButton
local built = false

local function S() return ns.Settings() end

local function dimColor(fs)
    fs:SetTextColor(ns.Colors.dim.r, ns.Colors.dim.g, ns.Colors.dim.b)
end

---------------------------------------------------------------------------
-- Direction
---------------------------------------------------------------------------
--- Angle (radians, counter-clockwise from straight ahead) from the player to
--- a stop, or nil when it can't be known. Map coordinates run east (+x) and
--- south (+y); GetPlayerFacing is 0 for north, increasing counter-clockwise,
--- so the bearing to (dx, dy) is atan2(-dx, -dy).
function HUD.RelativeAngle(stop)
    if not stop or not stop.uiMapID or not stop.x then return nil end
    if type(_G.GetPlayerFacing) ~= "function" then return nil end
    local facing = ns.SafeNum(_G.GetPlayerFacing())
    if not facing then return nil end
    local pos = ns:PlayerPosition(stop.uiMapID)
    if not pos then return nil end

    local dx, dy = stop.x - pos.x, stop.y - pos.y
    -- Maps aren't square in yards; scale so the angle is true on the ground.
    if ns.Has.mapWorldSize then
        local w, h = ns.Try("C_Map", "GetMapWorldSize", stop.uiMapID)
        w, h = ns.SafeNum(w), ns.SafeNum(h)
        if w and h and w > 0 and h > 0 then dx, dy = dx * w, dy * h end
    end
    if dx == 0 and dy == 0 then return 0 end
    return math.atan2(-dx, -dy) - facing
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------
local function smallButton(parent, label, tip, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(18, 16)
    local t = Widgets:Text(b, label, "GameFontNormalSmall", "CENTER")
    t:SetPoint("CENTER", 0, 0)
    b.text = t
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.15)
    b:SetScript("OnClick", onClick)
    Widgets:TooltipLines(b, tip, {})
    return b
end

local function buildUpcomingRow(i)
    local row = CreateFrame("Button", nil, body)
    row:SetHeight(16)
    row:RegisterForClicks("LeftButtonUp")
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)

    row.dist = Widgets:Line(row, "", "GameFontHighlightSmall", "RIGHT")
    row.dist:SetPoint("RIGHT", -4, 0)
    row.dist:SetWidth(56)
    dimColor(row.dist)

    row.text = Widgets:Line(row, "", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 6, 0)
    row.text:SetPoint("RIGHT", row.dist, "LEFT", -4, 0)

    row:SetScript("OnClick", function(self)
        if self.index then ns.Route:Guide(self.index) end
    end)
    row:SetScript("OnEnter", function(self)
        local st = self.stop
        if not st then return end
        Widgets:ShowTooltip(self, st.title or "?", {
            st.kind == "turnin" and "Hand in" or "Objective",
            ns:MapName(st.uiMapID),
            "",
            "Click: guide from this stop",
        })
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:Hide()
    upcomingRows[i] = row
    return row
end

local function build()
    frame = CreateFrame("Frame", "SolarynExpeditionHUD", UIParent)
    frame:SetSize(WIDTH, 60)
    frame:SetFrameStrata("LOW")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:Hide()
    Widgets.RestorePosition(frame, "hudPoint", { "RIGHT", -60, 120 })

    local bg = Widgets:Fill(frame, "BACKGROUND", 0, 0, 0, 0.35)
    bg:SetAllPoints()

    -- Header: drag handle, click to open the panel.
    header = CreateFrame("Button", nil, frame)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    header:SetHeight(20)
    header:RegisterForDrag("LeftButton")
    header:RegisterForClicks("LeftButtonUp")
    header:SetScript("OnDragStart", function()
        if not S().hudLocked then frame:StartMoving() end
    end)
    header:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        Widgets.SavePosition(frame, "hudPoint")
        HUD:UpdateItems()          -- move the item buttons along
    end)
    header:SetScript("OnClick", function() ns.Panel:Toggle(true); ns.Panel:SetTab("route") end)
    Widgets:TooltipLines(header, "Route tracker", {
        "Click: open the Route tab",
        "Drag: move (lock it in options)",
    })

    local rule = Widgets:Divider(header)
    rule:SetPoint("BOTTOMLEFT", 0, 0)
    rule:SetPoint("BOTTOMRIGHT", 0, 0)

    collapseButton = smallButton(header, "-", "Collapse / expand", function()
        S().hudCollapsed = not S().hudCollapsed
        HUD:Refresh()
    end)
    collapseButton:SetPoint("RIGHT", -2, 0)
    stopButton = smallButton(header, "x", "Stop guiding", function() ns.Route:StopGuiding() end)
    stopButton:SetPoint("RIGHT", collapseButton, "LEFT", -2, 0)
    skipButton = smallButton(header, ">>", "Skip this stop", function() ns.Route:Advance("skipped") end)
    skipButton:SetPoint("RIGHT", stopButton, "LEFT", -2, 0)

    titleText = Widgets:Line(header, "ROUTE", "GameFontNormalSmall")
    titleText:SetPoint("LEFT", 6, 0)
    countText = Widgets:Line(header, "", "GameFontHighlightSmall")
    countText:SetPoint("LEFT", titleText, "RIGHT", 6, 0)

    body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", 0, -20)
    body:SetPoint("TOPRIGHT", 0, -20)
    body:SetHeight(40)

    -- Current stop: click to re-point the waypoint at it.
    currentBlock = CreateFrame("Button", nil, body)
    currentBlock:SetPoint("TOPLEFT", 0, -4)
    currentBlock:SetPoint("TOPRIGHT", 0, -4)
    currentBlock:RegisterForClicks("LeftButtonUp")
    currentBlock:SetScript("OnClick", function()
        local st = ns.Route:Next()
        if st then ns.Route:SetWaypointTo(st) end
    end)
    Widgets:TooltipLines(currentBlock, "Current stop", { "Click: set the waypoint here again" })

    arrow = currentBlock:CreateTexture(nil, "ARTWORK")
    arrow:SetSize(24, 24)
    arrow:SetPoint("TOPLEFT", 4, -2)
    arrow:SetTexture("Interface\\Minimap\\MinimapArrow")

    stopTitle = Widgets:Line(currentBlock, "", "GameFontNormal")
    stopTitle:SetPoint("TOPLEFT", 32, 0)
    stopTitle:SetPoint("TOPRIGHT", -4, 0)

    stopWhere = Widgets:Line(currentBlock, "", "GameFontHighlightSmall")
    stopWhere:SetPoint("TOPLEFT", stopTitle, "BOTTOMLEFT", 0, -2)
    stopWhere:SetPoint("TOPRIGHT", stopTitle, "BOTTOMRIGHT", 0, -2)
    dimColor(stopWhere)

    for i = 1, MAX_OBJECTIVE_LINES do
        local fs = Widgets:Line(currentBlock, "", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", stopWhere, "BOTTOMLEFT", 0, -2 - (i - 1) * 13)
        fs:SetPoint("TOPRIGHT", stopWhere, "BOTTOMRIGHT", 0, -2 - (i - 1) * 13)
        fs:Hide()
        objectiveLines[i] = fs
    end

    for i = 1, MAX_UPCOMING do buildUpcomingRow(i) end

    -- Shown when a route exists but the guide isn't running (hudAlways).
    startButton = Widgets:Button(body, "Start guide", 100, 20, function() ns.Route:Guide() end)
    startButton:SetPoint("TOPLEFT", 6, -6)
    startButton:Hide()

    -- Live distance and arrow.
    local elapsedSince = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        elapsedSince = elapsedSince + (elapsed or 0)
        if elapsedSince < TICK then return end
        elapsedSince = 0
        HUD:UpdateLive()
    end)

    built = true
end

---------------------------------------------------------------------------
-- Quest item buttons
---------------------------------------------------------------------------
-- Using an item is a protected action, so these are SecureActionButtons:
-- their item, visibility and position can only change out of combat. They
-- are parented to UIParent (not the tracker) so the tracker itself never
-- becomes protected and can still update during fights; they're placed
-- beside it by screen coordinates instead of being anchored to it.
local function inCombat()
    return type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown()
end

local function itemIcon(itemID)
    local ci = _G.C_Item
    if type(ci) == "table" and type(ci.GetItemIconByID) == "function" then return ci.GetItemIconByID(itemID) end
    if type(_G.GetItemIcon) == "function" then return _G.GetItemIcon(itemID) end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function itemCount(itemID)
    local ci = _G.C_Item
    if type(ci) == "table" and type(ci.GetItemCount) == "function" then return ci.GetItemCount(itemID) end
    return type(_G.GetItemCount) == "function" and _G.GetItemCount(itemID) or 0
end

local function itemCooldown(itemID)
    local cc = _G.C_Container
    if type(cc) == "table" and type(cc.GetItemCooldown) == "function" then return cc.GetItemCooldown(itemID) end
    if type(_G.GetItemCooldown) == "function" then return _G.GetItemCooldown(itemID) end
end

local function buildItemButton(i)
    local size = i == 1 and 36 or 30
    local b = CreateFrame("Button", "SolarynExpeditionQuestItemButton" .. i, UIParent, "SecureActionButtonTemplate")
    b:SetSize(size, size)
    b:SetFrameStrata("MEDIUM")
    -- Secure buttons act on key-down or key-up depending on this CVar;
    -- registering only the matching one makes clicks and keybinds work
    -- (and never fire twice) on old and new clients alike.
    local down = type(_G.GetCVarBool) == "function" and _G.GetCVarBool("ActionButtonUseKeyDown")
    b:RegisterForClicks(down and "AnyDown" or "AnyUp")
    b:SetAttribute("type", "item")

    local border = Widgets:Fill(b, "BACKGROUND", 0, 0, 0, 0.9)
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.2)

    b.count = Widgets:Text(b, "", "NumberFontNormal", "RIGHT")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)

    b.hotkey = Widgets:Text(b, "", "NumberFontNormalSmallGray", "RIGHT")
    b.hotkey:SetPoint("TOPRIGHT", -2, -2)

    b.cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cooldown:SetAllPoints()

    b:SetScript("OnEnter", function(self)
        if not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        if GameTooltip.SetItemByID then
            GameTooltip:SetItemByID(self.itemID)
        elseif GameTooltip.SetHyperlink then
            GameTooltip:SetHyperlink("item:" .. self.itemID)
        end
        if self.questTitle then
            GameTooltip:AddLine("For: " .. self.questTitle, ns.Colors.accent.r, ns.Colors.accent.g, ns.Colors.accent.b)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:Hide()
    itemButtons[i] = b
    return b
end

--- Cooldowns and counts can update any time, even in combat.
local function updateItemCooldowns()
    for _, b in ipairs(itemButtons) do
        if b.itemID and b:IsShown() then
            local n = itemCount(b.itemID) or 0
            b.count:SetText(n > 1 and tostring(n) or "")
            local start, duration, enable = itemCooldown(b.itemID)
            if start and duration and b.cooldown.SetCooldown then
                b.cooldown:SetCooldown(start, duration, enable)
            end
        end
    end
end

--- Items for the guided quests: the current stop's quest first, then the
--- upcoming ones shown in the tracker, one button per distinct item.
local function wantedItems()
    local out, seenItem, seenQuest = {}, {}, {}
    if not frame or not frame:IsShown() or not S().questItemButtons then return out end
    local state = ns.Route:Get()
    if not state.guiding then return out end
    local stops = state.stops or {}
    local bag = ns.QuestData:BagQuestItems()
    local last = math.min(#stops, (state.current or 1) + (ns.SafeNum(S().hudUpcoming) or 3))
    for i = state.current or 1, last do
        local st = stops[i]
        if st and st.questID and not seenQuest[st.questID] then
            seenQuest[st.questID] = true
            local it = ns.QuestData:QuestItem(st.questID, bag)
            if it and not seenItem[it.itemID] and itemCount(it.itemID) ~= 0 then
                seenItem[it.itemID] = true
                it.questTitle = st.title
                table.insert(out, it)
                if #out >= MAX_ITEM_BUTTONS then break end
            end
        end
    end
    return out
end

--- Point the item buttons at the right items and park them left of the
--- tracker. Deferred until combat ends when called during combat.
function HUD:UpdateItems()
    if not built then return end
    if inCombat() then
        itemsPending = true
        updateItemCooldowns()
        return
    end
    itemsPending = false

    local items = wantedItems()
    -- Screen position of the tracker's top-left, in UIParent units.
    local left, top = frame:GetLeft(), frame:GetTop()
    local scale = (frame:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
    local y = (top or 0) * scale

    for i = 1, MAX_ITEM_BUTTONS do
        local b = itemButtons[i] or buildItemButton(i)
        local it = items[i]
        if it and left and top then
            b.itemID, b.questTitle = it.itemID, it.questTitle
            b:SetAttribute("item", "item:" .. it.itemID)
            b.icon:SetTexture(itemIcon(it.itemID))
            local key = i == 1 and type(_G.GetBindingKey) == "function"
                and _G.GetBindingKey("CLICK SolarynExpeditionQuestItemButton1:LeftButton")
            b.hotkey:SetText(key or "")
            b:ClearAllPoints()
            b:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", left * scale - 6, y)
            y = y - b:GetHeight() - 6
            b:Show()
        else
            b.itemID, b.questTitle = nil, nil
            b:SetAttribute("item", nil)
            b:Hide()
        end
    end
    updateItemCooldowns()
end

function HUD:GetItemButton(i) return itemButtons[i] end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------
--- Should the tracker be on screen right now?
function HUD:ShouldShow()
    local s = S()
    if not s.hud then return false end
    local state = ns.Route:Get()
    local stops = state.stops or {}
    if #stops == 0 or (state.current or 1) > #stops then return false end
    return state.guiding and true or (s.hudAlways and true or false)
end

--- Distance text and arrow for the current stop (cheap; runs on the ticker).
function HUD:UpdateLive()
    if not built or not frame:IsShown() then return end
    local stop = ns.Route:IsGuiding() and ns.Route:Next()
    if not stop then return end

    local d = ns.Route:DistanceTo(stop)
    local where = ns:MapName(stop.uiMapID)
    stopWhere:SetText(d and (where .. "  ·  " .. ns:FormatDistance(d)) or where)

    local angle = HUD.RelativeAngle(stop)
    if angle then
        arrow:SetRotation(angle)
        arrow:SetVertexColor(1, 1, 1, 1)
        arrow:Show()
    else
        -- Different map: no reliable direction, so show it faded and upright.
        arrow:SetRotation(0)
        arrow:SetVertexColor(0.5, 0.5, 0.5, 0.5)
    end

    for _, row in ipairs(upcomingRows) do
        if row:IsShown() and row.stop then
            local ud = ns.Route:DistanceTo(row.stop)
            row.dist:SetText(ud and ns:FormatDistance(ud) or "")
        end
    end
end

local function objectiveTexts(stop)
    if stop.kind == "turnin" then
        return { Widgets.Colorize("Hand in" .. (stop.npcName and (" to " .. stop.npcName) or " this quest"), ns.Colors.turnin) }
    end
    local out = {}
    for _, o in ipairs(ns.QuestData:PendingObjectives(stop.questID)) do
        local text = o.text or ""
        if not text:find("%d+/%d+") and (o.numRequired or 0) > 1 then
            text = string.format("%s: %d/%d", text, o.numFulfilled or 0, o.numRequired)
        end
        table.insert(out, "- " .. text)
    end
    if #out == 0 then table.insert(out, "- In progress") end
    return out
end

function HUD:Refresh()
    if not built then return end
    if not self:ShouldShow() then
        frame:Hide()
        self:UpdateItems()
        return
    end

    local s = S()
    frame:SetScale(math.max(0.5, math.min(2, ns.SafeNum(s.hudScale) or 1)))
    local state = ns.Route:Get()
    local stops = state.stops or {}
    local cur = math.min(state.current or 1, #stops)
    local guiding = state.guiding and true or false

    countText:SetText(string.format("%d/%d", cur, #stops))
    titleText:SetText(guiding and "ROUTE" or "ROUTE  " .. Widgets.Colorize("(paused)", ns.Colors.dim))
    if guiding then skipButton:Show(); stopButton:Show() else skipButton:Hide(); stopButton:Hide() end
    collapseButton.text:SetText(s.hudCollapsed and "+" or "-")

    local height = 20
    if s.hudCollapsed then
        body:Hide()
    else
        body:Show()
        local y = 4
        if guiding then
            startButton:Hide()
            currentBlock:Show()
            local stop = stops[cur]
            local c = stop.kind == "turnin" and ns.Colors.turnin or ns.Colors.quest
            stopTitle:SetText(stop.title or ("Quest " .. tostring(stop.questID)))
            stopTitle:SetTextColor(c.r, c.g, c.b)
            local texts = objectiveTexts(stop)
            for i, fs in ipairs(objectiveLines) do
                if texts[i] then fs:SetText(texts[i]); fs:Show() else fs:Hide() end
            end
            local lines = math.min(#texts, MAX_OBJECTIVE_LINES)
            local blockH = 30 + lines * 13
            currentBlock:SetHeight(blockH)
            y = y + blockH + 4
        else
            currentBlock:Hide()
            startButton:Show()
            y = y + 28
        end

        -- Upcoming stops (after the current one; all of them when paused).
        local want = math.max(0, math.min(MAX_UPCOMING, ns.SafeNum(s.hudUpcoming) or 3))
        local first = guiding and cur + 1 or cur
        local shown = 0
        for i, row in ipairs(upcomingRows) do
            local idx = first + i - 1
            local st = stops[idx]
            if i <= want and st then
                row.index, row.stop = idx, st
                local kind = st.kind == "turnin" and ("  ·  " .. Widgets.Colorize("Hand in", ns.Colors.turnin)) or ""
                row.text:SetText(string.format("%d. %s%s", idx, st.title or "?", kind))
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
                row:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -y)
                row:Show()
                y = y + 16
                shown = shown + 1
            else
                row.index, row.stop = nil, nil
                row:Hide()
            end
        end
        y = y + 4
        body:SetHeight(y)
        height = height + y
    end

    frame:SetHeight(height)
    frame:Show()
    self:UpdateLive()
    self:UpdateItems()
end

function HUD:GetFrame() return frame end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function HUD:Initialize()
    if not built then build() end
end

function HUD:OnLogin()
    HUD:Refresh()
end

local function onChanged()
    ns:Debounce("hud", 0.1, function() HUD:Refresh() end)
end
ns:RegisterEvent("route_changed", onChanged, HUD)
ns:RegisterEvent("BAG_UPDATE", onChanged, HUD)
ns:RegisterEvent("BAG_UPDATE_COOLDOWN", function() updateItemCooldowns() end, HUD)
ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    if itemsPending then HUD:UpdateItems() end
end, HUD)
ns:RegisterEvent("QUEST_LOG_UPDATE", onChanged, HUD)
ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", onChanged, HUD)

ns:RegisterModule("HUD", HUD)

return HUD
