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
        function group:addComboBox(optionId, optionName)
            local handle = { id = optionId, name = optionName, value = nil, items = {} }
            function handle:addItem(itemName, selected)
                self.items[#self.items + 1] = { name = itemName, selected = selected }
                if selected then self.value = #self.items end
            end
            function handle:getValue() return self.value end
            function handle:setValue(value) self.value = value end
            self.combos = self.combos or {}
            self.combos[#self.combos + 1] = handle
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
local haulingMode = registrations[1].combos[1]
expect(haulingMode.id == "haulingMode" and haulingMode.items[1].name == "localized:UI_Basekeeper_Options_HaulingMode_Safe"
    and haulingMode.items[1].selected and haulingMode.items[2].name == "localized:UI_Basekeeper_Options_HaulingMode_Yolo",
    "hauling mode uses stable Safe and YOLO indices")
assert(Settings.registerForTests(modOptions))
expect(#registrations == 1, "settings registration is idempotent")
firstOption:setValue(false)
secondOption:setValue(true)
expect(not Settings.getRestoreHeldItems() and Settings.getIncludeKeyRingKeysInUnloadAll(), "settings read current handles")
expect(Settings.getHaulingMode() == "safe", "Safe is the default hauling mode")
haulingMode:setValue(2)
expect(Settings.getHaulingMode() == "yolo", "YOLO reads from persisted combo index two")
haulingMode:setValue(3)
expect(Settings.getHaulingMode() == "safe", "malformed hauling mode falls back to Safe")

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

local aliasedBagValues = { category = "Container" }
local aliasedBag = item(30, aliasedBagValues)
local aliasedMain = inventory({ aliasedBag })
aliasedBagValues.inventory = aliasedMain
local aliasedBagSources, aliasedBagError = Builder.buildAll({
    getInventory = function() return aliasedMain end,
    isEquipped = function(_, candidate) return candidate == aliasedBag end,
}, { x = 0, y = 0, z = 0 }, false, runtime)
expect(not aliasedBagSources and aliasedBagError == "duplicate_source_container", "equipped bags cannot reuse main inventory")

local aliasedRingValues = { category = "Container", type = "keyring" }
local aliasedRing = item(31, aliasedRingValues)
local ringAliasedMain = inventory({ aliasedRing })
aliasedRingValues.inventory = ringAliasedMain
local aliasedRingSources, aliasedRingError = Builder.buildAll({
    getInventory = function() return ringAliasedMain end,
    isEquipped = function() return false end,
}, { x = 0, y = 0, z = 0 }, true, runtime)
expect(not aliasedRingSources and aliasedRingError == "duplicate_source_container", "key rings cannot reuse main inventory")

local invalidBag = item(40, { category = "Container", inventory = inventory({ item(math.huge) }) })
local invalidBagSources, invalidBagError = Builder.buildAll({
    getInventory = function() return inventory({ invalidBag }) end,
    isEquipped = function(_, candidate) return candidate == invalidBag end,
}, { x = 0, y = 0, z = 0 }, false, runtime)
expect(not invalidBagSources and invalidBagError == "invalid_source_item_id", "equipped source contents require finite integer IDs")

local duplicateRingContents = inventory({ item(41) })
local duplicateRing = item(41, { category = "Container", type = "keyring", inventory = duplicateRingContents })
local duplicateRingMain = inventory({ duplicateRing })
local duplicateRingSources, duplicateRingError = Builder.buildAll({
    getInventory = function() return duplicateRingMain end,
    isEquipped = function() return false end,
}, { x = 0, y = 0, z = 0 }, true, runtime)
expect(not duplicateRingSources and duplicateRingError == "duplicate_source_item_id", "key-ring contents share operation-local item IDs")

local sharedDirectItem = item(500)
local firstSharedBag = item(42, { category = "Container", inventory = inventory({ sharedDirectItem }) })
local secondSharedBag = item(43, { category = "Container", inventory = inventory({ sharedDirectItem }) })
local sharedBagsMain = inventory({ firstSharedBag, secondSharedBag })
local sharedBagsSources, sharedBagsError = Builder.buildAll({
    getInventory = function() return sharedBagsMain end,
    isEquipped = function(_, candidate) return candidate == firstSharedBag or candidate == secondSharedBag end,
}, { x = 0, y = 0, z = 0 }, false, runtime)
expect(not sharedBagsSources and sharedBagsError == "duplicate_source_item_id", "equipped sources cannot duplicate direct item IDs")

local selectedDuplicateBag = item(44, { category = "Container", inventory = inventory({ item(44) }) })
local selectedDuplicateMain = inventory({ selectedDuplicateBag })
local selectedDuplicateSources, selectedDuplicateError = Builder.buildSelected({
    getInventory = function() return selectedDuplicateMain end,
    isEquipped = function(_, candidate) return candidate == selectedDuplicateBag end,
}, selectedDuplicateBag:getInventory(), { x = 0, y = 0, z = 0 }, runtime)
expect(not selectedDuplicateSources and selectedDuplicateError == "duplicate_source_item_id", "selected sources share operation-local item IDs")

local nilSelected, nilSelectedError = Builder.buildSelected(character, nil, { x = 0, y = 0, z = 0 }, runtime)
local primitiveSelected, primitiveSelectedError = Builder.buildSelected(character, 1, { x = 0, y = 0, z = 0 }, runtime)
expect(not nilSelected and nilSelectedError == "invalid_selected_container" and not primitiveSelected and primitiveSelectedError == "invalid_selected_container",
    "nil and primitive selected containers reject without lookup")
local mismatchedRingContainer = inventory({ item(600) })
mismatchedRingContainer.containingItem = keyRing
local mismatchedRingSources, mismatchedRingError = Builder.buildSelected(character, mismatchedRingContainer, { x = 0, y = 0, z = 0 }, runtime)
expect(not mismatchedRingSources and mismatchedRingError == "invalid_selected_container", "selected key rings require their exact live inventory")

print("player_source_builder_spec: ok")
