Basekeeper = Basekeeper or {}
if not Basekeeper.CategoryRules then
    require "Basekeeper/CategoryRules"
end
Basekeeper.CategoryCatalog = Basekeeper.CategoryCatalog or {}

local CategoryCatalog = Basekeeper.CategoryCatalog
local CategoryRules = Basekeeper.CategoryRules

local presetDefinitions = {
    ["basekeeper:preset:food"] = {
        id = "basekeeper:preset:food",
        kind = "preset",
        labelKey = "UI_Basekeeper_Category_Food",
        includedCategories = { Food = true },
        whitelist = {},
        blacklist = {},
    },
    ["basekeeper:preset:medical"] = {
        id = "basekeeper:preset:medical",
        kind = "preset",
        labelKey = "UI_Basekeeper_Category_Medical",
        includedCategories = { FirstAid = true, Bandage = true, FirstAidWeapon = true },
        whitelist = {},
        blacklist = {},
    },
    ["basekeeper:preset:tools"] = {
        id = "basekeeper:preset:tools",
        kind = "preset",
        labelKey = "UI_Basekeeper_Category_Tools",
        includedCategories = { Tool = true, ToolWeapon = true },
        whitelist = {},
        blacklist = {},
    },
    ["basekeeper:preset:weapons"] = {
        id = "basekeeper:preset:weapons",
        kind = "preset",
        labelKey = "UI_Basekeeper_Category_Weapons",
        includedCategories = { Weapon = true, WeaponCrafted = true, WeaponImprovised = true },
        whitelist = {},
        blacklist = {},
    },
    ["basekeeper:preset:ammunition"] = {
        id = "basekeeper:preset:ammunition",
        kind = "preset",
        labelKey = "UI_Basekeeper_Category_Ammunition",
        includedCategories = { Ammo = true },
        whitelist = {},
        blacklist = {},
    },
    ["basekeeper:preset:clothing"] = {
        id = "basekeeper:preset:clothing",
        kind = "preset",
        labelKey = "UI_Basekeeper_Category_Clothing",
        includedCategories = { Clothing = true, ProtectiveGear = true, Accessory = true },
        whitelist = {},
        blacklist = {},
    },
    ["basekeeper:preset:literature"] = {
        id = "basekeeper:preset:literature",
        kind = "preset",
        labelKey = "UI_Basekeeper_Category_Literature",
        includedCategories = { Literature = true, SkillBook = true, RecipeResource = true, Cartography = true },
        whitelist = {},
        blacklist = {},
    },
    ["basekeeper:preset:mechanics"] = {
        id = "basekeeper:preset:mechanics",
        kind = "preset",
        labelKey = "UI_Basekeeper_Category_Mechanics",
        includedCategories = { VehicleMaintenance = true, VehicleMaintenanceWeapon = true },
        whitelist = {},
        blacklist = {},
    },
    ["basekeeper:preset:crafting_materials"] = {
        id = "basekeeper:preset:crafting_materials",
        kind = "preset",
        labelKey = "UI_Basekeeper_Category_CraftingMaterials",
        includedCategories = { Material = true, MaterialWeapon = true },
        whitelist = {},
        blacklist = {},
    },
}

local presetIds = {
    "basekeeper:preset:food",
    "basekeeper:preset:medical",
    "basekeeper:preset:tools",
    "basekeeper:preset:weapons",
    "basekeeper:preset:ammunition",
    "basekeeper:preset:clothing",
    "basekeeper:preset:literature",
    "basekeeper:preset:mechanics",
    "basekeeper:preset:crafting_materials",
}

local function copyPreset(definition)
    return {
        id = definition.id,
        kind = definition.kind,
        labelKey = definition.labelKey,
        includedCategories = CategoryRules.normalize(definition).includedCategories,
        whitelist = {},
        blacklist = {},
    }
end

function CategoryCatalog.newPresetCopies()
    local copies = {}
    for _, id in ipairs(presetIds) do
        copies[id] = copyPreset(presetDefinitions[id])
    end
    return copies
end

function CategoryCatalog.getPresetIds()
    local copies = {}
    for index, id in ipairs(presetIds) do
        copies[index] = id
    end
    return copies
end

function CategoryCatalog.discoverDisplayCategories()
    local categories = {}
    local allItems = getAllItems and getAllItems() or nil
    if not allItems then
        return categories
    end

    local function addItem(item)
        local category = CategoryRules.getDisplayCategory(item)
        if category and category ~= "" then
            categories[category] = true
        end
    end

    if type(allItems.size) == "function" and type(allItems.get) == "function" then
        for index = 0, allItems:size() - 1 do
            addItem(allItems:get(index))
        end
    elseif type(allItems) == "table" then
        for _, item in ipairs(allItems) do
            addItem(item)
        end
    end

    local sorted = {}
    for category in pairs(categories) do
        table.insert(sorted, category)
    end
    table.sort(sorted)
    return sorted
end
