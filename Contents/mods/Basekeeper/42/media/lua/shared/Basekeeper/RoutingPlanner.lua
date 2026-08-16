Basekeeper = Basekeeper or {}
if not Basekeeper.CategoryRules then
    require "Basekeeper/CategoryRules"
end
Basekeeper.RoutingPlanner = Basekeeper.RoutingPlanner or {}

local RoutingPlanner = Basekeeper.RoutingPlanner
local CategoryRules = Basekeeper.CategoryRules
local WEIGHT_EPSILON = 0.000001

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isInteger(value)
    return isFiniteNumber(value) and value == math.floor(value)
end

local function validFullType(value)
    return type(value) == "string" and value:match("^[^%s%.]+%.[^%s%.]+$") ~= nil
end

local function copyArray(source, label)
    if type(source) ~= "table" then
        return nil, "invalid_" .. label
    end
    local length = #source
    for key in pairs(source) do
        if not isInteger(key) or key < 1 or key > length then
            return nil, "invalid_" .. label
        end
    end
    local copy = {}
    for index = 1, length do
        if type(source[index]) ~= "table" then
            return nil, "invalid_" .. label
        end
        copy[index] = source[index]
    end
    return copy
end

local function copyCounts(source, label)
    if type(source) ~= "table" then
        return nil, "invalid_" .. label
    end
    local copied = {}
    for fullType, count in pairs(source) do
        if not validFullType(fullType) or not isInteger(count) or count < 0 then
            return nil, "invalid_" .. label
        end
        copied[fullType] = count
    end
    return copied
end

local function copyStockTargets(source)
    if type(source) ~= "table" then
        return nil, "invalid_stock_targets"
    end
    local copied = {}
    for fullType, target in pairs(source) do
        if not validFullType(fullType) or not isInteger(target) or target <= 0 then
            return nil, "invalid_stock_targets"
        end
        copied[fullType] = target
    end
    return copied
end

local function copyRange(source)
    if type(source) ~= "table" then
        return nil, "invalid_advanced_filters"
    end
    for key in pairs(source) do
        if key ~= "min" and key ~= "max" then
            return nil, "invalid_advanced_filters"
        end
    end
    if not isFiniteNumber(source.min) or not isFiniteNumber(source.max)
        or source.min < 0 or source.max > 100 or source.min > source.max then
        return nil, "invalid_advanced_filters"
    end
    return { min = source.min, max = source.max }
end

local function copyAdvancedFilters(source)
    if type(source) ~= "table" then
        return nil, "invalid_advanced_filters"
    end
    local copied = {}
    for key, range in pairs(source) do
        if key ~= "condition" and key ~= "remaining" then
            return nil, "invalid_advanced_filters"
        end
        local copiedRange, errorCode = copyRange(range)
        if not copiedRange then
            return nil, errorCode
        end
        copied[key] = copiedRange
    end
    return copied
end

local function validMetric(value)
    return value == nil or isFiniteNumber(value) and value >= 0 and value <= 100
end

local function rangeMatches(range, metric)
    return not range or metric == nil or metric >= range.min and metric <= range.max
end

local function categoryIsBlacklisted(category, fullType)
    return category.blacklist and category.blacklist[fullType] == true
end

local function validateSnapshot(snapshot)
    if type(snapshot) ~= "table" or (snapshot.mode ~= "consolidate" and snapshot.mode ~= "balance" and snapshot.mode ~= "nearest") then
        return nil, "invalid_snapshot"
    end
    local destinationInputs, destinationError = copyArray(snapshot.destinations, "destinations")
    if not destinationInputs then
        return nil, destinationError
    end
    local itemInputs, itemError = copyArray(snapshot.items, "items")
    if not itemInputs then
        return nil, itemError
    end

    local destinations = {}
    local destinationById = {}
    for _, input in ipairs(destinationInputs) do
        if not nonEmptyString(input.id) or destinationById[input.id] then
            return nil, "invalid_destination_id"
        end
        if not isInteger(input.priority) or input.priority < 0 or input.priority > 10
            or type(input.active) ~= "boolean"
            or not isFiniteNumber(input.maxWeight) or input.maxWeight < 0
            or not isFiniteNumber(input.baseWeight) or input.baseWeight < 0 then
            return nil, "invalid_destination"
        end
        local category, categoryError = CategoryRules.normalize(input.category)
        if not category then
            return nil, categoryError or "invalid_category"
        end
        local stockTargets, targetError = copyStockTargets(input.stockTargets)
        if not stockTargets then
            return nil, targetError
        end
        local advancedFilters, filtersError = copyAdvancedFilters(input.advancedFilters)
        if not advancedFilters then
            return nil, filtersError
        end
        local baseCounts, baseError = copyCounts(input.baseCounts, "base_counts")
        if not baseCounts then
            return nil, baseError
        end
        local originalCounts, originalError = copyCounts(input.originalCounts, "original_counts")
        if not originalCounts then
            return nil, originalError
        end
        local destination = {
            id = input.id,
            priority = input.priority,
            category = category,
            stockTargets = stockTargets,
            advancedFilters = advancedFilters,
            active = input.active,
            maxWeight = input.maxWeight,
            baseWeight = input.baseWeight,
            baseCounts = baseCounts,
            originalCounts = originalCounts,
        }
        destinations[#destinations + 1] = destination
        destinationById[destination.id] = destination
    end

    local items = {}
    local seenKeys = {}
    for _, input in ipairs(itemInputs) do
        local keyType = type(input.key)
        if (keyType ~= "string" and keyType ~= "number") or keyType == "number" and not isFiniteNumber(input.key)
            or seenKeys[input.key] then
            return nil, "invalid_item_key"
        end
        seenKeys[input.key] = true
        if input.sourceId ~= nil and (not nonEmptyString(input.sourceId) or not destinationById[input.sourceId]) then
            return nil, "invalid_source_destination"
        end
        if not validFullType(input.fullType) or input.displayCategory ~= nil and type(input.displayCategory) ~= "string"
            or type(input.favorite) ~= "boolean" or not isFiniteNumber(input.weight) or input.weight < 0
            or not validMetric(input.conditionPercent) or not validMetric(input.remainingPercent)
            or type(input.distanceByDestination) ~= "table" then
            return nil, "invalid_item"
        end
        local distances = {}
        for id, distance in pairs(input.distanceByDestination) do
            if not nonEmptyString(id) or not destinationById[id] or not isFiniteNumber(distance) or distance < 0 then
                return nil, "invalid_distance"
            end
            distances[id] = distance
        end
        items[#items + 1] = {
            key = input.key,
            sourceId = input.sourceId,
            fullType = input.fullType,
            displayCategory = input.displayCategory,
            favorite = input.favorite,
            weight = input.weight,
            conditionPercent = input.conditionPercent,
            remainingPercent = input.remainingPercent,
            distances = distances,
        }
    end
    return { mode = snapshot.mode, destinations = destinations, items = items }
end

local function candidateWinsByDistance(left, right)
    if left.distance ~= right.distance then
        return left.distance < right.distance
    end
    return left.destination.id < right.destination.id
end

local function chooseCandidate(mode, candidates, item)
    if mode == "consolidate" then
        local hasOriginal = false
        for _, candidate in ipairs(candidates) do
            if (candidate.destination.originalCounts[item.fullType] or 0) > 0 then
                hasOriginal = true
                break
            end
        end
        if hasOriginal then
            local filtered = {}
            for _, candidate in ipairs(candidates) do
                if (candidate.destination.originalCounts[item.fullType] or 0) > 0 then
                    filtered[#filtered + 1] = candidate
                end
            end
            candidates = filtered
        end
    end

    local best = nil
    for _, candidate in ipairs(candidates) do
        local wins = false
        if not best then
            wins = true
        elseif mode == "balance" then
            if candidate.tier == "target" then
                local left = (candidate.count + 1) / candidate.target
                local right = (best.count + 1) / best.target
                if left ~= right then
                    wins = left < right
                elseif candidate.destination.id == item.sourceId and best.destination.id ~= item.sourceId then
                    wins = true
                elseif candidate.destination.id ~= item.sourceId or best.destination.id == item.sourceId then
                    wins = candidateWinsByDistance(candidate, best)
                end
            else
                if candidate.count ~= best.count then
                    wins = candidate.count < best.count
                elseif candidate.destination.id == item.sourceId and best.destination.id ~= item.sourceId then
                    wins = true
                elseif candidate.destination.id ~= item.sourceId or best.destination.id == item.sourceId then
                    wins = candidateWinsByDistance(candidate, best)
                end
            end
        else
            wins = candidateWinsByDistance(candidate, best)
        end
        if wins then
            best = candidate
        end
    end
    return best
end

function RoutingPlanner.plan(snapshot)
    local normalized, validationError = validateSnapshot(snapshot)
    if not normalized then
        return nil, validationError
    end

    local planned = {}
    for _, destination in ipairs(normalized.destinations) do
        planned[destination.id] = { weight = destination.baseWeight, counts = destination.baseCounts }
    end
    local result = { assignments = {}, excluded = {}, final = {} }

    for _, item in ipairs(normalized.items) do
        if item.favorite then
            result.excluded[#result.excluded + 1] = { itemKey = item.key, reason = "favorite" }
        else
            local candidates = {}
            for _, destination in ipairs(normalized.destinations) do
                local distance = item.distances[destination.id]
                local state = planned[destination.id]
                if destination.active and distance ~= nil and state.weight + item.weight <= destination.maxWeight + WEIGHT_EPSILON
                    and rangeMatches(destination.advancedFilters.condition, item.conditionPercent)
                    and rangeMatches(destination.advancedFilters.remaining, item.remainingPercent) then
                    local target = destination.stockTargets[item.fullType]
                    local blacklisted = categoryIsBlacklisted(destination.category, item.fullType)
                    local accepted = not blacklisted and (target ~= nil
                        or CategoryRules.matches(destination.category, { fullType = item.fullType, displayCategory = item.displayCategory }))
                    local count = state.counts[item.fullType] or 0
                    if accepted and (not target or count < target) then
                        candidates[#candidates + 1] = {
                            destination = destination,
                            distance = distance,
                            target = target,
                            tier = target and "target" or "unlimited",
                            count = count,
                        }
                    end
                end
            end
            if #candidates == 0 then
                result.excluded[#result.excluded + 1] = { itemKey = item.key, reason = "no_destination" }
            else
                local highestPriority = candidates[1].destination.priority
                for _, candidate in ipairs(candidates) do
                    if candidate.destination.priority > highestPriority then
                        highestPriority = candidate.destination.priority
                    end
                end
                local priorityCandidates = {}
                local targetPresent = false
                for _, candidate in ipairs(candidates) do
                    if candidate.destination.priority == highestPriority then
                        priorityCandidates[#priorityCandidates + 1] = candidate
                        targetPresent = targetPresent or candidate.tier == "target"
                    end
                end
                if targetPresent then
                    local targetCandidates = {}
                    for _, candidate in ipairs(priorityCandidates) do
                        if candidate.tier == "target" then
                            targetCandidates[#targetCandidates + 1] = candidate
                        end
                    end
                    priorityCandidates = targetCandidates
                end
                local chosen = chooseCandidate(normalized.mode, priorityCandidates, item)
                local state = planned[chosen.destination.id]
                state.weight = state.weight + item.weight
                state.counts[item.fullType] = (state.counts[item.fullType] or 0) + 1
                result.assignments[#result.assignments + 1] = {
                    itemKey = item.key,
                    sourceId = item.sourceId,
                    destinationId = chosen.destination.id,
                    moveRequired = item.sourceId ~= chosen.destination.id,
                    tier = chosen.tier,
                }
            end
        end
    end

    for _, destination in ipairs(normalized.destinations) do
        local state = planned[destination.id]
        local counts = {}
        for fullType, count in pairs(state.counts) do
            counts[fullType] = count
        end
        result.final[destination.id] = { weight = state.weight, counts = counts }
    end
    return result
end
