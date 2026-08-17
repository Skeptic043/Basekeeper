local function expect(value, message) if not value then error(message, 2) end end
local function equal(actual, expected, message) expect(actual == expected, message) end

Basekeeper = nil
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/HaulBatchPlanner.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/client/Basekeeper/ContainerAccess.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/client/Basekeeper/StorageJobExecutor.lua")

local function container(name, options)
    options = options or {}
    local value = { name = name, carried = options.carried, room = options.room ~= false, exists = options.exists ~= false,
        floor = options.floor, parent = options.parent, containingItem = options.containingItem, vehiclePart = options.vehiclePart }
    function value:isInCharacterInventory() return self.carried == true end
    function value:hasRoomFor() return self.room == true end
    function value:isRemoveItemAllowed() return self.removeAllowed ~= false end
    function value:isItemAllowed() return self.acceptAllowed ~= false end
    function value:isExistYet() return self.exists == true end
    function value:getType() return self.floor and "floor" or self.name end
    function value:getParent() return self.parent end
    function value:getContainingItem() return self.containingItem end
    function value:getVehiclePart() return self.vehiclePart end
    return value
end

local function item(key, source, options)
    options = options or {}
    local value = { key = key, container = source, weight = options.weight or 1, favorite = options.favorite,
        force = options.force, human = options.human, equippedWeight = options.equippedWeight }
    function value:getUnequippedWeight() return self.weight end
    function value:getEquippedWeight() return self.equippedWeight or self.weight end
    function value:isFavorite() return self.favorite == true end
    function value:isHumanCorpse() return self.human == true end
    function value:getContainer() return self.container end
    return value
end

local function character(inventory)
    local value = { inventory = inventory }
    function value:getInventory() return self.inventory end
    function value:getMaxWeight() return 20 end
    function value:isUnlimitedCarry() return false end
    function value:getPrimaryHandItem() return self.primary end
    function value:getSecondaryHandItem() return self.secondary end
    return value
end

local function fakeRuntime(character, inventory, options)
    options = options or {}
    local state = { queue = {}, clears = 0, maximumQueued = 0, transfers = {}, heavy = 0, unequips = 0, equips = 0 }
    local function add(action)
        state.queue[#state.queue + 1] = action
        if #state.queue > state.maximumQueued then state.maximumQueued = #state.queue end
        return true
    end
    local function path(kind, subject)
        local action = { kind = kind, subject = subject }
        function action:setRunActionsAfterFailing() self.runAfterFail = true end
        function action:setOnFail(callback) self.onFail = callback end
        function action:perform()
            if self.subject and self.subject.pathFails and self.onFail then self.onFail() end
        end
        return action
    end
    local runtime = {
        clear = function() state.clears = state.clears + 1; state.queue = {}; return true end,
        add = add,
        addAfter = function(previous, action)
            if state.current == previous then return add(action) end
            for _, queued in ipairs(state.queue) do if queued == previous then return add(action) end end
            return false
        end,
        getInventory = function() return inventory end,
        getCapacityWeight = function() return options.currentWeight or 0 end,
        getEffectiveCapacity = function() return options.hardCapacity or 100 end,
        getMaxWeight = function() return 20 end,
        isUnlimitedCarry = function() return false end,
        itemInContainer = function(value, target) return value.container == target end,
        isInCharacterInventory = function(value) return value.carried == true end,
        isLocalFloor = function(value) return value.floor == true end,
        containerExists = function(value) return value.exists == true end,
        isForceDropHeavyItem = function(value) return value.force == true end,
        isHumanCorpse = function(value) return value.human == true end,
        getPrimaryHandItem = function() return character.primary end,
        getSecondaryHandItem = function() return character.secondary end,
        newTransferAction = function(_, moved, from, to)
            state.transfers[#state.transfers + 1] = { key = moved.key, from = from.name, to = to.name, corpse = moved.human == true }
            return { perform = function()
                if from == inventory and to.failDelivery then return end
                moved.container = to
                if character.primary == moved then character.primary = nil end
                if character.secondary == moved then character.secondary = nil end
            end }
        end,
        newHeavyAcquireAction = function(_, moved)
            state.heavy = state.heavy + 1
            return { perform = function()
                moved.container = inventory
                character.primary, character.secondary = moved, moved
            end }
        end,
        newUnequipAction = function(_, held)
            state.unequips = state.unequips + 1
            return { perform = function()
                if character.primary == held then character.primary = nil end
                if character.secondary == held then character.secondary = nil end
                if held.disappearOnUnequip then held.container = nil end
            end }
        end,
        newEquipWeaponAction = function(_, held, primary)
            state.equips = state.equips + 1
            return { perform = function()
                if not held.failEquip then
                    if primary then character.primary = held else character.secondary = held end
                end
            end }
        end,
        distToProper = function(_, parent) return parent.distance or 3 end,
        pathAdjacentToMultiTileObject = function(_, parent) return path("fixed", parent) end,
        pathAdjacentToSquares = function(_, squares) return path("placed", squares[1]) end,
        pathToVehicleArea = function(_, vehicle) return path("vehicle", vehicle) end,
    }
    local function drain(limit)
        local count = 0
        while #state.queue > 0 do
            count = count + 1
            expect(count < (limit or 200), "queue did not drain")
            local action = table.remove(state.queue, 1)
            state.current = action
            action:perform()
            state.current = nil
        end
    end
    return runtime, state, drain
end

local function job(moves)
    return { kind = "unload", zoneId = "home", zoneRevision = 1, retained = {}, final = {}, moves = moves }
end

local function move(key, value, source, destination, destinationId)
    return { itemKey = key, item = value, sourceContainer = source, destinationId = destinationId or destination.name,
        destinationContainer = destination }
end

do
    local inv, source, dest = container("inventory", { carried = true }), container("source", { floor = true }), container("dest", { floor = true })
    local chr = character(inv)
    local runtime, state, drain = fakeRuntime(chr, inv)
    local bad = Basekeeper.StorageJobExecutor.start({ moves = {} }, chr, { carryMode = "safe", restoreHeldItems = false }, runtime)
    equal(bad, nil, "invalid job must not start")
    equal(state.clears, 0, "invalid job must not clear")
    local value = item("one", source)
    local finished = 0
    local session = assert(Basekeeper.StorageJobExecutor.start(job({ move("one", value, source, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = false, onFinished = function() finished = finished + 1 end }, runtime))
    equal(state.clears, 1, "valid start clears exactly once")
    drain()
    equal(session.status, "completed", "normal chain completes")
    equal(finished, 1, "completion callback once")
    equal(value.container, dest, "transfer checkpoint completed")
    expect(state.maximumQueued <= 2, "executor must only queue bounded next work")
end

do
    local inv = container("inventory", { carried = true })
    local source = container("world", { floor = true })
    local a, b = container("A", { floor = true }), container("B", { floor = true, room = false })
    local chr = character(inv)
    local runtime, state, drain = fakeRuntime(chr, inv, { hardCapacity = 35 })
    local carriedA, carriedB, worldOne, worldTwo = item("ca", inv), item("cb", inv), item("w1", source, { weight = 20 }), item("w2", source, { weight = 20 })
    local session = assert(Basekeeper.StorageJobExecutor.start(job({
        move("ca", carriedA, inv, a, "a"), move("cb", carriedB, inv, b, "b"),
        move("w1", worldOne, source, a, "a"), move("w2", worldTwo, source, a, "a"),
    }), chr, { carryMode = "safe", restoreHeldItems = false }, runtime))
    drain()
    equal(state.transfers[1].key, "ca", "carried destination runs first")
    equal(carriedB.container, inv, "failed carried delivery stays in inventory")
    equal(#session.stranded, 0, "carried failure never strands")
    equal(session.skipped[1].itemKey, "cb", "carried failure reports skip")
    equal(worldOne.container, a, "first fresh batch delivers")
    equal(worldTwo.container, a, "later fresh batch delivers")
end

do
    local chr = { getCurrentSquare = function() return { } end }
    local runtime = {
        isLocalFloor = function(value) return value.floor == true end,
        distToProper = function(_, parent) return parent.distance end,
        pathAdjacentToMultiTileObject = function(_, parent) return { kind = "fixed", parent = parent } end,
        pathAdjacentToSquares = function(_, squares) return { kind = "placed", square = squares[1] } end,
        pathToVehicleArea = function(_, vehicle, area) return { kind = "vehicle", vehicle = vehicle, area = area } end,
    }
    expect(Basekeeper.ContainerAccess.prepare({ floor = true }, chr, runtime).ready, "floor ready")
    local parent = { distance = 3, getSquare = function() return {} end }
    local fixed = assert(Basekeeper.ContainerAccess.prepare({ getParent = function() return parent end }, chr, runtime))
    equal(fixed.action.kind, "fixed", "fixed paths")
    expect(not fixed.recheck(), "fixed recheck detects still-distant parent")
    parent.distance = 1
    expect(fixed.recheck(), "fixed recheck succeeds near")
    local worldObject = { distance = 3, getSquare = function() return {} end }
    local placed = assert(Basekeeper.ContainerAccess.prepare({ getContainingItem = function() return { getWorldItem = function() return worldObject end } end }, chr, runtime))
    equal(placed.action.kind, "placed", "placed paths from world object square")
    local vehicle = { canAccessContainer = function() return false end }
    local part = { getVehicle = function() return vehicle end, getArea = function() return "TruckBed" end, getIndex = function() return 4 end }
    equal(assert(Basekeeper.ContainerAccess.prepare({ getVehiclePart = function() return part end }, chr, runtime)).action.kind, "vehicle", "vehicle area path")
end

do
    local inv, badSource, goodSource, dest = container("inventory", { carried = true }), container("bad", { floor = true }), container("good", { floor = true }), container("dest", { floor = true })
    badSource.exists = false
    local chr = character(inv)
    local runtime, _, drain = fakeRuntime(chr, inv)
    local missing, good = item("missing", badSource), item("good", goodSource)
    local session = assert(Basekeeper.StorageJobExecutor.start(job({ move("missing", missing, badSource, dest), move("good", good, goodSource, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = false }, runtime))
    drain()
    equal(session.skipped[1].reason, "missing_source", "existence failure is prechecked")
    equal(good.container, dest, "unrelated move continues")
end

do
    local inv, source, dest = container("inventory", { carried = true }), container("source", { floor = true }), container("dest", { floor = true })
    local chr = character(inv)
    local runtime, _, drain = fakeRuntime(chr, inv)
    local value = item("revalidate", source)
    local session = assert(Basekeeper.StorageJobExecutor.start(job({ move("revalidate", value, source, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = false }, runtime))
    value.favorite = true
    drain()
    equal(session.skipped[1].reason, "favorite_item", "favorite is revalidated before pickup")
    value.favorite = false
    local capacity = item("capacity", source)
    local second = assert(Basekeeper.StorageJobExecutor.start(job({ move("capacity", capacity, source, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = false }, runtime))
    dest.room = false
    drain()
    equal(second.skipped[1].reason, "destination_full", "capacity is revalidated before pickup")
    dest.room = true
    local denied = item("denied", source)
    local permission = assert(Basekeeper.StorageJobExecutor.start(job({ move("denied", denied, source, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = false }, runtime))
    source.removeAllowed = false
    drain()
    equal(permission.skipped[1].reason, "source_removal_denied", "source permission is revalidated")
    source.removeAllowed = true
    local parent = { distance = 3, pathFails = true, getSquare = function() return {} end }
    local inaccessible, good = container("inaccessible", { parent = parent }), container("good", { floor = true })
    local blocked, continued = item("blocked", inaccessible), item("continued", good)
    local third = assert(Basekeeper.StorageJobExecutor.start(job({ move("blocked", blocked, inaccessible, dest), move("continued", continued, good, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = false }, runtime))
    drain()
    equal(third.skipped[1].reason, "access_failed", "path failure skips source entry")
    equal(continued.container, dest, "path failure continues unrelated entry")
end

do
    local inv, source, dest = container("inventory", { carried = true }), container("source", { floor = true }), container("dest", { floor = true })
    local chr = character(inv)
    local runtime, state, drain = fakeRuntime(chr, inv, { hardCapacity = 35 })
    local exceptional = item("exceptional", source, { weight = 30, equippedWeight = 10 })
    local session = assert(Basekeeper.StorageJobExecutor.start(job({ move("exceptional", exceptional, source, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = false }, runtime))
    drain()
    equal(session.completed[1], "exceptional", "safe exceptional singleton completes through ordinary transfer")
    equal(state.heavy, 0, "ordinary exceptional never enters force-heavy lane")
end

do
    local inv, source, dest = container("inventory", { carried = true }), container("source", { floor = true }), container("dest", { floor = true })
    dest.failDelivery = true
    local chr = character(inv)
    local primary, secondary = item("primary", inv), item("secondary", inv)
    chr.primary, chr.secondary = primary, secondary
    local runtime, state, drain = fakeRuntime(chr, inv)
    local heavy = item("heavy", source, { force = true })
    local session = assert(Basekeeper.StorageJobExecutor.start(job({ move("heavy", heavy, source, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = true }, runtime))
    drain()
    equal(heavy.container, source, "failed delivery recovers item to source")
    equal(session.skipped[1].reason, "recovered_delivery_transfer_failed", "recovery is reported")
    equal(chr.primary, primary, "primary restored after recovery")
    equal(chr.secondary, secondary, "secondary restored after recovery")
    equal(state.heavy, 1, "normally fitting force-heavy uses heavy lane")
    source.room = false
    local heavyTwo = item("heavyTwo", source, { force = true })
    local sessionTwo = assert(Basekeeper.StorageJobExecutor.start(job({ move("heavyTwo", heavyTwo, source, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = false }, runtime))
    drain()
    equal(sessionTwo.stranded[1].itemKey, "heavyTwo", "unrecoverable item is stranded")
    expect(chr.primary ~= primary or chr.secondary ~= secondary, "restore false leaves prior hands unequipped")
end

do
    local inv, source, dest = container("inventory", { carried = true }), container("source", { floor = true }), container("dest", { floor = true })
    local chr = character(inv)
    local runtime, state, drain = fakeRuntime(chr, inv, { hardCapacity = 50 })
    local blocked = item("blocked", source, { force = true, weight = 100 })
    assert(Basekeeper.StorageJobExecutor.start(job({ move("blocked", blocked, source, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = false }, runtime))
    drain()
    equal(blocked.container, dest, "first blocked force-heavy fallback completes")
    expect(state.heavy >= 1, "fallback uses ISEquipHeavyItem lane")
    local corpse = item("corpse", source, { force = true, human = true })
    assert(Basekeeper.StorageJobExecutor.start(job({ move("corpse", corpse, source, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = false }, runtime))
    drain()
    equal(state.transfers[#state.transfers].corpse, true, "human corpse uses transfer factory lane")
end

do
    local inv, source, dest = container("inventory", { carried = true }), container("source", { floor = true }), container("dest", { floor = true })
    local chr = character(inv)
    local runtime, state, drain = fakeRuntime(chr, inv)
    local favoriteHeld, heavy = item("held", inv, { favorite = true }), item("heavy", source, { force = true })
    chr.secondary = favoriteHeld
    local session = assert(Basekeeper.StorageJobExecutor.start(job({ move("heavy", heavy, source, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = false }, runtime))
    drain()
    equal(session.skipped[1].reason, "favorite_hands_blocked", "favorite secondary blocks force-heavy")
    chr.secondary = item("otherHeavy", inv, { force = true })
    local sessionTwo = assert(Basekeeper.StorageJobExecutor.start(job({ move("heavy2", item("heavy2", source, { force = true }), source, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = false }, runtime))
    drain()
    equal(sessionTwo.skipped[1].reason, "unrelated_heavy_hands_blocked", "unrelated heavy blocks force-heavy")
    chr.secondary = nil
    local stopped = assert(Basekeeper.StorageJobExecutor.start(job({ move("stop", item("stop", source), source, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = false }, runtime))
    state.queue = {}
    equal(stopped.status, "running", "manual stop invents no completion")
end

do
    local inv, source, dest = container("inventory", { carried = true }), container("source", { floor = true }), container("dest", { floor = true })
    dest.failDelivery = true
    local chr = character(inv)
    local secondary = item("secondary", inv)
    chr.secondary = secondary
    local runtime, _, drain = fakeRuntime(chr, inv)
    local originalMoves = {}
    local heavy = item("restore", source, { force = true })
    local request = job({ move("restore", heavy, source, dest) })
    originalMoves[1] = request.moves[1]
    local session = assert(Basekeeper.StorageJobExecutor.start(request, chr, { carryMode = "safe", restoreHeldItems = true }, runtime))
    drain()
    equal(chr.secondary, secondary, "secondary-only snapshot restores without ipairs truncation")
    equal(request.moves[1], originalMoves[1], "job move reference stays immutable")
    expect(session.handSnapshots.restore == nil, "singleton snapshot is cleared")
    local vanished = item("vanished", inv)
    vanished.disappearOnUnequip = true
    chr.secondary = vanished
    local nextHeavy = item("next", source, { force = true })
    assert(Basekeeper.StorageJobExecutor.start(job({ move("next", nextHeavy, source, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = true }, runtime))
    drain()
    equal(chr.secondary, nil, "disappeared prior hand is ignored")
    local fails = item("fails", inv)
    fails.failEquip = true
    chr.secondary = fails
    local lastHeavy = item("last", source, { force = true })
    local finalSession = assert(Basekeeper.StorageJobExecutor.start(job({ move("last", lastHeavy, source, dest) }), chr,
        { carryMode = "safe", restoreHeldItems = true }, runtime))
    drain()
    equal(finalSession.status, "completed", "failed best-effort restoration does not fail job")
end

print("storage_job_executor_spec: ok")
