--[[---------------------------------------------------------------------------
    Test harness: a mock WoW API sufficient to load and exercise Solaryn's Expedition
    outside the game. Run with:  lua5.1 test/harness.lua

    This is not a complete WoW emulation. It implements the specific functions
    the addon calls, plus a fake quest log with real-looking data, so we can
    verify that the addon loads, that modules initialize in order, and that the
    scoring/route/tracking logic produces sane output.
-----------------------------------------------------------------------------]]

package.path = "./?.lua;./test/?.lua;" .. package.path

local Mock = require("mockenv")
Mock.install()

local playerState = Mock.playerState

---------------------------------------------------------------------------
-- The mock WoW environment (widgets, C_Map, C_QuestLog, zones) lives in
-- test/mockenv.lua and is shared with test/load_addon.lua.

---------------------------------------------------------------------------
-- Load the addon
---------------------------------------------------------------------------
local toc = io.open("SolarynExpedition.toc", "r")
local tocText = toc:read("*a")
toc:close()

_G.ns = nil

local files = {}
for line in tocText:gmatch("[^\r\n]+") do
    local f = line:match("^([^#%s].*%.lua)%s*$")
    if f then table.insert(files, f) end
end

print("Loading " .. #files .. " files in TOC order:")
for _, f in ipairs(files) do
    local chunk, err = loadfile(f)
    if not chunk then
        print("  LOAD FAIL " .. f .. ": " .. tostring(err))
        os.exit(1)
    end
    -- IMPORTANT: the real client passes ONLY the addon name to each file.
    -- Passing ns as a second argument here once hid a nil-namespace crash
    -- that only appeared in-game, so keep this faithful.
    local ok, runErr = pcall(chunk, "SolarynExpedition")
    if not ok then
        print("  RUN FAIL " .. f .. ": " .. tostring(runErr))
        os.exit(1)
    end
    print("  ok  " .. f)
end

---------------------------------------------------------------------------
-- Fire lifecycle
---------------------------------------------------------------------------
print("\nFiring ADDON_LOADED + PLAYER_LOGIN...")
ns:Fire("ADDON_LOADED", "SolarynExpedition")
ns.playerName = "Testchar"
ns.realmName = "Testrealm"
ns.charKey = "Testchar-Testrealm"
ns:Fire("PLAYER_LOGIN")

_G.SolarynCharDB.zones = _G.SolarynCharDB.zones or {}
local accDB = _G.SolarynDB
accDB.characters[ns.charKey] = accDB.characters[ns.charKey] or { zones = {}, lastSeen = 0 }

---------------------------------------------------------------------------
-- Assertions
---------------------------------------------------------------------------
local pass, fail = 0, 0

local function check(label, cond, detail)
    if cond then
        pass = pass + 1
        print("  PASS  " .. label .. (detail and ("  (" .. detail .. ")") or ""))
    else
        fail = fail + 1
        print("  FAIL  " .. label .. (detail and ("  (" .. detail .. ")") or ""))
    end
end

print("\n== capability probe ==")
for _, cap in ipairs({ "questObjectives", "nextWaypoint", "setUserWaypoint", "mapChildrenInfo", "questInfo" }) do
    check("cap " .. cap, ns.Has[cap] == true, tostring(ns.Has[cap]))
end
-- Regression guard: these APIs do NOT exist on Forever 1.60.1. Asserting the
-- addon doesn't depend on them means a future refactor can't reintroduce a
-- call that silently returns nil in-game.
check("no dependency on nonexistent GetAllMapInfo",
    ns.Has.allMapInfo == nil or ns.Has.allMapInfo == false)
check("no dependency on nonexistent GetActiveQuestMapIDs",
    ns.Has.activeQuestMaps == nil or ns.Has.activeQuestMaps == false)

print("\n== settings defaults ==")
local s = ns.Settings()
check("maxRouteQuests defaulted", s.maxRouteQuests == 12, tostring(s.maxRouteQuests))
check("panelLocked defaulted", s.panelLocked == false)
check("no leftover debug key", s.debug == nil or s.debug == false)

print("\n== zone data ==")
ns.ZoneData:Load()
-- The map tree is walked from the Cosmic root (946), so a real build must
-- discover zones without any hardcoded list.
check("map tree walked from cosmic root", ns:Count(ns.ZoneData:Maps()) > 0,
    tostring(ns:Count(ns.ZoneData:Maps())))
check("zone 1 classified as world (UIMapType.Zone)",
    ns.ZoneData:IsWorldZone(1) == true)
check("dungeon excluded (UIMapType.Dungeon)", not ns.ZoneData:IsWorldZone(84))
check("continent excluded", not ns.ZoneData:IsWorldZone(100))
check("zone 1 name", ns.ZoneData:Name(1) == "Elwynn Forest", ns.ZoneData:Name(1))
check("zone names cached for MapName", ns:MapName(2) == "Westfall", ns:MapName(2))
-- Children() filters to world zones, so the dungeon (mapType 4) is excluded:
-- Eastern Kingdoms: Elwynn, Westfall, Redridge, Duskwood, Stranglethorn (+ a dungeon).
check("children filtered to world zones", #ns.ZoneData:Children(100) == 5,
    tostring(#ns.ZoneData:Children(100)))
check("children excludes dungeons", (function()
    for _, z in ipairs(ns.ZoneData:Children(100)) do
        if z.mapID == 84 then return false end
    end
    return true
end)())
check("neighbours exclude self", (function()
    for _, z in ipairs(ns.ZoneData:Neighbours(1)) do
        if z.mapID == 1 then return false end
    end
    return true
end)())

print("\n== quest log scan ==")
local entries, byID = ns.QuestData:Scan()
check("scanned 5 quests", #entries == 5, tostring(#entries))
check("has Kobold Camp Cleanup", byID[1001] ~= nil)
check("task quest flagged", byID[1004] and byID[1004].isTask == true)
check("story quest flagged", byID[1005] and byID[1005].isStory == true)

print("\n== completion detection ==")
ns.QuestData:Objectives(1001)
ns.QuestData:Objectives(1002)
ns.QuestData:Objectives(1003)
check("1002 complete", ns.QuestData:IsComplete(1002) == true)
check("1001 incomplete", ns.QuestData:IsComplete(1001) == false)
check("1003 partial progress", math.abs((ns.QuestData:Progress(1003) or 0) - 0.5) < 0.01,
    tostring(ns.QuestData:Progress(1003)))
-- "Kobold Vermin: 4/8" already contains its own counts, so the formatter must
-- not append a second "(4/8)".
check("next objective text not double-counted",
    ns.QuestData:NextObjectiveText(1001) == "Kobold Vermin: 4/8",
    tostring(ns.QuestData:NextObjectiveText(1001)))
check("bare objective text gets counts appended",
    ns.QuestData:NextObjectiveText(1003) == "Weeds Divided",
    tostring(ns.QuestData:NextObjectiveText(1003)))

print("\n== vector / multi-return handling ==")
-- Regression guard: C_Map.GetWorldPosFromMapPos returns (continentID, pos).
-- Collapsing to one value hands VecXY a bare number, which crashes with
-- "attempt to index local 'v' (a number value)". These cover both shapes.
check("VecXY handles Vector2DMixin", (function()
    local x, y = ns:VecXY({ GetXY = function() return 3, 4 end })
    return x == 3 and y == 4
end)())
check("VecXY handles plain x/y table", (function()
    local x, y = ns:VecXY({ x = 5, y = 6 })
    return x == 5 and y == 6
end)())
check("VecXY handles bare number pair", (function()
    local x, y = ns:VecXY(7, 8)
    return x == 7 and y == 8
end)())
check("VecXY rejects a lone number (the crash case)", (function()
    local ok = pcall(ns.VecXY, ns, 1)
    return ok
end)())
check("VecXY rejects nil", ns:VecXY(nil) == nil)
check("VecXY survives a GetXY that throws", (function()
    local ok, x = pcall(ns.VecXY, ns, { GetXY = function() error("boom") end })
    return ok and x == nil
end)())
-- WorldPos must read the SECOND return value, not the continentID.
playerState.mapID, playerState.mapX, playerState.mapY = 1, 0.5, 0.5
check("PlayerPosition succeeds with 2-return API", (function()
    local ok, pos = pcall(ns.PlayerPosition, ns, 1)
    return ok and pos ~= nil
end)())
check("world position is a table, not a number", (function()
    local pos = ns:PlayerPosition(1)
    return pos and type(pos.world) == "table"
end)())
check("world coords are numbers", (function()
    local pos = ns:PlayerPosition(1)
    return pos and type(pos.world.x) == "number" and type(pos.world.y) == "number"
end)())

print("\n== distances ==")
playerState.mapID, playerState.mapX, playerState.mapY = 1, 0.5, 0.5
local d = ns.QuestData:ObjectiveDistance(1001)
-- Player at (0.5,0.5) in a 1000-unit zone; wp at (0.3,0.4): sqrt(200^2+100^2)=223.6
check("distance to Kobold Camp", d and math.abs(d - 223.6) < 1.0, tostring(d and string.format("%.1f", d)))
-- 223.6 truncates to "223 yd" with %d; the point is that it stays in yards
-- rather than showing as "0.1 mi".
check("223 yd stays in yards", ns:FormatDistance(223.6) == "223 yd", ns:FormatDistance(223.6))
check("1000 yd still in yards", ns:FormatDistance(1000) == "1000 yd", ns:FormatDistance(1000))
check("5000 yd shows as miles", ns:FormatDistance(5000) == "2.8 mi", ns:FormatDistance(5000))

print("\n== suggestions ==")
local sugg = ns.Suggest:Compute()
check("got suggestions", #sugg > 0, tostring(#sugg))
local kinds = {}
for _, sg in ipairs(sugg) do kinds[sg.kind] = true end
check("turn-in suggestion present", kinds["turnout"] == true)
check("objective suggestion present", kinds["objective"] == true)
check("unlock suggestion present", kinds["unlock"] == true)
check("task quest deprioritised out", (function()
    for _, sg in ipairs(sugg) do
        if sg.questID == 1004 then return false end
    end
    return true
end)(), "quest 1004 is a task and ignoreTasks=true")
check("first suggestion is the turn-in", sugg[1] and sugg[1].kind == "turnout",
    sugg[1] and sugg[1].kind or "nil")

print("\n== route ==")
local route = ns.Route:Build()
check("route has stops", #route.stops > 0, tostring(#route.stops))
check("route respects maxRouteQuests", #route.questIDs <= s.maxRouteQuests, tostring(#route.questIDs))
check("stops are ordered 1..n", (function()
    for i, st in ipairs(route.stops) do
        if st.index ~= i then return false end
    end
    return true
end)())
check("route includes the ready turn-in", (function()
    for _, st in ipairs(route.stops) do
        if st.questID == 1002 and st.kind == "turnin" then return true end
    end
    return false
end)())
check("waypoint set works", ns.Route:GoToStop(route.stops[1]) == true)
check("waypoint actually recorded", playerState.waypoint ~= nil)

print("\n== overrides ==")
ns.Overrides:Set(1001, {
    objectives = { { uiMapID = 1, x = 0.255, y = 0.355, label = "corrected" } },
    note = "test override",
})
local resolved, wasOverridden = ns.Overrides:ResolveObjectives(1001, {
    { uiMapID = 1, x = 30, y = 40 } })
check("override replaces client data", wasOverridden == true)
check("override coords used", resolved[1].x == 0.255 and resolved[1].y == 0.355)
ns.Overrides:Clear(1001)
local _, wasOverridden2 = ns.Overrides:ResolveObjectives(1001, { { uiMapID = 1, x = 0.3, y = 0.4 } })
check("clear restores client data", wasOverridden2 == false)

print("\n== chains ==")
ns.Chains:Link(1001, 1003)
check("chain recorded", #ns.Chains:FollowUps(1001) == 1, tostring(#ns.Chains:FollowUps(1001)))
ns.Chains:Link(1003, 1005)
local depths = ns.Chains:Depths()
check("chain depths computed", depths[1003] ~= nil, tostring(depths[1003]))
check("chain link is idempotent", (function()
    ns.Chains:Link(1001, 1003)
    return #ns.Chains:FollowUps(1001) == 1
end)())

print("\n== zone tracking ==")
-- Move the player around Elwynn and force samples so coverage builds up.
for i = 1, 40 do
    playerState.mapX = ((i % 10) * 10 + 5) / 100
    playerState.mapY = ((math.floor(i / 10)) * 10 + 5) / 100
    ns.Explored:SampleNow()
end
local cov = ns.Explored:Coverage(1)
check("coverage recorded for zone 1", cov ~= nil, tostring(cov))
check("coverage is a fraction", cov == nil or (cov >= 0 and cov <= 1))
-- 40 samples spread over the map land in 25 distinct cells of the 8x8 grid
-- (some points share a cell). With 0-1 client coordinates scaled as if they
-- were 0-100, all 40 fell in one cell and coverage read 0%.
check("samples spread across the grid", ns.Explored:Detail(1).cells >= 20,
    tostring(ns.Explored:Detail(1).cells) .. " cells")
check("coverage reflects the ground walked", (cov or 0) > 0.3, tostring(cov))
check("a sub-map sample counts toward its zone", (function()
    -- Standing in a micro map (type 5) inside Elwynn records Elwynn.
    local tree = Mock.MAP_TREE
    tree[1] = { { mapID = 9001, name = "Goldshire", mapType = 5, parentMapID = 1 } }
    ns.ZoneData:Load()
    local before = ns.Explored:Detail(1).hits
    local oldMap = playerState.mapID
    playerState.mapID = 9001
    ns.Explored:SampleNow()
    playerState.mapID = oldMap
    tree[1] = nil
    ns.ZoneData:Load()
    return ns.Explored:Detail(1).hits == before + 1
end)())
check("zones still classify without the Cosmic root (Classic clients)", (function()
    local tree = Mock.MAP_TREE
    local cosmic = tree[946]
    tree[946] = nil
    ns.ZoneData:Load()
    local ok = ns.ZoneData:IsWorldZone(1) and #ns.ZoneData:WorldZones() >= 3
    tree[946] = cosmic
    ns.ZoneData:Load()
    return ok, tostring(#ns.ZoneData:WorldZones()) .. " zones"
end)())
check("dungeon not tracked", ns.Explored:Coverage(84) == nil)
local summary = ns.Explored:Summary()
check("summary has a zone count", summary.zones >= 1, tostring(summary.zones))
check("coverage is monotone", ns.Explored:Coverage(1) >= (cov or 0))

print("\n== secret value guards ==")
check("nil is not safe", ns.IsSafe(nil) == false)
check("number is safe", ns.IsSafe(5) == true)
check("SafeNum rejects non-number", ns.SafeNum("hi") == nil)
check("SafeNum accepts number", ns.SafeNum(7) == 7)
check("SafeStr of nil is empty", ns.SafeStr(nil) == "")

print("\n== slash commands ==")
for _, cmd in ipairs({ "help", "suggestions", "route", "next", "map", "zones", "debug" }) do
    local ok = pcall(function() ns.Slash.dispatch(cmd) end)
    check("/sol " .. cmd .. " runs", ok)
end
local function chatAfter(fn)
    local before = #DEFAULT_CHAT_FRAME.messages
    fn()
    local out = {}
    for i = before + 1, #DEFAULT_CHAT_FRAME.messages do out[#out + 1] = DEFAULT_CHAT_FRAME.messages[i] end
    return table.concat(out, "\n")
end
check("an unknown command says so", (function()
    local text = chatAfter(function() ns.Slash.dispatch("zzzznope") end)
    return text:find("unknown command 'zzzznope'", 1, true) ~= nil, text
end)())
check("/sol empty toggles panel", pcall(ns.Slash.dispatch, ""))
-- /sol pin was documented but never registered, and this test used to pass
-- just because the fallback didn't error.
check("/sol pin with no quest lists your quests", (function()
    local text = chatAfter(function() ns.Slash.dispatch("pin") end)
    return text:find("Usage: /sol pin", 1, true) ~= nil, text
end)())
check("/sol pin <questID> records your position for that quest", (function()
    ns.Slash.dispatch("pin 1004")
    local rec = ns.Overrides:Get(1004)
    ns.Overrides:Clear(1004)
    return rec ~= nil
end)())
check("every command is in the help, and every help entry is a command", (function()
    local inHelp = {}
    for _, g in ipairs(ns.Slash.HELP) do
        for _, c in ipairs(g.commands) do inHelp[c[1]] = true end
    end
    for name in pairs(ns.Slash.COMMANDS) do
        if not inHelp[name] then return false, "undocumented: " .. name end
    end
    for name in pairs(inHelp) do
        if name ~= "" and not ns.Slash.COMMANDS[name] then return false, "documented but missing: " .. name end
    end
    return true
end)())
check("every command is in README.md", (function()
    local f = io.open("README.md")
    if not f then return false, "no README.md" end
    local readme = f:read("*a"); f:close()
    for _, g in ipairs(ns.Slash.HELP) do
        for _, c in ipairs(g.commands) do
            local usage = "/sol" .. (c[1] ~= "" and (" " .. c[1]) or "")
            if not readme:find("`" .. usage, 1, true) then return false, "README lacks " .. usage end
        end
    end
    return true
end)())
check("/sol help <command> gives details and an example", (function()
    local text = chatAfter(function() ns.Slash.dispatch("help pin") end)
    return text:find("/sol pin <questID>", 1, true) and text:find("Example", 1, true), text
end)())
-- In game there was no way to get /sol api and /sol where output out of the
-- client; they're now saved to SavedVariables and /sol report opens a copy.
check("/sol api output is saved for later", (function()
    ns.Slash.dispatch("api")
    local d = _G.SolarynDB.diagnostics and _G.SolarynDB.diagnostics.api
    local all = d and table.concat(d.lines, "\n") or ""
    return d and all:find("capabilities present", 1, true) and not all:find("|c", 1, true)
        and all:find("GetMapLevels", 1, true) and all:find("continent:", 1, true) and all:find("next zones:", 1, true)
        and d.version == ns.version, all:sub(1, 120)
end)())
check("/sol where output is saved, one line per quest", (function()
    ns.Slash.dispatch("where")
    local d = _G.SolarynDB.diagnostics and _G.SolarynDB.diagnostics.where
    local all = d and table.concat(d.lines, "\n") or ""
    return all:find("Kobold Camp Cleanup", 1, true) ~= nil and all:find("GetQuestsOnMap", 1, true) ~= nil, all:sub(1, 160)
end)())
check("/sol report saves both and opens them ready to copy", (function()
    ns.Slash.dispatch("report")
    local r = _G.SolarynDB.diagnostics.report
    local all = table.concat(r.lines, "\n")
    local w = ns.Slash.ShowCopyWindow("t", all)       -- returns the same window
    return all:find("== /sol api ==", 1, true) and all:find("== /sol where ==", 1, true)
        and w.shown and w.box:GetText() == all and w.box.highlighted and w.box.focused
end)())
check("/sol help groups every command", (function()
    local text = chatAfter(function() ns.Slash.dispatch("help") end)
    for _, g in ipairs(ns.Slash.HELP) do
        if not text:find(g.group, 1, true) then return false, "missing group " .. g.group end
    end
    return true
end)())

print("\n== empty-state rendering (regression) ==")
-- In-game this crashed: /sol -> Toggle -> SetTab -> renderNext took the
-- "Nothing to suggest" branch and indexed content.inner before buildPanel had
-- produced it. A naive test misses this because earlier tests already built the
-- panel, so this one drives Refresh directly the way a pre-build event would.
check("renderNext with zero suggestions does not throw", (function()
    local real = ns.Suggest.Compute
    ns.Suggest.Compute = function() return {} end
    -- Refresh is the public entry point events use; before buildPanel it must
    -- no-op rather than index a nil inner frame.
    local ok, err = pcall(function() ns.Panel:Refresh() end)
    ns.Suggest.Compute = real
    return ok, err
end)())
check("Widgets:Text survives nil parent", (function()
    local ok = pcall(function() ns.Widgets:Text(nil, "x") end)
    return ok
end)())
check("panel toggles repeatedly without error", (function()
    local ok = pcall(function()
        ns.Panel:Toggle(false); ns.Panel:Toggle(true); ns.Panel:Toggle(true)
    end)
    return ok
end)())
check("panel renders empty route after build", (function()
    local real = ns.Route.Get
    ns.Route.Get = function() return { stops = {}, built = 0 } end
    local ok = pcall(function() ns.Panel:SetTab("route") end)
    ns.Route.Get = real
    ns.Panel:SetTab("next")
    return ok
end)())

print("\n== no render recursion (regression) ==")
-- In-game this blew the C stack: Compute -> Fire("suggestions_updated")
-- -> Panel:Refresh -> renderNext -> Compute -> ... forever.
-- Opening the panel must call Compute a bounded number of times.
check("one panel open does not recurse", (function()
    local real = ns.Suggest.Compute
    local calls = 0
    ns.Suggest.Compute = function(self) calls = calls + 1; return real(self) end
    local ok = pcall(function() ns.Panel:Toggle(true) end)
    ns.Suggest.Compute = real
    return ok and calls <= 3, "Compute called " .. calls .. " times"
end)())
check("Compute re-entry returns cached result", (function()
    ns.Suggest._computing = true          -- simulate being mid-computation
    local res = ns.Suggest:Compute()
    ns.Suggest._computing = false
    return type(res) == "table"
end)())
check("ComputeQuietly does not notify listeners", (function()
    local fired = false
    local h = function() fired = true end
    ns:RegisterEvent("suggestions_updated", h)
    ns.Suggest:ComputeQuietly()
    ns:UnregisterEvent("suggestions_updated")
    return fired == false
end)())
check("Recompute does notify listeners", (function()
    local fired = false
    local h = function() fired = true end
    ns:RegisterEvent("suggestions_updated", h)
    ns.Suggest:Recompute()
    ns:UnregisterEvent("suggestions_updated")
    return fired == true
end)())

print("\n== saved position restore (regression) ==")
-- In-game: buildPanel called p:SetPoint(...) on the plain SavedVariables
-- table {point=,x=,y=}, which has no methods -> "attempt to call a nil value",
-- and because it threw mid-build the panel never finished (panelBuilt stayed
-- false), so every later render failed too.
local function freshPanel(savedPoint)
    -- Rebuild the DB with the given saved position, then load fresh.
    _G.SolarynDB = _G.SolarynDB or {}
    _G.SolarynDB.settings = _G.SolarynDB.settings or {}
    _G.SolarynDB.settings.panelPoint = savedPoint
    _G.SolarynExpedition = nil
    _G.ns = nil
    for line in io.open("SolarynExpedition.toc"):read("*a"):gmatch("[^\r\n]+") do
        local f = line:match("^([^#%s].*%.lua)%s*$")
        if f then
            local c, e = loadfile(f)
            assert(c, tostring(e))
            assert(pcall(c, "SolarynExpedition"))
        end
    end
    ns:Fire("ADDON_LOADED", "SolarynExpedition")
    ns.playerName, ns.realmName, ns.charKey = "P", "R", "P-R"
    ns:Fire("PLAYER_LOGIN")
    return ns.Panel.initError
end

check("builds with a valid saved position", (function()
    local err = freshPanel({ point = "CENTER", x = 100, y = 200 })
    return err == nil, err
end)())
check("saved position is a table with no widget methods", (function()
    local p = { point = "CENTER", x = 1, y = 2 }
    return type(p) == "table" and p.SetPoint == nil
end)())
check("survives a corrupt saved position", (function()
    local err = freshPanel({ point = "CENTER" })          -- missing x/y
    return err == nil, err
end)())
check("survives a garbage saved position", (function()
    local err = freshPanel({ point = 42, x = "nope", y = {} })
    return err == nil, err
end)())
check("survives a non-table saved position", (function()
    local err = freshPanel("garbage")
    return err == nil, err
end)())
check("options panel builds after position restore", (function()
    _G.SolarynDB.settings.optionsPoint = { point = "CENTER", x = 10, y = 20 }
    ns.Options:Toggle(true)
    local ok = pcall(function() ns.Options:Toggle(false) end)
    return ok
end)())

print("\n== panel dragging & minimap placement ==")
-- Note on defence-in-depth: reverting only the panel to Compute() does NOT
-- recurse, because Compute() itself also carries a re-entrancy guard. That is
-- intended; the two guards are independent, so the test asserts the guard
-- exists in both places rather than expecting a single revert to blow the stack.
check("panel renders via ComputeQuietly", (function()
    local src = io.open("UI_Panel.lua"):read("*a")
    return src:find("ns.Suggest:ComputeQuietly()") ~= nil
end)())
check("Compute has its own re-entrancy guard", (function()
    -- Behavioural, not grep: force a re-entrant Compute and confirm it returns
    -- the cached result instead of recursing. (A source-grep version of this
    -- passed for the wrong reason — it matched the guard in Recompute.)
    local realFire = ns.Fire
    local depth, maxDepth = 0, 0
    ns.Fire = function(self, event, ...)
        if event == "suggestions_updated" then
            depth = depth + 1
            maxDepth = math.max(maxDepth, depth)
            ns.Suggest:Compute()          -- deliberately re-enter
            depth = depth - 1
        end
        return realFire(self, event, ...)
    end
    local ok = pcall(function() ns.Suggest:Compute() end)
    ns.Fire = realFire
    return ok and maxDepth == 1, "max re-entrancy depth " .. maxDepth
end)())
check("Refresh has a re-entrancy guard", (function()
    local src = io.open("UI_Panel.lua"):read("*a")
    return src:find("if refreshing then return end") ~= nil
end)())
check("dragging the title bar moves the panel frame, not the bar", (function()
    ns.Panel:Toggle(true)
    local header = ns.Panel:GetHeader()
    local frame = ns.Panel:GetFrame()
    if not header or not frame then return false, "missing accessor" end
    header.scripts.OnDragStart(header)
    local movedFrame = frame.moving == true and not header.moving
    header.scripts.OnDragStop(header)
    return movedFrame and frame.moving == false
end)())
check("title-bar drag saves a v2 position", (function()
    local p = ns.Settings().panelPoint
    return type(p) == "table" and p.v == 2 and type(p.x) == "number", p and tostring(p.v)
end)())
check("locked panel does not start moving", (function()
    local header, frame = ns.Panel:GetHeader(), ns.Panel:GetFrame()
    ns.Settings().panelLocked = true
    header.scripts.OnDragStart(header)
    local moved = frame.moving
    ns.Settings().panelLocked = false
    return not moved
end)())
check("options window drags from its title bar", (function()
    ns.Options:Toggle(true)
    local f = ns.Options:GetFrame()
    f.titleBar.scripts.OnDragStart(f.titleBar)
    local ok = f.moving == true
    f.titleBar.scripts.OnDragStop(f.titleBar)
    ns.Options:Toggle(false)
    return ok
end)())

-- Minimap button: centre offset from the minimap centre, from the last anchor.
local function minimapOffset()
    local b = ns.MinimapButton:GetButton()
    local last = b.points[#b.points]
    return last[3], last[2], last[4] or 0, last[5] or 0
end
check("minimap ring radius sits just outside the minimap edge", (function()
    local r = ns.MinimapButton:GetRingRadius()
    return r == 144 / 2 + 5, tostring(r)
end)())
check("minimap button is anchored to the minimap centre on the ring", (function()
    ns.MinimapButton:Update()
    local rel, parent, x, y = minimapOffset()
    local dist = math.sqrt(x * x + y * y)
    return rel == "CENTER" and parent == Minimap and math.abs(dist - ns.MinimapButton:GetRingRadius()) < 0.01,
        ("dist %.1f, anchored to %s"):format(dist, tostring(rel))
end)())
check("minimap button angle maps to the right spot", (function()
    ns.MinimapButton:SetAngle(90)                  -- straight up
    local _, _, x, y = minimapOffset()
    return math.abs(x) < 0.01 and y > 70, ("%.1f, %.1f"):format(x, y)
end)())
check("minimap button has the gold tracking-border ring", (function()
    local b = ns.MinimapButton:GetButton()
    return b.border and b.border.texture == "Interface\\Minimap\\MiniMap-TrackingBorder"
end)())
check("minimap button is parented to the minimap", ns.MinimapButton:GetButton().parent == Minimap)
check("minimap drag does not free-move the button", (function()
    local b = ns.MinimapButton:GetButton()
    b.scripts.OnDragStart(b)
    local freeMoving = b.moving
    local hasUpdate = b.scripts.OnUpdate ~= nil
    b.scripts.OnDragStop(b)
    return not freeMoving and hasUpdate and b.scripts.OnUpdate == nil
end)())
check("dragging snaps to the ring toward the cursor", (function()
    local r = ns.MinimapButton:GetRingRadius()
    local results = {}
    -- Cursor far east, due north, and barely off-centre to the south-west:
    -- the button must land on the ring every time, in the cursor's direction.
    for _, c in ipairs({ { 1900, 600, 0 }, { 1000, 900, 90 }, { 990, 590, 225 } }) do
        Mock.cursor.x, Mock.cursor.y = c[1], c[2]
        ns.MinimapButton:DragStep()
        local _, _, x, y = minimapOffset()
        local dist = math.sqrt(x * x + y * y)
        local angle = ns.Settings().minimapPos
        if math.abs(dist - r) > 0.01 or math.abs(angle - c[3]) > 0.5 then
            return false, ("cursor %d,%d -> angle %.1f dist %.1f"):format(c[1], c[2], angle, dist)
        end
    end
    return true
end)())
check("minimap button re-anchors on resize", (function()
    return pcall(function() ns:Fire("DISPLAY_SIZE_CHANGED") end)
end)())
check("minimap right-click opens options", (function()
    ns.Options:Toggle(false)
    ns.MinimapButton:GetButton():Click("RightButton")
    local shown = ns.Options:GetFrame():IsShown()
    ns.Options:Toggle(false)
    return shown
end)())

print("\n== panel rendering ==")
-- Refresh swallows render errors (a broken row must not take down the addon),
-- so each tab asserts Panel.lastError explicitly.
for _, key in ipairs({ "next", "route", "zones" }) do
    check("tab renders cleanly: " .. key, (function()
        ns.Panel:Toggle(true)
        ns.Panel:SetTab(key)
        return ns.Panel.lastError == nil, ns.Panel.lastError
    end)())
end
check("next tab shows one row per suggestion", (function()
    ns.Panel:SetTab("next")
    local n = #ns.Panel:ActiveRows()
    return n > 0 and n == #ns.Suggest:ComputeQuietly(), tostring(n)
end)())
check("route tab shows one row per stop", (function()
    ns.Route:Build()
    ns.Panel:SetTab("route")
    return #ns.Panel:ActiveRows() == ns.Route:Count(), tostring(#ns.Panel:ActiveRows())
end)())
check("rows are pooled, not recreated, across refreshes", (function()
    ns.Panel:SetTab("next")
    local inner = ns.Panel:GetContent().inner
    local before = #inner.children
    for _ = 1, 5 do ns.Panel:Refresh() end
    return #inner.children == before, ("%d -> %d children"):format(before, #inner.children)
end)())
check("tab labels show counts", (function()
    ns.Panel:Refresh()
    local t = ns.Panel:GetTabButton("route").text.text or ""
    return t:find(tostring(ns.Route:Count())) ~= nil, t
end)())
check("empty route shows a build action and no rows", (function()
    local real = ns.Route.Get
    ns.Route.Get = function() return { stops = {}, built = 0 } end
    ns.Panel:SetTab("route")
    local rows = #ns.Panel:ActiveRows()
    ns.Route.Get = real
    return rows == 0 and ns.Panel.lastError == nil
end)())
check("switching tabs leaves no stale rows", (function()
    ns.Panel:SetTab("next")
    ns.Panel:SetTab("zones")
    local allowed = { zone = true, level = true, header = true }
    for _, row in ipairs(ns.Panel:ActiveRows()) do
        if not allowed[row.poolKind] then return false, row.poolKind end
    end
    return true
end)())
check("clicking a route row sets a waypoint", (function()
    ns.Panel:SetTab("route")
    playerState.waypoint = nil
    local row = ns.Panel:ActiveRows()[1]
    if not row then return false, "no rows" end
    row:Click("LeftButton")
    return playerState.waypoint ~= nil
end)())
check("stale v1 saved position is ignored", (function()
    local err = freshPanel({ point = "CENTER", x = 1650, y = 900 })
    ns.Panel:Toggle(true)
    local f = ns.Panel:GetFrame()
    local last = f.points[#f.points]
    return err == nil and last[4] == -250 and last[5] == 60,
        ("restored to %s,%s"):format(tostring(last[4]), tostring(last[5]))
end)())
check("options reset restores defaults but keeps layout", (function()
    local s = ns.Settings()
    s.wDistance = 2.5
    s.minimapPos = 42
    ns.Options:ResetToDefaults()
    return s.wDistance == ns.Defaults.settings.wDistance and s.minimapPos == 42
end)())

print("\n== quest freshness & locations (regression) ==")
local function findSuggestion(list, questID, kind)
    for _, sg in ipairs(list) do
        if sg.questID == questID and (not kind or sg.kind == kind) then return sg end
    end
end
-- In game the first compute after login showed no hand-ins: IsComplete read
-- objectives that nothing had loaded yet, so every quest looked unfinished
-- until a manual Refresh.
check("first compute from a cold cache lists the ready hand-in", (function()
    for _, e in pairs(ns.QuestData.cache) do e.objectives, e.objGen = nil, nil end
    ns.QuestData:Invalidate()
    local sg = findSuggestion(ns.Suggest:ComputeQuietly(), 1002, "turnout")
    return sg ~= nil
end)())
-- Objectives used to be read once per session, so progress never moved.
check("objective progress updates after QUEST_LOG_UPDATE", (function()
    local o = Mock.QUESTS[1001].objectives[1]
    local oldText, oldN = o.text, o.numFulfilled
    ns.QuestData:NextObjectiveText(1001)             -- prime the cache
    o.text, o.numFulfilled = "Kobold Vermin: 5/8", 5
    ns:Fire("QUEST_LOG_UPDATE")
    local text = ns.QuestData:NextObjectiveText(1001)
    o.text, o.numFulfilled = oldText, oldN
    ns:Fire("QUEST_LOG_UPDATE")
    return text and text:find("5/8") ~= nil, tostring(text)
end)())
check("objective locations come from world-map markers", (function()
    ns.QuestData:Invalidate()
    local wp = ns.QuestData:PrimaryWaypoint(1001)
    return wp and wp.source == "poi" and wp.uiMapID == 1, wp and wp.source
end)())
check("finished quest's hand-in location comes from its marker", (function()
    local t = ns.QuestData:TurnInLocation(1002)
    return t ~= nil and t.x ~= nil
end)())
check("unfinished quest has no made-up hand-in location", ns.QuestData:TurnInLocation(1001) == nil)
check("quest with no marker falls back to a routing waypoint", (function()
    Mock.NO_POI[1003] = true
    Mock.ROUTES[1003] = { [1] = { 0.95, 0.5 } }       -- exit east from Elwynn toward Westfall
    ns.QuestData:Invalidate()
    local wp = ns.QuestData:PrimaryWaypoint(1003)
    Mock.NO_POI[1003], Mock.ROUTES[1003] = nil, nil
    ns.QuestData:Invalidate()
    return wp and wp.source == "mapWaypoint" and wp.uiMapID == 1, wp and wp.source
end)())
-- In game, quests without a location were dropped from the list entirely.
check("quest with no location at all is still suggested", (function()
    Mock.NO_POI[1005] = true
    ns.QuestData:Invalidate()
    local sg = findSuggestion(ns.Suggest:ComputeQuietly(), 1005)
    Mock.NO_POI[1005] = nil
    ns.QuestData:Invalidate()
    return sg ~= nil and sg.x == nil
end)())
check("/sol where runs", pcall(ns.Slash.dispatch, "where"))

print("\n== route guide ==")
local function standAt(stop)
    playerState.mapID, playerState.mapX, playerState.mapY = stop.uiMapID, stop.x, stop.y
end
local homeMap, homeX, homeY = playerState.mapID, playerState.mapX, playerState.mapY
local function goHome()
    playerState.mapID, playerState.mapX, playerState.mapY = homeMap, homeX, homeY
end
local function freshRoute()
    goHome()
    ns.Settings().autoAdvance, ns.Settings().advanceWhenDone, ns.Settings().arriveRadius = true, false, 30
    ns.QuestData:Invalidate()
    local st = ns.Route:Build()
    st.guiding, st.current = nil, 1
    ns.Route:Save(st)
    return ns.Route:Get().stops
end
local function waypointIs(stop)
    local w = playerState.waypoint
    local x = w and (w.position and w.position.x or w.x)
    return w ~= nil and x == stop.x
end

check("starting the guide points the waypoint at stop 1", (function()
    local stops = freshRoute()
    if #stops < 3 then return false, "route too short: " .. #stops end
    ns.Route:Guide()
    return ns.Route:IsGuiding() and ns.Route:CurrentIndex() == 1 and waypointIs(stops[1])
end)())
check("far from the stop, the guide waits", (function()
    ns.Route:CheckProgress(false)
    return ns.Route:CurrentIndex() == 1
end)())
check("arriving moves the waypoint to the next stop", (function()
    local stops = ns.Route:Get().stops
    standAt(stops[1])
    ns.Route:CheckProgress(false)
    return ns.Route:CurrentIndex() == 2 and waypointIs(stops[2]), "at " .. ns.Route:CurrentIndex()
end)())
check("the ticker drives arrival checks", (function()
    local stops = ns.Route:Get().stops
    standAt(stops[2])
    ns.Route.guideTicker.scripts.OnUpdate(ns.Route.guideTicker, 1)
    return ns.Route:CurrentIndex() == 3, "at " .. ns.Route:CurrentIndex()
end)())
check("panel marks passed stops done and the current one", (function()
    ns.Panel:Toggle(true)
    ns.Panel:SetTab("route")
    local rows = ns.Panel:ActiveRows()
    local detail = ("rows %d, alpha1 %s, tag3 %s, err %s"):format(#rows, tostring(rows[1] and rows[1].alpha),
        tostring(rows[3] and rows[3].tag.text), tostring(ns.Panel.lastError))
    return rows[1].alpha < 1 and rows[3].tag.text:find("GUIDING") ~= nil and ns.Panel.lastError == nil, detail
end)())
check("waiting for completion ignores arrival", (function()
    local stops = freshRoute()
    ns.Settings().advanceWhenDone = true
    ns.Route:Guide()
    standAt(stops[1])
    ns.Route:CheckProgress(false)
    local stayed = ns.Route:CurrentIndex() == 1
    ns.Settings().advanceWhenDone = false
    return stayed
end)())
-- In game: arriving at a quest's area moved the guide on before the work was
-- done. Now an objective stop is finished by finishing the quest; it then
-- becomes the quest's hand-in stop, and handing in moves the guide on.
local function firstObjectiveStop()
    for i, st in ipairs(ns.Route:Get().stops) do
        if st.kind == "objective" then return i, st end
    end
end
check("by default, arriving at an objective doesn't move the guide on", (function()
    freshRoute()
    ns.Settings().advanceWhenDone = ns.Defaults.settings.advanceWhenDone
    local i, st = firstObjectiveStop()
    ns.Route:Guide(i)
    standAt(st)
    ns.Route:CheckProgress(false)
    goHome()
    return ns.Defaults.settings.advanceWhenDone == true and ns.Route:CurrentIndex() == i
end)())
-- In game: finishing the first quest in an area sent the player straight back
-- to hand it in while other quests nearby were half done. Now the hand-in is
-- added to the route and the rest re-planned: nearby objectives first, the
-- walk back to hand in after (unless the hand-in is right on the way).
local function finish(questID, finished)
    local saved = {}
    for k, o in ipairs(Mock.QUESTS[questID].objectives) do saved[k] = o.finished; o.finished = finished end
    return saved
end
local function restore(questID, saved)
    for k, o in ipairs(Mock.QUESTS[questID].objectives) do o.finished = saved[k] end
end
local function stopIndex(questID, kind)
    for i, st in ipairs(ns.Route:Get().stops) do
        if st.questID == questID and st.kind == kind then return i end
    end
end
local function guideTo(questID, kind)
    local i = stopIndex(questID, kind)
    ns.Route:Guide(i)
    return i
end
local function completeAt(questID)
    -- Stand at the quest's objective, as you would when finishing it.
    local st = ns.Route:Get().stops[stopIndex(questID, "objective")]
    standAt(st)
    local saved = finish(questID, true)
    ns:Fire("QUEST_LOG_UPDATE")
    return saved
end

check("finishing a quest with work left nearby keeps you questing", (function()
    freshRoute()
    ns.Settings().advanceWhenDone, ns.Settings().batchTurnIns = true, true
    Mock.TURNIN_WP[1001] = { mapID = 1, x = 0.45, y = 0.62 }     -- back toward town
    guideTo(1001, "objective")
    local saved = completeAt(1001)
    local st = ns.Route:Get()
    local now = st.stops[st.current]
    local handIn = stopIndex(1001, "turnin")
    local leftover = stopIndex(1001, "objective")
    goHome(); restore(1001, saved); Mock.TURNIN_WP[1001] = nil
    ns:Fire("QUEST_LOG_UPDATE"); ns.Route:StopGuiding()
    return now.questID == 1005 and now.kind == "objective" and handIn and handIn > st.current
        and leftover == nil, ("now %s %s, hand-in at %s"):format(tostring(now.questID), now.kind, tostring(handIn))
end)())
check("a hand-in right beside you is taken straight away", (function()
    freshRoute()
    ns.Settings().advanceWhenDone, ns.Settings().batchTurnIns = true, true
    Mock.TURNIN_WP[1001] = { mapID = 1, x = 0.32, y = 0.42 }     -- ~28 yd away
    guideTo(1001, "objective")
    local saved = completeAt(1001)
    local st = ns.Route:Get()
    local now = st.stops[st.current]
    goHome(); restore(1001, saved); Mock.TURNIN_WP[1001] = nil
    ns:Fire("QUEST_LOG_UPDATE"); ns.Route:StopGuiding()
    return now.questID == 1001 and now.kind == "turnin", ("now %s %s"):format(tostring(now.questID), now.kind)
end)())
check("with batching off, a finished quest is handed in first", (function()
    freshRoute()
    ns.Settings().advanceWhenDone, ns.Settings().batchTurnIns = true, false
    Mock.TURNIN_WP[1001] = { mapID = 1, x = 0.45, y = 0.62 }
    guideTo(1001, "objective")
    local saved = completeAt(1001)
    -- Eager: hand-ins are ordinary stops, so the nearest ones (1002's, then
    -- 1001's) come before walking on to the 1005 objective.
    local st = ns.Route:Get()
    local now = st.stops[st.current]
    local handIn, nextObjective = stopIndex(1001, "turnin"), stopIndex(1005, "objective")
    goHome(); restore(1001, saved); Mock.TURNIN_WP[1001] = nil
    ns.Settings().batchTurnIns = true
    ns:Fire("QUEST_LOG_UPDATE"); ns.Route:StopGuiding()
    return now.kind == "turnin" and handIn and nextObjective and handIn < nextObjective,
        ("now %s %s; 1001 hand-in %s, 1005 objective %s"):format(tostring(now.questID), now.kind,
            tostring(handIn), tostring(nextObjective))
end)())
check("built routes also finish objectives before distant hand-ins", (function()
    -- 1002 is ready to hand in at (0.52,0.51); from the 1001 objective that's
    -- ~240 yd, while the 1005 objective is ~570 yd: batched, 1005 comes first.
    goHome()
    playerState.mapX, playerState.mapY = 0.3, 0.4
    ns.Settings().batchTurnIns = true
    local stops = ns.Route.OrderStops({
        { kind = "turnin", questID = 1002, uiMapID = 1, x = 0.52, y = 0.51, world = ns:WorldPos(1, 0.52, 0.51) },
        { kind = "objective", questID = 1005, uiMapID = 1, x = 0.7, y = 0.8, world = ns:WorldPos(1, 0.7, 0.8) },
    }, ns:PlayerPosition(1))
    goHome()
    return stops[1].questID == 1005 and stops[2].questID == 1002 and stops[1].index == 1
end)())
check("handing the quest in moves the guide on", (function()
    freshRoute()
    ns.Settings().advanceWhenDone = true
    local i = guideTo(1002, "turnin")
    local q = Mock.QUESTS[1002]
    Mock.QUESTS[1002] = nil
    ns:Fire("QUEST_TURNED_IN", 1002)
    local cur = ns.Route:CurrentIndex()
    local moved = (ns.Route:Get().stops[cur] or {}).questID ~= 1002 or not ns.Route:IsGuiding()
    Mock.QUESTS[1002] = q
    ns:Fire("QUEST_LOG_UPDATE")
    ns.Route:StopGuiding()
    ns.Settings().advanceWhenDone = false
    return moved, "at " .. cur
end)())
check("settings migration turns on waiting for quest work once", (function()
    local db = _G.SolarynDB
    local saved = db.settingsVersion
    db.settingsVersion, db.settings.advanceWhenDone = nil, false
    ns.OnAddonLoaded(nil, "SolarynExpedition")
    local migrated = db.settings.advanceWhenDone == true and db.settingsVersion == 2
    db.settings.advanceWhenDone = false                 -- a later user choice sticks
    ns.OnAddonLoaded(nil, "SolarynExpedition")
    local kept = db.settings.advanceWhenDone == false
    db.settingsVersion = saved or 2
    return migrated and kept
end)())
check("a stop whose quest left the log is skipped", (function()
    local stops = freshRoute()
    ns.Route:Guide()
    local gone = stops[1].questID
    local q = Mock.QUESTS[gone]
    Mock.QUESTS[gone] = nil
    ns:Fire("QUEST_REMOVED", gone)
    -- The route is rebuilt without the dropped quest; the guide carries on.
    local st = ns.Route:Get()
    local now = st.stops[st.current or 1]
    local stillThere = false
    for _, s2 in ipairs(st.stops) do if s2.questID == gone then stillThere = true end end
    Mock.QUESTS[gone] = q
    ns:Fire("QUEST_LOG_UPDATE")
    ns.Route:StopGuiding()
    return now and now.questID ~= gone and not stillThere and st.guiding,
        ("now %s, dropped quest still in route: %s"):format(tostring(now and now.questID), tostring(stillThere))
end)())
check("/sol skip moves on one stop", (function()
    freshRoute()
    ns.Route:Guide()
    ns.Slash.dispatch("skip")
    return ns.Route:CurrentIndex() == 2
end)())
check("finishing the last stop ends the guide and clears the waypoint", (function()
    local stops = freshRoute()
    ns.Route:Guide(#stops)
    standAt(stops[#stops])
    ns.Route:CheckProgress(false)
    return not ns.Route:IsGuiding() and playerState.waypoint == nil
end)())
check("rebuilding while guiding keeps reached stops done", (function()
    local stops = freshRoute()
    ns.Route:Guide()
    local reached = stops[1]
    standAt(reached)
    ns.Route:CheckProgress(false)             -- arrive at stop 1
    ns.Route:Build()                          -- e.g. the panel rebuilt a stale route
    local st = ns.Route:Get()
    local ok = ns.Route:IsGuiding() and st.current == 2
        and ns.Route.StopKey(st.stops[1]) == ns.Route.StopKey(reached)
    ns.Route:StopGuiding()
    goHome()
    return ok, "current " .. tostring(st.current)
end)())
check("auto-advance off: arriving does nothing", (function()
    local stops = freshRoute()
    ns.Route:Guide()
    ns.Settings().autoAdvance = false
    standAt(stops[1])
    ns.Route:CheckProgress(false)
    local stayed = ns.Route:CurrentIndex() == 1
    ns.Settings().autoAdvance = true
    ns.Route:StopGuiding()
    goHome()
    return stayed
end)())

print("\n== next-tab ordering ==")
check("quests are ranked nearest first", (function()
    ns.Settings().sortByDistance = true
    ns.Settings().suggestLimit = 10
    ns.QuestData:Invalidate()
    local list = ns.Suggest:ComputeQuietly()
    local last, sawUnlocated, sawZone = -1, false, false
    for _, sg in ipairs(list) do
        if not sg.questID then
            sawZone = true
        elseif sawZone then
            return false, "quest after a zone suggestion"
        elseif sg.distance then
            if sawUnlocated then return false, "located quest after an unlocated one" end
            if sg.distance < last then return false, "out of distance order" end
            last = sg.distance
        else
            sawUnlocated = true
        end
    end
    return last >= 0
end)())
check("a quest with no location sorts after located ones", (function()
    Mock.NO_POI[1001] = true
    ns.QuestData:Invalidate()
    local list = ns.Suggest:ComputeQuietly()
    Mock.NO_POI[1001] = nil
    ns.QuestData:Invalidate()
    local pos, lastLocated
    for i, sg in ipairs(list) do
        if sg.questID == 1001 then pos = i end
        if sg.questID and sg.distance then lastLocated = i end
    end
    return pos and lastLocated and pos > lastLocated
end)())
check("distance ranking off uses the weighted score", (function()
    ns.Settings().sortByDistance = false
    local list = ns.Suggest:ComputeQuietly()
    ns.Settings().sortByDistance = true
    ns.Settings().suggestLimit = 5
    for i = 2, #list do
        if list[i].score > list[i - 1].score then return false end
    end
    return #list > 1
end)())

print("\n== zone levels & progression ==")
local function withLevel(lvl, fn)
    local old = playerState.level
    playerState.level = lvl
    local ok, a, b = pcall(fn)
    playerState.level = old
    if not ok then return false, a end
    return a, b
end
local function names(list)
    local t = {}
    for _, z in ipairs(list) do t[#t + 1] = z.name end
    return table.concat(t, ", ")
end
goHome()
check("zone level ranges come from the Classic table by name", (function()
    local r = ns.ZoneData:LevelRange(2)
    return r and r.min == 10 and r.max == 20 and r.source == "classic"
end)())
check("the client's own range wins when it has one", (function()
    C_Map.GetMapLevels = function(id) if id == 2 then return 12, 22 end end
    ns:ProbeCapabilities()
    local r = ns.ZoneData:LevelRange(2)
    C_Map.GetMapLevels = nil
    ns:ProbeCapabilities()
    return r and r.min == 12 and r.max == 22 and r.source == "client"
end)())
check("an unknown zone has no made-up range", ns.ZoneData:LevelRange(84) == nil)
check("continent of Elwynn is Eastern Kingdoms", ns.ZoneData:Continent(1) == 100)
check("status: level 5 in Elwynn is ok, 10 is outgrowing, 14 outgrown", (function()
    local r = ns.ZoneData:LevelRange(1)
    return ns.ZoneData:LevelStatus(r, 5) == "ok" and ns.ZoneData:LevelStatus(r, 10) == "late"
        and ns.ZoneData:LevelStatus(r, 14) == "low"
end)())
check("level 10 in Elwynn: next is Westfall, not Redridge or Durotar", withLevel(10, function()
    local p = ns.ZoneData:Progression(3)
    return p.next[1] and p.next[1].name == "Westfall" and #p.next == 1, names(p.next)
end))
check("level 17: in-range zones first, nearest first", withLevel(17, function()
    -- Westfall (10-20) and Redridge (15-25) are in range; Duskwood (18-30) opens soon.
    local p = ns.ZoneData:Progression(3)
    local n = p.next
    local ok = #n == 3 and n[1].inRange and n[2].inRange and not n[3].inRange
        and n[3].name == "Duskwood" and (n[1].distance or 0) <= (n[2].distance or 0)
    return ok, names(n)
end))
check("other continents are never recommended", withLevel(5, function()
    for _, z in ipairs(ns.ZoneData:Progression(10).next) do
        if z.name == "Durotar" then return false end
    end
    return true
end))
check("hostile faction home zones are skipped", withLevel(12, function()
    Mock.faction = "Horde"
    local p = ns.ZoneData:Progression(3)
    Mock.faction = "Alliance"
    for _, z in ipairs(p.next) do
        if z.range.faction == "Alliance" then return false, z.name end
    end
    return true
end))
check("Next tab suggests the next zone when you're outgrowing yours", withLevel(10, function()
    local list = ns.Suggest:ComputeQuietly()
    for _, sg in ipairs(list) do
        if sg.kind == "unlock" and sg.title == "Westfall" then return true end
    end
    return false
end))
check("no zone nag while your zone still fits", withLevel(5, function()
    for _, sg in ipairs(ns.Suggest:ComputeQuietly()) do
        if sg.kind == "unlock" then return false, sg.title end
    end
    return true
end))
check("Zones tab renders level guidance cleanly", withLevel(12, function()
    ns.Panel:Toggle(true)
    ns.Panel:SetTab("zones")
    local levelRows = 0
    for _, row in ipairs(ns.Panel:ActiveRows()) do
        if row.poolKind == "level" then levelRows = levelRows + 1 end
    end
    ns.Panel:SetTab("next")
    return ns.Panel.lastError == nil and levelRows >= 2, tostring(ns.Panel.lastError or levelRows)
end))

print("\n== explored before install (fog of war) ==")
check("a zone explored before install shows up after import", (function()
    -- Westfall: never visited with the addon, but the left half and a strip
    -- of the right are revealed on the world map.
    Mock.REVEALED[2] = { { 0, 0, 0.5, 1, 108 }, { 0.5, 0, 1, 0.25, 87 } }
    local found = ns.Explored:ImportAll()
    local d = ns.Explored:Detail(2)
    -- 8x8 grid: left half = 32 cells, top quarter of the right = 2 rows x 4 = 8.
    return found >= 1 and d.revealedCells == 40 and d.trusted and math.abs(d.coverage - 40 / 64) < 1e-9,
        ("%d revealed, coverage %.3f"):format(d.revealedCells, d.coverage)
end)())
check("discovered area names are listed", (function()
    local names = ns.Explored:AreaNames(2)
    return table.concat(names, ",") == "Goldshire,Sentinel Hill", table.concat(names, ",")
end)())
check("walked and revealed cells are counted once", (function()
    -- Walk through a revealed cell and an unrevealed one.
    local oldMap, oldX, oldY = playerState.mapID, playerState.mapX, playerState.mapY
    playerState.mapID = 2
    playerState.mapX, playerState.mapY = 0.1, 0.1; ns.Explored:SampleNow()   -- already revealed
    playerState.mapX, playerState.mapY = 0.9, 0.9; ns.Explored:SampleNow()   -- new ground
    playerState.mapID, playerState.mapX, playerState.mapY = oldMap, oldX, oldY
    local d = ns.Explored:Detail(2)
    return d.cells == 41 and d.visitedCells == 2, ("%d cells, %d walked"):format(d.cells, d.visitedCells)
end)())
check("re-import tracks the client exactly (more revealed later)", (function()
    table.insert(Mock.REVEALED[2], { 0.5, 0.25, 1, 1, 87 })              -- rest revealed
    ns.Explored:ImportFromClient(2)
    local d = ns.Explored:Detail(2)
    return d.revealedCells == 64 and d.coverage == 1, tostring(d.revealedCells)
end)())
check("a zone with nothing revealed gets no record", (function()
    ns.Explored:ImportFromClient(6)                                      -- Stranglethorn
    for _, z in ipairs(ns.Explored:All()) do
        if z.mapID == 6 then return false end
    end
    return true
end)())
check("dungeons are never imported", ns.Explored:ImportFromClient(84) == false)
check("zone change re-imports the current zone", (function()
    Mock.REVEALED[1] = { { 0, 0, 1, 1, 87 } }
    ns:Fire("ZONE_CHANGED")
    local d = ns.Explored:Detail(1)
    Mock.REVEALED[1] = nil
    return d.revealedCells == 64, tostring(d.revealedCells)
end)())
check("without the fog-of-war API, import runs and keeps existing data", (function()
    local before = ns.Explored:Detail(2).revealedCells
    local api = C_MapExplorationInfo
    C_MapExplorationInfo = nil
    ns:ProbeCapabilities()
    local ok = pcall(ns.Explored.ImportAll, ns.Explored)
    C_MapExplorationInfo = api
    ns:ProbeCapabilities()
    return ok and ns.Explored:Detail(2).revealedCells == before
end)())
check("Zones tab renders imported zones cleanly", (function()
    ns.Panel:Toggle(true)
    ns.Panel:SetTab("zones")
    local found
    for _, row in ipairs(ns.Panel:ActiveRows()) do
        if row.poolKind == "zone" and row.data.mapID == 2 then found = row end
    end
    local tip = found and found.tooltip(found.data)
    ns.Panel:SetTab("next")
    Mock.REVEALED[2] = nil
    return ns.Panel.lastError == nil and found ~= nil and found.sub.text:find("discovered") ~= nil
        and tip and #tip.lines > 3, tostring(ns.Panel.lastError)
end)())

print("\n== route tracker (HUD) ==")
local HUD = ns.HUD
local hf = HUD:GetFrame()
local function hudRefresh() HUD:Refresh() end
local function hudTexts(onlyShown)
    local texts = {}
    local function collect(w)
        if type(w.text) == "string" and (not onlyShown or w.shown) then texts[#texts + 1] = w.text end
        for _, c in ipairs(w.children or {}) do collect(c) end
    end
    collect(hf)
    return table.concat(texts, "|")
end
check("tracker hidden when not guiding", (function()
    freshRoute()
    ns.Route:StopGuiding()
    hudRefresh()
    return not hf:IsShown()
end)())
check("tracker appears when the guide starts", (function()
    ns.Route:Guide()
    hudRefresh()
    return hf:IsShown()
end)())
check("tracker shows the current stop and progress count", (function()
    local st = ns.Route:Get()
    local cur = st.stops[st.current]
    local all = hudTexts(false)
    return all:find(("%d/%d"):format(st.current, #st.stops), 1, true) ~= nil
        and all:find(cur.title, 1, true) ~= nil, all
end)())
check("tracker lists pending objectives for an objective stop", (function()
    local cur = ns.Route:Next()
    if cur.kind ~= "objective" then return true end
    local want = ns.QuestData:PendingObjectives(cur.questID)[1]
    return hudTexts(true):find(want.text, 1, true) ~= nil
end)())
check("tracker lists upcoming stops, numbered", (function()
    local st = ns.Route:Get()
    local want = math.min(ns.Settings().hudUpcoming, #st.stops - st.current)
    local all = hudTexts(true)
    for i = st.current + 1, st.current + want do
        if not all:find(i .. ". " .. st.stops[i].title, 1, true) then return false, "missing " .. i end
    end
    return true
end)())
check("arrow: target due north while facing north points straight ahead", (function()
    playerState.mapID, playerState.mapX, playerState.mapY = 1, 0.5, 0.5   -- map centre
    Mock.facing = 0
    local a = HUD.RelativeAngle({ uiMapID = 1, x = 0.5, y = 0.2 })
    return a and math.abs(a) < 1e-9, tostring(a)
end)())
check("arrow: target due east is a quarter turn clockwise", (function()
    Mock.facing = 0
    local a = HUD.RelativeAngle({ uiMapID = 1, x = 0.8, y = 0.5 })
    return a and math.abs(a + math.pi / 2) < 1e-9, tostring(a)
end)())
check("arrow: facing west, a northern target is to the right", (function()
    Mock.facing = math.pi / 2
    local a = HUD.RelativeAngle({ uiMapID = 1, x = 0.5, y = 0.2 })
    Mock.facing = 0
    goHome()
    return a and math.abs(a + math.pi / 2) < 1e-9, tostring(a)
end)())
check("arrow: no direction for a stop on another map", HUD.RelativeAngle({ uiMapID = 2, x = 0.5, y = 0.5 }) == nil)
check("clicking an upcoming stop guides from it", (function()
    local row
    local function find(w)
        if w.index and w.stop and w.shown and not row then row = w end
        for _, c in ipairs(w.children or {}) do find(c) end
    end
    find(hf)
    if not row then return false, "no upcoming row" end
    local target = row.index
    row:Click("LeftButton")
    return ns.Route:CurrentIndex() == target, "at " .. ns.Route:CurrentIndex()
end)())
check("collapsing hides the body and keeps the header", (function()
    ns.Settings().hudCollapsed = true
    hudRefresh()
    local h = hf:GetHeight()
    ns.Settings().hudCollapsed = false
    hudRefresh()
    return h == 20 and hf:GetHeight() > 20, tostring(h)
end)())
check("tracker off in options hides it", (function()
    ns.Settings().hud = false
    hudRefresh()
    local hidden = not hf:IsShown()
    ns.Settings().hud = true
    hudRefresh()
    return hidden and hf:IsShown()
end)())
check("show-always keeps a paused tracker with a start button", (function()
    ns.Route:StopGuiding()
    ns.Settings().hudAlways = true
    hudRefresh()
    local shown = hf:IsShown()
    ns.Settings().hudAlways = false
    hudRefresh()
    return shown and not hf:IsShown()
end)())
check("tracker hides when the route is finished", (function()
    local stops = freshRoute()
    ns.Route:Guide(#stops)
    standAt(stops[#stops])
    ns.Route:CheckProgress(false)
    hudRefresh()
    goHome()
    return not hf:IsShown()
end)())
check("tracker live update runs cleanly", (function()
    freshRoute()
    ns.Route:Guide()
    hudRefresh()
    local ok, err = pcall(HUD.UpdateLive, HUD)
    ns.Route:StopGuiding()
    return ok, err
end)())
check("/sol hud toggles the tracker", (function()
    ns.Slash.dispatch("hud")
    local off = ns.Settings().hud == false
    ns.Slash.dispatch("hud")
    return off and ns.Settings().hud == true
end)())

print("\n== quest item buttons ==")
Mock.ITEMS[7001] = { name = "Kobold Repellent", usable = true, questItem = true }
Mock.ITEMS[7002] = { name = "Westfall Stew Pot", usable = true, questItem = true, questID = 1003 }
Mock.ITEMS[7003] = { name = "Night Lantern", usable = true, questItem = true }
Mock.ITEMS[7004] = { name = "Bent Spoon", usable = false, questItem = true, questID = 1005 }
Mock.BAGS[0] = { [1] = 7001, [2] = 7002, [3] = 7003, [4] = 7004 }

check("quest log's own item is found first", (function()
    Mock.SPECIAL_ITEM[1001] = 7001
    local it = ns.QuestData:QuestItem(1001)
    return it and it.itemID == 7001 and it.source == "quest log", it and it.source
end)())
check("a bag item tied to the quest is found", (function()
    local it = ns.QuestData:QuestItem(1003)
    return it and it.itemID == 7002 and it.source == "bag", it and it.source
end)())
check("a usable quest item named in the objectives is found", (function()
    local o = Mock.QUESTS[1005].objectives[1]
    local old = o.text
    o.text = "Light the Night Lantern"
    ns.QuestData:Invalidate()
    local it = ns.QuestData:QuestItem(1005)
    o.text = old
    ns.QuestData:Invalidate()
    return it and it.itemID == 7003 and it.source == "objective", it and it.source
end)())
check("items with no Use: effect are ignored", (function()
    local it = ns.QuestData:QuestItem(1005)          -- only the unusable spoon is tied to 1005
    return it == nil
end)())

local function guideQuest(questID)
    freshRoute()
    for i, st in ipairs(ns.Route:Get().stops) do
        if st.questID == questID then ns.Route:Guide(i); break end
    end
    ns.HUD:Refresh()
end
check("guiding a quest with an item shows a usable button", (function()
    guideQuest(1001)
    local b = ns.HUD:GetItemButton(1)
    return b and b.shown and b:GetAttribute("type") == "item" and b:GetAttribute("item") == "item:7001",
        b and tostring(b:GetAttribute("item"))
end)())
check("item buttons are secure and parented to UIParent, not the tracker", (function()
    local b = ns.HUD:GetItemButton(1)
    return b.__template:find("SecureActionButtonTemplate") ~= nil and b.parent == UIParent
end)())
check("button clicks are registered to match the key-down setting", (function()
    local b = ns.HUD:GetItemButton(1)
    return b.clicks and b.clicks[1] == "AnyUp" and #b.clicks == 1
end)())
check("in combat, item changes wait instead of erroring", (function()
    Mock.inCombat = true
    Mock.SPECIAL_ITEM[1001] = nil
    Mock.ITEMS[7005] = { name = "Kobold Bait", usable = true, questItem = true, questID = 1001 }
    Mock.BAGS[0][5] = 7005
    local ok, err = pcall(function() ns:Fire("route_changed"); ns.HUD:Refresh() end)
    local b = ns.HUD:GetItemButton(1)
    local unchanged = b:GetAttribute("item") == "item:7001"
    Mock.inCombat = false
    return ok and unchanged, tostring(err)
end)())
check("leaving combat applies the waiting change", (function()
    ns:Fire("PLAYER_REGEN_ENABLED")
    local b = ns.HUD:GetItemButton(1)
    return b:GetAttribute("item") == "item:7005", tostring(b:GetAttribute("item"))
end)())
check("the mock really does block secure changes in combat", (function()
    Mock.inCombat = true
    local ok = pcall(function() ns.HUD:GetItemButton(1):SetAttribute("item", "x") end)
    Mock.inCombat = false
    return not ok
end)())
check("buttons hide when the guide stops", (function()
    ns.Route:StopGuiding()
    ns.HUD:Refresh()
    return not ns.HUD:GetItemButton(1).shown
end)())
check("the keybinding is declared and named", (function()
    local xml = io.open("Bindings.xml"):read("*a")
    return xml:find('CLICK SolarynExpeditionQuestItemButton1:LeftButton', 1, true) ~= nil
        and type(_G["BINDING_NAME_CLICK SolarynExpeditionQuestItemButton1:LeftButton"]) == "string"
end)())
Mock.BAGS[0] = nil
Mock.SPECIAL_ITEM[1001] = nil

print("\n== quest tooltips ==")
local QT = ns.QuestTooltip
local function hasLine(lines, needle)
    for _, l in ipairs(lines) do if l:find(needle, 1, true) then return true end end
    return false
end
check("name matching handles plurals and rejects noise", (function()
    local m = QT.NameMatches
    return m("Kobold Vermin: 4/8", "Kobold Vermin") and m("Boars slain: 0/10", "Boar")
        and m("Young Wolves slain: 1/5", "Young Wolf") and m("Fleshripper Harpies: 2/6", "Fleshripper Harpy")
        and not m("Kobold Vermin: 4/8", "Kobold Laborer") and not m("Boars slain", "Bo")
end)())
check("hovering a quest mob shows the quest and its progress", (function()
    goHome()
    Mock.UNITS.mouseover = "Kobold Vermin"
    local lines = Mock.hoverUnit("mouseover")
    return hasLine(lines, "Kobold Camp Cleanup") and hasLine(lines, " - Kobold Vermin: 4/8"), table.concat(lines, " | ")
end)())
check("the guided quest is marked", (function()
    guideQuest(1001)
    local lines = Mock.hoverUnit("mouseover")
    ns.Route:StopGuiding()
    return hasLine(lines, "(guided)"), table.concat(lines, " | ")
end)())
check("unrelated mobs get nothing", (function()
    Mock.UNITS.mouseover = "Murloc Streamrunner"
    return #Mock.hoverUnit("mouseover") == 1
end)())
check("players are never annotated", (function()
    return #Mock.hoverUnit("player") == 1
end)())
check("a quest the tooltip already shows isn't repeated", (function()
    Mock.UNITS.mouseover = "Kobold Vermin"
    GameTooltip.lines, Mock.tooltipUnit = {}, "mouseover"
    GameTooltip:AddLine("Kobold Vermin")
    GameTooltip:AddLine("Kobold Camp Cleanup")       -- client already listed it
    local added = QT:Annotate(GameTooltip, "Kobold Vermin", "mouseover")
    return added == 0
end)())
check("world objects named in objectives are annotated", (function()
    local lines = Mock.hoverObject("Thieves' Tools")
    return hasLine(lines, "Westfall Plots"), table.concat(lines, " | ")
end)())
check("a quest mob the client flags gets a generic line", (function()
    C_QuestLog.UnitIsRelatedToActiveQuest = function() return true end
    Mock.UNITS.mouseover = "Gnoll Brute"
    local lines = Mock.hoverUnit("mouseover")
    C_QuestLog.UnitIsRelatedToActiveQuest = nil
    return hasLine(lines, "Quest mob"), table.concat(lines, " | ")
end)())
check("tooltip setting off adds nothing", (function()
    ns.Settings().questTooltips = false
    Mock.UNITS.mouseover = "Kobold Vermin"
    local n = #Mock.hoverUnit("mouseover")
    ns.Settings().questTooltips = true
    return n == 1
end)())
-- In game (group combat): the mob's name arrived as a secret value and the
-- tooltip hook compared it, raising an error on every hover.
local function captureDebug(fn)
    local logged, realDebug = {}, ns.Debug
    ns.Debug = function(self, fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
    local ok, err = pcall(fn)
    ns.Debug = realDebug
    return ok, err, logged
end
check("the mock's secret values refuse string use", (function()
    local secretName = Mock.secret("Kobold Vermin")
    return issecretvalue(secretName) and type(secretName) == "string"
        and not pcall(function() return secretName:lower() end)
        and not pcall(function() return secretName .. "x" end)
end)())
check("a secret mob name adds nothing and raises nothing", (function()
    Mock.UNITS.mouseover = Mock.secret("Kobold Vermin")
    local ok, err, logged = captureDebug(function() Mock.hoverUnit("mouseover") end)
    Mock.UNITS.mouseover = nil
    return ok and #GameTooltip.lines == 1 and #logged == 0, tostring(err) .. " " .. table.concat(logged, "; ")
end)())
check("a secret object name adds nothing and raises nothing", (function()
    local ok, err, logged = captureDebug(function() Mock.hoverObject(Mock.secret("Thieves' Tools")) end)
    return ok and #GameTooltip.lines == 1 and #logged == 0, tostring(err) .. " " .. table.concat(logged, "; ")
end)())
check("secret text already on a tooltip is skipped when checking for repeats", (function()
    Mock.UNITS.mouseover = "Kobold Vermin"
    GameTooltip.lines, GameTooltip.raw, Mock.tooltipUnit = {}, {}, "mouseover"
    GameTooltip:AddLine("Kobold Vermin")
    GameTooltip:AddLine(Mock.secret("Level 4"))
    local ok, added = pcall(QT.Annotate, QT, GameTooltip, "Kobold Vermin", "mouseover")
    Mock.UNITS.mouseover = nil
    return ok and added == 1, tostring(added)
end)())
check("ns.IsSafe checks secrecy before comparing", (function()
    return ns.IsSafe(Mock.secret(5)) == false and ns.IsSafe(5) and not ns.IsSafe(nil)
end)())
check("a failing tooltip extra is caught, never shown as an error", (function()
    local real = QT.Annotate
    QT.Annotate = function() error("boom") end
    Mock.UNITS.mouseover = "Kobold Vermin"
    local ok = pcall(Mock.hoverUnit, "mouseover")
    QT.Annotate = real
    Mock.UNITS.mouseover = nil
    return ok
end)())
Mock.UNITS.mouseover = nil

print("\n== quest givers (learned) ==")
local QG = ns.QuestGivers
check("NPC IDs come from creature GUIDs only", (function()
    return QG.IDFromGUID("Creature-0-1465-0-2105-448-000043F59F") == 448
        and QG.IDFromGUID("Player-1465-0ABCDEF") == nil
        and QG.IDFromGUID(Mock.secret("Creature-0-1-0-1-448-0")) == nil
end)())
check("talking to an NPC records what it offers and takes back", (function()
    goHome()
    Mock.completedQuests[2003] = true
    Mock.npc = { id = 240, name = "Marshal Dughan" }
    Mock.GOSSIP = {
        available = {
            { title = "Report to Gryan", questLevel = 10, questID = 2002 },
            { title = "The Fargodeep Mine", questLevel = 7, questID = 2001 },
            { title = "Old Business", questLevel = 5, questID = 2003 },
        },
        active = { { title = "Kobold Camp Cleanup", questID = 1001 } },
    }
    ns:Fire("GOSSIP_SHOW")
    local rec = QG:NPC(240)
    local n = 0
    for _ in pairs(rec and rec.offers or {}) do n = n + 1 end
    return rec and rec.name == "Marshal Dughan" and n == 3 and rec.takes[1001] ~= nil and rec.mapID == 1
end)())
check("NPC tooltip lists available quests with levels, minus finished ones", (function()
    Mock.UNITS.mouseover, Mock.GUIDS.mouseover = "Marshal Dughan", Mock.guidFor(240)
    local lines = Mock.hoverUnit("mouseover")
    local all = table.concat(lines, " | ")
    local i7, i10 = all:find("[7] The Fargodeep Mine", 1, true), all:find("[10] Report to Gryan", 1, true)
    return i7 and i10 and i7 < i10 and not all:find("Old Business", 1, true), all
end)())
check("NPC tooltip shows quests in your log it takes back", (function()
    local all = table.concat(Mock.hoverUnit("mouseover"), " | ")
    return all:find("Kobold Camp Cleanup  (in progress)", 1, true) ~= nil, all
end)())
check("quest greeting windows are learned too", (function()
    Mock.npc = { id = 241, name = "Deputy Willem" }
    Mock.GOSSIP = { available = { { title = "Wolves Across the Border", questLevel = 6, questID = 2004, isTrivial = true } }, active = {} }
    ns:Fire("QUEST_GREETING")
    local o = QG:Offers(241)
    return #o == 1 and o[1].title == "Wolves Across the Border" and o[1].level == 6 and o[1].trivial
end)())
check("accepting a quest remembers who gave it", (function()
    Mock.npc = { id = 242, name = "Farmer Saldean" }
    Mock.questFrame = { questID = 1003, title = "Westfall Plots" }
    ns:Fire("QUEST_DETAIL")
    ns:Fire("QUEST_ACCEPTED", 1003)
    return _G.SolarynDB.questGivers[1003] == 242
end)())
check("a quest already in your log isn't offered", (function()
    for _, q in ipairs(QG:Offers(242)) do
        if q.questID == 1003 then return false end
    end
    return true
end)())
local saved1003 = {}
check("with no turn-in marker, the hand-in goes to the quest giver", (function()
    Mock.NO_POI[1003] = true
    for k, o in ipairs(Mock.QUESTS[1003].objectives) do saved1003[k] = o.finished; o.finished = true end
    ns.QuestData:Invalidate()
    local t = ns.QuestData:TurnInLocation(1003)
    return t and t.source == "npc" and t.approximate and t.uiMapID == 1, t and tostring(t.source)
end)())
check("an NPC seen taking the quest beats the giver", (function()
    playerState.mapID, playerState.mapX, playerState.mapY = 2, 0.4, 0.6
    Mock.npc = { id = 243, name = "Salma Saldean" }
    Mock.questFrame = { questID = 1003, title = "Westfall Plots" }
    ns:Fire("QUEST_PROGRESS")
    goHome()
    local t = ns.QuestData:TurnInLocation(1003)
    Mock.NO_POI[1003] = nil
    for k, o in ipairs(Mock.QUESTS[1003].objectives) do o.finished = saved1003[k] end
    ns.QuestData:Invalidate()
    return t and t.uiMapID == 2 and not t.approximate and t.npcName == "Salma Saldean"
end)())
check("quest-giver data is account-wide", _G.SolarynDB.npcs[240] ~= nil and (_G.SolarynCharDB.npcs == nil))
check("a secret NPC GUID adds nothing and raises nothing", (function()
    Mock.GUIDS.mouseover = Mock.secret(Mock.guidFor(240))
    local ok, err, logged = captureDebug(function() Mock.hoverUnit("mouseover") end)
    local all = table.concat(GameTooltip.lines, " | ")
    Mock.GUIDS.mouseover = Mock.guidFor(240)
    return ok and #logged == 0 and not all:find("Available", 1, true), tostring(err) .. table.concat(logged, ";")
end)())
check("quest tooltips off hides giver lines too", (function()
    ns.Settings().questTooltips = false
    local n = #Mock.hoverUnit("mouseover")
    ns.Settings().questTooltips = true
    return n == 1
end)())
Mock.npc, Mock.questFrame, Mock.UNITS.mouseover, Mock.GUIDS.mouseover = nil, nil, nil, nil
Mock.GOSSIP = { available = {}, active = {} }

print("\n== exploration achievements ==")
local EK_EXPLORE = 14777
Mock.ACHIEVEMENTS[802] = { name = "Explore Westfall", cat = EK_EXPLORE, earned = false, criteria = {
    { "Sentinel Hill", true }, { "Moonbrook", false }, { "The Dead Acre", true }, { "Jangolode Mine", false } } }
Mock.ACHIEVEMENTS[776] = { name = "Explore Elwynn Forest", cat = EK_EXPLORE, earned = true, criteria = {
    { "Goldshire", true }, { "Northshire Valley", true }, { "Fargodeep Mine", false } } }
Mock.ACHIEVEMENTS[780] = { name = "Explore Redridge Mountains", cat = EK_EXPLORE, earned = true, criteria = {
    { "Lakeshire", true } } }
ns.Explored:ResetAchievementIndex()

check("achievement progress sets coverage from real area counts", (function()
    ns.Explored:ImportAll()
    local cov = ns.Explored:Coverage(2)
    return cov == 0.5, tostring(cov)
end)())
check("the areas still to find are listed", (function()
    local a = ns.Explored:Detail(2).achievement
    return a and table.concat(a.missing, ",") == "Moonbrook,Jangolode Mine", a and table.concat(a.missing, ",")
end)())
check("an earned achievement means 100% (the in-game picture)", (function()
    return ns.Explored:Coverage(1) == 1, tostring(ns.Explored:Coverage(1))
end)())
check("a zone explored before install appears from its achievement alone", (function()
    for _, z in ipairs(ns.Explored:All()) do
        if z.mapID == 3 then return z.coverage == 1 end
    end
    return false, "Redridge missing"
end)())
check("finding a new area updates coverage on CRITERIA_UPDATE", (function()
    Mock.ACHIEVEMENTS[802].criteria[2][2] = true       -- Moonbrook found
    local oldMap = playerState.mapID
    playerState.mapID = 2
    ns:Fire("CRITERIA_UPDATE")
    playerState.mapID = oldMap
    return ns.Explored:Coverage(2) == 0.75, tostring(ns.Explored:Coverage(2))
end)())
check("earning the achievement completes the zone", (function()
    Mock.ACHIEVEMENTS[802].earned = true
    ns:Fire("ACHIEVEMENT_EARNED", 802)
    return ns.Explored:Coverage(2) == 1
end)())
check("without the category list, known IDs are used (name-checked)", (function()
    local gcl = GetCategoryList
    GetCategoryList = nil
    ns.Explored:ResetAchievementIndex()
    local a = ns.Explored:Achievement(2)
    GetCategoryList = gcl
    return a and a.id == 802
end)())
check("a known ID whose name doesn't match is not used", (function()
    local gcl = GetCategoryList
    GetCategoryList = nil
    Mock.ACHIEVEMENTS[776].name = "Something Else Entirely"
    ns.Explored:ResetAchievementIndex()
    local a = ns.Explored:Achievement(1)
    Mock.ACHIEVEMENTS[776].name = "Explore Elwynn Forest"
    GetCategoryList = gcl
    ns.Explored:ResetAchievementIndex()
    return a == nil
end)())
check("Zones tab shows achievement progress", (function()
    Mock.ACHIEVEMENTS[802].earned = false
    Mock.ACHIEVEMENTS[802].criteria[2][2] = false
    ns.Explored:ImportAll()
    ns.Panel:Toggle(true)
    ns.Panel:SetTab("zones")
    local westfall, elwynn
    for _, row in ipairs(ns.Panel:ActiveRows()) do
        if row.poolKind == "zone" and row.data.mapID == 2 then westfall = row.sub.text end
        if row.poolKind == "zone" and row.data.mapID == 1 then elwynn = row.sub.text end
    end
    ns.Panel:SetTab("next")
    return ns.Panel.lastError == nil and westfall and westfall:find("2 of 4 areas found", 1, true)
        and elwynn and elwynn:find("Fully explored", 1, true), tostring(westfall) .. " / " .. tostring(elwynn)
end)())
Mock.ACHIEVEMENTS = {}
ns.Explored:ResetAchievementIndex()

print("\n== one stop per objective (regression) ==")
-- In game: a quest's marker came back on its zone map AND the continent map
-- (and neighbouring zones), and each copy became its own route stop.
check("a quest marker seen on several maps is one location", (function()
    goHome()
    ns.QuestData:Invalidate()
    local wps = ns.QuestData:Waypoints(1001)
    return #wps == 1 and wps[1].uiMapID == 1, ("%d waypoints, first on map %s"):format(#wps, tostring(wps[1] and wps[1].uiMapID))
end)())
check("the route has one objective stop per quest location", (function()
    freshRoute()
    local seen = {}
    for _, st in ipairs(ns.Route:Get().stops) do
        local key = st.questID .. ":" .. st.kind
        if seen[key] then return false, "duplicate " .. key .. " on map " .. st.uiMapID end
        seen[key] = true
    end
    return true
end)())

print("\n== keeping the route up to date ==")
local function routeQuests()
    local set = {}
    for _, st in ipairs(ns.Route:Get().stops or {}) do set[st.questID] = true end
    return set
end
check("accepting a quest rebuilds the route with it", (function()
    freshRoute(); ns.Route:ResetSync(); ns:Fire("QUEST_LOG_UPDATE")
    Mock.QUESTS[1006] = { title = "Gold Dust Exchange", level = 7,
        objectives = { { text = "Gold Dust: 0/10", finished = false, numFulfilled = 0, numRequired = 10 } },
        wp = { mapID = 1, x = 0.4, y = 0.45 } }
    ns:Fire("QUEST_ACCEPTED", 1006)
    local has = routeQuests()[1006]
    Mock.QUESTS[1006] = nil
    ns:Fire("QUEST_REMOVED", 1006)
    return has == true and not routeQuests()[1006]
end)())
check("objective progress alone doesn't rebuild", (function()
    freshRoute(); ns.Route:ResetSync(); ns:Fire("QUEST_LOG_UPDATE")
    local built = ns.Route:Get().built
    local realBuild, calls = ns.Route.Build, 0
    ns.Route.Build = function(self, ...) calls = calls + 1; return realBuild(self, ...) end
    local o = Mock.QUESTS[1001].objectives[1]
    local old = o.numFulfilled
    o.numFulfilled = 5
    ns:Fire("QUEST_LOG_UPDATE")
    o.numFulfilled = old
    ns.Route.Build = realBuild
    return calls == 0, tostring(calls) .. " rebuilds"
end)())
check("finishing a quest while not guiding still updates the route", (function()
    freshRoute(); ns.Route:ResetSync(); ns:Fire("QUEST_LOG_UPDATE")
    ns.Route:StopGuiding()
    local saved = finish(1005, true)
    ns:Fire("QUEST_LOG_UPDATE")
    local handIn = stopIndex(1005, "turnin")
    local objective = stopIndex(1005, "objective")
    restore(1005, saved)
    ns:Fire("QUEST_LOG_UPDATE")
    return handIn ~= nil and objective == nil
end)())
check("a new quest joins a running guide without losing progress", (function()
    local stops = freshRoute(); ns.Route:ResetSync(); ns:Fire("QUEST_LOG_UPDATE")
    ns.Settings().advanceWhenDone = false
    stops = ns.Route:Get().stops
    ns.Route:Guide()
    local first = stops[1]
    standAt(first)
    ns.Route:CheckProgress(false)                          -- reach stop 1
    local reachedKey = ns.Route.StopKey(first)
    Mock.QUESTS[1006] = { title = "Gold Dust Exchange", level = 7,
        objectives = { { text = "Gold Dust: 0/10", finished = false, numFulfilled = 0, numRequired = 10 } },
        wp = { mapID = 1, x = 0.4, y = 0.45 } }
    ns:Fire("QUEST_ACCEPTED", 1006)
    local st = ns.Route:Get()
    local ok = st.guiding and st.current == 2 and ns.Route.StopKey(st.stops[1]) == reachedKey
        and routeQuests()[1006] == true
    Mock.QUESTS[1006] = nil
    ns:Fire("QUEST_REMOVED", 1006)
    ns.Route:StopGuiding(); goHome()
    return ok, ("guiding %s, current %s"):format(tostring(st.guiding), tostring(st.current))
end)())
check("auto-update off leaves the route alone", (function()
    freshRoute(); ns.Route:ResetSync(); ns:Fire("QUEST_LOG_UPDATE")
    ns.Settings().autoRebuild = false
    Mock.QUESTS[1006] = { title = "Gold Dust Exchange", level = 7,
        objectives = { { text = "Gold Dust: 0/10", finished = false } }, wp = { mapID = 1, x = 0.4, y = 0.45 } }
    ns:Fire("QUEST_ACCEPTED", 1006)
    local has = routeQuests()[1006]
    Mock.QUESTS[1006] = nil
    ns.Settings().autoRebuild = true
    ns:Fire("QUEST_REMOVED", 1006)
    return not has
end)())
check("the tracker's rebuild button rebuilds the route", (function()
    freshRoute()
    ns.Route:Guide()
    ns.HUD:Refresh()
    local b = ns.HUD:GetRebuildButton()
    local realBuild, calls = ns.Route.Build, 0
    ns.Route.Build = function(self, ...) calls = calls + 1; return realBuild(self, ...) end
    b:Click("LeftButton")
    ns.Route.Build = realBuild
    local ok = b.shown ~= false and calls == 1 and ns.Route:IsGuiding()
    ns.Route:StopGuiding()
    return ok
end)())

print("\n== client event registration ==")
-- Regression: ns:RegisterEvent once only filled a Lua table, so in game the
-- client never delivered QUEST_LOG_UPDATE & co. Tests that drive ns:Fire
-- directly can't see that, so check the dispatcher frame itself.
do
    local d = ns.dispatcher
    local listened = {}
    for event, list in pairs(ns.eventHandlers) do
        if #list > 0 then listened[event] = true end
    end
    local custom, game = 0, 0
    for event in pairs(listened) do
        if ns.IsGameEvent(event) then
            game = game + 1
            check("client event registered on frame: " .. event, d.events[event] == true)
        else
            custom = custom + 1
            check("custom event kept off the frame: " .. event, d.events[event] == nil)
        end
    end
    check("some game events are listened for", game >= 8, tostring(game))
    check("no event names the client rejected", next(ns.badEvents or {}) == nil,
        (function() local t = {} for k in pairs(ns.badEvents or {}) do t[#t + 1] = k end return table.concat(t, ", ") end)())
    check("ADDON_LOADED still delivered after our own load (map hook needs it)", d.events.ADDON_LOADED == true)
end
check("a client event reaches handlers through the frame's OnEvent", (function()
    local hit = false
    ns:RegisterEvent("USER_WAYPOINT_UPDATED", function() hit = true end, "probe")
    ns.dispatcher.scripts.OnEvent(ns.dispatcher, "USER_WAYPOINT_UPDATED")
    ns:UnregisterEvent("USER_WAYPOINT_UPDATED", "probe")
    return hit and ns.dispatcher.events.USER_WAYPOINT_UPDATED == nil
end)())
check("an unknown client event is reported, not thrown", (function()
    local ok = pcall(function() ns:RegisterEvent("NOT_A_REAL_EVENT", function() end, "probe") end)
    local reported = ns.badEvents and ns.badEvents.NOT_A_REAL_EVENT ~= nil
    ns:UnregisterEvent("NOT_A_REAL_EVENT", "probe")
    ns.badEvents.NOT_A_REAL_EVENT = nil
    return ok and reported
end)())
check("world map OnShow is hooked for route pins", WorldMapFrame.scripts.OnShow ~= nil)

check("a burst of debounced calls runs once", (function()
    local queue = {}
    _G.C_Timer = { After = function(_, fn) queue[#queue + 1] = fn end }
    local runs = 0
    for _ = 1, 10 do ns:Debounce("probe", 0.2, function() runs = runs + 1 end) end
    local queued = #queue
    for _, fn in ipairs(queue) do fn() end
    ns:Debounce("probe", 0.2, function() runs = runs + 1 end)   -- a later burst runs again
    for i = queued + 1, #queue do queue[i]() end
    _G.C_Timer = nil
    return queued == 1 and runs == 2, ("queued %d, ran %d"):format(queued, runs)
end)())

print("\n== module registration ==")
-- Regression guard: every module that defines Initialize must be registered,
-- or it silently never builds in-game (no error, just a missing feature).
for _, name in ipairs({ "QuestData", "Explored", "Slash", "Panel", "Options", "MinimapButton", "HUD", "QuestTooltip" }) do
    check("module registered: " .. name, ns.Modules[name] ~= nil)
end
-- Modules that HAVE an Initialize must be flagged initialized with no error.
-- QuestData and Route are pure data modules with no Initialize at all.
for name, mod in pairs(ns.Modules) do
    if type(mod.Initialize) == "function" then
        check("module initialized: " .. name, mod.initialized == true)
        check("module init clean: " .. name, mod.initError == nil, tostring(mod.initError))
    end
end
check("slash command wired", SlashCmdList["SOLARYNEXPEDITION"] ~= nil)
check("slash handler is callable", type(SlashCmdList["SOLARYNEXPEDITION"]) == "function")

print("\n== panel ==")
check("panel frame exists", ns.Panel ~= nil)
local okPanel = pcall(function() ns.Panel:Toggle(true) end)
check("panel opens", okPanel)
check("panel cycles tabs", pcall(function()
    ns.Panel:SetTab("route"); ns.Panel:SetTab("zones"); ns.Panel:SetTab("next")
end))
check("options panel builds", pcall(function() ns.Options:Toggle(true); ns.Options:Toggle(false) end))
check("minimap button exists", ns.MinimapButton:GetButton() ~= nil)
check("minimap button clickable", pcall(function() ns.MinimapButton:GetButton():Click() end))

print("\n== map pins ==")
check("route pins generated", #ns.Route:Pins() > 0, tostring(#ns.Route:Pins()))
-- In game, a plain-table "provider" crashed Blizzard_MapCanvas on map open.
check("world map rejects a plain-table provider (mock is faithful)", (function()
    local bogus = { type = "pin" }
    local ok = pcall(WorldMapFrame.AddDataProvider, WorldMapFrame, bogus)
    WorldMapFrame.dataProviders[bogus] = nil     -- the real map keeps it too; tidy up
    return not ok
end)())

local PIN = "SolarynExpeditionRoutePinTemplate"
local function pinsShown() return WorldMapFrame.pins[PIN] or {} end
local function stopsOn(mapID)
    local n = 0
    for _, st in ipairs(ns.Route:Get().stops or {}) do
        if st.uiMapID == mapID and st.x then n = n + 1 end
    end
    return n
end

check("opening the map draws one pin per stop on that map", (function()
    ns.Route:Build()
    WorldMapFrame.mapID = 1
    WorldMapFrame.shown = true
    local ok, err = pcall(WorldMapFrame.scripts.OnShow, WorldMapFrame)
    if not ok then return false, err end
    local want = stopsOn(1)
    return want > 0 and #pinsShown() == want, ("%d pins, %d stops"):format(#pinsShown(), want)
end)())
check("pins are numbered in route order", (function()
    for _, pin in ipairs(pinsShown()) do
        local st = ns.Route:Get().stops[pin.index]
        if st ~= pin.stop or pin.num.text ~= tostring(pin.index) then return false end
        if pin.normalizedX ~= st.x then return false, "position not set" end
    end
    return #pinsShown() > 0
end)())
check("clicking a pin sets a waypoint", (function()
    playerState.waypoint = nil
    local pin = pinsShown()[1]
    pin.scripts.OnMouseUp(pin, "LeftButton")
    return playerState.waypoint ~= nil
end)())
check("changing the displayed map redraws its pins", (function()
    WorldMapFrame:SetMapID(2)
    local n2, want2 = #pinsShown(), stopsOn(2)
    WorldMapFrame:SetMapID(1)
    return n2 == want2, ("%d pins on map 2, %d stops"):format(n2, want2)
end)())
check("provider is added only once", (function()
    WorldMapFrame.scripts.OnShow(WorldMapFrame)
    ns.MapPins:DrawRoute()
    local n = 0
    for _ in pairs(WorldMapFrame.dataProviders) do n = n + 1 end
    return n == 1, tostring(n)
end)())
check("ClearRoute removes pins and DrawRoute restores them", (function()
    ns.MapPins:ClearRoute()
    local cleared = #pinsShown() == 0
    ns.MapPins:DrawRoute()
    return cleared and #pinsShown() == stopsOn(1)
end)())
check("map pins setting off hides pins", (function()
    ns.Settings().mapPins = false
    ns.MapPins:DrawRoute()
    local n = #pinsShown()
    ns.Settings().mapPins = true
    ns.MapPins:DrawRoute()
    return n == 0
end)())
check("OpenAt switches the map without SetMapPoint", (function()
    ns.MapPins:OpenAt(2, 0.5, 0.5)
    local ok = WorldMapFrame.mapID == 2
    WorldMapFrame:SetMapID(1)
    return ok
end)())

---------------------------------------------------------------------------
print(string.format("\n========================================"));
print(string.format("  %d passed, %d failed", pass, fail));
print(string.format("========================================"));
if fail > 0 then os.exit(1) end