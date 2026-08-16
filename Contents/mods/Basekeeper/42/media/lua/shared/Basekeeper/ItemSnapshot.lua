Basekeeper = Basekeeper or {}
if not Basekeeper.CategoryRules then
    require "Basekeeper/CategoryRules"
end
Basekeeper.ItemSnapshot = Basekeeper.ItemSnapshot or {}

local ItemSnapshot = Basekeeper.ItemSnapshot
local CategoryRules = Basekeeper.CategoryRules

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isFiniteInteger(value)
    return isFiniteNumber(value) and value == math.floor(value)
end

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function clampPercent(value)
    if value < 0 then
        return 0
    end
    if value > 100 then
        return 100
    end
    return value
end

local function runtimeValue(runtime, name)
    if runtime and runtime[name] ~= nil then
        return runtime[name]
    end
    return _G[name]
end

local function isInstance(runtime, item, className)
    local instanceOf = runtimeValue(runtime, "instanceof")
    return type(instanceOf) == "function" and instanceOf(item, className) == true
end

local function hasTag(item, tag)
    if type(item.hasTag) ~= "function" then
        return nil, "invalid_item_has_tag"
    end
    return item:hasTag(tag) == true
end

function ItemSnapshot.directItems(container)
    if not container or type(container.getItems) ~= "function" then
        return nil, "invalid_container_items"
    end
    local items = container:getItems()
    if not items then
        return nil, "invalid_container_items"
    end

    if type(items.size) == "function" and type(items.get) == "function" then
        local size = items:size()
        if not isFiniteInteger(size) or size < 0 then
            return nil, "invalid_container_items"
        end
        local copied = {}
        for index = 0, size - 1 do
            copied[#copied + 1] = items:get(index)
        end
        return copied
    end

    if type(items) ~= "table" then
        return nil, "invalid_container_items"
    end
    local copied = {}
    for index = 1, #items do
        copied[index] = items[index]
    end
    return copied
end

function ItemSnapshot.fromItem(item, runtime)
    if not item or type(item.getID) ~= "function" or type(item.getFullType) ~= "function"
        or type(item.isFavorite) ~= "function" or type(item.getUnequippedWeight) ~= "function" then
        return nil, "invalid_item"
    end

    local itemId = item:getID()
    local fullType = item:getFullType()
    local favorite = item:isFavorite()
    local weight = item:getUnequippedWeight()
    if not isFiniteInteger(itemId) or not nonEmptyString(fullType) or type(favorite) ~= "boolean"
        or not isFiniteNumber(weight) or weight < 0 then
        return nil, "invalid_item"
    end

    local classification = CategoryRules.classify(item)
    local facts = {
        itemId = itemId,
        fullType = fullType,
        displayCategory = classification.displayCategory,
        favorite = favorite,
        weight = weight,
        conditionPercent = nil,
        remainingPercent = nil,
    }

    local itemTag = runtimeValue(runtime, "ItemTag")
    local showCondition = false
    if itemTag and itemTag.SHOW_CONDITION ~= nil then
        local tagged, tagError = hasTag(item, itemTag.SHOW_CONDITION)
        if tagged == nil then
            return nil, tagError
        end
        showCondition = tagged
    end
    if isInstance(runtime, item, "HandWeapon") or showCondition then
        if type(item.getCondition) ~= "function" or type(item.getConditionMax) ~= "function" then
            return nil, "invalid_item_condition"
        end
        local condition = item:getCondition()
        local conditionMax = item:getConditionMax()
        if not isFiniteNumber(condition) or not isFiniteNumber(conditionMax) or conditionMax <= 0 then
            return nil, "invalid_item_condition"
        end
        facts.conditionPercent = clampPercent(condition / conditionMax * 100)
    end

    if isInstance(runtime, item, "Drainable") then
        local hidden = false
        if itemTag and itemTag.HIDE_REMAINING ~= nil then
            local tagged, tagError = hasTag(item, itemTag.HIDE_REMAINING)
            if tagged == nil then
                return nil, tagError
            end
            hidden = tagged
        end
        if not hidden then
            if type(item.getCurrentUsesFloat) ~= "function" then
                return nil, "invalid_item_remaining"
            end
            local remaining = item:getCurrentUsesFloat()
            if not isFiniteNumber(remaining) then
                return nil, "invalid_item_remaining"
            end
            facts.remainingPercent = clampPercent(remaining * 100)
        end
    end

    return facts
end

local function validAnchor(anchor)
    return type(anchor) == "table" and isFiniteNumber(anchor.x) and isFiniteNumber(anchor.y) and isFiniteNumber(anchor.z)
end

function ItemSnapshot.distanceSquared(sourceAnchor, destinationAnchor)
    if not validAnchor(sourceAnchor) or not validAnchor(destinationAnchor) then
        return nil, "invalid_anchor"
    end
    local x = sourceAnchor.x - destinationAnchor.x
    local y = sourceAnchor.y - destinationAnchor.y
    local z = sourceAnchor.z - destinationAnchor.z
    local distance = x * x + y * y + z * z
    if not isFiniteNumber(distance) then
        return nil, "invalid_anchor"
    end
    return distance
end
