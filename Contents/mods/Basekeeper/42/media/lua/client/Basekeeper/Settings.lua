Basekeeper = Basekeeper or {}
Basekeeper.Settings = Basekeeper.Settings or {}

local Settings = Basekeeper.Settings

local restoreHeldItems = nil
local includeKeyRingKeysInUnloadAll = nil
local haulingMode = nil
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
    if not group or type(group.addTickBox) ~= "function" or type(group.addComboBox) ~= "function" then
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
    haulingMode = group:addComboBox(
        "haulingMode",
        translated("UI_Basekeeper_Options_HaulingMode")
    )
    if haulingMode and type(haulingMode.addItem) == "function" then
        haulingMode:addItem(translated("UI_Basekeeper_Options_HaulingMode_Safe"), true)
        haulingMode:addItem(translated("UI_Basekeeper_Options_HaulingMode_Yolo"), false)
    else
        haulingMode = nil
    end
    if not restoreHeldItems or not includeKeyRingKeysInUnloadAll or not haulingMode then
        restoreHeldItems = nil
        includeKeyRingKeysInUnloadAll = nil
        haulingMode = nil
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

function Settings.getHaulingMode()
    if haulingMode and haulingMode:getValue() == 2 then
        return "yolo"
    end
    return "safe"
end

local modOptions = require "PZAPI/ModOptions"
if (not modOptions or type(modOptions.create) ~= "function") and PZAPI then
    modOptions = PZAPI.ModOptions
end
register(modOptions)
