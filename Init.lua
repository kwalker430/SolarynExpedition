--[[---------------------------------------------------------------------------
    Solaryn's Expedition — namespace bootstrap and event dispatcher.

    Loaded first (see SolarynExpedition.toc). Creates the shared namespace table and
    the single event frame every other module registers against, so a bug in one
    module cannot stop the others from receiving events.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...

ns = _G.SolarynExpedition or {}
_G.SolarynExpedition = ns

ns.ADDON_NAME = ADDON_NAME
-- The TOC's "## Version" is the single source of truth.
local getMetadata = (_G.C_AddOns and _G.C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
ns.version = (getMetadata and getMetadata(ADDON_NAME, "Version")) or "1.2.0"

-- Build/interface info, captured for the About line and for API capability
-- probes. GetBuildInfo() is 5-tuples (version, build, date, tocVersion, isTest).
local _, _, _, tocVersion = GetBuildInfo()
ns.tocVersion = tocVersion

---------------------------------------------------------------------------
-- Event dispatcher
---------------------------------------------------------------------------
local handlers = {}
ns.eventHandlers = handlers

local dispatcher = CreateFrame("Frame")
ns.dispatcher = dispatcher

--- Client events are ALL_CAPS; our own events (route_changed etc.) are
-- lowercase and never touch the frame.
local function isGameEvent(event)
    return type(event) == "string" and event:match("^[A-Z][A-Z0-9_]*$") ~= nil
end
ns.IsGameEvent = isGameEvent

--- Register a handler. Client events are also registered on the dispatcher
-- frame; without that the client never delivers them and the handler is
-- dead code. An unknown event name errors in the client, so registration is
-- guarded and reported rather than allowed to abort the calling file.
function ns:RegisterEvent(event, fn, owner)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], { fn = fn, owner = owner })
    if isGameEvent(event) and not dispatcher:IsEventRegistered(event) then
        local ok, err = pcall(dispatcher.RegisterEvent, dispatcher, event)
        if not ok then
            ns.badEvents = ns.badEvents or {}
            ns.badEvents[event] = tostring(err)
            if ns.Debug then ns:Debug("cannot register event %s: %s", event, tostring(err)) end
        end
    end
end

function ns:UnregisterEvent(event, owner)
    local list = handlers[event]
    if not list then return end
    for i = #list, 1, -1 do
        if owner == nil or list[i].owner == owner then
            table.remove(list, i)
        end
    end
    -- Stop the client delivering an event nobody listens to any more.
    if #list == 0 and isGameEvent(event) then
        pcall(dispatcher.UnregisterEvent, dispatcher, event)
    end
end

local function onEvent(self, event, ...)
    local list = handlers[event]
    if not list then return end
    -- Iterate a snapshot: handlers may add/remove registrations during dispatch.
    local snapshot = {}
    for i = 1, #list do snapshot[i] = list[i] end
    for i = 1, #snapshot do
        local ok, err = pcall(snapshot[i].fn, event, ...)
        if not ok then
            ns:Debug("event error in %s: %s", event, tostring(err))
        end
    end
end

dispatcher:SetScript("OnEvent", onEvent)

--- Fire a custom event to registered handlers. Handlers receive (event, ...),
--- matching the WoW convention. `owner` is bookkeeping only — it is never
--- passed as an argument.
function ns:Fire(event, ...)
    local list = handlers[event]
    if not list then return end
    local snapshot = {}
    for i = 1, #list do snapshot[i] = list[i] end
    for i = 1, #snapshot do
        local ok, err = pcall(snapshot[i].fn, event, ...)
        if not ok then
            ns:Debug("dispatch error in %s: %s", event, tostring(err))
        end
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function ns.OnAddonLoaded(_, name)
    if name ~= ADDON_NAME then return end
    -- Only our own handler: other modules may still want ADDON_LOADED.
    ns:UnregisterEvent("ADDON_LOADED", ns)

    _G.SolarynDB = _G.SolarynDB or {}
    _G.SolarynCharDB = _G.SolarynCharDB or {}

    local db = _G.SolarynDB
    db.schemaVersion = db.schemaVersion or 1
    db.settings = db.settings or {}
    db.overrides = db.overrides or {}       -- account-wide, hand-recorded objective pins
    db.characters = db.characters or {}     -- account-wide summary index

    -- Merge in defaults without clobbering user choices.
    for k, v in pairs(ns.Defaults.settings) do
        if db.settings[k] == nil then db.settings[k] = v end
    end

    -- One-time settings migrations, for defaults that changed meaning.
    db.settingsVersion = db.settingsVersion or 1
    if db.settingsVersion < 2 then
        -- v2: the guide waits for quest work to be done instead of moving on
        -- when you arrive (arriving at a camp is when the work starts). The
        -- old default was saved into everyone's settings, so flip it once.
        db.settings.advanceWhenDone = true
        db.settingsVersion = 2
    end

    local char = _G.SolarynCharDB
    char.schemaVersion = char.schemaVersion or 1
    char.zones = char.zones or {}
    char.route = char.route or {}
    char.stats = char.stats or {}
    char.suggestOverrides = char.suggestOverrides or {}

    -- Probe which APIs this build actually exposes. Forever is in beta and the
    -- API surface is still moving; every consumer of an optional API checks
    -- ns.Has first and degrades instead of erroring.
    ns:ProbeCapabilities()

    -- Load the client's map tree early: the suggester and zone tracker both
    -- need it, and deferring this left them reporting "map tree empty" even
    -- with quests in the log.
    if ns.ZoneData and ns.ZoneData.Load then ns.ZoneData:Load() end
    ns:CacheMapNames()

    if ns.Modules then
        for name2, mod in pairs(ns.Modules) do
            if type(mod) == "table" and type(mod.Initialize) == "function" then
                mod.initialized = true
                local ok, err = pcall(mod.Initialize, mod)
                if not ok then
                    -- Report init failures loudly rather than letting a broken
                    -- module look like it simply has no features.
                    mod.initError = tostring(err)
                    ns:Error("module '%s' failed to initialise: %s", tostring(name2), tostring(err))
                end
            end
        end
    end
end

ns:RegisterEvent("ADDON_LOADED", ns.OnAddonLoaded, ns)

function ns.OnPlayerLogin()
    ns.playerName = UnitName("player")
    ns.realmName = GetRealmName()
    ns.charKey = (ns.playerName or "?") .. "-" .. (ns.realmName or "?")

    local db = _G.SolarynDB
    db.characters[ns.charKey] = db.characters[ns.charKey] or { zones = {}, lastSeen = 0 }

    if ns.Modules then
        for name, mod in pairs(ns.Modules) do
            if type(mod) == "table" and type(mod.OnLogin) == "function" then
                local ok, err = pcall(mod.OnLogin, mod)
                if not ok then
                    mod.loginError = tostring(err)
                    ns:Error("module '%s' failed at login: %s", tostring(name), tostring(err))
                end
            end
        end
    end

    if db.settings.showLoginMessage then
        ns:Print("v%s loaded — type /sol for the panel.", ns.version or "?")
    end
end

ns:RegisterEvent("PLAYER_LOGIN", ns.OnPlayerLogin, ns)

---------------------------------------------------------------------------
-- Module registry
---------------------------------------------------------------------------
ns.Modules = ns.Modules or {}

--- Register a module so it receives Initialize/OnLogin lifecycle callbacks.
function ns:RegisterModule(name, mod)
    ns.Modules[name] = mod
    -- Late registration (after login) still initializes immediately.
    if mod.initialized then return end
    if _G.SolarynDB and mod.Initialize then
        mod.initialized = true
        pcall(mod.Initialize, mod)
    end
    if ns.playerName and mod.OnLogin then
        pcall(mod.OnLogin, mod)
    end
end
