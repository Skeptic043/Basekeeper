Basekeeper = Basekeeper or {}
if not Basekeeper.RoutingPlanner then
    require "Basekeeper/RoutingPlanner"
end
if not Basekeeper.ItemSnapshot then
    require "Basekeeper/ItemSnapshot"
end
Basekeeper.StorageJobPlanner = Basekeeper.StorageJobPlanner or {}

local StorageJobPlanner = Basekeeper.StorageJobPlanner
local RoutingPlanner = Basekeeper.RoutingPlanner
local ItemSnapshot = Basekeeper.ItemSnapshot

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isPositiveInteger(value)
    return isFiniteNumber(value) and value == math.floor(value) and value > 0
end

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function copyArray(source, errorCode)
    if type(source) ~= "table" then
        return nil, errorCode
    end
    local length = #source
    for key in pairs(source) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > length then
            return nil, errorCode
        end
    end
    local copied = {}
    for index = 1, length do
        if type(source[index]) ~= "table" then
            return nil, errorCode
        end
        copied[index] = source[index]
    end
    return copied
end

local function copyItemArray(source, errorCode)
    if type(source) ~= "table" then
        return nil, errorCode
    end
    local length = #source
    for key in pairs(source) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > length then
            return nil, errorCode
        end
    end
    local copied = {}
    for index = 1, length do
        if source[index] == nil then
            return nil, errorCode
        end
        copied[index] = source[index]
    end
    return copied
end

local function copyCounts(counts)
    local copied = {}
    for fullType, count in pairs(counts) do
        copied[fullType] = count
    end
    return copied
end

local function copyFinal(final)
    local copied = {}
    for id, state in pairs(final) do
        copied[id] = { weight = state.weight, counts = copyCounts(state.counts) }
    end
    return copied
end

local function sortById(left, right)
    return left.id < right.id
end

local function sourceItemSort(left, right)
    return left.facts.itemId < right.facts.itemId
end

local function destinationInput(snapshot)
    return {
        id = snapshot.id,
        priority = snapshot.config.priority,
        category = snapshot.category,
        stockTargets = snapshot.config.stockTargets,
        advancedFilters = snapshot.config.advancedFilters,
        active = true,
        maxWeight = snapshot.maxWeight,
        initialWeight = snapshot.initialWeight,
        originalCounts = copyCounts(snapshot.originalCounts),
    }
end

local function plannerDestinations(destinations, projected)
    local inputs = {}
    for _, destination in ipairs(destinations) do
        local input = destinationInput(destination)
        if projected then
            local state = projected[destination.id]
            input.initialWeight = state.weight
            input.originalCounts = copyCounts(state.counts)
        end
        inputs[#inputs + 1] = input
    end
    return inputs
end

local function itemInput(record, sourceId, destinations)
    local distances = {}
    for _, destination in ipairs(destinations) do
        local distance, distanceError = ItemSnapshot.distanceSquared(record.anchor, destination.anchor)
        if distance == nil then
            return nil, distanceError
        end
        distances[destination.id] = distance
    end
    return {
        key = record.itemKey,
        sourceId = sourceId,
        fullType = record.facts.fullType,
        displayCategory = record.facts.displayCategory,
        favorite = record.facts.favorite,
        weight = record.facts.weight,
        conditionPercent = record.facts.conditionPercent,
        remainingPercent = record.facts.remainingPercent,
        distanceByDestination = distances,
    }
end

local function validateRequest(request)
    if type(request) ~= "table" or (request.kind ~= "unload" and request.kind ~= "organizeContainer" and request.kind ~= "organizeZone")
        or not nonEmptyString(request.zoneId) or not isPositiveInteger(request.zoneRevision)
        or (request.mode ~= "consolidate" and request.mode ~= "balance" and request.mode ~= "nearest")
        or request.character == nil then
        return nil, "invalid_request"
    end
    return true
end

local function snapshotDestinations(request, runtime, factCache)
    local inputs, inputsError = copyArray(request.destinations, "invalid_destinations")
    if not inputs then
        return nil, inputsError
    end
    if #inputs == 0 then
        return nil, "invalid_destinations"
    end

    local destinations = {}
    local byId = {}
    local seenContainers = {}
    for _, input in ipairs(inputs) do
        if type(input.config) ~= "table" or not nonEmptyString(input.config.id) or type(input.category) ~= "table" or not input.container then
            return nil, "invalid_destination"
        end
        local anchorDistance, anchorError = ItemSnapshot.distanceSquared(input.anchor, input.anchor)
        if anchorDistance == nil then
            return nil, anchorError
        end
        if byId[input.config.id] then
            return nil, "duplicate_destination_id"
        end
        if seenContainers[input.container] then
            return nil, "duplicate_destination_container"
        end
        if type(input.container.getCapacityWeight) ~= "function" or type(input.container.getEffectiveCapacity) ~= "function" then
            return nil, "invalid_destination_container"
        end
        local initialWeight = input.container:getCapacityWeight()
        local maxWeight = input.container:getEffectiveCapacity(request.character)
        if not isFiniteNumber(initialWeight) or initialWeight < 0 or not isFiniteNumber(maxWeight) or maxWeight < 0 then
            return nil, "invalid_destination_capacity"
        end
        local directItems, directError = ItemSnapshot.directItems(input.container)
        if not directItems then
            return nil, directError
        end
        local destination = {
            id = input.config.id,
            config = input.config,
            category = input.category,
            container = input.container,
            anchor = input.anchor,
            initialWeight = initialWeight,
            maxWeight = maxWeight,
            originalCounts = {},
            items = {},
        }
        local eligibilityDestination = destinationInput(destination)
        for _, item in ipairs(directItems) do
            local facts = factCache[item]
            if not facts then
                local factError
                facts, factError = ItemSnapshot.fromItem(item, runtime)
                if not facts then
                    return nil, factError
                end
                factCache[item] = facts
            end
            local itemKey = destination.id .. ":" .. tostring(facts.itemId)
            if destination.items[itemKey] then
                return nil, "duplicate_item_key"
            end
            local record = { itemKey = itemKey, item = item, facts = facts, anchor = input.anchor, container = input.container }
            destination.items[itemKey] = record
            if RoutingPlanner.itemIsEligible(eligibilityDestination, facts) then
                destination.originalCounts[facts.fullType] = (destination.originalCounts[facts.fullType] or 0) + 1
            end
        end
        seenContainers[input.container] = true
        byId[destination.id] = destination
        destinations[#destinations + 1] = destination
    end
    table.sort(destinations, sortById)
    return destinations, byId
end

local function snapshotUnloadSources(request, runtime, factCache, destinationByContainer)
    local inputs, inputsError = copyArray(request.sources, "invalid_sources")
    if not inputs then
        return nil, inputsError
    end
    if #inputs == 0 then
        return nil, "invalid_sources"
    end
    local sources = {}
    local keys = {}
    for _, input in ipairs(inputs) do
        if not nonEmptyString(input.key) or not input.container then
            return nil, "invalid_source"
        end
        if keys[input.key] then
            return nil, "duplicate_source_key"
        end
        if destinationByContainer[input.container] then
            return nil, "destination_is_unload_source"
        end
        local anchorDistance, anchorError = ItemSnapshot.distanceSquared(input.anchor, input.anchor)
        if anchorDistance == nil then
            return nil, anchorError
        end
        local explicitItems = nil
        if input.items ~= nil then
            local explicitError
            explicitItems, explicitError = copyItemArray(input.items, "invalid_source_items")
            if not explicitItems then
                return nil, explicitError
            end
        end
        local directItems, directError = ItemSnapshot.directItems(input.container)
        if not directItems then
            return nil, directError
        end
        if explicitItems then
            local directMembership = {}
            for _, directItem in ipairs(directItems) do
                directMembership[directItem] = true
            end
            local supplied = {}
            for _, explicitItem in ipairs(explicitItems) do
                if supplied[explicitItem] then
                    return nil, "duplicate_source_item"
                end
                if not directMembership[explicitItem] then
                    return nil, "source_item_not_direct_member"
                end
                supplied[explicitItem] = true
            end
            directItems = explicitItems
        end
        local source = { key = input.key, container = input.container, anchor = input.anchor, items = {} }
        local seenItems = {}
        for _, item in ipairs(directItems) do
            local facts = factCache[item]
            if not facts then
                local factError
                facts, factError = ItemSnapshot.fromItem(item, runtime)
                if not facts then
                    return nil, factError
                end
                factCache[item] = facts
            end
            local itemKey = source.key .. ":" .. tostring(facts.itemId)
            if seenItems[itemKey] then
                return nil, "duplicate_item_key"
            end
            seenItems[itemKey] = true
            source.items[#source.items + 1] = { itemKey = itemKey, item = item, facts = facts, anchor = source.anchor, container = source.container }
        end
        table.sort(source.items, sourceItemSort)
        keys[source.key] = true
        sources[#sources + 1] = source
    end
    table.sort(sources, function(left, right) return left.key < right.key end)
    return sources
end

local function appendRouteResults(job, plan, records, phase)
    local excludedByKey = {}
    for _, excluded in ipairs(plan.excluded) do
        excludedByKey[excluded.itemKey] = excluded
    end
    local assignmentByKey = {}
    for _, assignment in ipairs(plan.assignments) do
        assignmentByKey[assignment.itemKey] = assignment
    end
    for _, record in ipairs(records) do
        local excluded = excludedByKey[record.itemKey]
        local assignment = assignmentByKey[record.itemKey]
        if excluded then
            job.retained[#job.retained + 1] = {
                itemKey = record.itemKey, item = record.item, sourceId = record.sourceId, reason = excluded.reason,
            }
        elseif assignment.moveRequired then
            job.moves[#job.moves + 1] = {
                itemKey = record.itemKey, item = record.item, sourceKey = record.sourceKey,
                sourceId = assignment.sourceId, sourceContainer = record.container,
                destinationId = assignment.destinationId, destinationContainer = nil, phase = phase,
            }
        else
            job.retained[#job.retained + 1] = {
                itemKey = record.itemKey, item = record.item, sourceId = assignment.sourceId, reason = "already_correct",
            }
        end
    end
end

local function assignDestinationContainers(job, destinationById)
    for _, move in ipairs(job.moves) do
        move.destinationContainer = destinationById[move.destinationId].container
    end
end

local function buildRoutePlan(mode, destinations, records)
    local items = {}
    for _, record in ipairs(records) do
        local input, inputError = itemInput(record, record.sourceId, destinations)
        if not input then
            return nil, inputError
        end
        items[#items + 1] = input
    end
    return RoutingPlanner.plan({ mode = mode, destinations = plannerDestinations(destinations), items = items })
end

function StorageJobPlanner.build(request, runtime)
    local validRequest, requestError = validateRequest(request)
    if not validRequest then
        return nil, requestError
    end

    local factCache = {}
    local destinations, destinationById = snapshotDestinations(request, runtime, factCache)
    if not destinations then
        return nil, destinationById
    end
    local destinationByContainer = {}
    for _, destination in ipairs(destinations) do
        destinationByContainer[destination.container] = destination
    end

    local job = { kind = request.kind, zoneId = request.zoneId, zoneRevision = request.zoneRevision, moves = {}, retained = {}, final = {} }
    local records = {}

    if request.kind == "unload" then
        local sources, sourceError = snapshotUnloadSources(request, runtime, factCache, destinationByContainer)
        if not sources then
            return nil, sourceError
        end
        for _, source in ipairs(sources) do
            for _, record in ipairs(source.items) do
                record.sourceKey = source.key
                records[#records + 1] = record
            end
        end
    elseif request.kind == "organizeZone" then
        for _, destination in ipairs(destinations) do
            for _, record in pairs(destination.items) do
                record.sourceId = destination.id
                record.sourceKey = destination.id
                records[#records + 1] = record
            end
        end
        table.sort(records, function(left, right)
            if left.sourceId ~= right.sourceId then return left.sourceId < right.sourceId end
            return left.facts.itemId < right.facts.itemId
        end)
    else
        if not nonEmptyString(request.selectedContainerId) or not destinationById[request.selectedContainerId] then
            return nil, "invalid_selected_container"
        end
        local selected = destinationById[request.selectedContainerId]
        for _, record in pairs(selected.items) do
            record.sourceId = selected.id
            record.sourceKey = selected.id
            records[#records + 1] = record
        end
        table.sort(records, sourceItemSort)
    end

    local plan, planError = buildRoutePlan(request.mode, destinations, records)
    if not plan then
        return nil, planError
    end
    appendRouteResults(job, plan, records, "route")
    assignDestinationContainers(job, destinationById)
    local projected = copyFinal(plan.final)

    if request.kind == "organizeContainer" then
        local selected = destinationById[request.selectedContainerId]
        local candidates = {}
        for _, source in ipairs(destinations) do
            if source.id ~= selected.id then
                for _, record in pairs(source.items) do
                    if not record.facts.favorite and selected.config.stockTargets[record.facts.fullType] ~= nil then
                        local distance, distanceError = ItemSnapshot.distanceSquared(source.anchor, selected.anchor)
                        if distance == nil then
                            return nil, distanceError
                        end
                        candidates[#candidates + 1] = { record = record, source = source, distance = distance }
                    end
                end
            end
        end
        table.sort(candidates, function(left, right)
            if left.distance ~= right.distance then return left.distance < right.distance end
            if left.source.id ~= right.source.id then return left.source.id < right.source.id end
            return left.record.facts.itemId < right.record.facts.itemId
        end)
        for _, candidate in ipairs(candidates) do
            local fullType = candidate.record.facts.fullType
            local target = selected.config.stockTargets[fullType]
            if (projected[selected.id].counts[fullType] or 0) < target then
                candidate.record.sourceId = candidate.source.id
                candidate.record.sourceKey = candidate.source.id
                local input, inputError = itemInput(candidate.record, candidate.source.id, destinations)
                if not input then
                    return nil, inputError
                end
                local exploratory, exploratoryError = RoutingPlanner.plan({
                    mode = request.mode, destinations = plannerDestinations(destinations, projected), items = { input },
                })
                if not exploratory then
                    return nil, exploratoryError
                end
                local assignment = exploratory.assignments[1]
                if assignment and assignment.destinationId == selected.id then
                    job.moves[#job.moves + 1] = {
                        itemKey = candidate.record.itemKey, item = candidate.record.item, sourceKey = candidate.source.id,
                        sourceId = candidate.source.id, sourceContainer = candidate.source.container,
                        destinationId = selected.id, destinationContainer = selected.container, phase = "targetPull",
                    }
                    projected = copyFinal(exploratory.final)
                end
            end
        end
    end

    job.final = copyFinal(projected)
    return job
end
