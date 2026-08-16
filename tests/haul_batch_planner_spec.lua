local function expect(condition, message)
    if not condition then error(message, 2) end
end

dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/HaulBatchPlanner.lua")

local Planner = Basekeeper.HaulBatchPlanner

local function item(id, weight, favorite)
    local result = { id = id, weight = weight, favorite = favorite == true, weightReads = 0 }
    function result:getUnequippedWeight() self.weightReads = self.weightReads + 1 return self.weight end
    function result:isFavorite() return self.favorite end
    return result
end

local function container(name, carried)
    local result = { name = name, carried = carried == true }
    function result:isInCharacterInventory(character) return self.carried end
    return result
end

local function move(key, itemValue, source, destinationId, destination)
    return {
        itemKey = key, item = itemValue, sourceContainer = source,
        destinationId = destinationId, destinationContainer = destination,
    }
end

local function job(moves)
    return { kind = "unload", zoneId = "home", zoneRevision = 1, moves = moves, retained = {}, final = {} }
end

local inventory = { capacityWeight = 6, effectiveCapacity = 42, weightReads = 0, capacityReads = 0 }
function inventory:getCapacityWeight() self.weightReads = self.weightReads + 1 return self.capacityWeight end
function inventory:getEffectiveCapacity(character) self.capacityReads = self.capacityReads + 1 return self.effectiveCapacity end
local character = { inventory = inventory, maxWeight = 20, unlimited = false, inventoryReads = 0, maxReads = 0, unlimitedReads = 0 }
function character:getInventory() self.inventoryReads = self.inventoryReads + 1 return self.inventory end
function character:getMaxWeight() self.maxReads = self.maxReads + 1 return self.maxWeight end
function character:isUnlimitedCarry() self.unlimitedReads = self.unlimitedReads + 1 return self.unlimited end

local carry = assert(Planner.snapshotCarry(character))
expect(carry.currentWeight == 6 and carry.nominalCapacity == 20 and carry.hardCapacity == 42 and not carry.unlimitedCarry,
    "snapshot reads live character and inventory facts")
expect(character.inventoryReads == 1 and inventory.weightReads == 1 and inventory.capacityReads == 1 and character.maxReads == 1 and character.unlimitedReads == 1,
    "snapshot calls each live method once")
local adapted = assert(Planner.snapshotCarry({}, {
    getInventory = function() return {} end,
    getCapacityWeight = function() return 4 end,
    getMaxWeight = function() return 0 end,
    getEffectiveCapacity = function() return 0 end,
    isUnlimitedCarry = function() return true end,
}))
expect(adapted.unlimitedCarry and adapted.nominalCapacity == 0 and adapted.hardCapacity == 0, "runtime adapter supports unlimited carry tests")
expect(not Planner.snapshotCarry({}), "missing capacity methods reject")
expect(not Planner.limits({ currentWeight = 0, nominalCapacity = 0, hardCapacity = 20, unlimitedCarry = false }, "safe"), "invalid capacity facts reject")

local carriedSource, worldSource = container("carried", true), container("world", false)
local destinationA, destinationB = container("A"), container("B")
local carriedItem, worldItem = item("carried", 2), item("world", 3)
local original = job({
    move("carried-key", carriedItem, carriedSource, "a", destinationA),
    move("world-key", worldItem, worldSource, "b", destinationB),
})
local partition = assert(Planner.partition(original, character))
expect(#partition.carried == 1 and partition.carried[1].move == original.moves[1] and #partition.world == 1
    and partition.world[1].move == original.moves[2] and carriedItem.weightReads == 1 and worldItem.weightReads == 1,
    "partition preserves move order and reads each atomic weight once")
partition.world[1].weight = 99
expect(original.moves[2].item == worldItem and #original.moves == 2, "partition output does not mutate job")
expect(not Planner.partition(job({ move("same", item(1, 1), worldSource, "a", worldSource) }), character), "same source and destination reject")
local shared = item("shared", 1)
expect(not Planner.partition(job({ move("a", shared, worldSource, "a", destinationA), move("b", shared, worldSource, "b", destinationB) }), character), "duplicate item references reject")
expect(not Planner.partition(job({ move("a", item(1, 1), worldSource, "a", destinationA), move("a", item(2, 1), worldSource, "b", destinationB) }), character), "duplicate item keys reject")
expect(not Planner.partition(job({ move("fav", item(3, 1, true), worldSource, "a", destinationA) }), character), "favorite item rejects")
expect(not Planner.partition(job({ move("bad", item(4, math.huge), worldSource, "a", destinationA) }), character), "malformed weight rejects")

local safe = assert(Planner.limits({ currentWeight = 0, nominalCapacity = 20, hardCapacity = 100, unlimitedCarry = false }, "safe"))
local yolo = assert(Planner.limits({ currentWeight = 0, nominalCapacity = 20, hardCapacity = 63, unlimitedCarry = false }, "yolo"))
expect(safe.margin == 2 and safe.limit == 24, "safe uses exact 1.20 nominal limit")
expect(yolo.margin == 1.26 and yolo.limit == 61.74, "yolo margin follows live hard capacity")
expect(assert(Planner.limits({ currentWeight = 0, nominalCapacity = 0, hardCapacity = 0, unlimitedCarry = true }, "safe")).limit == math.huge,
    "unlimited carry has no batch limit")

local world = assert(Planner.partition(original, character)).world
local batch = assert(Planner.nextBatch(world, { currentWeight = 18, nominalCapacity = 20, hardCapacity = 30, unlimitedCarry = false }, "safe"))
expect(#batch.entries == 1 and batch.entries[1].itemKey == "world-key" and batch.projectedWeight == 21 and batch.complete,
    "batch selects a fitting deterministic prefix")
local nextItem = item(5, 2)
local more = {
    world[1],
    { move = move("next", nextItem, worldSource, "a", destinationA), itemKey = "next", item = nextItem, sourceContainer = worldSource, destinationId = "a", destinationContainer = destinationA, weight = 2 },
}
local bounded = assert(Planner.nextBatch(more, { currentWeight = 20, nominalCapacity = 20, hardCapacity = 30, unlimitedCarry = false }, "safe"))
expect(#bounded.entries == 1 and #bounded.remaining == 1 and bounded.remaining[1] ~= more[2], "batch never skips and copies remaining suffix")
local blocked = assert(Planner.nextBatch(world, { currentWeight = 29, nominalCapacity = 20, hardCapacity = 30, unlimitedCarry = false }, "safe"))
expect(blocked.blocked and blocked.reason == "carry_limit" and #blocked.entries == 0 and #blocked.remaining == 1 and blocked.projectedWeight == 29,
    "insufficient headroom returns a non-error blocked batch")
local zeroHeadroom = assert(Planner.nextBatch(world, { currentWeight = 0, nominalCapacity = 1, hardCapacity = 1, unlimitedCarry = false }, "safe"))
expect(zeroHeadroom.blocked and #zeroHeadroom.entries == 0 and zeroHeadroom.projectedWeight == 0,
    "zero safe headroom blocks the first item")
local empty = assert(Planner.nextBatch({}, { currentWeight = 1, nominalCapacity = 20, hardCapacity = 30, unlimitedCarry = false }, "safe"))
expect(empty.complete and not empty.blocked and #empty.entries == 0, "empty input completes")
local unlimited = assert(Planner.nextBatch(more, { currentWeight = 100, nominalCapacity = 0, hardCapacity = 0, unlimitedCarry = true }, "yolo"))
expect(#unlimited.entries == 2 and unlimited.complete, "unlimited carry takes every entry")

local heavyItem = item("heavy", 25)
local heavyEntry = assert(Planner.partition(job({ move("heavy", heavyItem, worldSource, "a", destinationA) }), character)).world
local singleton = assert(Planner.nextBatch(heavyEntry, { currentWeight = 4, nominalCapacity = 10, hardCapacity = 30, unlimitedCarry = false }, "safe"))
expect(#singleton.entries == 1 and singleton.exceptionalSingleton and singleton.projectedWeight == 29,
    "safe allows one indivisible item below hard capacity")
local tooHeavy = assert(Planner.nextBatch(heavyEntry, { currentWeight = 6, nominalCapacity = 10, hardCapacity = 30, unlimitedCarry = false }, "safe"))
expect(tooHeavy.blocked and #tooHeavy.entries == 0, "safe blocks indivisible item over hard capacity")

local sourceTwo = container("world-two", false)
local visits = assert(Planner.nextBatch({
    assert(Planner.partition(job({ move("one", item(10, 1), worldSource, "a", destinationA) }), character)).world[1],
    assert(Planner.partition(job({ move("two", item(11, 1), sourceTwo, "b", destinationB) }), character)).world[1],
    assert(Planner.partition(job({ move("three", item(12, 1), worldSource, "b", destinationB) }), character)).world[1],
}, { currentWeight = 0, nominalCapacity = 20, hardCapacity = 100, unlimitedCarry = false }, "safe"))
expect(#visits.sourceVisits == 2 and visits.sourceVisits[1].container == worldSource and visits.sourceVisits[2].container == sourceTwo
    and #visits.destinationVisits == 2 and visits.destinationVisits[1].id == "a" and visits.destinationVisits[2].id == "b"
    and #visits.sourceVisits[1].entries == 2 and visits.entries[1] ~= visits.sourceVisits[1].entries[2],
    "source and destination visits retain first-occurrence order without reordering")
visits.entries[1].weight = 77
expect(visits.sourceVisits[1].entries[1].weight == 77, "visit entries describe the copied selected entries")

print("haul_batch_planner_spec: ok")
