Basekeeper = Basekeeper or {}
Basekeeper.Settings = Basekeeper.Settings or {}

local Settings = Basekeeper.Settings

local restoreHeldItems = nil
local includeKeyRingKeysInUnloadAll = nil
local registered = false

local function translated(key)
    if type(getText) == "function" then
        return getText(key)
    end
    return key
end

local function register(modOptions)
    if registered then
        return true
    end
    if not modOptions or type(modOptions.create) ~= "function" then
        return nil, "invalid_mod_options"
    end

    local group = modOptions:create("Basekeeper", translated("UI_Basekeeper_Options_Group"))
    if not group or type(group.addTickBox) ~= "function" then
        return nil, "invalid_mod_options_group"
    end

    restoreHeldItems = group:addTickBox(
        "restoreHeldItems",
        translated("UI_Basekeeper_Options_RestoreHeldItems"),
        true,
        translated("UI_Basekeeper_Options_RestoreHeldItems_Tooltip")
    )
    includeKeyRingKeysInUnloadAll = group:addTickBox(
        "includeKeyRingKeysInUnloadAll",
        translated("UI_Basekeeper_Options_IncludeKeyRingKeys"),
        false,
        translated("UI_Basekeeper_Options_IncludeKeyRingKeys_Tooltip")
    )
    if not restoreHeldItems or not includeKeyRingKeysInUnloadAll then
        restoreHeldItems = nil
        includeKeyRingKeysInUnloadAll = nil
        return nil, "invalid_mod_options_tickbox"
    end

    registered = true
    return true
end

function Settings.registerForTests(modOptions)
    return register(modOptions)
end

function Settings.getRestoreHeldItems()
    if not restoreHeldItems then
        return true
    end
    return restoreHeldItems:getValue() == true
end

function Settings.getIncludeKeyRingKeysInUnloadAll()
    return includeKeyRingKeysInUnloadAll and includeKeyRingKeysInUnloadAll:getValue() == true or false
end

local modOptions = require "PZAPI/ModOptions"
if (not modOptions or type(modOptions.create) ~= "function") and PZAPI then
    modOptions = PZAPI.ModOptions
end
register(modOptions)
