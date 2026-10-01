--[[---------------------------------------------------------------------------
    Solaryn's Expedition — slash commands.

      /sol                 toggle the panel
      /sol help            command list
      /sol suggestions     print the current suggestions to chat
      /sol route           rebuild and print the route
      /sol next            set a waypoint to the next route stop
      /sol map             open the map at the next stop
      /sol pin <questID>   record a hand-verified objective override
      /sol chain <from> <to>
      /sol zones           list tracked zones and coverage
      /sol zone reset [all]
      /sol options         toggle the options panel
      /sol api             report live API return shapes
      /sol debug           toggle debug logging
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

function COMMANDS.help()
    printList({
        "/sol                  toggle panel",
        "/sol suggestions      print suggestions to chat",
        "/sol route            rebuild route",
        "/sol next             start the guide at the next stop",
        "/sol skip             skip the current stop",
        "/sol stop             stop the guide",
        "/sol hud              show/hide the route tracker",
        "/sol map              open map at next stop",
        "/sol pin <questID>    pin your position as an objective",
        "/sol chain <from> <to> record a quest follow-up",
        "/sol zones            zone coverage list",
        "/sol zone reset [all] clear zone data",
        "/sol options          options panel",
        "/sol api              report live API return shapes",
        "/sol where            show every location source for each quest",
        "/sol debug            toggle debug logging",
    }, "commands:")
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
function COMMANDS.api()
    ns:Print("--- API shape report ---")
    ns:Print("addon v%s, client interface %s", tostring(ns.version), tostring(ns.tocVersion))

    local caps = {}
    for k, v in pairs(ns.Has) do
        if v then table.insert(caps, k) end
    end
    table.sort(caps)
    ns:Print("capabilities present (%d): %s", #caps, table.concat(caps, ", "))

    local mapID = ns:PlayerMapID()
    ns:Print("player map: %s", tostring(mapID))
    if mapID then
        local pos = ns.Try("C_Map", "GetPlayerMapPosition", mapID, "player")
        ns:Print("  GetPlayerMapPosition -> %s (%s)",
            type(pos), pos and type(pos.GetXY) or "no GetXY")
        local cid, wp = ns.Try("C_Map", "GetWorldPosFromMapPos", mapID, pos or { x = 50, y = 50 })
        ns:Print("  GetWorldPosFromMapPos -> continentID=%s, pos=%s",
            tostring(cid), type(wp))
    end

    local cosmic = ns.Try("C_Map", "GetMapChildrenInfo", 946)
    ns:Print("  map tree from 946 (Cosmic) -> %s", type(cosmic) == "table" and (#cosmic .. " children") or "none")
    local azeroth = ns.Try("C_Map", "GetMapChildrenInfo", 947)
    ns:Print("  map tree from 947 (Azeroth) -> %s", type(azeroth) == "table" and (#azeroth .. " children") or "none")
    ns:Print("  zones known: %d  (current map type %s)", #ns.ZoneData:WorldZones(),
        tostring(mapID and ns.ZoneData:Get(mapID) and ns.ZoneData:Get(mapID).mapType))
    ns:Print("  exploration: tracking %s, %d zones recorded, fog-of-war import %s",
        ns.Settings().trackingEnabled and "on" or "off", ns.Explored:Summary().zones,
        ns.Has.exploredAreasAtPos and "available" or "NOT available")

    local n = ns.Try("C_QuestLog", "GetNumQuestLogEntries")
    ns:Print("quest log entries: %s", tostring(n))
    ns:Print("panel built: %s", tostring(ns.Panel:CurrentTab() ~= nil))
    ns:Print("zones loaded: %s", tostring(ns.ZoneData:Name(mapID or -1)))
end

--- For each quest in the log, show what every location source returns, so
-- we can see which sources this client actually supports.
function COMMANDS.where()
    local yes = function(cap) return ns.Has[cap] and "|cff40ff40yes|r" or "|cffff4040no|r" end
    ns:Print("--- quest location sources ---")
    ns:Print("GetQuestsOnMap %s  GetNextWaypoint %s  GetNextWaypointForMap %s",
        yes("questsOnMap"), yes("nextWaypointAny"), yes("nextWaypoint"))
    ns:Print("GetQuestUiMapID %s  C_TaskQuest %s  C_QuestLog.IsComplete %s  UiMapPoint %s",
        yes("questUiMapID"), yes("taskQuestLocation"), yes("questIsComplete"), yes("uiMapPoint"))

    local playerMap = ns:PlayerMapID()
    ns:Print("you are on map %s (%s)", tostring(playerMap), ns:MapName(playerMap or -1))
    if ns.Has.questsOnMap and playerMap then
        local list = ns.Try("C_QuestLog", "GetQuestsOnMap", playerMap)
        ns:Print("GetQuestsOnMap(%s) -> %s markers", tostring(playerMap),
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
            table.insert(parts, ns.QuestData:IsComplete(e.questID) and "done" or "open")
            DEFAULT_CHAT_FRAME:AddMessage(string.format("  %d %s: %s",
                e.questID, ns:Truncate(e.title or "?", 24), table.concat(parts, "  ")))
        end
    end
    if n == 0 then ns:Print("quest log is empty (or not loaded yet).") end
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
        COMMANDS.help()
        return
    end
    fn(rest)
end

Slash.dispatch = dispatch

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