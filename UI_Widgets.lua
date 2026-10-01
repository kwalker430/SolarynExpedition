--[[---------------------------------------------------------------------------
    Solaryn's Expedition — shared UI building blocks.

    The panel and options window share one look: a flat dark body, a thin
    bronze border, a draggable title bar with a gold title and a standard close
    button. Everything here builds that look so the windows never drift apart.

    Colour fills are always Textures. Frames have no SetColorTexture in the
    real client (the mock enforces this too), so a "coloured frame" is a frame
    holding a texture made by Widgets:Fill.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.Widgets = {}

local Widgets = ns.Widgets

local WHITE = "Interface\\Buttons\\WHITE8X8"

-- Palette for chrome (content colours live in ns.Colors).
Widgets.Theme = {
    bg        = { 0.05, 0.05, 0.07, 0.94 },
    border    = { 0.42, 0.34, 0.18, 0.95 },
    titleBg   = { 0.10, 0.09, 0.07, 1.00 },
    sectionBg = { 0.09, 0.09, 0.11, 0.95 },
    rowHover  = { 1.00, 1.00, 1.00, 0.06 },
    rowAlt    = { 1.00, 1.00, 1.00, 0.025 },
    divider   = { 0.42, 0.34, 0.18, 0.45 },
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
        math.floor((c.r or 1) * 255 + 0.5),
        math.floor((c.g or 1) * 255 + 0.5),
        math.floor((c.b or 1) * 255 + 0.5))
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

--- Coloured label.
function Widgets:Label(parent, text, color)
    local fs = self:Text(parent, text, "GameFontNormalSmall")
    if color then fs:SetTextColor(color.r, color.g, color.b) end
    return fs
end

--- A standard red-panel button.
function Widgets:Button(parent, text, width, height, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 90, height or 22)
    b:SetText(text or "")
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

    local trough = self:Fill(bar, "BACKGROUND", 0.14, 0.14, 0.16, 0.95)
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

--- Create a movable window with the shared chrome.
-- opts: title, width, height, posKey (settings key for the saved position),
--       default = { point, x, y }, resizable = bool, minW/minH/maxW/maxH.
-- Returns the frame; frame.titleBar, frame.title, frame.closeButton exist.
--
-- Only the title bar drags the window. A frame that drags anywhere begins a
-- move on any click that never receives OnDragStop, which leaves the window
-- stuck to the cursor.
function Widgets:Window(name, opts)
    opts = opts or {}
    local frame = CreateFrame("Frame", name, UIParent, backdropTemplate())
    frame:SetSize(opts.width or 320, opts.height or 400)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetToplevel(true)
    applyBackdrop(frame)
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
    local rule = self:Divider(bar)
    rule:SetPoint("BOTTOMLEFT", 0, 0)
    rule:SetPoint("BOTTOMRIGHT", 0, 0)

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
        icon = bar:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT", 8, 0)
        icon:SetTexture(opts.icon)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end

    local title = self:Line(bar, opts.title or "", "GameFontNormal")
    title:SetPoint("LEFT", icon or bar, icon and "RIGHT" or "LEFT", icon and 6 or 10, 0)
    title:SetPoint("RIGHT", bar, "RIGHT", -60, 0)
    title:SetTextColor(ns.Colors.accent.r, ns.Colors.accent.g, ns.Colors.accent.b)
    frame.title = title

    local close = CreateFrame("Button", nil, bar, "UIPanelCloseButton")
    close:SetSize(24, 24)
    close:SetPoint("RIGHT", -2, 0)
    close:SetScript("OnClick", function() frame:Hide() end)
    frame.closeButton = close

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

--- Small square icon button (e.g. the options cog in a title bar).
function Widgets:IconButton(parent, texture, size, tooltipTitle, tooltipLines, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size or 18, size or 18)
    local tex = b:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture(texture)
    tex:SetVertexColor(0.85, 0.85, 0.85)
    b.icon = tex
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.15)
    b:SetScript("OnClick", onClick)
    if tooltipTitle then self:TooltipLines(b, tooltipTitle, tooltipLines) end
    return b
end

---------------------------------------------------------------------------
-- Form controls
---------------------------------------------------------------------------
--- Horizontal slider with a label on the left and a live value on the right.
-- Returns the holder frame (height 44); holder.slider and holder.Refresh().
function Widgets:Slider(parent, label, minVal, maxVal, step, get, set, formatFn, tip)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(44)

    local lbl = self:Line(holder, label, "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 2, 0)
    lbl:SetPoint("TOPRIGHT", -80, 0)

    local val = self:Line(holder, "", "GameFontNormalSmall", "RIGHT")
    val:SetPoint("TOPRIGHT", -2, 0)
    val:SetWidth(78)

    local slider = CreateFrame("Slider", nil, holder, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 6, -16)
    slider:SetPoint("TOPRIGHT", -6, -16)
    slider:SetHeight(16)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step or 1)
    slider:SetObeyStepOnDrag(true)
    if slider.low then slider.low:SetText("") end
    if slider.high then slider.high:SetText("") end
    if slider.Text then slider.Text:SetText("") end
    if slider.text then slider.text:SetText("") end

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

    function holder.Refresh()
        updating = true
        slider:SetValue(get() or minVal)
        updating = false
        show(get() or minVal)
    end
    holder.Refresh()

    if tip then self:TooltipLines(slider, label, { tip }) end
    holder.slider = slider
    return holder
end

--- A checkbox row with an optional tooltip. Returns the holder frame;
-- holder.check and holder.Refresh().
function Widgets:Check(parent, label, get, set, tip)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(26)

    local chk = CreateFrame("CheckButton", nil, holder, "InterfaceOptionsCheckButtonTemplate")
    chk:SetSize(24, 24)
    chk:SetPoint("LEFT", -2, 0)
    chk:SetChecked(get() and true or false)
    if chk.Text then chk.Text:SetText("") end

    local lbl = self:Line(holder, label, "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", chk, "RIGHT", 4, 0)
    lbl:SetPoint("RIGHT", holder, "RIGHT", 0, 0)

    chk:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
    end)

    function holder.Refresh() chk:SetChecked(get() and true or false) end
    if tip then self:TooltipLines(chk, label, { tip }) end
    holder.check = chk
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
    -- inside the window by shifting it in.
    local bar = scroll.ScrollBar
    if bar and bar.ClearAllPoints then
        pcall(function()
            bar:ClearAllPoints()
            bar:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 18, -16)
            bar:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 18, 16)
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
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel((frame:GetFrameLevel() or 1) + 10)

    local tex = grip:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
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
