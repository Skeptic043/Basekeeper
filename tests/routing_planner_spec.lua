local function expect(condition, message)
    if not condition then error(message, 2) end
end

dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/CategoryRules.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ContainerBinding.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ContainerConfig.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/RoutingPlanner.lua")

local Config = Basekeeper.ContainerConfig
local Planner = Basekeeper.RoutingPlanner

local binding = { kind = "placedItem", itemId = 1, x = 0, y = 0, z = 0 }
local filters = { condition = { min = 0, max = 100 }, remaining = { min = 50, max = 50 } }
local config = assert(Config.normalize({ id = "c", binding = binding, categoryId = "cat", advancedFilters = filters }))
expect(config.advancedFilters.condition.min == 0 and config.advancedFilters.condition.max == 100,
    "advanced filter boundaries normalize inclusively")
filters.condition.min = 99
expect(config.advancedFilters.condition.min == 0, "advanced filters are copied")
expect(next(assert(Config.normalize({ id = "empty", binding = binding, categoryId = "cat" })).advancedFilters) == nil,
    "omitted advanced filters normalize independently to empty tables")
expect(not Config.normalize({ id = "bad", binding = binding, categoryId = "cat", advancedFilters = { condition = { min = 40 } } }),
    "incomplete advanced ranges reject")
expect(not Config.normalize({ id = "bad", binding = binding, categoryId = "cat", advancedFilters = { other = { min = 0, max = 1 } } }),
    "unknown advanced ranges reject")

local function category(included, whitelist, blacklist)
    return {
        id = "basekeeper:custom:routing", kind = "custom", name = "Routing",
        includedCategories = included or {}, whitelist = whitelist or {}, blacklist = blacklist or {},
    }
end

local function destination(id, values)
    values = values or {}
    return {
        id = id, priority = values.priority == nil and 5 or values.priority,
        category = values.category or category({ Food = true }), stockTargets = values.stockTargets or {},
        advancedFilters = values.advancedFilters or {}, active = values.active == nil or values.active,
        maxWeight = values.maxWeight == nil and 100 or values.maxWeight,
        initialWeight = values.initialWeight or 0, originalCounts = values.originalCounts or {},
    }
end

local function item(key, fullType, values)
    values = values or {}
    return {
        key = key, sourceId = values.sourceId, fullType = fullType, displayCategory = values.displayCategory,
        favorite = values.favorite == true, weight = values.weight or 1,
        conditionPercent = values.conditionPercent, remainingPercent = values.remainingPercent,
        distanceByDestination = values.distances or {},
    }
end

local function plan(mode, destinations, items)
    return assert(Planner.plan({ mode = mode, destinations = destinations, items = items }))
end

local oneUnit = plan("nearest", { destination("a", { stockTargets = { ["Base.Nails"] = 3 } }) }, {
    item("nail", "Base.Nails", { distances = { a = 1 } }),
})
expect(#oneUnit.assignments == 1 and oneUnit.final.a.counts["Base.Nails"] == 1,
    "one input record is one physical unit")

local favorite = plan("nearest", { destination("a", { stockTargets = { ["Base.Nails"] = 3 } }) }, {
    item("fav", "Base.Nails", { favorite = true, distances = { a = 1 } }),
})
expect(favorite.excluded[1].reason == "favorite" and favorite.final.a.counts["Base.Nails"] == nil,
    "favorites are explicitly excluded without changing targets")

local acceptance = plan("nearest", {
    destination("category", { category = category({ Food = true }) }),
    destination("target", { category = category(), stockTargets = { ["Base.Hammer"] = 1 } }),
    destination("blacklist", { category = category({ Food = true }, {}, { ["Base.Hammer"] = true }), stockTargets = { ["Base.Hammer"] = 1 } }),
}, {
    item("food", "Base.Apple", { displayCategory = "Food", distances = { category = 1 } }),
    item("target", "Base.Hammer", { distances = { target = 1, blacklist = 0 } }),
})
expect(acceptance.assignments[1].destinationId == "category", "category matching accepts matching display categories")
expect(acceptance.assignments[2].destinationId == "target", "stock targets imply exact-item acceptance")

local filtered = plan("nearest", { destination("a", {
    advancedFilters = { condition = { min = 50, max = 100 }, remaining = { min = 20, max = 80 } },
}) }, {
    item("inclusive", "Base.Apple", { displayCategory = "Food", conditionPercent = 50, remainingPercent = 80, distances = { a = 1 } }),
    item("condition", "Base.Apple", { displayCategory = "Food", conditionPercent = 49, distances = { a = 1 } }),
    item("absent", "Base.Apple", { displayCategory = "Food", distances = { a = 1 } }),
    item("both", "Base.Apple", { displayCategory = "Food", conditionPercent = 70, remainingPercent = 81, distances = { a = 1 } }),
})
expect(#filtered.assignments == 2 and filtered.assignments[1].itemKey == "inclusive" and filtered.assignments[2].itemKey == "absent",
    "filters are inclusive, compose, and ignore absent metrics")

local fullTarget = plan("nearest", {
    destination("high", { priority = 10, stockTargets = { ["Base.Nails"] = 1 }, originalCounts = { ["Base.Nails"] = 1 } }),
    destination("low", { priority = 1, category = category({ Hardware = true }) }),
}, { item("n", "Base.Nails", { displayCategory = "Hardware", distances = { high = 1, low = 2 } }) })
expect(fullTarget.assignments[1].destinationId == "low", "full targets stop broader acceptance and allow fallback")

local priority = plan("nearest", {
    destination("high-unlimited", { priority = 10 }),
    destination("low-target", { priority = 1, stockTargets = { ["Base.Apple"] = 2 } }),
    destination("high-target", { priority = 10, stockTargets = { ["Base.Apple"] = 2 } }),
}, { item("apple", "Base.Apple", { displayCategory = "Food", distances = { ["high-unlimited"] = 1, ["low-target"] = 1, ["high-target"] = 2 } }) })
expect(priority.assignments[1].destinationId == "high-target", "priority wins before same-priority target deficits")

local capacity = plan("nearest", {
    destination("high", { priority = 10, maxWeight = 2, initialWeight = 1 }),
    destination("low", { priority = 1 }),
}, {
    item("first", "Base.Apple", { displayCategory = "Food", weight = 1, distances = { high = 1, low = 2 } }),
    item("second", "Base.Apple", { displayCategory = "Food", weight = 1, distances = { high = 1, low = 2 } }),
})
expect(capacity.assignments[1].destinationId == "high" and capacity.assignments[2].destinationId == "low",
    "planned capacity accumulates and falls back by priority")

local nearest = plan("nearest", { destination("a"), destination("b") }, {
    item("nearest", "Base.Apple", { displayCategory = "Food", distances = { a = 2, b = 1 } }),
    item("id-tie", "Base.Apple", { displayCategory = "Food", distances = { a = 1, b = 1 } }),
})
expect(nearest.assignments[1].destinationId == "b" and nearest.assignments[2].destinationId == "a",
    "nearest and stable ID ties are deterministic")

local consolidate = plan("consolidate", {
    destination("near", { originalCounts = {} }),
    destination("holding", { originalCounts = { ["Base.Apple"] = 1 } }),
}, { item("apple", "Base.Apple", { displayCategory = "Food", distances = { near = 1, holding = 5 } }) })
expect(consolidate.assignments[1].destinationId == "holding", "consolidate prefers an existing exact type")

local retainedSource = plan("nearest", {
    destination("source", { maxWeight = 6, initialWeight = 5, originalCounts = { ["Base.Apple"] = 1 } }),
}, {
    item("incoming", "Base.Apple", { displayCategory = "Food", weight = 1, distances = { source = 1 } }),
    item("retained", "Base.Apple", { sourceId = "source", displayCategory = "Food", weight = 1, distances = {} }),
    item("later", "Base.Apple", { displayCategory = "Food", weight = 1, distances = { source = 1 } }),
})
expect(#retainedSource.assignments == 1 and retainedSource.assignments[1].itemKey == "incoming"
    and retainedSource.excluded[1].itemKey == "retained" and retainedSource.excluded[2].itemKey == "later"
    and retainedSource.final.source.weight == 6 and retainedSource.final.source.counts["Base.Apple"] == 2,
    "retained source items restore planned load and eligible counts after earlier assignments")

local function balanceSourceTie(destinations, target)
    local source = destination("a", {
        stockTargets = target and { ["Base.Apple"] = 2 } or {},
        originalCounts = { ["Base.Apple"] = 1 },
    })
    local other = destination("b", {
        stockTargets = target and { ["Base.Apple"] = 2 } or {},
    })
    local ordered = destinations == "forward" and { source, other } or { other, source }
    return plan("balance", ordered, {
        item("apple", "Base.Apple", { sourceId = "a", displayCategory = "Food", distances = { a = 2, b = 1 } }),
    })
end

for _, order in ipairs({ "forward", "reverse" }) do
    expect(balanceSourceTie(order, false).assignments[1].destinationId == "a",
        "balance unlimited source preference wins tied counts in " .. order .. " candidate order")
    expect(balanceSourceTie(order, true).assignments[1].destinationId == "a",
        "balance target source preference wins tied fractions in " .. order .. " candidate order")
end
local balanceTargets = plan("balance", {
    destination("a", { stockTargets = { ["Base.Apple"] = 4 }, originalCounts = { ["Base.Apple"] = 1 } }),
    destination("b", { stockTargets = { ["Base.Apple"] = 2 }, originalCounts = {} }),
}, { item("apple", "Base.Apple", { distances = { a = 1, b = 1 } }) })
expect(balanceTargets.assignments[1].destinationId == "a", "balance compares projected target fractions")

local snapshot = {
    mode = "nearest", destinations = { destination("a") },
    items = { item("copy", "Base.Apple", { displayCategory = "Food", distances = { a = 1 } }) },
}
local copied = assert(Planner.plan(snapshot))
copied.final.a.counts["Base.Apple"] = 99
expect(snapshot.destinations[1].originalCounts["Base.Apple"] == nil and snapshot.items[1].distanceByDestination.a == 1,
    "planning neither mutates inputs nor shares output count tables")
local invalid, invalidError = Planner.plan({ mode = "nearest", destinations = { destination("a"), destination("a") }, items = {} })
expect(invalid == nil and invalidError == "invalid_destination_id", "validation completes before duplicate-id planning")

print("routing_planner_spec: ok")
