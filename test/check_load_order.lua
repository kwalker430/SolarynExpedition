-- Verify load order and that each file sees what it needs from earlier ones.
package.path = "./?.lua;./test/?.lua;" .. package.path
local M = require("mockenv")
M.install()

local toc = io.open("SolarynExpedition.toc"):read("*a")
_G.ns = nil

-- What each file must find already defined when it runs.
local REQUIREMENTS = {
    ["Core_Util.lua"]       = { "Defaults" },
    ["Core_QuestData.lua"]  = { "ZoneData", "Overrides" },
    ["Core_QuestGivers.lua"] = { "QuestData" },
    ["Core_Route.lua"]      = { "QuestData", "Overrides", "Settings" },
    ["Core_Suggest.lua"]    = { "QuestData", "ZoneData", "Explored", "Chains" },
    ["Core_Explored.lua"]   = { "ZoneData" },
    ["UI_Panel.lua"]        = { "Suggest", "Route", "Explored", "MapPins", "Widgets" },
    ["UI_Options.lua"]      = { "Widgets", "Settings" },
    ["UI_Minimap.lua"]      = { "Panel" },
    ["UI_HUD.lua"]          = { "Widgets", "Route", "Panel" },
    ["UI_Tooltip.lua"]      = { "QuestData", "Route" },
}

local problems = 0

for line in toc:gmatch("[^\r\n]+") do
    local f = line:match("^([^#%s].*%.lua)%s*$")
    if f then
        local needs = REQUIREMENTS[f]
        local missing = {}
        if needs and ns then
            for _, key in ipairs(needs) do
                if ns[key] == nil then table.insert(missing, key) end
            end
        end
        -- Faithful to the client: one vararg (the addon name) per file.
        local ok, err = pcall(loadfile(f), "SolarynExpedition")
        if not ok then
            print(string.format("  FAIL  %-22s %s", f, tostring(err)))
            problems = problems + 1
        elseif #missing > 0 then
            print(string.format("  ORDER %-22s missing before load: %s", f, table.concat(missing, ", ")))
            problems = problems + 1
        else
            print(string.format("  ok    %-22s (deps satisfied)", f))
        end
    end
end

print(string.format("\n%d load-order problem(s)", problems))
if problems > 0 then os.exit(1) end
