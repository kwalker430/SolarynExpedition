--[[---------------------------------------------------------------------------
    Solaryn's Expedition — slash commands (/sol, also /expedition).

    HELP below is the single reference for every command: /sol help prints
    it, /sol help <command> shows one entry in full, and the test suite checks
    it matches the COMMANDS table and README.md, so neither can drift.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...
local ns = _G.SolarynExpedition

ns.Slash = {}

local Slash = ns.Slash

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function printList(lines, header)
    DEFAULT_CHAT_FRAME:AddMessage("|cff82c8ffSolaryn|r " .. (header or ""))
    for _, line in ipairs(lines) do
        DEFAULT_CHAT_FRAME:AddMessage("  " .. line)
    end
end

---------------------------------------------------------------------------
-- Diagnostics capture
---------------------------------------------------------------------------
-- /sol api and /sol where print through out()/outf(), which also keep a copy
-- while a capture is running. The copy is saved to SolarynDB.diagnostics
-- (written to disk on /reload or logout) so it can be read without copying
-- chat by hand. We never hook the chat frame itself: changing Blizzard
-- frames from addon code taints them.
local captured

local function plain(text)
    text = tostring(text or "")
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "")
    return text
end

local function out(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
    if captured then captured[#captured + 1] = plain(msg) end
end

local function outf(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    ns:Print("%s", msg)
    if captured then captured[#captured + 1] = plain(msg) end
end

--- Run fn while capturing its output; save it under diagnostics[kind].
local function captureTo(kind, fn)
    captured = {}
    local ok, err = pcall(fn)
    if not ok then captured[#captured + 1] = "error: " .. tostring(err) end
    local lines = captured
    captured = nil
    local d = _G.SolarynDB
    if d then
        d.diagnostics = d.diagnostics or {}
        d.diagnostics[kind] = {
            when = date("%Y-%m-%d %H:%M:%S"),
            character = ns.charKey,
            version = ns.version,
            lines = lines,
        }
    end
    return lines
end
Slash.CaptureTo = captureTo

---------------------------------------------------------------------------
-- Command reference
---------------------------------------------------------------------------
-- { name, args, summary, details, example }. name "" is bare /sol.
local HELP = {
    { group = "Panel & guide", commands = {
        { "", "", "Open or close the panel",
          "Three tabs: Next (what to do now, nearest first), Route (your stops in walking order) and Zones (where to level next and what you've explored)." },
        { "next", "", "Start the guide at the next stop",
          "Puts a waypoint on the next stop and follows the route for you: when a quest's work is done (or it's handed in) the waypoint moves on by itself." },
        { "skip", "", "Skip the current stop",
          "Moves the guide to the following stop. Handy when you want to come back to something later." },
        { "stop", "", "Stop the guide",
          "Stops following the route. The route itself is kept; /sol next picks it up again." },
        { "route", "", "Rebuild the route and print it",
          "Re-orders your quest log into a walking route from where you stand, finishing nearby objectives before hand-ins." },
        { "map", "", "Open the world map at the current stop",
          "Opens the map on the zone of the stop you're heading to. Route stops are drawn on the map as numbered pins." },
        { "hud", "", "Show or hide the route tracker",
          "The on-screen tracker shows the current stop, its objectives, a direction arrow, upcoming stops and quest item buttons." },
        { "options", "", "Open the options window",
          "Route behaviour, tracker, tooltips, exploration tracking and suggestion weights." },
    } },
    { group = "Quests", commands = {
        { "suggestions", "", "Print what to do next to chat",
          "The same list as the panel's Next tab: hand-ins, objectives nearest first, and a new zone when you've outgrown yours." },
        { "where", "", "Show where each quest's location comes from",
          "For every quest in your log, prints which location source answered (world-map marker, waypoint, learned NPC...) or 'none'. Useful when a quest has no pin.",
          "/sol where" },
        { "pin", "<questID>", "Record an objective's real position",
          "Stand where the objective really is and run this: the position is saved and used instead of the client's for that quest (all characters). With no quest ID it lists the quests in your log with their IDs.",
          "/sol pin 1001" },
        { "chain", "<from> <to>", "Record that one quest leads to another",
          "Links a quest to its follow-up so later steps of a chain you've started rank higher. Chains are also learned automatically when you hand in and accept.",
          "/sol chain 1001 1003" },
    } },
    { group = "Zones & exploration", commands = {
        { "zones", "", "Print exploration coverage per zone",
          "Coverage comes from your 'Explore <Zone>' achievement when there is one (areas found of the total), otherwise from your world map and where you've walked." },
        { "zone", "reset [all]", "Clear the addon's exploration data",
          "'reset' clears the zone you're in, 'reset all' clears every zone. Your world map and achievements are untouched and are read back in on the next update.",
          "/sol zone reset" },
    } },
    { group = "Help & troubleshooting", commands = {
        { "help", "[command]", "This list, or details for one command", nil, "/sol help pin" },
        { "report", "", "Collect diagnostics to share",
          "Runs /sol api and /sol where together, saves the result (written to disk on /reload) and opens it in a window ready to copy into a bug report." },
        { "api", "", "Report what this client supports",
          "Lists the game APIs the addon found (quest markers, fog of war, zone levels...). Include this when reporting a problem." },
        { "debug", "", "Toggle debug messages",
          "Prints internal errors the addon caught instead of keeping them silent." },
    } },
}
Slash.HELP = HELP

local function usage(c)
    return "/sol" .. (c[1] ~= "" and (" " .. c[1]) or "") .. (c[2] ~= "" and (" " .. c[2]) or "")
end

local function findHelp(name)
    for _, g in ipairs(HELP) do
        for _, c in ipairs(g.commands) do
            if c[1] == name then return c end
        end
    end
end

--- /sol pin — walk the user through recording an override for a quest.
-- Deliberately interactive-but-simple: it lists the quests in the log so the
-- user can name one, then captures the current position as the override.
local function cmdPin(arg)
    arg = (arg or ""):gsub("%s+", "")
    if arg == "" then
        printList({
            "Usage: /sol pin <questID>",
            "Quests in your log:",
        })
        for _, e in ipairs(ns.QuestData:Scan()) do
            if not e.isHeader then
                DEFAULT_CHAT_FRAME:AddMessage(string.format("    %d  %s", e.questID, ns:Truncate(e.title, 40)))
            end
        end
        return
    end

    local questID = tonumber(arg)
    if not questID then
        ns:Print("'%s' is not a quest ID.", arg)
        return
    end

    local mapID = ns:PlayerMapID()
    local pos = ns:PlayerPosition(mapID)
    if not mapID or not pos then
        ns:Print("could not read your position.")
        return
    end

    local entry = ns.QuestData.cache[questID]
    local title = entry and entry.title or ("quest " .. questID)
    local label = arg:match("^%d+%:(.*)$") or title

    ns.Overrides:Set(questID, {
        objectives = {
            {
                uiMapID = mapID,
                -- 0-1 map fractions; 4 places is well under a yard.
                x = math.floor(pos.x * 10000 + 0.5) / 10000,
                y = math.floor(pos.y * 10000 + 0.5) / 10000,
                label = label,
            },
        },
        note = "Recorded manually with /sol pin on " .. date("%Y-%m-%d"),
    })

    ns:Print("recorded an override for '%s' at %s (%.1f, %.1f).",
        ns:Truncate(title, 30), ns:MapName(mapID), pos.x * 100, pos.y * 100)
    ns:Print("Rebuild the route to use it: /sol route")
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
local COMMANDS = {}

function COMMANDS.help(arg)
    local name = ((arg or ""):match("^%s*(%S*)") or ""):lower():gsub("^/sol%s*", "")
    local c = name ~= "" and findHelp(name)
    if c then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff82c8ffSolaryn|r |cffffd100%s|r  %s", usage(c), c[3]))
        if c[4] then DEFAULT_CHAT_FRAME:AddMessage("  " .. c[4]) end
        if c[5] then DEFAULT_CHAT_FRAME:AddMessage("  Example: |cffffd100" .. c[5] .. "|r") end
        return
    end
    if name ~= "" then ns:Print("no command '%s'.", name) end

    DEFAULT_CHAT_FRAME:AddMessage("|cff82c8ffSolaryn's Expedition|r v" .. tostring(ns.version)
        .. " — quest routing & exploration")
    for _, g in ipairs(HELP) do
        DEFAULT_CHAT_FRAME:AddMessage("|cffc8a85c" .. g.group .. "|r")
        for _, cmd in ipairs(g.commands) do
            DEFAULT_CHAT_FRAME:AddMessage(string.format("  |cffffd100%-22s|r %s", usage(cmd), cmd[3]))
        end
    end
    DEFAULT_CHAT_FRAME:AddMessage("Type |cffffd100/sol help <command>|r for details, e.g. /sol help pin.")
end

function COMMANDS.suggestions()
    local list = ns.Suggest:Compute()
    if #list == 0 then
        ns:Print("no suggestions — quest log is empty or nothing is locatable.")
        return
    end
    printList({}, "suggestions:")
    for i, s in ipairs(list) do
        local dist = s.distance and ("  [" .. ns:FormatDistance(s.distance) .. "]") or ""
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "  %d. %s%s  |cff%s%s%s|r", i,
            ns:Truncate(s.title, 32), dist,
            tostring(math.floor((s.color.r or 1) * 255)),
            tostring(math.floor((s.color.g or 1) * 255)),
            tostring(math.floor((s.color.b or 1) * 255)),
            s.detail or ""))
    end
end

function COMMANDS.route()
    local state = ns.Route:Build()
    ns.Route:StampFingerprint()
    if #state.stops == 0 then
        ns:Print("no route — no quests in your log with a known objective location.")
        return
    end
    printList({}, string.format("route (%d stops):", #state.stops))
    for i, s in ipairs(state.stops) do
        local kind = s.kind == "turnin" and "turn in" or "objective"
        local line = string.format("  %2d. [%s] %s — %s", i, kind, ns:Truncate(s.title or "?", 28), ns:MapName(s.uiMapID))
        DEFAULT_CHAT_FRAME:AddMessage(line)
    end
    ns:Print("next stop: /sol next")
end

function COMMANDS.next()
    local stop = ns.Route:Next()
    if not stop then
        ns:Print("no route built. Try /sol route")
        return
    end
    ns.Route:Guide()
end

function COMMANDS.skip()
    if not ns.Route:Next() then
        ns:Print("no route to skip through.")
        return
    end
    if not ns.Route:IsGuiding() then ns.Route:Guide() end
    ns.Route:Advance("skipped")
end

function COMMANDS.hud()
    local s = ns.Settings()
    s.hud = not s.hud
    ns:Print("route tracker %s.", s.hud and "on" or "off")
    if ns.HUD then ns.HUD:Refresh() end
end

function COMMANDS.stop()
    ns.Route:StopGuiding()
    ns:Print("guide stopped.")
end

function COMMANDS.map()
    local stop = ns.Route:Next()
    if not stop then
        ns:Print("no route built. Try /sol route")
        return
    end
    ns.MapPins:OpenAt(stop.uiMapID, stop.x, stop.y)
end

COMMANDS.pin = cmdPin

function COMMANDS.chain(arg)
    local from, to = arg:match("^(%d+)%s+(%d+)$")
    if not from or not to then
        ns:Print("usage: /sol chain <fromQuestID> <toQuestID>")
        return
    end
    if ns.Chains:Link(tonumber(from), tonumber(to)) then
        ns:Print("recorded chain %d -> %d", tonumber(from), tonumber(to))
    else
        ns:Print("that chain link already exists.")
    end
end

function COMMANDS.zones()
    local all = ns.Explored:All()
    if #all == 0 then
        ns:Print("no zone data yet — move around for a minute and check back.")
        return
    end
    printList({}, "zone coverage:")
    for _, z in ipairs(all) do
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  %-28s %s  (%d cells, %d samples)",
            ns:Truncate(z.name, 26), ns:FormatPct(z.coverage), z.cells, z.hits))
    end
end

function COMMANDS.zone(arg)
    arg = (arg or ""):lower()
    if arg == "reset all" or arg == "resetall" then
        ns.Explored:ResetAll()
    elseif arg == "reset" then
        local mapID = ns:PlayerMapID()
        if mapID then
            ns.Explored:ResetZone(mapID)
            ns:Print("cleared tracking for %s.", ns:MapName(mapID))
        end
    else
        ns:Print("usage: /sol zone reset [all]")
    end
end

function COMMANDS.options()
    ns.Panel:ToggleOptions()
end

function COMMANDS.debug()
    local s = ns.Settings()
    s.debug = not s.debug
    ns:Print("debug logging %s.", s.debug and "on" or "off")
end

--- Report the live API shapes this build actually returns.
-- Every mock-vs-client mismatch so far has come from a return shape or a
-- template-provided region, so dump both rather than guessing.
local function run_api()
    outf("--- API shape report ---")
    outf("addon v%s, client interface %s", tostring(ns.version), tostring(ns.tocVersion))

    local caps = {}
    for k, v in pairs(ns.Has) do
        if v then table.insert(caps, k) end
    end
    table.sort(caps)
    outf("capabilities present (%d): %s", #caps, table.concat(caps, ", "))

    local mapID = ns:PlayerMapID()
    outf("player map: %s", tostring(mapID))
    if mapID then
        local pos = ns.Try("C_Map", "GetPlayerMapPosition", mapID, "player")
        outf("  GetPlayerMapPosition -> %s (%s)",
            type(pos), pos and type(pos.GetXY) or "no GetXY")
        local cid, wp = ns.Try("C_Map", "GetWorldPosFromMapPos", mapID, pos or { x = 50, y = 50 })
        outf("  GetWorldPosFromMapPos -> continentID=%s, pos=%s",
            tostring(cid), type(wp))
    end

    local cosmic = ns.Try("C_Map", "GetMapChildrenInfo", 946)
    outf("  map tree from 946 (Cosmic) -> %s", type(cosmic) == "table" and (#cosmic .. " children") or "none")
    local azeroth = ns.Try("C_Map", "GetMapChildrenInfo", 947)
    outf("  map tree from 947 (Azeroth) -> %s", type(azeroth) == "table" and (#azeroth .. " children") or "none")
    outf("  zones known: %d  (current map type %s)", #ns.ZoneData:WorldZones(),
        tostring(mapID and ns.ZoneData:Get(mapID) and ns.ZoneData:Get(mapID).mapType))
    -- Zone levels and progression, as the panel sees them.
    local zone = mapID and ns.ZoneData:WorldAncestor(mapID)
    if zone then
        local raw = { ns.Try("C_Map", "GetMapLevels", zone) }
        local r = ns.ZoneData:LevelRange(zone)
        outf("  zone %s (%d): GetMapLevels -> %s  |  used: %s", ns.ZoneData:Name(zone), zone,
            #raw > 0 and table.concat((function() local t = {} for i, v in ipairs(raw) do t[i] = tostring(v) end return t end)(), ", ") or "nothing",
            r and string.format("%d-%d from %s", r.min, r.max, r.source) or "no range")
        local cont = ns.ZoneData:Continent(zone)
        outf("  continent: %s", cont and string.format("%s (%d)", ns.ZoneData:Name(cont), cont) or "none found")
        local prog = ns.ZoneData:Progression(3)
        if prog.current and prog.current.status then outf("  this zone for you: %s", prog.current.status) end
        if #prog.next == 0 then
            outf("  next zones: none recommended")
        else
            local names = {}
            for i, z in ipairs(prog.next) do
                names[i] = string.format("%s %d-%d%s", z.name, z.range.min, z.range.max,
                    z.distance and (" " .. ns:FormatDistance(z.distance)) or "")
            end
            outf("  next zones: %s", table.concat(names, "; "))
        end
    end
    outf("  exploration: tracking %s, %d zones recorded, fog-of-war import %s",
        ns.Settings().trackingEnabled and "on" or "off", ns.Explored:Summary().zones,
        ns.Has.exploredAreasAtPos and "available" or "NOT available")

    local n = ns.Try("C_QuestLog", "GetNumQuestLogEntries")
    outf("quest log entries: %s", tostring(n))
    outf("panel built: %s", tostring(ns.Panel:CurrentTab() ~= nil))
    outf("zones loaded: %s", tostring(ns.ZoneData:Name(mapID or -1)))
end

function COMMANDS.api()
    captureTo("api", run_api)
    ns:Print("(saved too: /reload writes it to disk, or /sol report opens a copyable window)")
end

--- For each quest in the log, show what every location source returns, so
-- we can see which sources this client actually supports.
local function run_where()
    local yes = function(cap) return ns.Has[cap] and "|cff40ff40yes|r" or "|cffff4040no|r" end
    outf("--- quest location sources ---")
    outf("GetQuestsOnMap %s  GetNextWaypoint %s  GetNextWaypointForMap %s",
        yes("questsOnMap"), yes("nextWaypointAny"), yes("nextWaypoint"))
    outf("GetQuestUiMapID %s  C_TaskQuest %s  C_QuestLog.IsComplete %s  UiMapPoint %s",
        yes("questUiMapID"), yes("taskQuestLocation"), yes("questIsComplete"), yes("uiMapPoint"))
    outf("quest tags: C_QuestLog.GetQuestTagInfo %s  GetQuestTagInfo %s",
        yes("questTagInfo"), yes("questTagInfoOld"))

    local playerMap = ns:PlayerMapID()
    outf("you are on map %s (%s)", tostring(playerMap), ns:MapName(playerMap or -1))
    if ns.Has.questsOnMap and playerMap then
        local list = ns.Try("C_QuestLog", "GetQuestsOnMap", playerMap)
        outf("GetQuestsOnMap(%s) -> %s markers", tostring(playerMap),
            type(list) == "table" and tostring(#list) or type(list))
    end

    local fmt = function(x, y)
        x, y = ns.SafeNum(x), ns.SafeNum(y)
        if not (x and y) then return "-" end
        return string.format("%.3f,%.3f", x, y)
    end

    ns.QuestData:Invalidate()
    local n = 0
    for _, e in ipairs(ns.QuestData:Scan()) do
        if not e.isHeader then
            n = n + 1
            local parts = {}
            local wp = ns.QuestData:PrimaryWaypoint(e.questID)
            table.insert(parts, wp and string.format("|cff40ff40%s|r map %d @ %s", wp.source, wp.uiMapID, fmt(wp.x, wp.y))
                or "|cffff4040none|r")
            if ns.Has.nextWaypointAny then
                local m, x, y = ns.Try("C_QuestLog", "GetNextWaypoint", e.questID)
                table.insert(parts, "next=" .. (m and (tostring(m) .. "@" .. fmt(x, y)) or "-"))
            end
            if ns.Has.questUiMapID then
                table.insert(parts, "uiMap=" .. tostring(ns.Try("_G", "GetQuestUiMapID", e.questID) or "-"))
            end
            if ns.Has.nextWaypoint and playerMap then
                table.insert(parts, "forMap=" .. fmt(ns.Try("C_QuestLog", "GetNextWaypointForMap", e.questID, playerMap)))
            end
            table.insert(parts, "lv=" .. tostring(e.level or "-"))
            local tagID, tagName = ns.QuestData:TagInfo(e.questID)
            if tagID or tagName then
                table.insert(parts, string.format("tag=%s%s%s", tostring(tagID or "-"),
                    tagName and (" " .. tagName) or "", e.isDungeon and " (dungeon)" or ""))
            end
            table.insert(parts, ns.QuestData:IsComplete(e.questID) and "done" or "open")
            out(string.format("  %d %s: %s",
                e.questID, ns:Truncate(e.title or "?", 24), table.concat(parts, "  ")))
        end
    end
    if n == 0 then outf("quest log is empty (or not loaded yet).") end
end

function COMMANDS.where()
    captureTo("where", run_where)
    ns:Print("(saved too: /reload writes it to disk, or /sol report opens a copyable window)")
end

--- A window holding text selected and ready to copy (Ctrl+C).
local reportWindow
local function showCopyWindow(title, text)
    local W = ns.Widgets
    if not reportWindow then
        reportWindow = W:Window("SolarynExpeditionReport", {
            title = title, width = 560, height = 420, default = { "CENTER", 0, 0 },
        })
        local hint = W:Line(reportWindow, "Press Ctrl+C to copy (the text is already selected), then paste it into a GitHub issue.",
            "GameFontHighlightSmall")
        hint:SetPoint("TOPLEFT", 12, -(W.TITLE_HEIGHT + 6))
        hint:SetPoint("TOPRIGHT", -12, -(W.TITLE_HEIGHT + 6))
        local scroll = CreateFrame("ScrollFrame", nil, reportWindow, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -(W.TITLE_HEIGHT + 24))
        scroll:SetPoint("BOTTOMRIGHT", -32, 12)
        local box = CreateFrame("EditBox", nil, scroll)
        box:SetMultiLine(true)
        box:SetAutoFocus(false)
        box:SetFontObject(_G.ChatFontNormal or "ChatFontNormal")
        box:SetWidth(500)
        box:SetScript("OnEscapePressed", function() reportWindow:Hide() end)
        -- Keep it read-only in spirit: typing restores the report.
        box:SetScript("OnTextChanged", function(self, userInput)
            if userInput and reportWindow.text then self:SetText(reportWindow.text); self:HighlightText() end
        end)
        scroll:SetScrollChild(box)
        reportWindow.box = box
    end
    reportWindow.title:SetText(title)
    reportWindow.text = text
    reportWindow.box:SetText(text)
    reportWindow:Show()
    reportWindow.box:SetFocus()
    reportWindow.box:HighlightText()
    return reportWindow
end
Slash.ShowCopyWindow = showCopyWindow

--- Everything a bug report needs, in one copyable block.
function COMMANDS.report()
    local header = {
        "Solaryn's Expedition diagnostics",
        string.format("version %s  ·  %s  ·  %s", tostring(ns.version), tostring(ns.charKey), date("%Y-%m-%d %H:%M")),
        string.format("client %s (interface %s), level %s, map %s (%s)",
            tostring((GetBuildInfo())), tostring(ns.tocVersion), tostring(ns.UnitLevelSafe()),
            tostring(ns:PlayerMapID()), ns:MapName(ns:PlayerMapID() or -1)),
        "",
    }
    local lines = {}
    for _, l in ipairs(header) do lines[#lines + 1] = l end
    lines[#lines + 1] = "== /sol api =="
    for _, l in ipairs(captureTo("api", run_api)) do lines[#lines + 1] = l end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "== /sol where =="
    for _, l in ipairs(captureTo("where", run_where)) do lines[#lines + 1] = l end
    local d = _G.SolarynDB
    if d then
        d.diagnostics = d.diagnostics or {}
        d.diagnostics.report = { when = date("%Y-%m-%d %H:%M:%S"), character = ns.charKey, version = ns.version, lines = lines }
    end
    showCopyWindow("Solaryn's Expedition — diagnostics", table.concat(lines, "\n"))
    ns:Print("diagnostics saved (written to disk on /reload) and opened for copying.")
    return lines
end

---------------------------------------------------------------------------
-- Dispatcher
---------------------------------------------------------------------------
local function dispatch(msg)
    local cmd, rest = msg:match("^(%S*)%s*(.*)$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
        ns.Panel:Toggle()
        return
    end

    local fn = COMMANDS[cmd]
    if not fn then
        ns:Print("unknown command '%s'. Type /sol help for the list.", cmd)
        return
    end
    fn(rest)
end

Slash.dispatch = dispatch
Slash.COMMANDS = COMMANDS

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------
function Slash:Initialize()
    SLASH_SOLARYNEXPEDITION1 = "/sol"
    SLASH_SOLARYNEXPEDITION2 = "/expedition"
    SlashCmdList["SOLARYNEXPEDITION"] = dispatch
end

ns:RegisterModule("Slash", Slash)

return Slash