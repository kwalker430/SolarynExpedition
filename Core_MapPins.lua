--[[---------------------------------------------------------------------------
    Solaryn's Expedition — map pin + waypoint control.

    Wraps the client map APIs so the panel can draw the whole route as pins on
    the world map and the minimap, and clear them without touching the client's
    own quest tracker icons.

    Every call here is capability-gated: if this build lacks the API, we report
    it once rather than erroring on each click.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.MapPins = {}

local MapPins = ns.MapPins

local waypointOwnedByUs = false

---------------------------------------------------------------------------
-- World map pins
---------------------------------------------------------------------------
-- Blizzard's map canvas (Blizzard_MapCanvas) draws pins through "data
-- providers": objects built from MapCanvasDataProviderMixin that the map calls
-- back (OnAdded, RefreshAllData, OnMapChanged, ...). A provider asks the map
-- for pins by template name with AcquirePin, and the template must be a real
-- frame template, which is why SolarynExpedition.xml exists.
--
-- The provider is added to the map once and then only refreshed. Pins show
-- the route on whichever map is displayed, whether or not the panel is open.
local PIN_TEMPLATE = "SolarynExpeditionRoutePinTemplate"

local provider              -- our data provider, once added to the map
local pinsHidden = false    -- ClearRoute() hides pins until the next DrawRoute()

--- True when this client has the map canvas pieces pins need.
local function canDrawPins()
    return type(_G.MapCanvasDataProviderMixin) == "table"
        and type(_G.MapCanvasPinMixin) == "table"
        and type(_G.CreateFromMixins) == "function"
        and _G.WorldMapFrame ~= nil
        and type(_G.WorldMapFrame.AddDataProvider) == "function"
end

--- Route stops that belong on `mapID`, with their route position.
local function stopsForMap(mapID)
    local out = {}
    if pinsHidden or not ns.Settings().mapPins or not mapID then return out end
    for i, stop in ipairs(ns.Route:Get().stops or {}) do
        if stop.uiMapID == mapID and stop.x and stop.y then
            table.insert(out, { stop = stop, index = i })
        end
    end
    return out
end

--- Build the provider (once). Its methods are what the map canvas calls.
local function buildProvider()
    local p = _G.CreateFromMixins(_G.MapCanvasDataProviderMixin)

    function p:RemoveAllData()
        local map = self:GetMap()
        if map then map:RemoveAllPinsByTemplate(PIN_TEMPLATE) end
    end

    function p:RefreshAllData()
        self:RemoveAllData()
        local map = self:GetMap()
        if not map then return end
        for _, entry in ipairs(stopsForMap(map:GetMapID())) do
            map:AcquirePin(PIN_TEMPLATE, entry.stop, entry.index)
        end
    end

    function p:OnMapChanged()
        self:RefreshAllData()
    end

    return p
end

--- Add the provider to the world map, if this client supports it.
local function ensureProvider()
    if provider then return provider end
    if not canDrawPins() then return nil end
    local p = buildProvider()
    local ok, err = pcall(_G.WorldMapFrame.AddDataProvider, _G.WorldMapFrame, p)
    if not ok then
        ns:Debug("map pins unavailable: %s", tostring(err))
        return nil
    end
    provider = p
    return provider
end

--- Show the current route as numbered pins on the world map. Returns true
--- if the map can show pins.
function MapPins:DrawRoute()
    pinsHidden = false
    local p = ensureProvider()
    if not p then return false end
    local ok, err = pcall(p.RefreshAllData, p)
    if not ok then ns:Debug("pin refresh failed: %s", tostring(err)) end
    return ok
end

--- Remove our pins, leaving the client's own pins untouched.
function MapPins:ClearRoute()
    pinsHidden = true
    if provider then pcall(provider.RemoveAllData, provider) end
end

function MapPins:GetProvider() return provider end

---------------------------------------------------------------------------
-- Pin mixin
---------------------------------------------------------------------------
-- Applied to each pin frame by SolarynExpeditionRoutePin_OnLoad below.
local function pinColor(stop)
    return stop.kind == "turnin" and ns.Colors.turnin or ns.Colors.quest
end

local PinMixin = {}

function PinMixin:OnLoad()
    self:SetSize(20, 20)
    -- Keep pins readable at every zoom, like Blizzard's quest markers.
    if self.SetScalingLimits then pcall(self.SetScalingLimits, self, 1, 1.0, 1.2) end
    if self.UseFrameLevelType then pcall(self.UseFrameLevelType, self, "PIN_FRAME_LEVEL_AREA_POI") end

    local ring = self:CreateTexture(nil, "BACKGROUND")
    ring:SetPoint("CENTER")
    ring:SetSize(20, 20)
    ring:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    ring:SetVertexColor(0, 0, 0, 0.85)
    self.ring = ring

    local disc = self:CreateTexture(nil, "ARTWORK")
    disc:SetPoint("CENTER")
    disc:SetSize(16, 16)
    disc:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    self.disc = disc

    local num = self:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    num:SetPoint("CENTER", 0, 0)
    self.num = num

    local hl = self:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("CENTER")
    hl:SetSize(22, 22)
    hl:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    hl:SetVertexColor(1, 1, 1, 0.25)
end

function PinMixin:OnAcquired(stop, index)
    self.stop, self.index = stop, index
    local c = pinColor(stop)
    self.disc:SetVertexColor(c.r, c.g, c.b, 1)
    self.num:SetText(tostring(index))
    -- Stops already passed on the guide fade back.
    self:SetAlpha(index < ns.Route:CurrentIndex() and 0.4 or 1)
    self:SetPosition(stop.x, stop.y)
end

function PinMixin:OnReleased()
    self.stop, self.index = nil, nil
end

function PinMixin:OnMouseEnter()
    local stop = self.stop
    if not stop then return end
    local c = pinColor(stop)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(string.format("%d. %s", self.index or 0, stop.title or "?"), c.r, c.g, c.b)
    GameTooltip:AddLine(stop.kind == "turnin" and "Hand in" or "Objective", 0.85, 0.85, 0.85)
    GameTooltip:AddLine("Click to set a waypoint", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

function PinMixin:OnMouseLeave()
    GameTooltip:Hide()
end

function PinMixin:OnClick(button)
    if button == "LeftButton" and self.stop then
        ns.Route:GoToStop(self.stop)
    end
end

--- OnLoad for the XML template (a global, since XML names it). Pins are
-- created when the map first shows them, by which point Blizzard_MapCanvas
-- has certainly loaded, so MapCanvasPinMixin can be mixed in here. (The XML
-- mixin= attribute would need both mixins to exist when this file loads.)
function _G.SolarynExpeditionRoutePin_OnLoad(self)
    if type(_G.MapCanvasPinMixin) == "table" then
        for k, v in pairs(_G.MapCanvasPinMixin) do self[k] = v end
    end
    for k, v in pairs(PinMixin) do self[k] = v end
    -- Mouse events: only enable them. The map canvas owns a pin's
    -- OnEnter/OnLeave/OnMouseUp scripts and calls our OnMouseEnter,
    -- OnMouseLeave and OnClick methods; it asserts (Blizzard_MapCanvas)
    -- if a pin sets those scripts itself.
    self:EnableMouse(true)
    self:OnLoad()
end
MapPins.PinMixin = PinMixin

-- Keep pins in step with the route and the setting.
ns:RegisterEvent("route_changed", function()
    if provider then pcall(provider.RefreshAllData, provider) end
end, MapPins)

---------------------------------------------------------------------------
-- Waypoint
---------------------------------------------------------------------------
--- Set the client's single user waypoint, remembering that we set it so
--- /sol clear knows whether it is safe to remove.
function MapPins:SetWaypoint(uiMapID, x, y)
    if not ns.Has.setUserWaypoint then
        ns:Print("This build's map API has no SetUserWaypoint.")
        return false
    end
    -- Prefer the client's own point constructor; the plain-table shape is
    -- the fallback for builds without UiMapPoint.
    local point
    if ns.Has.uiMapPoint then
        point = ns.Try("UiMapPoint", "CreateFromCoordinates", uiMapID, x, y)
    end
    point = point or { uiMapID = uiMapID, position = { x = x, y = y } }
    local ok = ns.Try("C_Map", "SetUserWaypoint", point)
    -- SetUserWaypoint returns nothing on success in most builds.
    if ok == nil then ok = true end
    if ok then
        waypointOwnedByUs = true
        if ns.Has.clearUserWaypoint and ns.Settings().clearWaypointOnArrive then
            -- Attach a one-shot arrival watcher on the main thread; the client
            -- fires WAYPOINT_UPDATE when the player gets close.
            ns:Fire("waypoint_set", uiMapID, x, y)
        end
    end
    return ok and true or false
end

--- Clear the waypoint, but only if we were the one who set it.
function MapPins:ClearWaypoint()
    if not waypointOwnedByUs then return false end
    if not ns.Has.clearUserWaypoint then return false end
    ns.Try("C_Map", "ClearUserWaypoint")
    waypointOwnedByUs = false
    return true
end

---------------------------------------------------------------------------
-- Map navigation
---------------------------------------------------------------------------
--- Open the world map on a map ID. (The map has no "centre on a point" call,
--- so x/y are accepted for callers' convenience but only the map is chosen;
--- our pin marks the spot.)
function MapPins:OpenAt(uiMapID, x, y)
    local wmf = _G.WorldMapFrame
    if not wmf then return false end
    if type(_G.OpenWorldMap) == "function" then
        local ok = pcall(_G.OpenWorldMap, uiMapID)
        if ok then return true end
    end
    if not wmf:IsShown() then
        if type(_G.ShowUIPanel) == "function" then
            pcall(_G.ShowUIPanel, wmf)
        else
            pcall(wmf.Show, wmf)
        end
    end
    if uiMapID and type(wmf.SetMapID) == "function" then
        pcall(wmf.SetMapID, wmf, uiMapID)
    end
    return true
end

--- Open the map on the player's current map.
function MapPins:CenterOnPlayer()
    local mapID = ns:PlayerMapID()
    if not mapID then return false end
    return self:OpenAt(mapID)
end

---------------------------------------------------------------------------
-- Event glue
---------------------------------------------------------------------------
local function onMapOpened()
    -- The provider refreshes itself on map changes; opening the map only has
    -- to make sure it has been added.
    if ns.Settings().mapPins and ensureProvider() then
        pcall(provider.RefreshAllData, provider)
    end
end

-- There is no "world map opened" event; hook the frame's OnShow instead.
-- WorldMapFrame can be created after us, so retry at login and whenever
-- another addon (Blizzard_WorldMap) finishes loading.
local mapHooked = false
local function hookWorldMap()
    if mapHooked then return end
    local wmf = _G.WorldMapFrame
    if wmf and type(wmf.HookScript) == "function" then
        wmf:HookScript("OnShow", onMapOpened)
        mapHooked = true
    end
end
MapPins.HookWorldMap = hookWorldMap

hookWorldMap()
ns:RegisterEvent("PLAYER_LOGIN", hookWorldMap, MapPins)
ns:RegisterEvent("ADDON_LOADED", hookWorldMap, MapPins)

return MapPins