Basekeeper = Basekeeper or {}
if not Basekeeper.ItemSnapshot then
    require "Basekeeper/ItemSnapshot"
end
Basekeeper.PlayerSourceBuilder = Basekeeper.PlayerSourceBuilder or {}

local PlayerSourceBuilder = Basekeeper.PlayerSourceBuilder
local ItemSnapshot = Basekeeper.ItemSnapshot

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function validAnchor(anchor)
    return type(anchor) == "table" and isFiniteNumber(anchor.x) and isFiniteNumber(anchor.y) and isFiniteNumber(anchor.z)
end

local function copyAnchor(anchor)
    return { x = anchor.x, y = anchor.y, z = anchor.z }
end

local function runtimeValue(runtime, name)
    if runtime and runtime[name] ~= nil then
        return runtime[name]
    end
    return _G[name]
end

local function itemId(item)
    if not item or type(item.getID) ~= "function" then
        return nil, "invalid_source_item_id"
    end
    local id = item:getID()
    if not isFiniteNumber(id) or id ~= math.floor(id) then
        return nil, "invalid_source_item_id"
    end
    return id
end

local function isKeyRing(item, runtime)
    local itemType = runtimeValue(runtime, "ItemType")
    if itemType and itemType.KEY_RING ~= nil and type(item.isItemType) == "function"
        and item:isItemType(itemType.KEY_RING) == true then
        return true
    end
    local itemTag = runtimeValue(runtime, "ItemTag")
    return itemTag and itemTag.KEY_RING ~= nil and type(item.hasTag) == "function"
        and item:hasTag(itemTag.KEY_RING) == true
end

local function directMainItems(character)
    if not character or type(character.getInventory) ~= "function" then
        return nil, nil, "invalid_character"
    end
    local main = character:getInventory()
    local items, itemsError = ItemSnapshot.directItems(main)
    if not items then
        return nil, nil, itemsError
    end
    return main, items
end

local function currentHands(character)
    local primary = type(character.getPrimaryHandItem) == "function" and character:getPrimaryHandItem() or nil
    local secondary = type(character.getSecondaryHandItem) == "function" and character:getSecondaryHandItem() or nil
    return primary, secondary
end

local function equippedSource(item, character)
    if type(item.getCategory) ~= "function" or item:getCategory() ~= "Container" then
        return nil
    end
    if type(character.isEquipped) ~= "function" then
        return nil, "invalid_character"
    end
    if character:isEquipped(item) ~= true then
        return nil
    end
    if type(item.getInventory) ~= "function" then
        return nil, "invalid_source_container"
    end
    local container = item:getInventory()
    if not container then
        return nil, "invalid_source_container"
    end
    return container
end

local function descriptor(key, container, anchor, items)
    local copiedItems = {}
    for index, item in ipairs(items) do
        copiedItems[index] = item
    end
    return { key = key, container = container, anchor = copyAnchor(anchor), items = copiedItems }
end

local function scanMain(character, runtime)
    local main, mainItems, mainError = directMainItems(character)
    if not main then
        return nil, mainError
    end

    local byItem = {}
    local sourceContainers = {}
    local rings = {}
    local seenIds = {}
    for _, item in ipairs(mainItems) do
        local id, idError = itemId(item)
        if not id then
            return nil, idError
        end
        if seenIds[id] then
            return nil, "duplicate_source_item_id"
        end
        seenIds[id] = true

        local ring = isKeyRing(item, runtime)
        local bag, bagError = nil, nil
        if not ring then
            bag, bagError = equippedSource(item, character)
        end
        if bagError then
            return nil, bagError
        end
        local facts = { item = item, id = id, keyRing = ring, bag = bag }
        byItem[item] = facts
        if bag then
            if sourceContainers[bag] then
                return nil, "duplicate_source_container"
            end
            sourceContainers[bag] = true
        end
        if ring then
            rings[#rings + 1] = facts
        end
    end
    return { main = main, items = mainItems, byItem = byItem, rings = rings, sourceContainers = sourceContainers }
end

local function mainCandidates(scan, character)
    local primary, secondary = currentHands(character)
    local candidates = {}
    for _, item in ipairs(scan.items) do
        local facts = scan.byItem[item]
        local retained = facts.keyRing or facts.bag ~= nil
        if not retained and type(character.isEquipped) == "function" and character:isEquipped(item) == true
            and item ~= primary and item ~= secondary then
            retained = true
        end
        if not retained then
            candidates[#candidates + 1] = item
        end
    end
    return candidates
end

local function sourceItems(container)
    return ItemSnapshot.directItems(container)
end

local function ringContainer(facts)
    if type(facts.item.getInventory) ~= "function" then
        return nil, "invalid_source_container"
    end
    local container = facts.item:getInventory()
    if not container then
        return nil, "invalid_source_container"
    end
    return container
end

function PlayerSourceBuilder.buildAll(character, anchor, includeKeyRingKeys, runtime)
    if not validAnchor(anchor) then
        return nil, "invalid_anchor"
    end
    if type(includeKeyRingKeys) ~= "boolean" then
        return nil, "invalid_include_key_ring_keys"
    end
    local scan, scanError = scanMain(character, runtime)
    if not scan then
        return nil, scanError
    end

    local sources = { descriptor("main", scan.main, anchor, mainCandidates(scan, character)) }
    local bags = {}
    for _, item in ipairs(scan.items) do
        local facts = scan.byItem[item]
        if facts.bag then
            bags[#bags + 1] = facts
        end
    end
    table.sort(bags, function(left, right) return left.id < right.id end)
    for _, facts in ipairs(bags) do
        local items, itemsError = sourceItems(facts.bag)
        if not items then
            return nil, itemsError
        end
        sources[#sources + 1] = descriptor("equipped:" .. tostring(facts.id), facts.bag, anchor, items)
    end
    if includeKeyRingKeys then
        table.sort(scan.rings, function(left, right) return left.id < right.id end)
        for _, facts in ipairs(scan.rings) do
            local container, containerError = ringContainer(facts)
            if not container then
                return nil, containerError
            end
            if scan.sourceContainers[container] then
                return nil, "duplicate_source_container"
            end
            scan.sourceContainers[container] = true
            local items, itemsError = sourceItems(container)
            if not items then
                return nil, itemsError
            end
            sources[#sources + 1] = descriptor("keyring:" .. tostring(facts.id), container, anchor, items)
        end
    end
    return sources
end

function PlayerSourceBuilder.buildSelected(character, selectedContainer, anchor, runtime)
    if not validAnchor(anchor) then
        return nil, "invalid_anchor"
    end
    local scan, scanError = scanMain(character, runtime)
    if not scan then
        return nil, scanError
    end
    if selectedContainer == scan.main then
        return { descriptor("main", scan.main, anchor, mainCandidates(scan, character)) }
    end

    for _, item in ipairs(scan.items) do
        local facts = scan.byItem[item]
        if facts.bag and selectedContainer == facts.bag then
            local items, itemsError = sourceItems(facts.bag)
            if not items then
                return nil, itemsError
            end
            return { descriptor("equipped:" .. tostring(facts.id), facts.bag, anchor, items) }
        end
    end
    if type(selectedContainer.getContainingItem) == "function" then
        local containingItem = selectedContainer:getContainingItem()
        local facts = scan.byItem[containingItem]
        if facts and facts.keyRing then
            local items, itemsError = sourceItems(selectedContainer)
            if not items then
                return nil, itemsError
            end
            return { descriptor("keyring:" .. tostring(facts.id), selectedContainer, anchor, items) }
        end
    end
    return nil, "invalid_selected_container"
end
