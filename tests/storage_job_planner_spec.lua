local function expect(condition, message)
    if not condition then error(message, 2) end
end

dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/CategoryRules.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/RoutingPlanner.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ItemSnapshot.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/StorageJobPlanner.lua")

local Snapshot = Basekeeper.ItemSnapshot
local Jobs = Basekeeper.StorageJobPlanner

local runtime = {
    ItemTag = { SHOW_CONDITION = "show", HIDE_REMAINING = "hide" },
    instanceof = function(item, name) return item.classes and item.classes[name] == true end,
}

local function item(id, fullType, values)
    values = values or {}
    local result = {
        id = id, fullType = fullType, displayCategory = values.displayCategory, category = values.category,
        favorite = values.favorite == true, weight = values.weight == nil and 1 or values.weight,
        condition = values.condition == nil and 5 or values.condition,
        conditionMax = values.conditionMax == nil and 10 or values.conditionMax,
        remaining = values.remaining == nil and 1 or values.remaining,
        classes = values.classes or {}, tags = values.tags or {}, nestedReads = 0,
    }
    function result:getID() return self.id end
    function result:getFullType() return self.fullType end
    function result:getDisplayCategory() return self.displayCategory end
    function result:getCategory() return self.category end
    function result:isFavorite() return self.favorite end
    function result:getUnequippedWeight() return self.weight end
    function result:getCondition() return self.condition end
    function result:getConditionMax() return self.conditionMax end
    function result:getCurrentUsesFloat() return self.remaining end
    function result:hasTag(tag) return self.tags[tag] == true end
    function result:getInventory() self.nestedReads = self.nestedReads + 1 return {} end
    return result
end

local function container(items, values)
    values = values or {}
    local result = { items = items, load = values.load == nil and #items or values.load, capacity = values.capacity == nil and 20 or values.capacity, itemReads = 0, loadReads = 0, capacityReads = 0 }
    function result:getItems() self.itemReads = self.itemReads + 1 return self.items end
    function result:getCapacityWeight() self.loadReads = self.loadReads + 1 return self.load end
    function result:getEffectiveCapacity(character) self.capacityReads = self.capacityReads + 1 return self.capacity end
    return result
end

local function javaList(values)
    return {
        size = function() return #values end,
        get = function(_, index) return values[index + 1] end,
    }
end

local a = item(1, "Base.Apple", { category = "Food", weight = 2 })
local java = javaList({ a })
local copied = assert(Snapshot.directItems(container(java)))
expect(copied[1] == a and copied ~= java, "Java direct contents copy")
local bag = item(2, "Base.Bag", { category = "Container" })
local luaItems = assert(Snapshot.directItems(container({ bag })))
expect(luaItems[1] == bag and bag.nestedReads == 0, "Lua direct contents never recurse")

local fallback = assert(Snapshot.fromItem(item(3, "Base.Hammer", { category = "Tools", favorite = true, weight = 3 }), runtime))
expect(fallback.itemId == 3 and fallback.displayCategory == "Tools" and fallback.favorite and fallback.weight == 3, "facts use fallback category and atomic fields")
expect(not Snapshot.fromItem({ getID = function() return 1 end }, runtime), "invalid facts fail explicitly")
local ordinary = assert(Snapshot.fromItem(item(4, "Base.Apple", { category = "Food" }), runtime))
expect(ordinary.conditionPercent == nil and ordinary.remainingPercent == nil, "ordinary default metrics are omitted")
local durable = assert(Snapshot.fromItem(item(5, "Base.Axe", { category = "Weapon", condition = 15, conditionMax = 10, classes = { HandWeapon = true } }), runtime))
expect(durable.conditionPercent == 100, "weapon condition clamps")
local shown = assert(Snapshot.fromItem(item(6, "Base.Tool", { category = "Tools", condition = 0, conditionMax = 10, tags = { show = true } }), runtime))
expect(shown.conditionPercent == 0, "show-condition includes zero")
local drainable = assert(Snapshot.fromItem(item(7, "Base.Bottle", { category = "Food", remaining = .5, classes = { Drainable = true } }), runtime))
expect(drainable.remainingPercent == 50, "drainable remaining is emitted")
local hidden = assert(Snapshot.fromItem(item(8, "Base.Bottle", { category = "Food", classes = { Drainable = true }, tags = { hide = true } }), runtime))
expect(hidden.remainingPercent == nil, "hidden remaining is suppressed")
expect(Snapshot.distanceSquared({ x = 0, y = 0, z = 0 }, { x = 1, y = 2, z = 2 }) == 9, "3D distance")
expect(not Snapshot.distanceSquared({ x = 0, y = 0 }, { x = 0, y = 0, z = 0 }), "invalid anchors fail")

local function category(included)
    return { id = "basekeeper:custom:food", kind = "custom", name = "Food", includedCategories = included or { Food = true }, whitelist = {}, blacklist = {} }
end

local function destination(id, contents, values)
    values = values or {}
    return {
        config = { id = id, priority = values.priority == nil and 5 or values.priority, stockTargets = values.stockTargets or {}, advancedFilters = values.advancedFilters or {} },
        category = values.category or category(), container = container(contents, values), anchor = values.anchor or { x = values.x or 0, y = 0, z = 0 },
    }
end

local storedFavorite = item(10, "Base.Nails", { category = "Hardware", favorite = true })
local target = destination("target", { storedFavorite }, { stockTargets = { ["Base.Nails"] = 1 }, x = 5 })
local sourceItem = item(11, "Base.Apple", { category = "Food" })
local source = container({ sourceItem })
local directBag = item(14, "Base.Bag", { category = "Food" })
local sourceA = container({
    item(9, "Base.Apple", { category = "Food", favorite = true }),
    item(10, "Base.Hammer", { category = "Hardware" }),
    item(13, "Base.Apple", { category = "Food" }),
    directBag,
})
local unload = assert(Jobs.build({ kind = "unload", zoneId = "home", zoneRevision = 1, mode = "nearest", character = {}, destinations = { target }, sources = {
    { key = "b", container = source, anchor = { x = 2, y = 0, z = 0 } },
    { key = "a", container = sourceA, anchor = { x = 1, y = 0, z = 0 } },
} }, runtime))
expect(unload.zoneId == "home" and unload.zoneRevision == 1 and #unload.moves == 3
    and unload.moves[1].sourceKey == "a" and unload.moves[2].sourceKey == "a" and unload.moves[3].sourceKey == "b"
    and unload.retained[1].reason == "favorite" and unload.retained[2].reason == "no_destination" and directBag.nestedReads == 0,
    "unload orders explicit sources, retains favorite/no-destination items, and treats bags as direct objects")
expect(target.container.loadReads == 1 and target.container.capacityReads == 1 and target.container.itemReads == 1 and unload.final.target.counts["Base.Nails"] == 1, "destination reads once and stored favorite counts")
local rejected, rejectError = Jobs.build({ kind = "unload", zoneId = "home", zoneRevision = 1, mode = "nearest", character = {}, destinations = { target }, sources = { { key = "bad", container = target.container, anchor = target.anchor } } }, runtime)
expect(not rejected and rejectError == "destination_is_unload_source", "configured destination cannot unload")
local emptyUnload, emptyUnloadError = Jobs.build({ kind = "unload", zoneId = "home", zoneRevision = 1, mode = "nearest", character = {}, destinations = { target }, sources = {} }, runtime)
expect(not emptyUnload and emptyUnloadError == "invalid_sources", "unload requires an explicit source list")

local correct = item(12, "Base.Apple", { category = "Food" })
local fav = item(13, "Base.Apple", { category = "Food", favorite = true })
local zoneDestination = destination("zone", { correct, fav }, { x = 0 })
local zone = assert(Jobs.build({ kind = "organizeZone", zoneId = "home", zoneRevision = 2, mode = "nearest", character = {}, destinations = { zoneDestination } }, runtime))
expect(#zone.moves == 0 and #zone.retained == 2 and zone.retained[1].reason == "already_correct" and zone.retained[2].reason == "favorite", "zone retains correct and favorite contents")

local selected = destination("selected", { item(20, "Base.Apple", { category = "Food" }) }, { stockTargets = { ["Base.Nails"] = 1 }, category = category({}), x = 0 })
local near = destination("near", { item(21, "Base.Nails", { category = "Hardware" }) }, { category = category({ Hardware = true }), x = 1 })
local third = destination("third", { item(22, "Base.Nails", { category = "Hardware" }) }, { stockTargets = { ["Base.Nails"] = 1 }, priority = 10, x = 2 })
local organized = assert(Jobs.build({ kind = "organizeContainer", zoneId = "home", zoneRevision = 3, mode = "nearest", character = {}, destinations = { third, near, selected }, selectedContainerId = "selected" }, runtime))
expect(#organized.moves == 2 and organized.moves[1].phase == "route" and organized.moves[2].phase == "targetPull" and organized.moves[2].destinationId == "selected", "container routes invalid contents then pulls only selected deficit")
expect(organized.final.selected.counts["Base.Nails"] == 1, "target pull updates projected final")

local excessSelected = destination("selected", {
    item(30, "Base.Nails", { category = "Hardware" }),
    item(31, "Base.Nails", { category = "Hardware" }),
}, { stockTargets = { ["Base.Nails"] = 1 }, category = category({}), x = 0 })
local overflow = destination("overflow", {}, { category = category({ Hardware = true }), x = 1 })
local excess = assert(Jobs.build({ kind = "organizeContainer", zoneId = "home", zoneRevision = 3, mode = "nearest", character = {}, destinations = { overflow, excessSelected }, selectedContainerId = "selected" }, runtime))
expect(#excess.moves == 1 and excess.moves[1].phase == "route" and excess.moves[1].sourceId == "selected"
    and excess.moves[1].destinationId == "overflow" and excess.final.selected.counts["Base.Nails"] == 1,
    "container routes exactly the selected stock-target excess while retaining target quantity")

local blockedSelected = destination("selected", {}, { stockTargets = { ["Base.Nails"] = 1 }, category = category({}), x = 0 })
local blockedSource = destination("source", { item(23, "Base.Nails", { category = "Hardware" }) }, { category = category({ Hardware = true }), x = 1 })
local blockedThird = destination("third", {}, { stockTargets = { ["Base.Nails"] = 2 }, priority = 10, x = 2 })
local blocked = assert(Jobs.build({ kind = "organizeContainer", zoneId = "home", zoneRevision = 3, mode = "nearest", character = {}, destinations = { blockedSelected, blockedSource, blockedThird }, selectedContainerId = "selected" }, runtime))
expect(#blocked.moves == 0, "container does not move exploratory candidates chosen for an unrelated third destination")

local duplicate = destination("duplicate", {}, { x = 1 })
local duplicateJob, duplicateError = Jobs.build({ kind = "organizeZone", zoneId = "home", zoneRevision = 1, mode = "nearest", character = {}, destinations = { duplicate, duplicate } }, runtime)
expect(not duplicateJob and duplicateError == "duplicate_destination_id", "duplicate destinations reject explicitly")

local immutable = { kind = "unload", zoneId = "immutable", zoneRevision = 1, mode = "nearest", character = {}, destinations = { destination("a", {}, { x = 1 }) }, sources = { { key = "a", container = container({ item(30, "Base.Apple", { category = "Food" }) }), anchor = { x = 0, y = 0, z = 0 } } } }
local immutableJob = assert(Jobs.build(immutable, runtime))
immutableJob.final.a.counts["Base.Apple"] = 99
expect(immutable.destinations[1].config.stockTargets["Base.Apple"] == nil and immutableJob.moves ~= immutable.sources, "request and output tables stay independent")

local subsetFirst = item(40, "Base.Apple", { category = "Food" })
local subsetSecond = item(41, "Base.Hammer", { category = "Tools" })
local subsetContainer = container({ subsetFirst, subsetSecond })
local subsetRequest = {
    kind = "unload", zoneId = "subset", zoneRevision = 1, mode = "nearest", character = {},
    destinations = { destination("subset-target", {}, { x = 1 }) },
    sources = { { key = "subset", container = subsetContainer, anchor = { x = 0, y = 0, z = 0 }, items = { subsetFirst } } },
}
local subsetJob = assert(Jobs.build(subsetRequest, runtime))
expect(#subsetJob.moves == 1 and subsetJob.moves[1].item == subsetFirst and subsetContainer.itemReads == 1,
    "explicit source subset routes only its copied direct member after one direct snapshot")
subsetRequest.sources[1].items[1] = subsetSecond
expect(subsetJob.moves[1].item == subsetFirst, "explicit source array is copied before planning")

local invalidSubset, invalidSubsetError = Jobs.build({
    kind = "unload", zoneId = "subset", zoneRevision = 1, mode = "nearest", character = {},
    destinations = { destination("subset-invalid", {}, { x = 1 }) },
    sources = { { key = "subset", container = subsetContainer, anchor = { x = 0, y = 0, z = 0 }, items = { item(42, "Base.Apple", { category = "Food" }) } } },
}, runtime)
expect(not invalidSubset and invalidSubsetError == "source_item_not_direct_member", "explicit subset rejects non-direct items")
local duplicateSubset, duplicateSubsetError = Jobs.build({
    kind = "unload", zoneId = "subset", zoneRevision = 1, mode = "nearest", character = {},
    destinations = { destination("subset-duplicate", {}, { x = 1 }) },
    sources = { { key = "subset", container = subsetContainer, anchor = { x = 0, y = 0, z = 0 }, items = { subsetFirst, subsetFirst } } },
}, runtime)
expect(not duplicateSubset and duplicateSubsetError == "duplicate_source_item", "explicit subset rejects duplicate items")

print("storage_job_planner_spec: ok")
