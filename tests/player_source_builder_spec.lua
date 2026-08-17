local function expect(condition, message)
    if not condition then error(message, 2) end
end

local registrations = {}
local modOptions = {
    create = function(_, id, name)
        local group = { id = id, name = name, tickboxes = {} }
        function group:addTickBox(optionId, optionName, default, tooltip)
            local handle = { id = optionId, name = optionName, value = default, default = default, tooltip = tooltip }
            function handle:getValue() return self.value end
            function handle:setValue(value) self.value = value end
            self.tickboxes[#self.tickboxes + 1] = handle
            return handle
        end
        registrations[#registrations + 1] = group
        return group
    end,
}
getText = function(key) return "localized:" .. key end
local realRequire = require
require = function(path)
    expect(path == "PZAPI/ModOptions", "settings should require the vanilla ModOptions API")
    return modOptions
end
dofile("Contents/mods/Basekeeper/42/media/lua/client/Basekeeper/Settings.lua")
require = realRequire

local Settings = Basekeeper.Settings
expect(#registrations == 1 and registrations[1].id == "Basekeeper" and registrations[1].name == "localized:UI_Basekeeper_Options_Group",
    "settings register one localized Basekeeper group")
local firstOption, secondOption = registrations[1].tickboxes[1], registrations[1].tickboxes[2]
expect(firstOption.id == "restoreHeldItems" and firstOption.default == true and secondOption.id == "includeKeyRingKeysInUnloadAll" and secondOption.default == false,
    "settings use stable IDs and settled defaults")
expect(firstOption.tooltip == "localized:UI_Basekeeper_Options_RestoreHeldItems_Tooltip" and secondOption.tooltip == "localized:UI_Basekeeper_Options_IncludeKeyRingKeys_Tooltip",
    "settings localize both tooltips")
assert(Settings.registerForTests(modOptions))
expect(#registrations == 1, "settings registration is idempotent")
firstOption:setValue(false)
secondOption:setValue(true)
expect(not Settings.getRestoreHeldItems() and Settings.getIncludeKeyRingKeysInUnloadAll(), "settings read current handles")

dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/CategoryRules.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ItemSnapshot.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/client/Basekeeper/PlayerSourceBuilder.lua")

local Builder = Basekeeper.PlayerSourceBuilder
local runtime = { ItemType = { KEY_RING = "keyring" }, ItemTag = { KEY_RING = "keyring-tag" } }

local function inventory(items)
    local result = { items = items, containingItem = nil }
    function result:getItems() return self.items end
    function result:getContainingItem() return self.containingItem end
    return result
end

local function item(id, values)
    values = values or {}
    local result = { id = id, category = values.category or "Misc", type = values.type, tags = values.tags or {}, inventoryReads = 0 }
    function result:getID() return self.id end
    function result:getCategory() return self.category end
    function result:isItemType(value) return self.type == value end
    function result:hasTag(value) return self.tags[value] == true end
    function result:getInventory() self.inventoryReads = self.inventoryReads + 1 return values.inventory end
    return result
end

local bagContents = inventory({ item(101) })
local secondBagContents = inventory({ item(102) })
local ringContents = inventory({ item(201), item(202) })
local heldOrdinary = item(1)
local wornItem = item(2)
local favorite = item(3)
local looseBag = item(4, { category = "Container", inventory = inventory({ item(401) }) })
local equippedBag = item(10, { category = "Container", inventory = bagContents })
local secondBag = item(8, { category = "Container", inventory = secondBagContents })
local keyRing = item(20, { category = "Container", type = "keyring", inventory = ringContents })
ringContents.containingItem = keyRing
local main = inventory({ heldOrdinary, wornItem, favorite, looseBag, equippedBag, keyRing, secondBag })
local equipped = { [wornItem] = true, [equippedBag] = true, [keyRing] = true, [secondBag] = true }
local character = {
    getInventory = function() return main end,
    isEquipped = function(_, candidate) return equipped[candidate] == true end,
    getPrimaryHandItem = function() return heldOrdinary end,
    getSecondaryHandItem = function() return nil end,
}

local sources = assert(Builder.buildAll(character, { x = 1, y = 2, z = 3 }, false, runtime))
expect(#sources == 3 and sources[1].key == "main" and sources[2].key == "equipped:8" and sources[3].key == "equipped:10",
    "all sources are main first then equipped bags ordered by item ID")
expect(#sources[1].items == 3 and sources[1].items[1] == heldOrdinary and sources[1].items[2] == favorite and sources[1].items[3] == looseBag,
    "main retains worn, source-bag, and key-ring objects while held ordinary and favorites remain planner facts")
expect(looseBag.inventoryReads == 0 and keyRing.inventoryReads == 0,
    "unequipped bags and equipped category-Container key rings remain direct objects without entering them by default")
expect(sources[2].items[1]:getID() == 102 and sources[3].items[1]:getID() == 101, "equipped sources use direct contents")
sources[1].anchor.x = 99
sources[1].items[1] = nil
expect(sources[2].anchor.x == 1 and heldOrdinary ~= nil, "source anchors and item arrays are independent copies")

local allWithRings = assert(Builder.buildAll(character, { x = 1, y = 2, z = 3 }, true, runtime))
expect(#allWithRings == 4 and allWithRings[4].key == "keyring:20" and #allWithRings[4].items == 2,
    "opted-in key rings add one direct source after equipped bags")
local selectedRing = assert(Builder.buildSelected(character, ringContents, { x = 0, y = 0, z = 0 }, runtime))
expect(#selectedRing == 1 and selectedRing[1].key == "keyring:20" and #selectedRing[1].items == 2,
    "selected direct key rings process direct keys regardless of the all option")
local selectedBag = assert(Builder.buildSelected(character, bagContents, { x = 0, y = 0, z = 0 }, runtime))
expect(selectedBag[1].key == "equipped:10", "selected directly equipped bags are accepted")
local selectedMain = assert(Builder.buildSelected(character, main, { x = 0, y = 0, z = 0 }, runtime))
expect(selectedMain[1].key == "main" and #selectedMain[1].items == 3, "selected main uses the same retained-object boundary")
local invalidSelected, invalidSelectedError = Builder.buildSelected(character, inventory({}), { x = 0, y = 0, z = 0 }, runtime)
expect(not invalidSelected and invalidSelectedError == "invalid_selected_container", "nested or unrelated containers are rejected")
local invalidOption, invalidOptionError = Builder.buildAll(character, { x = 0, y = 0, z = 0 }, nil, runtime)
expect(not invalidOption and invalidOptionError == "invalid_include_key_ring_keys", "all builder requires an explicit boolean key-ring option")

local duplicate = item(10)
local duplicateMain = inventory({ equippedBag, duplicate })
local duplicateCharacter = {
    getInventory = function() return duplicateMain end,
    isEquipped = function(_, candidate) return candidate == equippedBag end,
}
local duplicateSources, duplicateError = Builder.buildAll(duplicateCharacter, { x = 0, y = 0, z = 0 }, false, runtime)
expect(not duplicateSources and duplicateError == "duplicate_source_item_id", "duplicate direct IDs reject rather than merge sources")

local zeroId = item(0)
local negativeId = item(-1)
local nonPositiveCharacter = {
    getInventory = function() return inventory({ zeroId, negativeId }) end,
    isEquipped = function() return false end,
}
local nonPositiveSources = assert(Builder.buildAll(nonPositiveCharacter, { x = 0, y = 0, z = 0 }, false, runtime))
expect(#nonPositiveSources == 1 and #nonPositiveSources[1].items == 2,
    "zero and negative finite integer item IDs remain valid stable IDs")
local fractionalSources, fractionalError = Builder.buildAll({
    getInventory = function() return inventory({ item(1.5) }) end,
    isEquipped = function() return false end,
}, { x = 0, y = 0, z = 0 }, false, runtime)
expect(not fractionalSources and fractionalError == "invalid_source_item_id", "non-integer item IDs reject")
local nanSources, nanError = Builder.buildAll({
    getInventory = function() return inventory({ item(0 / 0) }) end,
    isEquipped = function() return false end,
}, { x = 0, y = 0, z = 0 }, false, runtime)
expect(not nanSources and nanError == "invalid_source_item_id", "NaN item IDs reject")

print("player_source_builder_spec: ok")
