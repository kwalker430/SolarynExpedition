--[[---------------------------------------------------------------------------
    Load Solaryn's Expedition into the mock WoW environment and report what actually
    happened, without letting Init.lua's pcall hide failures.

    Run:  lua5.1 test/load_addon.lua
-----------------------------------------------------------------------------]]

package.path = "./?.lua;./test/?.lua;" .. package.path

local Mock = require("mockenv")
Mock.install()

-- Load every file listed in the TOC, in order.
local toc = io.open("SolarynExpedition.toc", "r")
local tocText = toc:read("*a")
toc:close()

local files = {}
for line in tocText:gmatch("[^\r\n]+") do
    local f = line:match("^([^#%s].*%.lua)%s*$")
    if f then table.insert(files, f) end
end

_G.ns = nil

for _, f in ipairs(files) do
    local chunk, err = loadfile(f)
    if not chunk then
        print(string.format("  LOAD FAIL  %-24s %s", f, tostring(err)))
        os.exit(1)
    end
    -- Faithful to the client: one vararg (the addon name) per file.
    local ok, runErr = pcall(chunk, "SolarynExpedition")
    if not ok then
        print(string.format("  RUN  FAIL  %-24s %s", f, tostring(runErr)))
        os.exit(1)
    end
    print(string.format("  ok         %s", f))
end

-- Run the addon lifecycle the way the client does.
ns:Fire("ADDON_LOADED", "SolarynExpedition")

print("\n--- registered modules, with the initialized flag Init.lua sets ---")
local names = {}
for n in pairs(ns.Modules) do table.insert(names, n) end
table.sort(names)
for _, n in ipairs(names) do
    print(string.format("  %-16s initialized=%s", n, tostring(ns.Modules[n].initialized)))
end

print("\n--- what actually got built ---")
print("  SavedVariables:      " .. tostring(_G.SolarynDB ~= nil))
print("  Per-character DB:    " .. tostring(_G.SolarynCharDB ~= nil))
print("  /sol wired:           " .. tostring(SlashCmdList["SOLARYNEXPEDITION"] ~= nil))
print("  minimap button:      " .. tostring(ns.MinimapButton:GetButton() ~= nil))
print("  panel frame:         " .. tostring(ns.Panel ~= nil))
print("  capabilities probed: " .. tostring(ns.Has.questObjectives ~= nil))

-- Now drive login, the way PLAYER_LOGIN does.
ns.playerName = UnitName("player")
ns.realmName = GetRealmName()
ns.charKey = (ns.playerName or "?") .. "-" .. (ns.realmName or "?")
ns:Fire("PLAYER_LOGIN")

print("\n--- after PLAYER_LOGIN ---")
print("  charDB zones table:  " .. tostring(_G.SolarynCharDB.zones ~= nil))
print("  account character:   " .. tostring(_G.SolarynDB.characters[ns.charKey] ~= nil))
