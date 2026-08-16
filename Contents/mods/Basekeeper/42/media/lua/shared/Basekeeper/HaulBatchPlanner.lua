Basekeeper = Basekeeper or {}
Basekeeper.HaulBatchPlanner = Basekeeper.HaulBatchPlanner or {}

local HaulBatchPlanner = Basekeeper.HaulBatchPlanner

-- Safe stays below the observed 1.25 heavy-load boundary, while the margin
-- leaves both an absolute and proportional buffer below the live hard ceiling.
local SAFE_NOMINAL_MULTIPLIER = 1.20
local MIN_CARRY_MARGIN = 1
local CARRY_MARGIN_RATIO = 0.02

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function isObject(value)
    local valueType = type(value)
    return valueType == "table" or valueType == "userdata"
end

local function isDenseArray(value)
    if type(value) ~= "table" then
        return false
    end
    local length = #value
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > length then
            return false
        end
    end
    return true
end

local function runtimeCall(runtime, name, ...)
    if runtime and type(runtime[name]) == "function" then
        return runtime[name](...)
    end
    return nil
end

local function snapshotInventory(character, runtime)
    local adapted = runtimeCall(runtime, "getInventory", character)
    if adapted ~= nil then
        return adapted
    end
    if not character or type(character.getInventory) ~= "function" then
        return nil
    end
    return character:getInventory()
end

local function currentWeight(inventory, runtime)
    local adapted = runtimeCall(runtime, "getCapacityWeight", inventory)
    if adapted ~= nil then
        return adapted
    end
    if not inventory or type(inventory.getCapacityWeight) ~= "function" then
        return nil
    end
    return inventory:getCapacityWeight()
end

local function nominalCapacity(character, runtime)
    local adapted = runtimeCall(runtime, "getMaxWeight", character)
    if adapted ~= nil then
        return adapted
    end
    if not character or type(character.getMaxWeight) ~= "function" then
        return nil
    end
    return character:getMaxWeight()
end

local function hardCapacity(inventory, character, runtime)
    local adapted = runtimeCall(runtime, "getEffectiveCapacity", inventory, character)
    if adapted ~= nil then
        return adapted
    end
    if not inventory or type(inventory.getEffectiveCapacity) ~= "function" then
        return nil
    end
    return inventory:getEffectiveCapacity(character)
end

local function unlimitedCarry(character, runtime)
    local adapted = runtimeCall(runtime, "isUnlimitedCarry", character)
    if adapted ~= nil then
        return adapted
    end
    if not character or type(character.isUnlimitedCarry) ~= "function" then
        return nil
    end
    return character:isUnlimitedCarry()
end

local function itemWeight(item, runtime)
    local adapted = runtimeCall(runtime, "getUnequippedWeight", item)
    if adapted ~= nil then
        return adapted
    end
    if not item or type(item.getUnequippedWeight) ~= "function" then
        return nil
    end
    return item:getUnequippedWeight()
end

local function itemFavorite(item, runtime)
    local adapted = runtimeCall(runtime, "isFavorite", item)
    if adapted ~= nil then
        return adapted
    end
    if not item or type(item.isFavorite) ~= "function" then
        return nil
    end
    return item:isFavorite()
end

local function sourceIsCarried(container, character, runtime)
    local adapted = runtimeCall(runtime, "isInCharacterInventory", container, character)
    if adapted ~= nil then
        return adapted
    end
    if not container or type(container.isInCharacterInventory) ~= "function" then
        return nil
    end
    return container:isInCharacterInventory(character)
end

local function validateCarryFacts(carryFacts)
    if type(carryFacts) ~= "table" or not isFiniteNumber(carryFacts.currentWeight) or carryFacts.currentWeight < 0
        or not isFiniteNumber(carryFacts.nominalCapacity) or carryFacts.nominalCapacity < 0
        or not isFiniteNumber(carryFacts.hardCapacity) or carryFacts.hardCapacity < 0
        or type(carryFacts.unlimitedCarry) ~= "boolean" then
        return nil, "invalid_carry_facts"
    end
    if not carryFacts.unlimitedCarry and (carryFacts.nominalCapacity <= 0 or carryFacts.hardCapacity <= 0) then
        return nil, "invalid_carry_facts"
    end
    return true
end

local function validateMove(move)
    if type(move) ~= "table" or not nonEmptyString(move.itemKey) or not isObject(move.item)
        or not isObject(move.sourceContainer) or not nonEmptyString(move.destinationId)
        or not isObject(move.destinationContainer) then
        return nil, "invalid_move"
    end
    if move.sourceContainer == move.destinationContainer then
        return nil, "source_equals_destination"
    end
    return true
end

local function validateJob(job)
    if type(job) ~= "table" or (job.kind ~= "unload" and job.kind ~= "organizeContainer" and job.kind ~= "organizeZone")
        or not nonEmptyString(job.zoneId) or not isFiniteNumber(job.zoneRevision) or job.zoneRevision <= 0
        or job.zoneRevision ~= math.floor(job.zoneRevision) or not isDenseArray(job.moves)
        or type(job.retained) ~= "table" or type(job.final) ~= "table" then
        return nil, "invalid_job"
    end
    return true
end

local function copyEntry(entry)
    return {
        move = entry.move,
        itemKey = entry.itemKey,
        item = entry.item,
        sourceContainer = entry.sourceContainer,
        destinationId = entry.destinationId,
        destinationContainer = entry.destinationContainer,
        weight = entry.weight,
    }
end

local function validateEntry(entry)
    if type(entry) ~= "table" or type(entry.move) ~= "table" or not nonEmptyString(entry.itemKey)
        or not isObject(entry.item) or not isObject(entry.sourceContainer) or not nonEmptyString(entry.destinationId)
        or not isObject(entry.destinationContainer) or not isFiniteNumber(entry.weight) or entry.weight < 0 then
        return nil, "invalid_world_entry"
    end
    if entry.sourceContainer == entry.destinationContainer then
        return nil, "invalid_world_entry"
    end
    return true
end

local function addVisit(visits, lookup, key, visit)
    local existing = lookup[key]
    if not existing then
        existing = visit
        lookup[key] = existing
        visits[#visits + 1] = existing
    end
    return existing
end

function HaulBatchPlanner.snapshotCarry(character, runtime)
    local inventory = snapshotInventory(character, runtime)
    if not inventory then
        return nil, "invalid_character_inventory"
    end
    local facts = {
        currentWeight = currentWeight(inventory, runtime),
        nominalCapacity = nominalCapacity(character, runtime),
        hardCapacity = hardCapacity(inventory, character, runtime),
        unlimitedCarry = unlimitedCarry(character, runtime),
    }
    local valid, errorCode = validateCarryFacts(facts)
    if not valid then
        return nil, errorCode
    end
    return facts
end

function HaulBatchPlanner.partition(job, character, runtime)
    local validJob, jobError = validateJob(job)
    if not validJob then
        return nil, jobError
    end

    local partition = { carried = {}, world = {} }
    local itemKeys = {}
    local itemReferences = {}
    for _, move in ipairs(job.moves) do
        local validMove, moveError = validateMove(move)
        if not validMove then
            return nil, moveError
        end
        if itemKeys[move.itemKey] then
            return nil, "duplicate_item_key"
        end
        if itemReferences[move.item] then
            return nil, "duplicate_item_reference"
        end
        local weight = itemWeight(move.item, runtime)
        if not isFiniteNumber(weight) or weight < 0 then
            return nil, "invalid_item_weight"
        end
        if itemFavorite(move.item, runtime) ~= false then
            return nil, "favorite_item"
        end
        local carried = sourceIsCarried(move.sourceContainer, character, runtime)
        if type(carried) ~= "boolean" then
            return nil, "invalid_source_container"
        end
        itemKeys[move.itemKey] = true
        itemReferences[move.item] = true
        local entry = {
            move = move,
            itemKey = move.itemKey,
            item = move.item,
            sourceContainer = move.sourceContainer,
            destinationId = move.destinationId,
            destinationContainer = move.destinationContainer,
            weight = weight,
        }
        local target = carried and partition.carried or partition.world
        target[#target + 1] = entry
    end
    return partition
end

function HaulBatchPlanner.limits(carryFacts, mode)
    local valid, errorCode = validateCarryFacts(carryFacts)
    if not valid then
        return nil, errorCode
    end
    if mode ~= "safe" and mode ~= "yolo" then
        return nil, "invalid_carry_mode"
    end

    local margin = math.min(carryFacts.hardCapacity,
        math.max(MIN_CARRY_MARGIN, carryFacts.hardCapacity * CARRY_MARGIN_RATIO))
    local limit
    if carryFacts.unlimitedCarry then
        limit = math.huge
    elseif mode == "safe" then
        limit = math.min(carryFacts.nominalCapacity * SAFE_NOMINAL_MULTIPLIER, carryFacts.hardCapacity - margin)
    else
        limit = carryFacts.hardCapacity - margin
    end
    return {
        mode = mode,
        limit = limit,
        margin = margin,
        hardCapacity = carryFacts.hardCapacity,
    }
end

function HaulBatchPlanner.nextBatch(remainingWorldEntries, carryFacts, mode)
    if not isDenseArray(remainingWorldEntries) then
        return nil, "invalid_world_entries"
    end
    local carryLimits, limitsError = HaulBatchPlanner.limits(carryFacts, mode)
    if not carryLimits then
        return nil, limitsError
    end
    for _, entry in ipairs(remainingWorldEntries) do
        local validEntry, entryError = validateEntry(entry)
        if not validEntry then
            return nil, entryError
        end
    end

    local selected = {}
    local selectedWeight = 0
    local exceptionalSingleton = false
    local first = remainingWorldEntries[1]
    if first then
        local firstProjected = carryFacts.currentWeight + first.weight
        local fitsLimit = carryFacts.unlimitedCarry or firstProjected <= carryLimits.limit
        local canUseExceptionalSingleton = mode == "safe" and not carryFacts.unlimitedCarry
            and first.weight > carryLimits.limit and firstProjected <= carryLimits.hardCapacity
        if fitsLimit or canUseExceptionalSingleton then
            selected[1] = copyEntry(first)
            selectedWeight = first.weight
            exceptionalSingleton = canUseExceptionalSingleton
            if not exceptionalSingleton then
                for index = 2, #remainingWorldEntries do
                    local entry = remainingWorldEntries[index]
                    if carryFacts.unlimitedCarry or carryFacts.currentWeight + selectedWeight + entry.weight <= carryLimits.limit then
                        selected[#selected + 1] = copyEntry(entry)
                        selectedWeight = selectedWeight + entry.weight
                    else
                        break
                    end
                end
            end
        end
    end

    local result = {
        entries = selected,
        sourceVisits = {},
        destinationVisits = {},
        remaining = {},
        projectedWeight = carryFacts.currentWeight + selectedWeight,
        exceptionalSingleton = exceptionalSingleton,
        blocked = false,
        complete = false,
    }
    if first and #selected == 0 then
        result.blocked = true
        result.reason = "carry_limit"
    end
    for index = #selected + 1, #remainingWorldEntries do
        result.remaining[#result.remaining + 1] = copyEntry(remainingWorldEntries[index])
    end
    result.complete = #result.remaining == 0 and not result.blocked

    local sources = {}
    local destinations = {}
    for _, entry in ipairs(selected) do
        local sourceVisit = addVisit(result.sourceVisits, sources, entry.sourceContainer,
            { container = entry.sourceContainer, entries = {} })
        sourceVisit.entries[#sourceVisit.entries + 1] = entry
        local destinationVisit = addVisit(result.destinationVisits, destinations, entry.destinationContainer,
            { id = entry.destinationId, container = entry.destinationContainer, entries = {} })
        destinationVisit.entries[#destinationVisit.entries + 1] = entry
    end
    return result
end

return HaulBatchPlanner
