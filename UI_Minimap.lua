--[[---------------------------------------------------------------------------
    Solaryn's Expedition — minimap button.

    Built the same way LibDBIcon builds the buttons most addons use, so it looks
    at home next to them: a 31px button whose icon sits inside the gold
    MiniMap-TrackingBorder ring, on a dark round backing.

    The button is locked to the minimap's edge. Its position is stored as a
    single angle (settings.minimapPos, in degrees), and dragging recomputes
    that angle from the cursor on every frame. The button therefore slides
    around the ring and can never be dropped anywhere else.

      Left-click    toggle the panel
      Right-click   toggle the options window
      Drag          slide the button around the minimap
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.MinimapButton = {}

local MinimapButton = ns.MinimapButton

local ICON = "Interface\\Icons\\INV_Misc_Map_01"

-- How far outside the minimap's edge the button's centre sits. LibDBIcon
-- uses 5 for round minimaps; matching it lines us up with other addons.
local RING_OFFSET = 5

local button

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------
--- Distance from the minimap centre to the button centre.
local function ringRadius()
    local size = 140
    local mm = _G.Minimap
    if mm and mm.GetWidth then
        local w = mm:GetWidth()
        if type(w) == "number" and w > 0 then size = w end
    end
    return size / 2 + RING_OFFSET
end

local function normaliseAngle(a)
    a = tonumber(a) or 225
    a = a % 360
    if a < 0 then a = a + 360 end
    return a
end

local function positionButton()
    if not button then return end
    local mm = _G.Minimap
    local angle = math.rad(normaliseAngle(ns.Settings().minimapPos))
    local r = ringRadius()
    button:ClearAllPoints()
    if mm then
        button:SetPoint("CENTER", mm, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
    else
        button:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

--- Angle, in degrees, from the minimap centre to the cursor.
local function cursorAngle()
    local mm = _G.Minimap
    if not mm or type(GetCursorPosition) ~= "function" then return nil end
    local mx, my = mm:GetCenter()
    if not mx or not my then return nil end
    local px, py = GetCursorPosition()
    local scale = mm:GetEffectiveScale() or 1
    px, py = px / scale, py / scale
    return normaliseAngle(math.deg(math.atan2(py - my, px - mx)))
end

local function onDragUpdate()
    local a = cursorAngle()
    if a then
        ns.Settings().minimapPos = a
        positionButton()
    end
end

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------
local function showTooltip(self)
    if self.isDragging then return end
    local c = ns.Colors.accent
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Solaryn's Expedition", c.r, c.g, c.b)

    local top = (ns.Suggest.last or {})[1]
    if top then
        GameTooltip:AddDoubleLine("Next:", ns:Truncate(top.title or "?", 32), 0.7, 0.7, 0.7, 1, 1, 1)
    else
        GameTooltip:AddDoubleLine("Next:", "nothing suggested", 0.7, 0.7, 0.7, 0.6, 0.6, 0.6)
    end

    local mapID = ns:PlayerMapID()
    local cov = mapID and ns.Explored:Coverage(mapID)
    if cov then
        GameTooltip:AddDoubleLine("Explored here:", ns:FormatPct(cov), 0.7, 0.7, 0.7, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Route stops:", tostring(ns.Route:Count()), 0.7, 0.7, 0.7, 1, 1, 1)

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffffd100Left-click|r  open or close the panel", 0.85, 0.85, 0.85)
    GameTooltip:AddLine("|cffffd100Right-click|r  options", 0.85, 0.85, 0.85)
    GameTooltip:AddLine("|cffffd100Drag|r  move around the minimap", 0.85, 0.85, 0.85)
    GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------
local function buildButton()
    local parent = _G.Minimap or UIParent
    button = CreateFrame("Button", "SolarynExpeditionMinimapButton", parent)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Dark round backing behind the icon.
    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)

    -- The icon, cropped so its square edges hide under the ring.
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -6)
    button.icon = icon

    -- The gold ring. The texture is 53px with the ring in its top-left
    -- portion, which is why it is anchored TOPLEFT rather than centred.
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")
    button.border = border

    ------------------------------------------------------------------
    -- Interactions
    ------------------------------------------------------------------
    -- Nudge the icon down-right while pressed, the usual "button pushed" cue.
    button:SetScript("OnMouseDown", function()
        icon:SetPoint("TOPLEFT", 8, -7)
    end)
    button:SetScript("OnMouseUp", function()
        icon:SetPoint("TOPLEFT", 7, -6)
    end)

    button:SetScript("OnClick", function(_, which)
        if which == "RightButton" then
            if ns.Panel.ToggleOptions then ns.Panel:ToggleOptions() end
        else
            ns.Panel:Toggle()
        end
    end)

    -- Drag follows the cursor's angle around the minimap centre every frame,
    -- so the button stays on the ring for the whole drag. StartMoving() is
    -- deliberately not used: it lets the button go anywhere on screen.
    button:SetScript("OnDragStart", function(self)
        self.isDragging = true
        self:LockHighlight()
        icon:SetPoint("TOPLEFT", 8, -7)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", onDragUpdate)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self.isDragging = false
        self:UnlockHighlight()
        icon:SetPoint("TOPLEFT", 7, -6)
        positionButton()
    end)

    button:SetScript("OnEnter", showTooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    positionButton()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
--- Cycle Next -> Route -> Zones and make sure the panel is open.
function MinimapButton:CycleTab()
    local order = { "next", "route", "zones" }
    local cur = nil
    for i, key in ipairs(order) do
        if ns.Panel:CurrentTab() == key then cur = i end
    end
    local nextIdx = ((cur or 1) % #order) + 1
    ns.Panel:SetTab(order[nextIdx])
    ns.Panel:Toggle(true)
end

function MinimapButton:Update()
    if not button then return end
    if ns.Settings().minimapButton then
        button:Show()
    else
        button:Hide()
    end
    positionButton()
end

--- Place the button at an angle in degrees (0 = east, 90 = north).
function MinimapButton:SetAngle(deg)
    ns.Settings().minimapPos = normaliseAngle(deg)
    positionButton()
end

--- Apply one drag step at the current cursor position (tests/diagnostics).
function MinimapButton:DragStep() onDragUpdate() end

--- Radius currently used for the button's ring position (tests/diagnostics).
function MinimapButton:GetRingRadius() return ringRadius() end

function MinimapButton:GetButton() return button end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function MinimapButton:Initialize()
    buildButton()
    -- Minimap-resizing addons change its size without any client event, so
    -- follow the frame itself.
    local mm = _G.Minimap
    if mm and type(mm.HookScript) == "function" then
        mm:HookScript("OnSizeChanged", function() positionButton() end)
    end
end

function MinimapButton:OnLogin()
    MinimapButton:Update()
end

--- Re-anchor when the minimap resizes or the UI scale changes.
local function onDisplaySizeChanged()
    if button then positionButton() end
end

ns:RegisterEvent("UI_SCALE_CHANGED", onDisplaySizeChanged, MinimapButton)
ns:RegisterEvent("DISPLAY_SIZE_CHANGED", onDisplaySizeChanged, MinimapButton)

ns:RegisterModule("MinimapButton", MinimapButton)

return MinimapButton
