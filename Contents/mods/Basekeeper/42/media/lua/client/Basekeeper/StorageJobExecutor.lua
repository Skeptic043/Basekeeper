Basekeeper = Basekeeper or {}
if not Basekeeper.HaulBatchPlanner then require "Basekeeper/HaulBatchPlanner" end
if not Basekeeper.ContainerAccess then require "Basekeeper/ContainerAccess" end
Basekeeper.StorageJobExecutor = Basekeeper.StorageJobExecutor or {}

local StorageJobExecutor = Basekeeper.StorageJobExecutor
local Planner = Basekeeper.HaulBatchPlanner
local ContainerAccess = Basekeeper.ContainerAccess

local function runtimeCall(runtime, name, ...)
    if runtime and type(runtime[name]) == "function" then return runtime[name](...) end
end

local function invoke(value, name, ...)
    if value and type(value[name]) == "function" then return value[name](value, ...) end
end

local function inventoryOf(character, runtime)
    return runtimeCall(runtime, "getInventory", character) or invoke(character, "getInventory")
end

local function inContainer(item, container, runtime)
    local adapted = runtimeCall(runtime, "itemInContainer", item, container)
    if adapted ~= nil then return adapted end
    local current = invoke(item, "getContainer")
    if current ~= nil then return current == container end
    return false
end

local function itemExists(item, itemKey, runtime)
    local adapted = runtimeCall(runtime, "itemExists", item, itemKey)
    if adapted ~= nil then return adapted end
    return item ~= nil and type(itemKey) == "string" and itemKey ~= ""
end

local function favorite(item, runtime)
    local adapted = runtimeCall(runtime, "isFavorite", item)
    if adapted ~= nil then return adapted end
    return invoke(item, "isFavorite")
end

local function permitsRemove(container, character, item, runtime)
    local adapted = runtimeCall(runtime, "canRemove", container, character, item)
    if adapted ~= nil then return adapted end
    local allowed = invoke(container, "isRemoveItemAllowed", item)
    if allowed ~= nil then return allowed end
    return true
end

local function permitsItem(container, character, item, runtime)
    local adapted = runtimeCall(runtime, "canAccept", container, character, item)
    if adapted ~= nil then return adapted end
    local allowed = invoke(container, "isItemAllowed", item)
    if allowed ~= nil then return allowed end
    return true
end

local function hasRoom(container, character, item, runtime)
    local adapted = runtimeCall(runtime, "hasRoomFor", container, character, item)
    if adapted ~= nil then return adapted end
    local result = invoke(container, "hasRoomFor", character, item)
    return result == true
end

local function containerExists(container, runtime)
    if not container then return false end
    local adapted = runtimeCall(runtime, "containerExists", container)
    if adapted ~= nil then return adapted == true end
    local exists = invoke(container, "isExistYet")
    return exists == nil or exists == true
end

local function createTransfer(character, item, source, destination, runtime)
    local adapted = runtimeCall(runtime, "newTransferAction", character, item, source, destination)
    if adapted ~= nil then return adapted end
    if ISInventoryTransferUtil and type(ISInventoryTransferUtil.newInventoryTransferAction) == "function" then
        return ISInventoryTransferUtil.newInventoryTransferAction(character, item, source, destination, 0)
    end
end

local function forceDropHeavy(item, runtime)
    local adapted = runtimeCall(runtime, "isForceDropHeavyItem", item)
    if adapted ~= nil then return adapted == true end
    if type(isForceDropHeavyItem) == "function" then return isForceDropHeavyItem(item) == true end
    return false
end

local function humanCorpse(item, runtime)
    local adapted = runtimeCall(runtime, "isHumanCorpse", item)
    if adapted ~= nil then return adapted == true end
    return invoke(item, "isHumanCorpse") == true
end

local function handItem(character, primary, runtime)
    local adapted = runtimeCall(runtime, primary and "getPrimaryHandItem" or "getSecondaryHandItem", character)
    if adapted ~= nil then return adapted end
    return invoke(character, primary and "getPrimaryHandItem" or "getSecondaryHandItem")
end

local function handStillHolds(session, item)
    return handItem(session.character, true, session.runtime) == item
        or handItem(session.character, false, session.runtime) == item
end

local function createHeavyAcquire(character, item, runtime)
    local adapted = runtimeCall(runtime, "newHeavyAcquireAction", character, item)
    if adapted ~= nil then return adapted end
    if ISEquipHeavyItem and type(ISEquipHeavyItem.new) == "function" then
        return ISEquipHeavyItem:new(character, item)
    end
end

local function queueAdd(session, action, after)
    if not action then return false end
    local runtime = session.runtime
    if after then
        local adapted = runtimeCall(runtime, "addAfter", after, action)
        if adapted ~= nil then return adapted ~= false end
        if ISTimedActionQueue and type(ISTimedActionQueue.addAfter) == "function" then
            ISTimedActionQueue.addAfter(after, action)
            return true
        end
    else
        local adapted = runtimeCall(runtime, "add", action)
        if adapted ~= nil then return adapted ~= false end
        if ISTimedActionQueue and type(ISTimedActionQueue.add) == "function" then
            ISTimedActionQueue.add(action)
            return true
        end
    end
    return false
end

local StepAction
if ISBaseTimedAction then
    StepAction = ISBaseTimedAction:derive("BasekeeperStorageJobStep")
    function StepAction:new(character, callback)
        local action = ISBaseTimedAction.new(self, character)
        action.callback = callback
        action.stopOnWalk = false
        action.stopOnRun = false
        action.maxTime = 0
        return action
    end
    function StepAction:start() end
    function StepAction:update() end
    function StepAction:isValid() return true end
    function StepAction:perform()
        if self.callback then self.callback(self) end
        ISBaseTimedAction.perform(self)
    end
else
    StepAction = {}
    function StepAction:new(character, callback)
        return { character = character, callback = callback, perform = function(self) self.callback(self) end }
    end
end

local function step(session, callback, after)
    local action = StepAction:new(session.character, callback)
    if queueAdd(session, action, after) then return action end
    return nil
end

local function appendSkipped(session, entry, reason)
    session.skipped[#session.skipped + 1] = { itemKey = entry.itemKey, reason = reason }
end

local function appendStranded(session, entry, reason)
    session.stranded[#session.stranded + 1] = { itemKey = entry.itemKey, reason = reason }
end

local function finish(session)
    session.status = "completed"
    if session.options.onFinished then session.options.onFinished(session) end
end

local function validateEntry(entry, expected, session)
    if not itemExists(entry.item, entry.itemKey, session.runtime) then return nil, "missing_item" end
    if favorite(entry.item, session.runtime) ~= false then return nil, "favorite_item" end
    if not containerExists(expected, session.runtime) then return nil, "missing_source" end
    if not containerExists(entry.sourceContainer, session.runtime) then return nil, "missing_source" end
    if not expected or not inContainer(entry.item, expected, session.runtime) then return nil, "item_not_in_expected_container" end
    if entry.sourceContainer == entry.destinationContainer then return nil, "source_equals_destination" end
    if not permitsRemove(expected, session.character, entry.item, session.runtime) then return nil, "source_removal_denied" end
    return true
end

local function validateDestination(entry, session)
    if not containerExists(entry.destinationContainer, session.runtime) then return nil, "missing_destination" end
    if not permitsItem(entry.destinationContainer, session.character, entry.item, session.runtime) then return nil, "destination_rejected" end
    if not hasRoom(entry.destinationContainer, session.character, entry.item, session.runtime) then return nil, "destination_full" end
    return true
end

local advance

local function queueAccess(session, container, after, onReady, onFailed)
    local access, accessError = ContainerAccess.prepare(container, session.character, session.runtime)
    if not access then onFailed(accessError, after); return end
    if access.ready then
        step(session, function(checkpoint) onReady(checkpoint) end, after)
        return
    end
    local path = access.action
    if type(path.setRunActionsAfterFailing) == "function" then path:setRunActionsAfterFailing(true) end
    local failed = false
    local fail = function() failed = true end
    if session.runtime and type(session.runtime.setOnFail) == "function" then session.runtime.setOnFail(path, fail)
    elseif type(path.setOnFail) == "function" then path:setOnFail(fail) end
    if not queueAdd(session, path, after) then onFailed("access_queue_failed", after); return end
    step(session, function(checkpoint)
        if failed or (access.recheck and access.recheck() ~= true) then onFailed("access_failed", checkpoint) else onReady(checkpoint) end
    end, path)
end

local function queueTransfer(session, entry, source, destination, after, expected, onDone, onFailure)
    local action = createTransfer(session.character, entry.item, source, destination, session.runtime)
    if not action or not queueAdd(session, action, after) then onFailure("transfer_unavailable"); return end
    step(session, function(checkpoint)
        if inContainer(entry.item, expected, session.runtime) then onDone(checkpoint) else onFailure("transfer_failed") end
    end, action)
end

local queueHandSequence

local function handSnapshot(session, entry)
    local primary = handItem(session.character, true, session.runtime)
    local secondary = handItem(session.character, false, session.runtime)
    local heldItems = {}
    if primary then heldItems[#heldItems + 1] = primary end
    if secondary and secondary ~= primary then heldItems[#heldItems + 1] = secondary end
    for _, held in ipairs(heldItems) do
        if held and favorite(held, session.runtime) == true then return nil, "favorite_hands_blocked" end
        if held and held ~= entry.item and forceDropHeavy(held, session.runtime) then return nil, "unrelated_heavy_hands_blocked" end
    end
    return { primary = primary, secondary = secondary }
end

local function unequipAction(session, item)
    return runtimeCall(session.runtime, "newUnequipAction", session.character, item)
        or (ISUnequipAction and type(ISUnequipAction.new) == "function" and ISUnequipAction:new(session.character, item, 0))
end

local function equipAction(session, item, primary)
    return runtimeCall(session.runtime, "newEquipWeaponAction", session.character, item, primary)
        or (ISEquipWeaponAction and type(ISEquipWeaponAction.new) == "function" and ISEquipWeaponAction:new(session.character, item, 0, primary, false))
end

queueHandSequence = function(session, snapshot, after, callback, onFailure)
    local held = {}
    if snapshot.primary then held[#held + 1] = snapshot.primary end
    if snapshot.secondary and snapshot.secondary ~= snapshot.primary then held[#held + 1] = snapshot.secondary end
    local function queueNext(index, previous)
        local item = held[index]
        if not item then callback(previous); return end
        local action = unequipAction(session, item)
        if not action or not queueAdd(session, action, previous) then onFailure("hands_unequip_unavailable"); return end
        step(session, function(checkpoint)
            local inventory = inventoryOf(session.character, session.runtime)
            if inventory and inContainer(item, inventory, session.runtime) and not handStillHolds(session, item) then
                queueNext(index + 1, checkpoint)
            else
                onFailure("hands_unequip_failed")
            end
        end, action)
    end
    queueNext(1, after)
    return true
end

local function restoreHands(session, entry, after, callback)
    local snapshot = session.handSnapshots[entry.itemKey]
    if not session.options.restoreHeldItems or not snapshot then callback(after); return end
    local slots = {
        { item = snapshot.primary, primary = true },
        { item = snapshot.secondary, primary = false },
    }
    local function queueNext(index, previous)
        local slot = slots[index]
        if not slot then
            local checkpoint = step(session, function(next)
                -- Read both slots after the final vanilla equip.  This is a
                -- checkpoint only: restoration is deliberately best effort.
                local primaryRestored = not snapshot.primary
                    or handItem(session.character, true, session.runtime) == snapshot.primary
                local secondaryRestored = not snapshot.secondary
                    or handItem(session.character, false, session.runtime) == snapshot.secondary
                if primaryRestored and secondaryRestored then callback(next) else callback(next) end
            end, previous)
            if not checkpoint then callback(previous) end
            return
        end
        local inventory = inventoryOf(session.character, session.runtime)
        if not slot.item or not inventory or not inContainer(slot.item, inventory, session.runtime) then
            queueNext(index + 1, previous)
            return
        end
        local action = equipAction(session, slot.item, slot.primary)
        if not action or not queueAdd(session, action, previous) then
            queueNext(index + 1, previous)
            return
        end
        step(session, function(checkpoint)
            -- Best effort only: a failed restore never changes storage-job outcome.
            if handItem(session.character, slot.primary, session.runtime) == slot.item then
                queueNext(index + 1, checkpoint)
            else
                queueNext(index + 1, checkpoint)
            end
        end, action)
    end
    queueNext(1, after)
end

local function finishHands(session, entry, after, callback)
    restoreHands(session, entry, after, function(next)
        session.handSnapshots[entry.itemKey] = nil
        session.heavyModes[entry.itemKey] = nil
        session.exceptionalKeys[entry.itemKey] = nil
        callback(next)
    end)
end

local function queueHeavyAcquire(session, entry, after, onDone, onFailure)
    local function launch(previous)
        local action = createHeavyAcquire(session.character, entry.item, session.runtime)
        if not action or not queueAdd(session, action, previous) then onFailure("heavy_action_unavailable"); return end
        local inventory = inventoryOf(session.character, session.runtime)
        step(session, function(checkpoint)
            if inventory and inContainer(entry.item, inventory, session.runtime) and handStillHolds(session, entry.item) then
                onDone(checkpoint)
            else
                onFailure("heavy_acquisition_failed")
            end
        end, action)
    end
    local snapshot = session.handSnapshots[entry.itemKey]
    if snapshot then
        queueHandSequence(session, snapshot, after, launch, onFailure)
    else
        launch(after)
    end
end

local function maybeAssistExceptional(session, entry, after, callback)
    if not session.exceptionalKeys[entry.itemKey] or not forceDropHeavy(entry.item, session.runtime) then callback(after); return end
    local equipped = runtimeCall(session.runtime, "getEquippedWeight", entry.item) or invoke(entry.item, "getEquippedWeight")
    local unequipped = runtimeCall(session.runtime, "getUnequippedWeight", entry.item) or invoke(entry.item, "getUnequippedWeight")
    if type(equipped) ~= "number" or type(unequipped) ~= "number" or equipped >= unequipped then callback(after); return end
    local snapshot, reason = handSnapshot(session, entry)
    if not snapshot then callback(after); return end
    session.handSnapshots[entry.itemKey] = snapshot
    queueHandSequence(session, snapshot, after, function(previous)
        local action = createHeavyAcquire(session.character, entry.item, session.runtime)
        if not action or not queueAdd(session, action, previous) then callback(previous); return end
        step(session, function(checkpoint)
            if handStillHolds(session, entry.item) then callback(checkpoint) else callback(checkpoint) end
        end, action)
    end, function() callback(after) end)
end

local function recover(session, entry, after, reason)
    local inventory = inventoryOf(session.character, session.runtime)
    if not inventory or not inContainer(entry.item, inventory, session.runtime) then
        finishHands(session, entry, after, function(next)
            appendStranded(session, entry, reason)
            advance(session, next)
        end)
        return
    end
    local valid = validateEntry(entry, inventory, session)
    if not valid or not permitsItem(entry.sourceContainer, session.character, entry.item, session.runtime)
        or not hasRoom(entry.sourceContainer, session.character, entry.item, session.runtime) then
        finishHands(session, entry, after, function(next)
            appendStranded(session, entry, reason)
            advance(session, next)
        end)
        return
    end
    queueAccess(session, entry.sourceContainer, after, function(accessCheckpoint)
        if not containerExists(entry.sourceContainer, session.runtime)
            or not permitsItem(entry.sourceContainer, session.character, entry.item, session.runtime)
            or not hasRoom(entry.sourceContainer, session.character, entry.item, session.runtime) then
            finishHands(session, entry, accessCheckpoint, function(next)
                appendStranded(session, entry, reason)
                advance(session, next)
            end)
            return
        end
        queueTransfer(session, entry, inventory, entry.sourceContainer, accessCheckpoint, entry.sourceContainer, function()
            finishHands(session, entry, nil, function(next)
                appendSkipped(session, entry, "recovered_" .. reason)
                advance(session, next)
            end)
        end, function()
            finishHands(session, entry, nil, function(next)
                appendStranded(session, entry, reason)
                advance(session, next)
            end)
        end)
    end, function(_, checkpoint)
        finishHands(session, entry, checkpoint or after, function(next)
            appendStranded(session, entry, reason)
            advance(session, next)
        end)
    end)
end

local function deliver(session, entry, after)
    local inventory = inventoryOf(session.character, session.runtime)
    local valid, errorCode = validateEntry(entry, inventory, session)
    if not valid then
        if entry.wasCarried then appendSkipped(session, entry, errorCode); advance(session, after) else recover(session, entry, after, errorCode) end
        return
    end
    local destinationValid, destinationError = validateDestination(entry, session)
    if not destinationValid then
        if entry.wasCarried then appendSkipped(session, entry, destinationError); advance(session, after) else recover(session, entry, after, destinationError) end
        return
    end
    queueAccess(session, entry.destinationContainer, after, function(accessCheckpoint)
        local nowEntry, nowEntryError = validateEntry(entry, inventory, session)
        if not nowEntry then
            if entry.wasCarried then appendSkipped(session, entry, nowEntryError); advance(session, accessCheckpoint)
            else recover(session, entry, accessCheckpoint, nowEntryError) end
            return
        end
        local nowValid, nowError = validateDestination(entry, session)
        if not nowValid then
            if entry.wasCarried then appendSkipped(session, entry, nowError); advance(session, accessCheckpoint) else recover(session, entry, accessCheckpoint, nowError) end
            return
        end
        queueTransfer(session, entry, inventory, entry.destinationContainer, accessCheckpoint, entry.destinationContainer, function(checkpoint)
            session.completed[#session.completed + 1] = entry.itemKey
            session.acquired[entry.itemKey] = nil
            finishHands(session, entry, checkpoint, function(next) advance(session, next) end)
        end, function()
            if entry.wasCarried then appendSkipped(session, entry, "delivery_transfer_failed"); advance(session) else recover(session, entry, nil, "delivery_transfer_failed") end
        end)
    end, function(accessError, checkpoint)
        local next = checkpoint or after
        if entry.wasCarried then appendSkipped(session, entry, accessError); advance(session, next) else recover(session, entry, next, accessError) end
    end)
end

local function acquire(session, entry, after)
    local valid, errorCode = validateEntry(entry, entry.sourceContainer, session)
    if not valid then appendSkipped(session, entry, errorCode); advance(session, after); return end
    local destinationValid, destinationError = validateDestination(entry, session)
    if not destinationValid then appendSkipped(session, entry, destinationError); advance(session, after); return end
    queueAccess(session, entry.sourceContainer, after, function(accessCheckpoint)
        local nowValid, nowError = validateEntry(entry, entry.sourceContainer, session)
        local nowDestination, destinationErrorNow = validateDestination(entry, session)
        if not nowValid then appendSkipped(session, entry, nowError); advance(session, accessCheckpoint); return end
        if not nowDestination then appendSkipped(session, entry, destinationErrorNow); advance(session, accessCheckpoint); return end
        local inventory = inventoryOf(session.character, session.runtime)
        if not inventory then appendSkipped(session, entry, "missing_character_inventory"); advance(session, accessCheckpoint); return end
        local acquired = function(checkpoint)
            session.acquired[entry.itemKey] = entry
            maybeAssistExceptional(session, entry, checkpoint, function(next) advance(session, next) end)
        end
        local failed = function()
            finishHands(session, entry, nil, function(next)
                appendSkipped(session, entry, "acquisition_transfer_failed")
                advance(session, next)
            end)
        end
        if forceDropHeavy(entry.item, session.runtime) then
            local snapshot, handsError = session.handSnapshots[entry.itemKey], nil
            if not snapshot then snapshot, handsError = handSnapshot(session, entry) end
            if not snapshot then appendSkipped(session, entry, handsError); advance(session, accessCheckpoint); return end
            session.handSnapshots[entry.itemKey] = snapshot
            if humanCorpse(entry.item, session.runtime) then
                queueHandSequence(session, snapshot, accessCheckpoint, function(previous)
                    queueTransfer(session, entry, entry.sourceContainer, inventory, previous, inventory, acquired, failed)
                end, failed)
            else
                queueHeavyAcquire(session, entry, accessCheckpoint, acquired, failed)
            end
        else
            queueTransfer(session, entry, entry.sourceContainer, inventory, accessCheckpoint, inventory, acquired, failed)
        end
    end, function(accessError, checkpoint)
        appendSkipped(session, entry, accessError)
        advance(session, checkpoint or after)
    end)
end

local function orderedVisits(visits)
    local result = {}
    for _, visit in ipairs(visits) do
        for _, entry in ipairs(visit.entries) do result[#result + 1] = entry end
    end
    return result
end

local function copyEntry(entry, wasCarried)
    return {
        move = entry.move,
        itemKey = entry.itemKey,
        item = entry.item,
        sourceContainer = entry.sourceContainer,
        destinationId = entry.destinationId,
        destinationContainer = entry.destinationContainer,
        weight = entry.weight,
        wasCarried = wasCarried == true,
    }
end

local function copyEntries(entries, wasCarried)
    local copied = {}
    for index, entry in ipairs(entries) do copied[index] = copyEntry(entry, wasCarried) end
    return copied
end

local function carriedDeliveries(entries)
    local visits, byDestination = {}, {}
    for _, entry in ipairs(entries) do
        local carried = copyEntry(entry, true)
        local visit = byDestination[carried.destinationContainer]
        if not visit then
            visit = { container = entry.destinationContainer, entries = {} }
            byDestination[carried.destinationContainer] = visit
            visits[#visits + 1] = visit
        end
        visit.entries[#visit.entries + 1] = carried
    end
    return orderedVisits(visits)
end

advance = function(session, after)
    if session.status ~= "running" then return end
    if session.phase == "carried" then
        local entry = session.carried[session.carriedIndex]
        if entry then
            session.carriedIndex = session.carriedIndex + 1
            deliver(session, entry, after)
            return
        end
        session.phase = "batch"
    end
    if session.phase == "batch" then
        if #session.worldRemaining == 0 then finish(session); return end
        local facts, factsError = Planner.snapshotCarry(session.character, session.runtime)
        if not facts then
            appendStranded(session, session.worldRemaining[1], factsError)
            table.remove(session.worldRemaining, 1)
            return advance(session, after)
        end
        local batch, batchError = Planner.nextBatch(session.worldRemaining, facts, session.options.carryMode)
        if not batch then appendStranded(session, session.worldRemaining[1], batchError); table.remove(session.worldRemaining, 1); return advance(session, after) end
        if batch.blocked then
            local first = session.worldRemaining[1]
            -- This is the one permitted Module 05 bypass: the blocked head is
            -- a vanilla force-drop heavy object whose real carrying lane is
            -- both hands.  Never bypass a non-heavy blocked entry.
            if batch.reason == "carry_limit" and forceDropHeavy(first.item, session.runtime) then
                local snapshot, handsError = handSnapshot(session, first)
                if not snapshot then
                    appendSkipped(session, first, handsError)
                    table.remove(session.worldRemaining, 1)
                    return advance(session, after)
                end
                session.handSnapshots[first.itemKey] = snapshot
                session.heavyModes[first.itemKey] = "force"
                session.batch = {
                    entries = { first }, remaining = {},
                    sourceVisits = { { container = first.sourceContainer, entries = { first } } },
                    destinationVisits = { { id = first.destinationId, container = first.destinationContainer, entries = { first } } },
                }
                table.remove(session.worldRemaining, 1)
                session.acquireEntries, session.acquireIndex, session.phase = orderedVisits(session.batch.sourceVisits), 1, "acquire"
                return advance(session, after)
            end
            appendSkipped(session, first, batch.reason)
            table.remove(session.worldRemaining, 1)
            return advance(session, after)
        end
        session.batch = batch
        if batch.exceptionalSingleton and batch.entries[1] then session.exceptionalKeys[batch.entries[1].itemKey] = true end
        session.worldRemaining = batch.remaining
        session.acquireEntries, session.acquireIndex = orderedVisits(batch.sourceVisits), 1
        session.phase = "acquire"
    end
    if session.phase == "acquire" then
        local entry = session.acquireEntries[session.acquireIndex]
        if entry then
            session.acquireIndex = session.acquireIndex + 1
            acquire(session, entry, after)
            return
        end
        session.deliveryEntries, session.deliveryIndex = orderedVisits(session.batch.destinationVisits), 1
        session.phase = "deliver"
    end
    if session.phase == "deliver" then
        local entry = session.deliveryEntries[session.deliveryIndex]
        if entry then
            session.deliveryIndex = session.deliveryIndex + 1
            if session.acquired[entry.itemKey] then deliver(session, entry, after) else advance(session, after) end
            return
        end
        session.phase = "batch"
        return advance(session, after)
    end
end

function StorageJobExecutor.start(job, character, options, runtime)
    if type(options) ~= "table" or (options.carryMode ~= "safe" and options.carryMode ~= "yolo")
        or type(options.restoreHeldItems) ~= "boolean" or (options.onFinished ~= nil and type(options.onFinished) ~= "function") then
        return nil, "invalid_options"
    end
    if not character then return nil, "invalid_character" end
    -- Partition performs complete immutable-job validation before this slice
    -- clears the vanilla queue or queues its first private step.
    local partition, partitionError = Planner.partition(job, character, runtime)
    if not partition then return nil, partitionError end
    local hasClear = runtime and type(runtime.clear) == "function"
    local hasAdd = runtime and type(runtime.add) == "function"
    local hasAddAfter = runtime and type(runtime.addAfter) == "function"
    if not hasClear and (not ISTimedActionQueue or type(ISTimedActionQueue.clear) ~= "function") then
        return nil, "queue_unavailable"
    end
    if not hasAdd and (not ISTimedActionQueue or type(ISTimedActionQueue.add) ~= "function") then
        return nil, "queue_unavailable"
    end
    if (#partition.carried > 0 or #partition.world > 0) and not hasAddAfter
        and (not ISTimedActionQueue or type(ISTimedActionQueue.addAfter) ~= "function") then
        return nil, "queue_unavailable"
    end
    local session = {
        status = "running", completed = {}, skipped = {}, stranded = {}, character = character, runtime = runtime,
        options = options, carried = carriedDeliveries(partition.carried), carriedIndex = 1,
        worldRemaining = copyEntries(partition.world, false),
        acquired = {}, heavyModes = {}, handSnapshots = {}, exceptionalKeys = {}, phase = "carried",
    }
    local cleared = runtimeCall(runtime, "clear", character)
    if cleared == false then return nil, "queue_unavailable" end
    if cleared == nil then
        if not ISTimedActionQueue or type(ISTimedActionQueue.clear) ~= "function" then return nil, "queue_unavailable" end
        ISTimedActionQueue.clear(character)
    end
    if not step(session, function(first) advance(session, first) end) then return nil, "queue_unavailable" end
    return session
end

return StorageJobExecutor
