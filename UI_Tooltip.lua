--[[---------------------------------------------------------------------------
    Solaryn's Expedition — quest info in tooltips.

    Hovering a mob, NPC or world object that one of your quests needs adds
    the quest and the matching objective's progress to its tooltip:

      Kobold Vermin
      Level 4
      Kobold Camp Cleanup  (guided)
       - Kobold Vermin slain: 4/8

    There is no quest database here, so a match means the unit's name appears
    in an objective's text, which covers "kill X", "talk to X" and "use X"
    objectives. Mobs that only DROP a quest item aren't named in the
    objective; for those, clients that have
    C_QuestLog.UnitIsRelatedToActiveQuest get a generic "quest mob" line.
    Quests the client's tooltip already shows are never repeated.

    Secret values: in combat (notably in groups) newer clients hand addons
    unit names and tooltip text as "secret" values, which may be held but not
    compared, concatenated or string-processed. Every value from a unit or a
    tooltip goes through ns.IsSafe before anything else touches it; when the
    name is secret there is nothing we may read, so no quest lines are added.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.QuestTooltip = {}

local QT = ns.QuestTooltip

local MAX_QUESTS = 3

---------------------------------------------------------------------------
-- Matching
---------------------------------------------------------------------------
--- True if objective text names this unit/object. Handles the common
--- plural forms objectives use ("Young Wolves" for "Young Wolf").
function QT.NameMatches(objectiveText, name)
    if type(objectiveText) ~= "string" or type(name) ~= "string" then return false end
    local t, n = objectiveText:lower(), name:lower()
    if #n < 3 then return false end
    if t:find(n, 1, true) then return true end
    local stem
    if n:sub(-1) == "f" then stem = n:sub(1, -2) .. "ves"
    elseif n:sub(-2) == "fe" then stem = n:sub(1, -3) .. "ves"
    elseif n:sub(-1) == "y" then stem = n:sub(1, -2) .. "ies"
    elseif n:sub(-3) == "man" then stem = n:sub(1, -4) .. "men"
    end
    return stem ~= nil and t:find(stem, 1, true) ~= nil
end

--- Quests (and their objectives) that mention `name`:
--- list of { questID, title, guided, objectives = { {text, finished}, ... } }.
function QT:Matches(name)
    local out = {}
    if not name or not ns.IsSafe(name) then return out end
    local guidedQuest = ns.Route:IsGuiding() and ns.Route:Next() and ns.Route:Next().questID
    for _, e in ipairs(ns.QuestData:Scan()) do
        if not e.isHeader then
            local objs = {}
            for _, o in ipairs(ns.QuestData:Objectives(e.questID)) do
                if QT.NameMatches(o.text, name) then table.insert(objs, o) end
            end
            if #objs > 0 then
                table.insert(out, {
                    questID = e.questID, title = e.title,
                    guided = e.questID == guidedQuest,
                    objectives = objs,
                })
            end
        end
    end
    -- Guided quest first, then unfinished objectives before finished ones.
    table.sort(out, function(a, b)
        if a.guided ~= b.guided then return a.guided end
        return (a.title or "") < (b.title or "")
    end)
    return out
end

---------------------------------------------------------------------------
-- Tooltip lines
---------------------------------------------------------------------------
--- Text already on the tooltip, so we never repeat what the client shows.
local function existingText(tooltip)
    local seen = {}
    local name = tooltip.GetName and tooltip:GetName()
    local n = tooltip.NumLines and tooltip:NumLines() or 0
    for i = 1, n do
        local region = name and _G[name .. "TextLeft" .. i]
        local text = region and region.GetText and region:GetText()
        if ns.IsSafe(text) and type(text) == "string" then seen[#seen + 1] = text:lower() end
    end
    return table.concat(seen, "\n")
end

local function formatObjective(o)
    local text = o.text or ""
    if not text:find("%d+/%d+") and (o.numRequired or 0) > 1 then
        text = string.format("%s: %d/%d", text, o.numFulfilled or 0, o.numRequired)
    end
    return " - " .. text
end

--- Add quest lines for `name` to `tooltip`. `unit` (optional) enables the
--- "related to a quest" fallback. Returns the number of quests added.
function QT:Annotate(tooltip, name, unit)
    if not ns.Settings().questTooltips then return 0 end
    if not ns.playerName then return 0 end
    local matches = self:Matches(name)
    local already = existingText(tooltip)
    local added = 0
    local a, q = ns.Colors.accent, ns.Colors.quest

    for _, m in ipairs(matches) do
        if added >= MAX_QUESTS then break end
        if not already:find((m.title or "\0"):lower(), 1, true) then
            tooltip:AddLine((m.title or "?") .. (m.guided and "  |cffffd100(guided)|r" or ""), q.r, q.g, q.b)
            for _, o in ipairs(m.objectives) do
                if o.finished then
                    tooltip:AddLine(formatObjective(o), 0.5, 0.5, 0.5)
                else
                    tooltip:AddLine(formatObjective(o), 1, 1, 1)
                end
            end
            added = added + 1
        end
    end

    if added == 0 and #matches == 0 and unit then
        local related = ns.Try("C_QuestLog", "UnitIsRelatedToActiveQuest", unit)
        if related then
            tooltip:AddLine("Quest mob: needed for an active quest", a.r, a.g, a.b)
            added = 1
        end
    end

    if added > 0 and tooltip.Show then tooltip:Show() end   -- resize to fit
    return added
end

---------------------------------------------------------------------------
-- Quest givers (learned by talking to them; see Core_QuestGivers)
---------------------------------------------------------------------------
local MAX_OFFERS = 5

--- Add what an NPC offers and takes back. Returns the number of lines added.
function QT:AnnotateGiver(tooltip, unit)
    if not ns.Settings().questTooltips or not ns.QuestGivers then return 0 end
    if type(_G.UnitGUID) ~= "function" then return 0 end
    local npcID = ns.QuestGivers.IDFromGUID(_G.UnitGUID(unit))
    if not npcID then return 0 end
    local already = existingText(tooltip)
    local added = 0

    for _, h in ipairs(ns.QuestGivers:HandIns(npcID)) do
        if not already:find(("hand in here: " .. (h.title or "")):lower(), 1, true) then
            if h.complete then
                tooltip:AddLine("Hand in here: " .. (h.title or "?"), 0.25, 0.85, 0.35)
            else
                tooltip:AddLine((h.title or "?") .. "  (in progress)", 0.6, 0.6, 0.6)
            end
            added = added + 1
        end
    end

    local offers = ns.QuestGivers:Offers(npcID)
    for i, q in ipairs(offers) do
        if i > MAX_OFFERS then
            tooltip:AddLine(string.format("  +%d more", #offers - MAX_OFFERS), 0.6, 0.6, 0.6)
            added = added + 1
            break
        end
        local c = q.trivial and { r = 0.5, g = 0.5, b = 0.5 } or ns:LevelColor(q.level)
        local lvl = q.level and string.format("[%d] ", q.level) or ""
        tooltip:AddLine("Available: " .. lvl .. (q.title or ("Quest " .. q.questID)), c.r, c.g, c.b)
        added = added + 1
    end

    if added > 0 and tooltip.Show then tooltip:Show() end
    return added
end

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------
--- The tooltip's unit token ("mouseover", "target", ...). Tokens are never
--- secret, unlike the name GetUnit also returns.
local function tooltipUnit(tooltip)
    if not tooltip.GetUnit then return nil end
    local _, unit = tooltip:GetUnit()
    if ns.IsSafe(unit) and type(unit) == "string" then return unit end
    return nil
end

local function annotateUnit(tooltip)
    if tooltip ~= GameTooltip then return end
    local unit = tooltipUnit(tooltip)
    if not unit then return end
    if type(_G.UnitIsPlayer) == "function" then
        local isPlayer = _G.UnitIsPlayer(unit)
        if not ns.IsSafe(isPlayer) or isPlayer then return end
    end
    local name = tooltip:GetUnit()
    if not ns.IsSafe(name) or type(name) ~= "string" then return end    -- secret: nothing we may read
    QT:Annotate(tooltip, name, unit)
    QT:AnnotateGiver(tooltip, unit)
end

-- World objects (chests, plants, wanted posters) have no unit; their
-- tooltip's first line is the object's name.
local function annotateObject(tooltip)
    if tooltip ~= GameTooltip then return end
    if tooltipUnit(tooltip) then return end
    local owner = tooltip.GetOwner and tooltip:GetOwner()
    if owner ~= UIParent and owner ~= _G.WorldFrame then return end   -- not a world tooltip
    local first = _G["GameTooltipTextLeft1"]
    local name = first and first.GetText and first:GetText()
    if not ns.IsSafe(name) or type(name) ~= "string" then return end    -- secret: nothing we may read
    if name ~= "" then QT:Annotate(tooltip, name, nil) end
end

-- Tooltip extras must never surface an error over the game, whatever the
-- client restricts next.
local function guarded(fn)
    return function(tooltip)
        local ok, err = pcall(fn, tooltip)
        if not ok then ns:Debug("tooltip: %s", tostring(err)) end
    end
end
local onUnit, onObject = guarded(annotateUnit), guarded(annotateObject)
QT.OnUnit, QT.OnObject = onUnit, onObject

local hooked = false
function QT:Hook()
    if hooked or not GameTooltip then return end
    hooked = true
    local TDP, E = _G.TooltipDataProcessor, _G.Enum and _G.Enum.TooltipDataType
    if type(TDP) == "table" and type(TDP.AddTooltipPostCall) == "function" and E then
        -- Modern clients: tooltips are built from data, post-calls run after.
        if E.Unit then TDP.AddTooltipPostCall(E.Unit, onUnit) end
        if E.Object then TDP.AddTooltipPostCall(E.Object, onObject) end
    else
        GameTooltip:HookScript("OnTooltipSetUnit", onUnit)
        GameTooltip:HookScript("OnShow", onObject)
    end
end

function QT:Initialize()
    self:Hook()
end

ns:RegisterModule("QuestTooltip", QT)

return QT
