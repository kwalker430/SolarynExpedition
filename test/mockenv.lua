--[[---------------------------------------------------------------------------
    Shared mock WoW environment for offline testing.

    Implements the specific functions Solaryn's Expedition calls, plus a small but
    realistic world: three outdoor zones laid out on a continent grid, one
    dungeon, and a five-quest log with a mix of in-progress, ready-to-hand-in,
    and task quests.

    Geometry is exact rather than approximated: each zone is a 1000-unit square
    at a known world offset and map coordinates map linearly onto it, so
    distance assertions in the tests check real numbers.
-----------------------------------------------------------------------------]]

local M = {}

---------------------------------------------------------------------------
-- Enum (must exist before anything references Enum.MapType)
---------------------------------------------------------------------------
Enum = Enum or {
    -- Enum.UIMapType — the enum the client's map APIs actually return.
    UIMapType = { Cosmic = 0, World = 1, Continent = 2, Zone = 3, Dungeon = 4, Micro = 5, Orphan = 6 },
}

---------------------------------------------------------------------------
-- Zones and player state
---------------------------------------------------------------------------
-- Two continents, laid out like the real ones: Eastern Kingdoms (100) with
-- zones of rising level, and Kalimdor (101) with Durotar. Zone names match
-- Classic's, so the built-in level table applies to them.
local ZONES = {
    [1]  = { name = "Elwynn Forest",      worldX = 0,    worldY = 0,    size = 1000, continent = 100 },
    [2]  = { name = "Westfall",           worldX = 2000, worldY = 0,    size = 1000, continent = 100 },
    [3]  = { name = "Redridge Mountains", worldX = 0,    worldY = 2000, size = 1000, continent = 100 },
    [5]  = { name = "Duskwood",           worldX = 2000, worldY = 2000, size = 1000, continent = 100 },
    [6]  = { name = "Stranglethorn Vale", worldX = 0,    worldY = 6000, size = 1000, continent = 100 },
    [4]  = { name = "Durotar",            worldX = 0,    worldY = 0,    size = 1000, continent = 101 },
    [84] = { name = "Dungeon Test",       worldX = 0,    worldY = 0,    size = 500, mapType = 4, continent = 100 },
    -- The continent map itself, covering all of its zones.
    [100] = { name = "Eastern Kingdoms",  worldX = 0,    worldY = 0,    size = 8000, continent = 100 },
}
M.ZONES = ZONES

M.playerState = {
    mapID = 1,
    -- Map coordinates are fractions (0-1), exactly as the client returns them.
    mapX = 0.5,
    mapY = 0.5,
    level = 10,
    waypoint = nil,
}

local function zoneOf(mapID) return ZONES[mapID] or ZONES[1] end
M.zoneOf = zoneOf

function M.mapToWorld(mapID, x, y)
    local z = zoneOf(mapID)
    return z.worldX + x * z.size, z.worldY + y * z.size
end

---------------------------------------------------------------------------
-- Widget mock
---------------------------------------------------------------------------
-- Client events the addon may register. Anything else errors on
-- RegisterEvent, exactly as the real client does.
M.KNOWN_EVENTS = {}
for _, e in ipairs({
    "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LOGOUT", "PLAYER_ENTERING_WORLD",
    "PLAYER_LEVEL_UP", "QUEST_ACCEPTED", "QUEST_LOG_UPDATE", "QUEST_TURNED_IN",
    "QUEST_REMOVED", "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED_INDOORS",
    "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED", "USER_WAYPOINT_UPDATED",
    "SUPER_TRACKING_CHANGED", "BAG_UPDATE", "BAG_UPDATE_COOLDOWN",
    "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "UPDATE_MOUSEOVER_UNIT",
    "CRITERIA_UPDATE", "ACHIEVEMENT_EARNED",
    "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE",
}) do M.KNOWN_EVENTS[e] = true end

local function makeWidget(kind)
    local w = { __kind = kind, shown = true, children = {}, scripts = {}, points = {}, events = {} }

    local function ret() return w end
    function w:GetObjectType() return kind end
    function w:GetName() return self and self.__name or nil end
    function w:SetSize(a, b) w.width, w.height = a, b; return w end
    function w:SetWidth(a) w.width = a; return w end
    function w:SetHeight(a) w.height = a; return w end
    function w:GetWidth() return w.width or 0 end
    function w:GetHeight() return w.height or 0 end
    -- Secure (protected) frames refuse layout/visibility/attribute changes in
    -- combat, exactly like the client ("ADDON_ACTION_BLOCKED").
    local function guard(what)
        if M.inCombat and type(w.__template) == "string" and w.__template:find("Secure") then
            error("ADDON_ACTION_BLOCKED: " .. what .. " on a protected frame in combat", 3)
        end
    end
    function w:SetPoint(...) guard("SetPoint"); w.points[#w.points + 1] = { ... }; return w end
    function w:ClearAllPoints() guard("ClearAllPoints"); w.points = {}; return w end
    function w:SetAttribute(k, v) guard("SetAttribute"); w.attributes = w.attributes or {}; w.attributes[k] = v end
    function w:GetAttribute(k) return w.attributes and w.attributes[k] end
    function w:GetLeft() return w.left or 900 end
    function w:GetTop() return w.top or 500 end
    function w:SetCooldown(start, duration) w.cooldownStart, w.cooldownDuration = start, duration end
    function w:GetPoint() return "CENTER", UIParent, "CENTER", 0, 0 end
    function w:SetScale(v) w.scale = v; return w end
    function w:SetAlpha(v) w.alpha = v; return w end
    -- Colour/texture fills exist only on Textures in the real client. Calling
    -- them on a Frame raises "attempt to call method 'SetColorTexture' (a nil
    -- value)" in game, so the mock refuses too instead of hiding the bug.
    function w:SetColorTexture(...)
        if kind ~= "Texture" then error("SetColorTexture called on a " .. kind, 2) end
        w.color = { ... }; return w
    end
    function w:SetTexture(t)
        if kind ~= "Texture" then error("SetTexture called on a " .. kind, 2) end
        w.texture = t; return w
    end
    function w:SetVertexColor(...) w.vertex = { ... }; return w end
    function w:SetRotation(r)
        if kind ~= "Texture" then error("SetRotation called on a " .. kind, 2) end
        w.rotation = r; return w
    end
    function w:SetDrawLayer() return w end
    function w:SetBlendMode() return w end
    function w:SetWordWrap(v) w.wordWrap = v; return w end
    function w:SetMultiLine(v) w.multiLine = v end
    function w:SetAutoFocus(v) w.autoFocus = v end
    function w:HighlightText() w.highlighted = true end
    function w:SetFocus() w.focused = true end
    function w:ClearFocus() w.focused = false end
    function w:SetMaxLines() return w end
    function w:SetFontObject() return w end
    function w:GetStringWidth() return #(w.text or "") * 6 end
    function w:SetHighlightTexture(t) w.highlight = t; return w end
    function w:LockHighlight() w.highlightLocked = true end
    function w:UnlockHighlight() w.highlightLocked = false end
    function w:Enable() w.enabled = true end
    function w:Disable() w.enabled = false end
    function w:IsEnabled() return w.enabled ~= false end
    function w:SetShown(v) w.shown = v and true or false end
    function w:SetToplevel() return w end
    function w:GetFrameLevel() return w.frameLevel or 1 end
    function w:GetEffectiveScale() return 1 end
    function w:GetCenter() return w.centerX, w.centerY end
    function w:SetResizeBounds() return w end
    function w:StartSizing() w.sizing = true end
    function w:SetVerticalScroll(v) w.vscroll = v end
    function w:UpdateScrollChildRect() end
    function w:SetTexCoord() return w end
    function w:SetAllPoints() return w end
    function w:SetClampedToScreen() return w end
    function w:SetMovable() return w end
    function w:EnableMouse(v) w.mouse = v and true or false; return w end
    function w:IsMouseClickEnabled() return w.mouse == true end
    function w:IsMouseMotionEnabled() return w.mouse == true end
    function w:RegisterForDrag() return w end
    function w:RegisterForClicks(...) w.clicks = { ... }; return w end
    function w:EnableMouseMove() return w end
    function w:SetFrameStrata() return w end
    function w:SetFrameLevel(v) w.frameLevel = v; return w end
    function w:SetBackdrop() return w end
    function w:SetBackdropColor() return w end
    function w:SetBackdropBorderColor() return w end
    function w:SetResizable() return w end
    function w:SetMinResize() return w end
    function w:SetScript(k, fn) w.scripts[k] = fn; return w end
    function w:GetScript(k) return w.scripts[k] end
    function w:HookScript(k, fn) w.scripts[k] = fn; return w end
    function w:StartMoving() w.moving = true end
    function w:StopMovingOrSizing() w.moving = false end
    function w:Show() guard("Show"); w.shown = true; return w end
    function w:Hide() guard("Hide"); w.shown = false; return w end
    function w:IsShown() return w.shown end
    function w:IsVisible() return w.shown end
    function w:SetParent(p) w.parent = p; return w end
    function w:GetParent() return w.parent end
    function w:CreateTexture() local t = makeWidget("Texture"); w.children[#w.children + 1] = t; return t end
    function w:CreateFontString() local t = makeWidget("FontString"); w.children[#w.children + 1] = t; return t end
    function w:GetChildren() return w.children end
    function w:SetText(t) w.text = t; return w end
    function w:GetText() return w.text end
    function w:SetJustifyH() return w end
    function w:SetJustifyV() return w end
    function w:SetTextColor() return w end
    function w:SetMinMaxValues() return w end
    function w:SetValueStep() return w end
    function w:SetValue(v) w.value = v; return w end
    function w:GetValue() return w.value or 0 end
    function w:SetObeyStepOnDrag() return w end
    function w:SetThumbTexture(t) w.thumb = t; return w end
    function w:SetChecked(v) w.checked = v; return w end
    function w:GetChecked() return w.checked end
    function w:SetStatusBarTexture() return w end
    function w:SetStatusBarColor() return w end
    function w:SetScrollChild(c) w.child = c; return w end
    function w:GetScrollChild() return w.child end
    function w:RegisterEvent(e)
        -- The client rejects names it doesn't know; so does the mock.
        if not M.KNOWN_EVENTS[e] then
            error('Attempt to register unknown event "' .. tostring(e) .. '"', 2)
        end
        w.events[e] = true; return w
    end
    function w:UnregisterEvent(e) w.events[e] = nil; return w end
    function w:UnregisterAllEvents() w.events = {}; return w end
    function w:IsEventRegistered(e) return w.events[e] or false end
    function w:Click(btn) if w.scripts.OnClick then w.scripts.OnClick(w, btn or "LeftButton") end end
    function w:Raise() return w end
    function w:Lower() return w end
    function w:SetHitRectInsets() return w end
    return w
end

M.makeWidget = makeWidget

---------------------------------------------------------------------------
-- Install globals
---------------------------------------------------------------------------
function M.install()
    -- Template-provided named regions. The real client creates these for the
    -- named templates; addons index them directly (slider.low / slider.high,
    -- btn.leftTexture, etc), so the mock must provide them too.
    local function templateRegions(f, template)
        if type(template) ~= "string" then return end
        if template:find("OptionsSliderTemplate") then
            f.low = makeWidget("FontString")
            f.high = makeWidget("FontString")
            f.text = makeWidget("FontString")
        end
        if template:find("UIPanelScrollFrameTemplate") then
            f.ScrollBar = makeWidget("Slider")
        end
        if template:find("BasicFrameTemplateWithInset") then
            f.bgTopLeft = makeWidget("Texture")
        end
        if template:find("CheckButton") then
            f.bg = makeWidget("Texture")
        end
    end

    CreateFrame = function(kind, name, parent, template)
        local f = makeWidget(kind or "Frame")
        f.__name = name
        f.__template = template
        templateRegions(f, template)
        if parent then
            f:SetParent(parent)
            -- Register with the parent so GetChildren() reflects reality,
            -- matching how the real client tracks region parenting.
            if type(parent.children) == "table" then
                parent.children[#parent.children + 1] = f
            end
        end
        return f
    end
    UIParent = makeWidget("Frame")

    function GetBuildInfo() return "1.60.1", "69913", "Sep 2026", "16001", false end
    -- Units: "player" is the test character; tests put mobs in M.UNITS.
    M.UNITS = {}
    function UnitName(unit)
        if unit == "npc" and M.npc then return M.npc.name end
        return M.UNITS[unit] or "Testchar"
    end
    function UnitIsPlayer(unit) return M.UNITS[unit] == nil end
    function UnitExists(unit) return unit == "player" or M.UNITS[unit] ~= nil end

    -- Combat lockdown, bags and items.
    M.inCombat = false
    function InCombatLockdown() return M.inCombat end
    M.cvars = { ActionButtonUseKeyDown = false }
    function GetCVarBool(name) return M.cvars[name] and true or false end
    function GetBindingKey() return nil end
    NUM_BAG_SLOTS = 4
    -- M.ITEMS[itemID] = { name, usable = bool, questItem = bool, questID = n }
    -- M.BAGS[bag][slot] = itemID
    M.ITEMS, M.BAGS = {}, {}
    C_Container = {
        GetContainerNumSlots = function(bag) return M.BAGS[bag] and 16 or 0 end,
        GetContainerItemID = function(bag, slot) return M.BAGS[bag] and M.BAGS[bag][slot] end,
        GetContainerItemQuestInfo = function(bag, slot)
            local it = M.BAGS[bag] and M.ITEMS[M.BAGS[bag][slot]]
            return { isQuestItem = it and it.questItem or false, questID = it and it.questID, isActive = false }
        end,
        GetItemCooldown = function() return 0, 0, 1 end,
    }
    C_Item = {
        GetItemSpell = function(id) local it = M.ITEMS[id]; return it and it.usable and "Use" or nil end,
        GetItemNameByID = function(id) return M.ITEMS[id] and M.ITEMS[id].name end,
        GetItemIconByID = function() return 134400 end,
        GetItemCount = function(id)
            local n = 0
            for _, slots in pairs(M.BAGS) do for _, v in pairs(slots) do if v == id then n = n + 1 end end end
            return n
        end,
    }
    -- Achievements. M.ACHIEVEMENTS[id] = { name, cat, earned, criteria = {
    -- { "Area name", found }, ... } }. Empty by default; tests fill it in.
    M.ACHIEVEMENTS = {}
    local function achInCat(cat)
        local ids = {}
        for id, a in pairs(M.ACHIEVEMENTS) do if a.cat == cat then ids[#ids + 1] = id end end
        table.sort(ids)
        return ids
    end
    local function achInfo(id)
        local a = M.ACHIEVEMENTS[id]
        if not a then return nil end
        -- id, name, points, completed, month, day, year, description, flags,
        -- icon, rewardText, isGuild, wasEarnedByMe
        return id, a.name, 10, a.earned or false, nil, nil, nil, "", 0, 0, "", false, a.earned or false
    end
    function GetCategoryList()
        local cats, seen = {}, {}
        for _, a in pairs(M.ACHIEVEMENTS) do
            if a.cat and not seen[a.cat] then seen[a.cat] = true; cats[#cats + 1] = a.cat end
        end
        return cats
    end
    function GetCategoryNumAchievements(cat) return #achInCat(cat) end
    function GetAchievementInfo(catOrID, index)
        if index then return achInfo(achInCat(catOrID)[index]) end
        return achInfo(catOrID)
    end
    function GetAchievementNumCriteria(id) return #((M.ACHIEVEMENTS[id] or {}).criteria or {}) end
    function GetAchievementCriteriaInfo(id, i)
        local c = M.ACHIEVEMENTS[id] and M.ACHIEVEMENTS[id].criteria[i]
        if c then return c[1], 0, c[2] and true or false, c[2] and 1 or 0, 1 end
    end

    -- Talking to NPCs. M.npc = { id, name, kind } is who the "npc" unit is;
    -- M.GUIDS[unit] = guid for any other unit (e.g. "mouseover").
    -- M.GOSSIP = { available = { {title, questLevel, questID, isTrivial, repeatable}, ... },
    --              active = { {title, questID}, ... } }
    -- M.questFrame = { questID, title } for QUEST_DETAIL / PROGRESS / COMPLETE.
    M.GUIDS, M.GOSSIP = {}, { available = {}, active = {} }
    function M.guidFor(id, kind)
        return string.format("%s-0-1465-0-2105-%d-000043F59F", kind or "Creature", id)
    end
    function UnitGUID(unit)
        if unit == "npc" and M.npc then return M.guidFor(M.npc.id, M.npc.kind) end
        return M.GUIDS[unit]
    end
    C_GossipInfo = {
        GetAvailableQuests = function() return M.GOSSIP.available end,
        GetActiveQuests = function() return M.GOSSIP.active end,
    }
    function GetNumAvailableQuests() return #M.GOSSIP.available end
    function GetAvailableTitle(i) return M.GOSSIP.available[i].title end
    function GetAvailableLevel(i) return M.GOSSIP.available[i].questLevel end
    function GetAvailableQuestInfo(i)
        local q = M.GOSSIP.available[i]
        return q.isTrivial, 0, q.repeatable, false, q.questID
    end
    function GetNumActiveQuests() return #M.GOSSIP.active end
    function GetActiveTitle(i) return M.GOSSIP.active[i].title end
    function GetActiveQuestID(i) return M.GOSSIP.active[i].questID end
    function GetQuestID() return M.questFrame and M.questFrame.questID end
    function GetTitleText() return M.questFrame and M.questFrame.title end
    M.completedQuests = {}

    -- M.SPECIAL_ITEM[questID] = itemID: the quest log's own usable item.
    M.SPECIAL_ITEM = {}
    function GetQuestLogSpecialItemInfo(index)
        local id = M.questAtIndex and M.questAtIndex(index)
        local item = id and M.SPECIAL_ITEM[id]
        if item then return "|cffffffff|Hitem:" .. item .. "::::|h[x]|h|r", 134400, 1, false end
    end
    function GetRealmName() return "Testrealm" end
    function UnitLevel() return M.playerState.level end
    function UnitClass() return "Warrior", "WARRIOR" end
    -- Radians, 0 = north, counter-clockwise (pi/2 = west), as in the client.
    M.facing = 0
    function GetPlayerFacing() return M.facing end
    M.faction = "Alliance"
    function UnitFactionGroup() return M.faction, M.faction end
    function GetTime() return 1234.5 end
    function GetFramerate() return 60 end
    -- Secret values (newer clients, e.g. unit names in group combat): may be
    -- held and passed around, but string methods, concatenation, length and
    -- comparison all error. type() still reports the underlying type, as in
    -- the client. (Plain Lua can't trap comparing a table with a literal like
    -- `secret ~= ""`; everything else errors as it would in game.)
    local rawtype = type
    M.SECRETS = setmetatable({}, { __mode = "k" })
    local function refuse(what) return function() error("attempt to " .. what .. " a secret value", 2) end end
    local secretMT = {
        __index = refuse("index"), __concat = refuse("concatenate"), __len = refuse("get length of"),
        __eq = refuse("compare"), __lt = refuse("compare"), __le = refuse("compare"),
        __call = refuse("call"), __tostring = function() return "<secret>" end,
    }
    function M.secret(value)
        local proxy = setmetatable({}, secretMT)
        M.SECRETS[proxy] = rawtype(value)
        return proxy
    end
    function issecretvalue(v) return v ~= nil and rawtype(v) == "table" and M.SECRETS[v] ~= nil end
    type = function(v)
        if rawtype(v) == "table" and M.SECRETS[v] then return M.SECRETS[v] end
        return rawtype(v)
    end
    function strsplit(sep, s) return { s } end
    function wipe(t) for k in pairs(t) do t[k] = nil end return t end
    function strtrim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end

    -- WoW provides these as globals; standalone Lua 5.1 does not.
    time = os.time
    date = os.date

    DEFAULT_CHAT_FRAME = { messages = {} }
    function DEFAULT_CHAT_FRAME:AddMessage(msg)
        self.messages[#self.messages + 1] = msg
    end

    -- A tooltip that records its lines and hooks, so tooltip additions can
    -- be asserted. TextLeftN globals mirror the client's named regions.
    GameTooltip = makeWidget("GameTooltip")
    GameTooltip.__name = "GameTooltip"
    GameTooltip.lines = {}
    function GameTooltip:AddLine(text)
        table.insert(self.lines, tostring(text or ""))
        local i = #self.lines
        self.raw = self.raw or {}
        self.raw[i] = text                   -- the value itself (may be secret)
        _G["GameTooltipTextLeft" .. i] = { GetText = function() return self.raw[i] end }
    end
    function GameTooltip:AddDoubleLine(l, r) self:AddLine(tostring(l) .. "  " .. tostring(r)) end
    function GameTooltip:ClearLines() self.lines, self.raw = {}, {} end
    function GameTooltip:NumLines() return #self.lines end
    function GameTooltip:SetOwner(owner) self.owner = owner; self.lines, self.raw = {}, {} end
    function GameTooltip:GetOwner() return self.owner end
    function GameTooltip:GetUnit() if M.tooltipUnit then return UnitName(M.tooltipUnit), M.tooltipUnit end end
    function GameTooltip:SetItemByID(id) self:AddLine("item " .. id) end
    function GameTooltip:HookScript(k, fn)
        self.hooks = self.hooks or {}
        self.hooks[k] = self.hooks[k] or {}
        table.insert(self.hooks[k], fn)
    end
    --- Test helper: show a unit (or world object) tooltip the way the client
    --- does, running the hooks addons registered.
    function M.hoverUnit(unit)
        GameTooltip.lines, GameTooltip.raw, M.tooltipUnit = {}, {}, unit
        GameTooltip.owner = UIParent
        GameTooltip:AddLine(UnitName(unit))
        for _, fn in ipairs((GameTooltip.hooks or {}).OnTooltipSetUnit or {}) do fn(GameTooltip) end
        for _, fn in ipairs((GameTooltip.hooks or {}).OnShow or {}) do fn(GameTooltip) end
        return GameTooltip.lines
    end
    function M.hoverObject(name)
        GameTooltip.lines, GameTooltip.raw, M.tooltipUnit = {}, {}, nil
        GameTooltip.owner = UIParent
        GameTooltip:AddLine(name)
        for _, fn in ipairs((GameTooltip.hooks or {}).OnShow or {}) do fn(GameTooltip) end
        return GameTooltip.lines
    end
    GameFontNormal = "F1"
    GameFontNormalSmall = "F2"
    GameFontNormalLarge = "F3"
    GameFontHighlightSmall = "F4"

    SLASH_SOLARYNEXPEDITION1 = "/sol"
    SLASH_SOLARYNEXPEDITION2 = "/expedition"
    SlashCmdList = {}

    _GenerateOverrideTooltip = function() end
    ToggleWorldMap = function() end

    -- Blizzard_MapCanvas, faithfully enough to catch misuse: AddDataProvider
    -- calls provider:OnAdded(map) (a plain table crashes there, exactly as it
    -- did in game), and AcquirePin only accepts templates defined in the
    -- addon's XML, running the template's OnLoad the way the client does.
    MapCanvasDataProviderMixin = {
        OnAdded = function(self, map) self.owningMap = map end,
        OnRemoved = function(self) self.owningMap = nil end,
        GetMap = function(self) return self.owningMap end,
        RemoveAllData = function() end,
        RefreshAllData = function() end,
        OnMapChanged = function(self) self:RefreshAllData() end,
    }
    MapCanvasPinMixin = {
        SetPosition = function(self, x, y) self.normalizedX, self.normalizedY = x, y end,
    }
    function CreateFromMixins(...)
        local out = {}
        for i = 1, select("#", ...) do
            for k, v in pairs((select(i, ...))) do out[k] = v end
        end
        return out
    end

    local function xmlTemplateOnLoad(template)
        local f = io.open("SolarynExpedition.xml", "r")
        if not f then return nil end
        local xml = f:read("*a"); f:close()
        local body = xml:match('<Frame name="' .. template .. '".-</Frame>')
        return body and body:match('<OnLoad function="([%w_]+)"')
    end

    WorldMapFrame = makeWidget("Frame")
    WorldMapFrame.dataProviders = {}
    WorldMapFrame.pins = {}
    WorldMapFrame.mapID = 1
    function WorldMapFrame:AddDataProvider(p)
        self.dataProviders[p] = true
        p:OnAdded(self)
    end
    function WorldMapFrame:RemoveDataProvider(p)
        self.dataProviders[p] = nil
        if p.RemoveAllData then p:RemoveAllData() end
        if p.OnRemoved then p:OnRemoved(self) end
    end
    function WorldMapFrame:GetMapID() return self.mapID end
    function WorldMapFrame:SetMapID(id)
        self.mapID = id
        for p in pairs(self.dataProviders) do p:OnMapChanged() end
    end
    function WorldMapFrame:AcquirePin(template, ...)
        local onLoad = xmlTemplateOnLoad(template)
        if not onLoad or type(_G[onLoad]) ~= "function" then
            error("AcquirePin: unknown template or OnLoad for " .. tostring(template), 2)
        end
        local pin = makeWidget("Frame")
        _G[onLoad](pin)
        pin.owningMap = self
        -- Like Blizzard_MapCanvas: the canvas owns a new pin's mouse scripts.
        -- It asserts the pin set no OnEnter/OnLeave of its own (that assert
        -- fired in game), then routes events to the pin's OnMouseEnter /
        -- OnMouseLeave / OnMouseUp / OnClick methods.
        if pin:IsMouseMotionEnabled() then
            assert(pin:GetScript("OnEnter") == nil, "pin set its own OnEnter (Blizzard_MapCanvas assertion)")
            assert(pin:GetScript("OnLeave") == nil, "pin set its own OnLeave (Blizzard_MapCanvas assertion)")
            pin:SetScript("OnEnter", function(p) if p.OnMouseEnter then p:OnMouseEnter() end end)
            pin:SetScript("OnLeave", function(p) if p.OnMouseLeave then p:OnMouseLeave() end end)
        end
        if pin:IsMouseClickEnabled() then
            pin:SetScript("OnMouseUp", function(p, button, upInside)
                if p.OnMouseUp then p:OnMouseUp(button, upInside) end
                if upInside ~= false and p.OnClick then p:OnClick(button) end
            end)
        end
        pin:OnAcquired(...)
        self.pins[template] = self.pins[template] or {}
        table.insert(self.pins[template], pin)
        return pin
    end
    function WorldMapFrame:RemoveAllPinsByTemplate(template)
        for _, pin in ipairs(self.pins[template] or {}) do
            if pin.OnReleased then pin:OnReleased() end
        end
        self.pins[template] = {}
    end
    function WorldMapFrame:IsShown() return self.shown end
    WorldMapFrame.shown = false

    Minimap = makeWidget("Frame")
    -- Real minimaps are ~144px; the button must orbit its OUTER ring, so the
    -- mock needs a realistic width for the placement test to mean anything.
    Minimap.width = 144
    Minimap.height = 144
    Minimap.GetWidth = function() return 144 end
    Minimap.GetHeight = function() return 144 end
    Minimap.GetSize = function() return 144, 144 end
    Minimap.centerX, Minimap.centerY = 1000, 600

    -- Cursor in screen pixels; tests move it to drive minimap-button drags.
    M.cursor = { x = 0, y = 0 }
    function GetCursorPosition() return M.cursor.x, M.cursor.y end
    function IsShiftKeyDown() return false end
    UISpecialFrames = {}
    GameFontHighlight = "F5"
    GameFontHighlightLarge = "F6"
    GameFontDisableSmall = "F7"

    M.installCMap()
    M.installCQuestLog()

    -- The world map's fog of war. M.REVEALED[mapID] = list of rectangles
    -- { x0, y0, x1, y1, areaID } that count as explored; empty by default.
    M.REVEALED = {}
    C_MapExplorationInfo = {}
    function C_MapExplorationInfo.GetExploredAreaIDsAtPosition(mapID, pos)
        if type(pos) ~= "table" or not pos.x then error("expected a position", 2) end
        local out
        for _, r in ipairs(M.REVEALED[mapID] or {}) do
            if pos.x >= r[1] and pos.x < r[3] and pos.y >= r[2] and pos.y < r[4] then
                out = out or {}
                table.insert(out, r[5])
            end
        end
        return out
    end
end

---------------------------------------------------------------------------
-- C_Map
---------------------------------------------------------------------------
-- Enum.UIMapType is what GetMapChildrenInfo / GetMapInfo actually return.
--   0 Cosmic 1 World 2 Continent 3 Zone 4 Dungeon 5 Micro 6 Orphan
-- Note there is NO C_Map.GetAllMapInfo in the real API — the map tree must be
-- walked from the Cosmic root. The mock models exactly that so a mistake here
-- fails loudly in tests instead of silently in-game.
local MAP_TREE = {
    -- (exported as M.MAP_TREE so tests can reshape it, e.g. drop the Cosmic root)
    [946] = {
        { mapID = 100, name = "Eastern Kingdoms", mapType = 2, parentMapID = 946 },
        { mapID = 101, name = "Kalimdor",         mapType = 2, parentMapID = 946 },
    },
    [100] = {
        { mapID = 1,  name = "Elwynn Forest",      mapType = 3, parentMapID = 100 },
        { mapID = 2,  name = "Westfall",           mapType = 3, parentMapID = 100 },
        { mapID = 3,  name = "Redridge Mountains", mapType = 3, parentMapID = 100 },
        { mapID = 5,  name = "Duskwood",           mapType = 3, parentMapID = 100 },
        { mapID = 6,  name = "Stranglethorn Vale", mapType = 3, parentMapID = 100 },
        { mapID = 84, name = "Dungeon Test",       mapType = 4, parentMapID = 100 },
    },
    [101] = {
        { mapID = 4,  name = "Durotar",            mapType = 3, parentMapID = 101 },
    },
}

M.MAP_TREE = MAP_TREE

function M.installCMap()
    C_Map = {}

    function C_Map.GetMapChildrenInfo(uiMapID, mapType)
        local children = MAP_TREE[uiMapID]
        if not children then return nil end
        local out = {}
        for _, c in ipairs(children) do
            if mapType == nil or c.mapType == mapType then
                table.insert(out, {
                    mapID = c.mapID, name = c.name,
                    mapType = c.mapType, parentMapID = c.parentMapID,
                })
            end
        end
        return out
    end

    function C_Map.GetMapInfo(mapID)
        for _, children in pairs(MAP_TREE) do
            for _, c in ipairs(children) do
                if c.mapID == mapID then
                    return { mapID = c.mapID, name = c.name, mapType = c.mapType, parentMapID = c.parentMapID }
                end
            end
        end
        if mapID == 946 then
            return { mapID = 946, name = "Cosmic", mapType = 0, parentMapID = 0 }
        end
        return nil
    end

    function C_Map.GetBestMapForUnit() return M.playerState.mapID end

    -- Like the client, also answers for a zone map ABOVE the player's map
    -- (standing in a town sub-map still has a position on the zone). The
    -- sub-map's coordinates are reused as-is, which is fine for tests.
    local function isZoneAncestor(mapID, of)
        local id, guard = of, 0
        while id and guard < 6 do
            guard = guard + 1
            local info = C_Map.GetMapInfo(id)
            id = info and info.parentMapID
            if id == mapID then
                local target = C_Map.GetMapInfo(mapID)
                return target and target.mapType == 3
            end
        end
        return false
    end
    function C_Map.GetPlayerMapPosition(mapID)
        if mapID ~= M.playerState.mapID and not isZoneAncestor(mapID, M.playerState.mapID) then
            return nil
        end
        local x, y = M.playerState.mapX, M.playerState.mapY
        return { GetXY = function() return x, y end }
    end

    -- C_Map.GetWorldPosFromMapPos returns TWO values:
    --   continentID, worldPosition
    -- The mock previously returned only the vector, which hid a real crash
    -- (VecXY indexing a bare number). Keep it faithful to the client.
    function C_Map.GetWorldPosFromMapPos(mapID, pos)
        if type(pos) ~= "table" then return nil end
        local x, y = pos.x, pos.y
        if not (x and y) then return nil end
        local wx, wy = M.mapToWorld(mapID, x, y)
        -- continentID: the zone's continent, mirroring the real first return.
        local continentID = zoneOf(mapID).continent or 100
        return continentID, {
            GetXY = function() return wx, wy end,
            x = wx, y = wy,
        }
    end

    function C_Map.CanSetUserWaypointOnMap() return true end

    -- Named sub-areas (C_Map.GetAreaInfo returns just the name).
    M.AREAS = { [87] = "Goldshire", [9] = "Northshire Valley", [108] = "Sentinel Hill" }
    function C_Map.GetAreaInfo(areaID) return M.AREAS[areaID] end

    function C_Map.SetUserWaypoint(point)
        M.playerState.waypoint = point
        return true
    end

    function C_Map.ClearUserWaypoint()
        M.playerState.waypoint = nil
        return true
    end
end

---------------------------------------------------------------------------
-- C_QuestLog
---------------------------------------------------------------------------
-- A quest log with one of every interesting shape:
--   1001 in progress, partial, nearby
--   1002 all objectives finished  -> ready to hand in
--   1003 partially finished      -> two objectives, one done
--   1004 a task quest, should be deprioritised
--   1005 a story quest
M.QUESTS = {
    [1001] = { title = "Kobold Camp Cleanup", level = 8,
               objectives = { { text = "Kobold Vermin: 4/8", finished = false, numFulfilled = 4, numRequired = 8 } },
               wp = { mapID = 1, x = 0.3, y = 0.4 } },
    [1002] = { title = "A Threat Within", level = 10,
               objectives = { { text = "Defeat the kobold leader", finished = true } },
               wp = { mapID = 1, x = 0.52, y = 0.51 } },
    [1003] = { title = "Westfall Plots", level = 9,
               objectives = { { text = "Thieves' Tools: 6/6", finished = true, numFulfilled = 6, numRequired = 6 },
                             { text = "Weeds Divided", finished = false } },
               wp = { mapID = 2, x = 0.6, y = 0.3 } },
    [1004] = { title = "Daily Bounty", level = 10, isTask = true,
               objectives = { { text = "Boars slain: 0/10", finished = false, numFulfilled = 0, numRequired = 10 } },
               wp = { mapID = 3, x = 0.2, y = 0.7 } },
    [1005] = { title = "The Long Night", level = 11, isStory = true,
               objectives = { { text = "Survive", finished = false } },
               wp = { mapID = 1, x = 0.7, y = 0.8 } },
}

function M.installCQuestLog()
    C_QuestLog = {}

    function C_QuestLog.GetNumQuestLogEntries()
        local n = 0
        for _ in pairs(M.QUESTS) do n = n + 1 end
        return n, n
    end

    function M.questAtIndex(index)
        local i = 0
        for id in pairs(M.QUESTS) do
            i = i + 1
            if i == index then return id end
        end
    end
    function C_QuestLog.GetLogIndexForQuestID(questID)
        local i = 0
        for id in pairs(M.QUESTS) do
            i = i + 1
            if id == questID then return i end
        end
    end

    function C_QuestLog.GetInfo(index)
        local i = 0
        for id, q in pairs(M.QUESTS) do
            i = i + 1
            if i == index then
                return { title = q.title, level = q.level, questID = id, isHeader = false,
                         frequency = q.isTask and 2 or 0, isTask = q.isTask, isStory = q.isStory }
            end
        end
        return nil
    end

    function C_QuestLog.GetQuestObjectives(questID)
        local q = M.QUESTS[questID]
        return q and q.objectives or nil
    end

    function C_QuestLog.IsQuestFlaggedCompleted(id) return M.completedQuests and M.completedQuests[id] or false end

    function C_QuestLog.GetActiveQuestMapIDs(questID)
        local q = M.QUESTS[questID]
        return q and { q.wp.mapID } or {}
    end

    -- Faithful to the client: this is a ROUTING call. It answers only when the
    -- objective is on a different map (the exit/portal to take), and returns
    -- nothing for the objective's own map. The old mock returned the objective
    -- for its own map, which hid the fact that in game no quest got a location.
    -- M.ROUTES[questID] = { [fromMapID] = { x, y } } models the routing case.
    M.ROUTES = {}
    function C_QuestLog.GetNextWaypointForMap(questID, mapID)
        local q = M.QUESTS[questID]
        if not q or q.wp.mapID == mapID then return nil end
        local r = M.ROUTES[questID] and M.ROUTES[questID][mapID]
        if r then return r[1], r[2] end
        return nil
    end

    -- The world map's quest markers for one map. M.NO_POI[questID] = true
    -- simulates a quest the client has no marker for.
    -- Once every objective is finished the client's marker moves to the quest
    -- giver: M.TURNIN_WP[questID] = { mapID, x, y } models that (default: the
    -- marker stays at the objective).
    M.NO_POI, M.TURNIN_WP = {}, {}
    local function markerFor(id, q)
        local done = #q.objectives > 0
        for _, o in ipairs(q.objectives) do if not o.finished then done = false end end
        return (done and M.TURNIN_WP[id]) or q.wp
    end
    -- Like the client, a marker also appears on the continent map containing
    -- its zone (projected into continent coordinates). In game this is how one
    -- objective came back on several maps and became duplicate route stops.
    function C_QuestLog.GetQuestsOnMap(mapID)
        local out = {}
        for id, q in pairs(M.QUESTS) do
            local wp = markerFor(id, q)
            if not M.NO_POI[id] then
                if wp.mapID == mapID then
                    table.insert(out, { questID = id, x = wp.x, y = wp.y, type = 0, isMapIndicatorQuest = false })
                elseif ZONES[mapID] and ZONES[wp.mapID] and mapID == ZONES[wp.mapID].continent
                    and mapID ~= wp.mapID then
                    local wx, wy = M.mapToWorld(wp.mapID, wp.x, wp.y)
                    local c = ZONES[mapID]
                    table.insert(out, { questID = id, x = (wx - c.worldX) / c.size, y = (wy - c.worldY) / c.size,
                        type = 0, isMapIndicatorQuest = false })
                end
            end
        end
        return out
    end
end

return M
