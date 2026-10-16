--[[---------------------------------------------------------------------------
    Solaryn's Expedition — shared UI building blocks.

    Every window, the tracker and the options share one look, an explorer's
    field kit: a deep ink body, a bronze frame with gold corner brackets like
    the edge of a map, gold headings and flat bronze-trimmed controls. Building
    it all here keeps the windows from drifting apart.

    Colour fills are always Textures. Frames have no SetColorTexture in the
    real client (the mock enforces this too), so a "coloured frame" is a frame
    holding a texture made by Widgets:Fill. Only stock client textures are
    used, so nothing ships as an image file.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.Widgets = {}

local Widgets = ns.Widgets

local WHITE = "Interface\\Buttons\\WHITE8X8"

-- Palette for chrome (content colours live in ns.Colors).
Widgets.Theme = {
    bg         = { 0.035, 0.034, 0.042, 0.96 },   -- window body: ink
    hudBg      = { 0.020, 0.020, 0.028 },         -- tracker body (alpha from settings)
    card       = { 0.090, 0.082, 0.070, 0.85 },   -- a raised group of rows
    cardEdge   = { 0.34, 0.27, 0.14, 0.55 },
    nav        = { 0.055, 0.050, 0.046, 1.00 },   -- options sidebar
    border     = { 0.56, 0.44, 0.21, 1.00 },      -- bronze frame
    shadow     = { 0.00, 0.00, 0.00, 0.70 },
    hairline   = { 1.00, 0.82, 0.40, 0.09 },      -- faint gold inner line
    bracket    = { 1.00, 0.82, 0.36, 0.95 },      -- gold corner brackets
    titleBg    = { 0.105, 0.082, 0.050, 1.00 },
    titleSheen = { 1.00, 0.80, 0.40, 0.045 },
    sectionBg  = { 0.09, 0.09, 0.11, 0.95 },
    rowHover   = { 1.00, 0.86, 0.50, 0.06 },
    rowAlt     = { 1.00, 1.00, 1.00, 0.025 },
    divider    = { 0.56, 0.44, 0.21, 0.40 },
    gold       = { 1.00, 0.82, 0.30, 1.00 },
    goldDeep   = { 0.62, 0.46, 0.14, 1.00 },
    track      = { 0.15, 0.14, 0.13, 1.00 },
    trackOff   = { 0.20, 0.19, 0.18, 1.00 },
    knobOff    = { 0.55, 0.53, 0.50, 1.00 },
    btnBg      = { 0.125, 0.095, 0.055, 0.95 },
    btnSheen   = { 1.00, 0.85, 0.50, 0.05 },
    btnHover   = { 1.00, 0.82, 0.30, 0.14 },
    primaryBg  = { 0.42, 0.30, 0.08, 0.95 },
    selected   = { 1.00, 0.82, 0.30, 0.12 },
}
local T = Widgets.Theme

local BACKDROP = {
    bgFile = WHITE,
    edgeFile = WHITE,
    tile = false, edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
}
Widgets.BACKDROP = BACKDROP

--- Hex escape for a colour table, for inline |c...|r text colouring.
function Widgets.Hex(c)
    if not c then return "ffffffff" end
    return string.format("ff%02x%02x%02x",
        math.floor((c.r or c[1] or 1) * 255 + 0.5),
        math.floor((c.g or c[2] or 1) * 255 + 0.5),
        math.floor((c.b or c[3] or 1) * 255 + 0.5))
end

function Widgets.Colorize(text, c)
    return "|c" .. Widgets.Hex(c) .. tostring(text) .. "|r"
end

---------------------------------------------------------------------------
-- Primitive helpers
---------------------------------------------------------------------------
--- A solid-colour texture. Pass an {r,g,b,a} array or numbers.
function Widgets:Fill(parent, layer, r, g, b, a)
    if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetColorTexture(r or 0, g or 0, b or 0, a or 1)
    return t
end

--- A 1px frame drawn with four fills, `inset` pixels in from the edge
-- (negative draws outside it). Returns the edge list; :SetColor(r,g,b,a)
-- recolours all four.
function Widgets:Border(frame, color, inset, layer)
    inset = inset or 0
    local edges = {}
    local function edge()
        local t = self:Fill(frame, layer or "BORDER", color)
        edges[#edges + 1] = t
        return t
    end
    local top = edge()
    top:SetPoint("TOPLEFT", inset, -inset); top:SetPoint("TOPRIGHT", -inset, -inset); top:SetHeight(1)
    local bottom = edge()
    bottom:SetPoint("BOTTOMLEFT", inset, inset); bottom:SetPoint("BOTTOMRIGHT", -inset, inset); bottom:SetHeight(1)
    local left = edge()
    left:SetPoint("TOPLEFT", inset, -inset); left:SetPoint("BOTTOMLEFT", inset, inset); left:SetWidth(1)
    local right = edge()
    right:SetPoint("TOPRIGHT", -inset, -inset); right:SetPoint("BOTTOMRIGHT", -inset, inset); right:SetWidth(1)
    function edges.SetColor(_, r, g, b, a)
        if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
        for _, t in ipairs(edges) do t:SetColorTexture(r, g, b, a or 1) end
    end
    return edges
end

--- Gold L-shaped brackets on the four corners, like the frame of a map.
function Widgets:Brackets(frame, size, color, layer)
    size = size or 8
    local list = {}
    for _, corner in ipairs({ "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }) do
        local h = self:Fill(frame, layer or "OVERLAY", color or T.bracket)
        h:SetSize(size, 2)
        h:SetPoint(corner, 0, 0)
        local v = self:Fill(frame, layer or "OVERLAY", color or T.bracket)
        v:SetSize(2, size)
        v:SetPoint(corner, 0, 0)
        list[#list + 1] = h
        list[#list + 1] = v
    end
    return list
end

--- The shared window chrome: a drop shadow, the ink body, a bronze border,
-- a faint gold inner line and gold corner brackets. Returns the body fill
-- (frame.chromeBg) so callers can change its opacity.
function Widgets:Chrome(frame, opts)
    opts = opts or {}
    local bg = self:Fill(frame, "BACKGROUND", opts.bg or T.bg)
    bg:SetAllPoints()
    frame.chromeBg = bg
    frame.chromeShadow = self:Border(frame, T.shadow, -1, "BACKGROUND")
    frame.chromeBorder = self:Border(frame, opts.border or T.border, 0, "BORDER")
    if opts.hairline ~= false then
        frame.chromeHairline = self:Border(frame, T.hairline, 2, "BORDER")
    end
    if opts.brackets ~= false then
        frame.chromeBrackets = self:Brackets(frame, opts.bracketSize or 10)
    end
    return bg
end

--- Apply the shared flat backdrop. Frames created without BackdropTemplate
-- (older clients have SetBackdrop natively) are handled by probing.
local function applyBackdrop(frame, bg, border)
    if type(frame.SetBackdrop) ~= "function" then return end
    bg, border = bg or T.bg, border or T.border
    frame:SetBackdrop(BACKDROP)
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
    frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
end
Widgets.ApplyBackdrop = applyBackdrop

--- Template string to pass to CreateFrame for a frame that needs a backdrop.
local function backdropTemplate()
    return _G.BackdropTemplateMixin and "BackdropTemplate" or nil
end
Widgets.BackdropTemplate = backdropTemplate

--- Font string with our default styling.
-- Tolerates a missing parent by falling back to UIParent: a rendering helper
-- should never be the thing that throws during a UI reload race.
function Widgets:Text(parent, text, template, justify)
    parent = parent or UIParent
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    fs:SetText(text or "")
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

--- Single-line text that clips with "..." at its anchored width instead of
-- wrapping onto the next row.
function Widgets:Line(parent, text, template, justify)
    local fs = self:Text(parent, text, template, justify)
    if type(fs.SetWordWrap) == "function" then fs:SetWordWrap(false) end
    if type(fs.SetMaxLines) == "function" then fs:SetMaxLines(1) end
    return fs
end

--- Wrapping, dimmed explanatory text at a fixed width. Returns the font
-- string and its height, measured when the client can and estimated when it
-- can't (an unloaded font measures 0).
function Widgets:Note(parent, text, width)
    local fs = self:Text(parent, text, "GameFontHighlightSmall")
    fs:SetTextColor(ns.Colors.dim.r, ns.Colors.dim.g, ns.Colors.dim.b)
    if type(fs.SetWordWrap) == "function" then fs:SetWordWrap(true) end
    if type(fs.SetJustifyV) == "function" then fs:SetJustifyV("TOP") end
    fs:SetWidth(width)
    local h = type(fs.GetStringHeight) == "function" and ns.SafeNum(fs:GetStringHeight()) or 0
    if not h or h <= 0 then
        local perLine = math.max(1, math.floor(width / 5.4))
        h = math.ceil(#(text or "") / perLine) * 12
    end
    fs:SetHeight(h)
    return fs, h
end

--- Coloured label.
function Widgets:Label(parent, text, color)
    local fs = self:Text(parent, text, "GameFontNormalSmall")
    if color then fs:SetTextColor(color.r, color.g, color.b) end
    return fs
end

--- Small gold section heading with a rule that fades out to the right.
-- Returns the holder frame (height 18).
function Widgets:Heading(parent, text)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(18)
    local fs = self:Line(holder, string.upper(text or ""), "GameFontNormalSmall")
    fs:SetPoint("LEFT", 2, 0)
    fs:SetTextColor(ns.Colors.header.r, ns.Colors.header.g, ns.Colors.header.b)
    holder.text = fs
    local near = self:Fill(holder, "ARTWORK", T.border[1], T.border[2], T.border[3], 0.55)
    near:SetHeight(1)
    near:SetPoint("LEFT", fs, "RIGHT", 8, 0)
    near:SetPoint("RIGHT", holder, "CENTER", 30, 0)
    local far = self:Fill(holder, "ARTWORK", T.border[1], T.border[2], T.border[3], 0.18)
    far:SetHeight(1)
    far:SetPoint("LEFT", near, "RIGHT", 0, 0)
    far:SetPoint("RIGHT", holder, "RIGHT", -2, 0)
    return holder
end

--- A raised card: slightly lighter than the window, with a soft bronze edge.
function Widgets:Card(parent)
    local card = CreateFrame("Frame", nil, parent)
    local bg = self:Fill(card, "BACKGROUND", T.card)
    bg:SetAllPoints()
    card.edge = self:Border(card, T.cardEdge, 0, "BORDER")
    return card
end

--- A flat bronze-trimmed button. `style` "primary" gives it a gold fill for
-- the main action of a view.
function Widgets:Button(parent, text, width, height, onClick, style)
    height = height or 22
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width or 90, height)

    local primary = style == "primary"
    local bg = self:Fill(b, "BACKGROUND", primary and T.primaryBg or T.btnBg)
    bg:SetAllPoints()
    local sheen = self:Fill(b, "BORDER", T.btnSheen)
    sheen:SetPoint("TOPLEFT", 1, -1)
    sheen:SetPoint("TOPRIGHT", -1, -1)
    sheen:SetHeight(math.floor(height / 2))
    b.border = self:Border(b, T.border, 0, "ARTWORK")
    local hl = self:Fill(b, "HIGHLIGHT", T.btnHover)
    hl:SetAllPoints()

    local fs = self:Text(b, text, "GameFontNormalSmall", "CENTER")
    fs:SetPoint("LEFT", 6, 0)
    fs:SetPoint("RIGHT", -6, 0)
    if primary then fs:SetTextColor(1, 0.95, 0.80) end
    b.label = fs
    if type(b.SetFontString) == "function" then b:SetFontString(fs) end
    b:SetText(text or "")
    if type(b.SetPushedTextOffset) == "function" then b:SetPushedTextOffset(1, -1) end

    -- Disabled buttons fade instead of keeping their gold.
    b:HookScript("OnDisable", function()
        fs:SetTextColor(0.5, 0.5, 0.5)
        b.border:SetColor(0.30, 0.27, 0.22, 1)
    end)
    b:HookScript("OnEnable", function()
        if primary then fs:SetTextColor(1, 0.95, 0.80) else fs:SetTextColor(T.gold[1], T.gold[2], T.gold[3]) end
        b.border:SetColor(T.border)
    end)

    if onClick then
        b:SetScript("OnClick", onClick)
    end
    return b
end

--- A thin horizontal rule.
function Widgets:Divider(parent, layer)
    local t = self:Fill(parent, layer or "ARTWORK", T.divider)
    t:SetHeight(1)
    return t
end

--- Horizontal progress bar with a dark trough. Returns the StatusBar; its
-- `.label` is an optional centred FontString.
function Widgets:ProgressBar(parent, height, color)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetHeight(height or 8)
    bar:SetStatusBarTexture(WHITE)
    local c = color or ns.Colors.accent
    bar:SetStatusBarColor(c.r, c.g, c.b, 0.85)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)

    local trough = self:Fill(bar, "BACKGROUND", 0.11, 0.10, 0.09, 0.95)
    trough:SetAllPoints()
    bar.trough = trough

    local label = self:Text(bar, "", "GameFontHighlightSmall", "CENTER")
    label:SetPoint("CENTER", 0, 0)
    bar.label = label
    return bar
end

---------------------------------------------------------------------------
-- Windows
---------------------------------------------------------------------------
local TITLE_HEIGHT = 28
Widgets.TITLE_HEIGHT = TITLE_HEIGHT

--- Save a window's anchor after a move. GetPoint() after StopMovingOrSizing
-- is relative to UIParent, so it restores exactly. `v = 2` marks the format:
-- version-1 saves stored absolute screen coords as CENTER offsets, which put
-- the window off-screen on restore, so those are ignored.
local function savePosition(frame, key)
    if not key then return end
    local point, _, relPoint, x, y = frame:GetPoint()
    if type(point) == "string" and type(x) == "number" and type(y) == "number" then
        ns.Settings()[key] = { v = 2, point = point, relPoint = relPoint or point, x = x, y = y }
    end
end

local function restorePosition(frame, key, default)
    local db = _G.SolarynDB
    local saved = key and db and db.settings and db.settings[key]
    local pt, rel, px, py = default[1], default[1], default[2], default[3]
    if type(saved) == "table" and saved.v == 2
        and type(saved.point) == "string" and type(saved.x) == "number" and type(saved.y) == "number" then
        pt, px, py = saved.point, saved.x, saved.y
        rel = type(saved.relPoint) == "string" and saved.relPoint or pt
    end
    frame:ClearAllPoints()
    local ok = pcall(function() frame:SetPoint(pt, UIParent, rel, px, py) end)
    if not ok then frame:SetPoint(default[1], UIParent, default[1], default[2], default[3]) end
end
Widgets.RestorePosition = restorePosition
Widgets.SavePosition = savePosition

--- Blizzard's close button, recoloured from red to the theme's gold.
local function goldClose(parent)
    local close = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
    close:SetSize(22, 22)
    pcall(function()
        for _, get in ipairs({ "GetNormalTexture", "GetPushedTexture" }) do
            local tex = type(close[get]) == "function" and close[get](close)
            if tex then
                if tex.SetDesaturated then tex:SetDesaturated(true) end
                tex:SetVertexColor(1, 0.82, 0.45)
            end
        end
    end)
    return close
end
Widgets.CloseButton = goldClose

--- Create a movable window with the shared chrome.
-- opts: title, subtitle, icon, width, height, posKey (settings key for the
--       saved position), default = { point, x, y }, resizable = bool,
--       minW/minH/maxW/maxH.
-- Returns the frame; frame.titleBar, frame.title, frame.subtitle and
-- frame.closeButton exist.
--
-- Only the title bar drags the window. A frame that drags anywhere begins a
-- move on any click that never receives OnDragStop, which leaves the window
-- stuck to the cursor.
function Widgets:Window(name, opts)
    opts = opts or {}
    local frame = CreateFrame("Frame", name, UIParent)
    frame:SetSize(opts.width or 320, opts.height or 400)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetToplevel(true)
    self:Chrome(frame)
    frame:Hide()

    restorePosition(frame, opts.posKey, opts.default or { "CENTER", 0, 0 })

    -- Closes with Escape, like Blizzard panels.
    if name and type(_G.UISpecialFrames) == "table" then
        table.insert(_G.UISpecialFrames, name)
    end

    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(TITLE_HEIGHT)
    local barBg = self:Fill(bar, "BACKGROUND", T.titleBg)
    barBg:SetAllPoints()
    local sheen = self:Fill(bar, "BORDER", T.titleSheen)
    sheen:SetPoint("TOPLEFT", 0, 0)
    sheen:SetPoint("TOPRIGHT", 0, 0)
    sheen:SetHeight(math.floor(TITLE_HEIGHT / 2))
    local rule = self:Fill(bar, "ARTWORK", T.border)
    rule:SetHeight(1)
    rule:SetPoint("BOTTOMLEFT", 0, 0)
    rule:SetPoint("BOTTOMRIGHT", 0, 0)
    local underRule = self:Fill(frame, "ARTWORK", T.shadow)
    underRule:SetHeight(2)
    underRule:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, 0)
    underRule:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, 0)

    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    -- Move the FRAME, not the bar: moving the bar dragged the title out of
    -- the window while the body stayed put.
    bar:SetScript("OnDragStart", function()
        if opts.isLocked and opts.isLocked() then return end
        frame:StartMoving()
    end)
    bar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        savePosition(frame, opts.posKey)
    end)
    frame.titleBar = bar

    local icon
    if opts.icon then
        local ring = self:Fill(bar, "ARTWORK", T.border)
        ring:SetSize(18, 18)
        ring:SetPoint("LEFT", 8, 0)
        icon = bar:CreateTexture(nil, "OVERLAY")
        icon:SetSize(16, 16)
        icon:SetPoint("CENTER", ring, "CENTER", 0, 0)
        icon:SetTexture(opts.icon)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon = ring
    end

    local title = self:Line(bar, opts.title or "", "GameFontNormal")
    title:SetPoint("LEFT", icon or bar, icon and "RIGHT" or "LEFT", icon and 7 or 12, 0)
    title:SetTextColor(ns.Colors.accent.r, ns.Colors.accent.g, ns.Colors.accent.b)
    frame.title = title

    local close = goldClose(bar)
    close:SetPoint("RIGHT", -3, 0)
    close:SetScript("OnClick", function() frame:Hide() end)
    frame.closeButton = close

    local subtitle = self:Line(bar, opts.subtitle or "", "GameFontDisableSmall", "RIGHT")
    subtitle:SetPoint("RIGHT", close, "LEFT", -6, 0)
    frame.subtitle = subtitle
    title:SetPoint("RIGHT", subtitle, "LEFT", -8, 0)

    if opts.resizable and type(frame.SetResizable) == "function" then
        frame:SetResizable(true)
        local minW, minH = opts.minW or 280, opts.minH or 240
        local maxW, maxH = opts.maxW or 900, opts.maxH or 1000
        if type(frame.SetResizeBounds) == "function" then
            pcall(frame.SetResizeBounds, frame, minW, minH, maxW, maxH)
        elseif type(frame.SetMinResize) == "function" then
            pcall(frame.SetMinResize, frame, minW, minH)
        end
        frame.grip = Widgets.ResizeGrip(frame, function()
            local key = opts.sizeKey
            if key then
                ns.Settings()[key] = { w = frame:GetWidth(), h = frame:GetHeight() }
            end
            savePosition(frame, opts.posKey)
        end)
        local saved = opts.sizeKey and ns.Settings()[opts.sizeKey]
        if type(saved) == "table" and type(saved.w) == "number" and type(saved.h) == "number" then
            frame:SetSize(math.max(minW, math.min(maxW, saved.w)), math.max(minH, math.min(maxH, saved.h)))
        end
    end

    return frame
end

--- Small square icon button (e.g. the options cog in a title bar). Dimmed
-- at rest, full brightness under the cursor.
function Widgets:IconButton(parent, texture, size, tooltipTitle, tooltipLines, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size or 18, size or 18)
    local tex = b:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture(texture)
    tex:SetVertexColor(0.80, 0.74, 0.62)
    b.icon = tex
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.85, 0.45, 0.15)
    b:SetScript("OnClick", onClick)
    if tooltipTitle then self:TooltipLines(b, tooltipTitle, tooltipLines) end
    return b
end

---------------------------------------------------------------------------
-- Form controls
---------------------------------------------------------------------------
-- Rows used by the options window: a label (and optional wrapped
-- description, opts.desc, at opts.width) on the left, the control on the
-- right or underneath. Each returns a holder frame with .Refresh() and a
-- .rowHeight the caller lays out by.

local ROW_PAD = 7

--- Horizontal slider with its value in a small badge on the right.
-- Returns the holder frame; holder.slider and holder.Refresh().
function Widgets:Slider(parent, label, minVal, maxVal, step, get, set, formatFn, tip, opts)
    opts = opts or {}
    local holder = CreateFrame("Frame", nil, parent)
    local width = opts.width or 300

    local lbl = self:Line(holder, label, "GameFontHighlight")
    lbl:SetPoint("TOPLEFT", 10, -ROW_PAD)
    lbl:SetPoint("TOPRIGHT", -80, -ROW_PAD)

    local badge = CreateFrame("Frame", nil, holder)
    badge:SetSize(64, 18)
    badge:SetPoint("TOPRIGHT", -10, -ROW_PAD + 2)
    local badgeBg = self:Fill(badge, "BACKGROUND", 0, 0, 0, 0.45)
    badgeBg:SetAllPoints()
    self:Border(badge, T.cardEdge, 0, "BORDER")
    local val = self:Line(badge, "", "GameFontNormalSmall", "CENTER")
    val:SetPoint("LEFT", 2, 0)
    val:SetPoint("RIGHT", -2, 0)

    local y = ROW_PAD + 16
    if opts.desc then
        local note, h = self:Note(holder, opts.desc, width - 20)
        note:SetPoint("TOPLEFT", 10, -(y + 2))
        y = y + 2 + h
    end

    local slider = CreateFrame("Slider", nil, holder)
    if type(slider.SetOrientation) == "function" then slider:SetOrientation("HORIZONTAL") end
    slider:SetPoint("TOPLEFT", 10, -(y + 6))
    slider:SetPoint("TOPRIGHT", -10, -(y + 6))
    slider:SetHeight(16)
    slider:EnableMouse(true)
    slider:SetHitRectInsets(-4, -4, -6, -6)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step or 1)
    slider:SetObeyStepOnDrag(true)

    local track = self:Fill(slider, "BACKGROUND", T.track)
    track:SetHeight(4)
    track:SetPoint("LEFT", 0, 0)
    track:SetPoint("RIGHT", 0, 0)
    local trackEdge = self:Fill(slider, "BORDER", 0, 0, 0, 0.6)
    trackEdge:SetHeight(1)
    trackEdge:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
    trackEdge:SetPoint("TOPRIGHT", track, "TOPRIGHT", 0, 0)

    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(T.gold[1], T.gold[2], T.gold[3], 1)
    thumb:SetSize(8, 16)
    slider:SetThumbTexture(thumb)
    local grip = self:Fill(slider, "OVERLAY", 0.30, 0.20, 0.05, 0.9)
    grip:SetSize(2, 8)
    grip:SetPoint("CENTER", thumb, "CENTER", 0, 0)

    local filled = self:Fill(slider, "ARTWORK", T.goldDeep)
    filled:SetHeight(4)
    filled:SetPoint("LEFT", track, "LEFT", 0, 0)
    filled:SetPoint("RIGHT", thumb, "CENTER", 0, 0)

    local function show(v)
        val:SetText(formatFn and formatFn(v) or tostring(v))
    end

    local updating = false
    slider:SetScript("OnValueChanged", function(_, v)
        -- Snap to the step so floating-point drift never shows as 0.8500001.
        if step and step > 0 then v = math.floor(v / step + 0.5) * step end
        show(v)
        if not updating then set(v) end
    end)

    -- The mouse wheel nudges one step at a time.
    if type(slider.EnableMouseWheel) == "function" then
        slider:EnableMouseWheel(true)
        slider:SetScript("OnMouseWheel", function(self, delta)
            local v = (self:GetValue() or minVal) + delta * (step or 1)
            self:SetValue(math.max(minVal, math.min(maxVal, v)))
        end)
    end

    function holder.Refresh()
        updating = true
        slider:SetValue(get() or minVal)
        updating = false
        show(get() or minVal)
    end
    holder.Refresh()

    if tip then self:TooltipLines(slider, label, { tip }) end
    holder.slider = slider
    holder.rowHeight = y + 6 + 16 + ROW_PAD
    holder:SetHeight(holder.rowHeight)
    return holder
end

--- An on/off switch row: a pill that slides gold when on. Clicking anywhere
-- on the row flips it. Returns the holder; holder.check and holder.Refresh().
function Widgets:Check(parent, label, get, set, tip, opts)
    opts = opts or {}
    local width = opts.width or 300
    local holder = CreateFrame("Button", nil, parent)
    holder:RegisterForClicks("LeftButtonUp")
    local hover = self:Fill(holder, "HIGHLIGHT", T.rowHover)
    hover:SetAllPoints()

    local chk = CreateFrame("CheckButton", nil, holder)
    chk:SetSize(30, 16)
    chk:SetPoint("TOPRIGHT", -10, -ROW_PAD)
    local trackBg = self:Fill(chk, "BACKGROUND", T.trackOff)
    trackBg:SetAllPoints()
    local trackEdge = self:Border(chk, { 0, 0, 0, 0.6 }, 0, "BORDER")
    local knob = self:Fill(chk, "ARTWORK", T.knobOff)
    knob:SetSize(12, 12)

    local lbl = self:Line(holder, label, "GameFontHighlight")
    lbl:SetPoint("TOPLEFT", 10, -ROW_PAD)
    lbl:SetPoint("RIGHT", chk, "LEFT", -10, 0)

    local h = ROW_PAD + 16
    if opts.desc then
        local note, nh = self:Note(holder, opts.desc, width - 70)
        note:SetPoint("TOPLEFT", 10, -(h + 2))
        h = h + 2 + nh
    end

    local function paint(on)
        knob:ClearAllPoints()
        if on then
            trackBg:SetColorTexture(T.goldDeep[1], T.goldDeep[2], T.goldDeep[3], 1)
            knob:SetColorTexture(T.gold[1], T.gold[2], T.gold[3], 1)
            knob:SetPoint("RIGHT", chk, "RIGHT", -2, 0)
            trackEdge:SetColor(T.border)
        else
            trackBg:SetColorTexture(T.trackOff[1], T.trackOff[2], T.trackOff[3], 1)
            knob:SetColorTexture(T.knobOff[1], T.knobOff[2], T.knobOff[3], 1)
            knob:SetPoint("LEFT", chk, "LEFT", 2, 0)
            trackEdge:SetColor(0, 0, 0, 0.6)
        end
    end

    chk:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        paint(on)
        set(on)
    end)
    -- The whole row is the hit area, not just the little switch.
    holder:SetScript("OnClick", function()
        chk:SetChecked(not chk:GetChecked())
        chk:GetScript("OnClick")(chk)
    end)

    function holder.Refresh()
        local on = get() and true or false
        chk:SetChecked(on)
        paint(on)
    end
    holder.Refresh()

    if tip then self:TooltipLines(holder, label, { tip }) end
    holder.check = chk
    holder.rowHeight = h + ROW_PAD
    holder:SetHeight(holder.rowHeight)
    return holder
end

--- A row with a label, description and a button on the right.
function Widgets:ActionRow(parent, label, desc, buttonText, onClick, opts)
    opts = opts or {}
    local width = opts.width or 300
    local holder = CreateFrame("Frame", nil, parent)
    local btn = self:Button(holder, buttonText, opts.buttonWidth or 110, 22, onClick)
    btn:SetPoint("TOPRIGHT", -10, -ROW_PAD + 2)
    local lbl = self:Line(holder, label, "GameFontHighlight")
    lbl:SetPoint("TOPLEFT", 10, -ROW_PAD)
    lbl:SetPoint("RIGHT", btn, "LEFT", -10, 0)
    local h = ROW_PAD + 16
    if desc then
        local note, nh = self:Note(holder, desc, width - (opts.buttonWidth or 110) - 30)
        note:SetPoint("TOPLEFT", 10, -(h + 2))
        h = h + 2 + nh
    end
    holder.button = btn
    holder.rowHeight = math.max(h, 26) + ROW_PAD
    holder:SetHeight(holder.rowHeight)
    function holder.Refresh() end
    return holder
end

--- Vertical scroll container anchored by the caller. Returns (scroll, inner).
-- The inner frame's width follows the scroll frame so rows anchored to both
-- of its edges always span the visible width, including after a resize.
-- The inner frame is always created and returned, even if sizing fails,
-- because callers store it and render into it.
function Widgets:Scroll(parent)
    parent = parent or UIParent
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")

    local inner = CreateFrame("Frame", nil, scroll)
    inner:SetSize(280, 1)
    scroll:SetScrollChild(inner)

    local function syncWidth()
        local w = scroll:GetWidth()
        if type(w) == "number" and w > 0 then inner:SetWidth(w) end
    end
    -- Hook rather than set: the template may own this script.
    scroll:HookScript("OnSizeChanged", syncWidth)
    syncWidth()

    -- The template's scrollbar sits outside the frame's right edge; keep it
    -- inside the window by shifting it in, and slim it to a gold rail: a
    -- thin trough, a gold thumb, and the arrow buttons faded right back.
    local bar = scroll.ScrollBar
    if bar and bar.ClearAllPoints then
        pcall(function()
            bar:ClearAllPoints()
            bar:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 18, -16)
            bar:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 18, 16)
        end)
        pcall(function()
            local rail = Widgets:Fill(bar, "BACKGROUND", 0, 0, 0, 0.35)
            rail:SetWidth(4)
            rail:SetPoint("TOP", 0, 0)
            rail:SetPoint("BOTTOM", 0, 0)
            local thumb = type(bar.GetThumbTexture) == "function" and bar:GetThumbTexture()
            if thumb then
                thumb:SetTexture(WHITE)
                thumb:SetVertexColor(T.goldDeep[1], T.goldDeep[2], T.goldDeep[3], 0.9)
                thumb:SetSize(4, 24)
            end
            for _, key in ipairs({ "ScrollUpButton", "ScrollDownButton" }) do
                local arrow = bar[key] or (bar.GetName and bar:GetName() and _G[bar:GetName() .. key])
                if arrow and arrow.SetAlpha then arrow:SetAlpha(0.35) end
            end
        end)
    end

    return scroll, inner
end

---------------------------------------------------------------------------
-- Resize grip
---------------------------------------------------------------------------
--- A small bottom-right grip for a resizable frame, matching Blizzard's
-- convention. `onDone` runs after each resize. Returns nil if the frame
-- isn't resizable.
function Widgets.ResizeGrip(frame, onDone)
    if not frame then return nil end
    if type(frame.SetResizable) ~= "function" then return nil end

    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetFrameLevel((frame:GetFrameLevel() or 1) + 10)

    local tex = grip:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    tex:SetVertexColor(1, 0.85, 0.5)
    grip.tex = tex

    grip:EnableMouse(true)
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        if onDone then onDone() end
    end)
    return grip
end

---------------------------------------------------------------------------
-- Tooltips
---------------------------------------------------------------------------
--- Tooltip anchored to a region. `lines` is a list of strings; an empty
-- string adds a spacer, and nil entries are skipped.
function Widgets:ShowTooltip(owner, title, lines, headerColor)
    local c = headerColor or ns.Colors.accent
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(title or "", c.r, c.g, c.b)
    for i = 1, (lines and table.maxn(lines) or 0) do
        local line = lines[i]
        if line then
            GameTooltip:AddLine(line, 0.85, 0.85, 0.85, true)
        end
    end
    GameTooltip:Show()
end

function Widgets:TooltipLines(region, title, lines, headerColor)
    region:SetScript("OnEnter", function(self)
        Widgets:ShowTooltip(self, title, lines, headerColor)
    end)
    region:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

return Widgets
