local function expect(condition, message)
    if not condition then error(message, 2) end
end

dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ZoneGeometry.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ContainerBinding.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/CategoryRules.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ContainerConfig.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ZoneRegistry.lua")
Basekeeper.CategoryCatalog = Basekeeper.CategoryCatalog or {}
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/Schema.lua")

local Geometry = Basekeeper.ZoneGeometry
local Binding = Basekeeper.ContainerBinding
local Config = Basekeeper.ContainerConfig
local Registry = Basekeeper.ZoneRegistry
local Schema = Basekeeper.Schema

local function categoryRules(id)
    return { id = id, kind = "custom", name = "Test", includedCategories = {}, whitelist = {}, blacklist = {} }
end

local rect = assert(Geometry.normalizeRect({ x = 1, y = 2, z = 0, w = 2, h = 3 }))
expect(not Geometry.normalizeRect({ x = 1, y = 2, z = 0, w = 0, h = 1 }), "rectangles require positive size")
for _, infinity in ipairs({ math.huge, -math.huge }) do
    expect(not Geometry.normalizeRect({ x = infinity, y = 2, z = 0, w = 1, h = 1 }), "rectangle coordinates require finite integers")
    expect(not Geometry.normalizeRect({ x = 1, y = 2, z = 0, w = infinity, h = 1 }), "rectangle dimensions require finite integers")
end
expect(Geometry.containsRect(rect, 1, 2, 0) and Geometry.containsRect(rect, 2, 4, 0), "rect bounds are inclusive/exclusive")
expect(not Geometry.containsRect(rect, 3, 4, 0) and not Geometry.containsRect(rect, 2, 5, 0), "rect excludes upper bounds")
expect(Geometry.rectsShareTiles(rect, { x = 2, y = 4, z = 0, w = 2, h = 2 }), "shared tiles connect")
expect(not Geometry.rectsShareTiles(rect, { x = 3, y = 2, z = 0, w = 1, h = 1 }), "edge-only contact does not connect")
expect(not Geometry.rectsShareTiles(rect, { x = 3, y = 5, z = 0, w = 1, h = 1 }), "corner contact does not connect")
expect(not Geometry.rectsShareTiles(rect, { x = 1, y = 2, z = 1, w = 1, h = 1 }), "different z does not connect")

local root = Schema.newRoot()
local alpha = assert(Registry.create(root, { id = "alpha", name = "Alpha", ownerAccount = "alice", routingMode = "nearest", areas = { { x = 0, y = 0, z = 0, w = 2, h = 2 } } }))
local beta = assert(Registry.create(root, { id = "beta", name = "Beta", ownerAccount = "bob", routingMode = "balance", areas = { { x = 4, y = 0, z = 0, w = 2, h = 2 } } }))
local connected = assert(Registry.findAreaConnections(root, "alpha", { x = 1, y = 0, z = 0, w = 4, h = 2 }))
expect(#connected == 1 and connected[1] == "beta", "connection detection is deterministic and excludes current zone")
local revision = alpha.revision
local failed, connectionError, ids = Registry.addArea(root, "alpha", { x = 1, y = 0, z = 0, w = 4, h = 2 })
expect(not failed and connectionError == "area_connects_zones" and ids[1] == "beta", "connected areas refuse silent merge")
expect(alpha.revision == revision, "refused area does not mutate")
assert(Registry.addArea(root, "alpha", { x = 0, y = 4, z = 0, w = 1, h = 1 }))
expect(alpha.revision == revision + 1, "real area mutation increments revision")
assert(Registry.addArea(root, "alpha", { x = 0, y = 4, z = 0, w = 1, h = 1 }))
expect(alpha.revision == revision + 1, "duplicate area does not increment revision")
assert(Registry.removeArea(root, "alpha", { x = 0, y = 4, z = 0, w = 1, h = 1 }))
local last, lastError = Registry.removeArea(root, "alpha", { x = 0, y = 0, z = 0, w = 2, h = 2 })
expect(not last and lastError == "last_area", "last area remains protected")
expect(Geometry.containsZone(alpha, 0, 0, 0) and not Geometry.containsZone(alpha, 2, 0, 0), "zone membership uses rect union")

local stock = { ["Base.Nails"] = 4 }
local defaultConfig = assert(Config.normalize({ id = "c1", binding = { kind = "placedItem", itemId = 1, x = 0, y = 0, z = 0 }, categoryId = "basekeeper:preset:tools", categoryRules = categoryRules("basekeeper:preset:tools"), stockTargets = stock }))
expect(defaultConfig.priority == 5 and defaultConfig.locked == false, "container defaults are stable")
expect(assert(Config.normalize({ id = "c2", binding = defaultConfig.binding, categoryId = "cat", categoryRules = categoryRules("cat"), priority = 0 })).priority == 0, "priority zero is valid")
expect(assert(Config.normalize({ id = "c3", binding = defaultConfig.binding, categoryId = "cat", categoryRules = categoryRules("cat"), priority = 10 })).priority == 10, "priority ten is valid")
expect(not Config.normalize({ id = "bad", binding = defaultConfig.binding, categoryId = "cat", categoryRules = categoryRules("cat"), stockTargets = { Bad = 1 } }), "stock targets require full types")
expect(not Config.normalize({ id = "bad", binding = defaultConfig.binding, categoryId = "cat", categoryRules = categoryRules("cat"), stockTargets = { ["Base.Nails"] = 1.5 } }), "stock target quantities are positive integers")
stock["Base.Nails"] = 9
expect(defaultConfig.stockTargets["Base.Nails"] == 4, "stock targets are copied")

expect(assert(Binding.normalize({ kind = "world", objectBindingId = "w1", x = 0, y = 0, z = 0, containerIndex = 0 })).kind == "world", "world binding normalizes")
expect(assert(Binding.normalize({ kind = "placedItem", itemId = 7, x = 0, y = 0, z = 0 })).kind == "placedItem", "placed binding normalizes")
expect(assert(Binding.normalize({ kind = "vehiclePart", vehicleSqlId = 7, partId = "TruckBed" })).kind == "vehiclePart", "vehicle binding normalizes")
expect(not Binding.normalize({ kind = "vehiclePart", vehicleId = 7, partId = "TruckBed" }), "runtime vehicle ID cannot be durable binding")
for _, infinity in ipairs({ math.huge, -math.huge }) do
    expect(not Binding.normalize({ kind = "world", objectBindingId = "w1", x = infinity, y = 0, z = 0, containerIndex = 0 }),
        "world bindings require finite integer fields")
    expect(not Binding.normalize({ kind = "placedItem", itemId = infinity, x = 0, y = 0, z = 0 }),
        "placed bindings require finite integer fields")
    expect(not Binding.normalize({ kind = "vehiclePart", vehicleSqlId = infinity, partId = "TruckBed" }),
        "vehicle bindings require finite integer fields")
end

local container = {}
local wrongObject = { getModData = function() return { [Binding.OBJECT_MARKER_KEY] = "other" } end, getContainerByIndex = function() return container end }
local markedObject = { modData = {}, transmissions = 0 }
function markedObject:getModData() return self.modData end
function markedObject:transmitModData() self.transmissions = self.transmissions + 1 end
function markedObject:getContainerByIndex(index) return (index == 0 or index == 1) and container or nil end
assert(Binding.markWorldObject(markedObject, "w1"))
expect(markedObject.modData[Binding.OBJECT_MARKER_KEY] == "w1" and markedObject.transmissions == 1, "world marking is namespaced and transmitted")
expect(Binding.markWorldObject(markedObject, "w1") == "w1" and markedObject.transmissions == 1, "second container reuses the existing object marker")
local conflictingMarker, markerError = Binding.markWorldObject(markedObject, "w2")
expect(not conflictingMarker and markerError == "world_marker_conflict" and markedObject.modData[Binding.OBJECT_MARKER_KEY] == "w1", "conflicting object marker is never overwritten")
local square = { objects = { wrongObject, markedObject }, worldObjects = {} }
function square:getObjects() return self.objects end
function square:getWorldObjects() return self.worldObjects end
local cell = { square = square }
function cell:getGridSquare(x, y, z) return x == 0 and y == 0 and z == 0 and self.square or nil end
local worldBinding = { kind = "world", objectBindingId = "w1", x = 0, y = 0, z = 0, containerIndex = 1 }
expect(Binding.resolveWorld(worldBinding, { cell = cell }).container == container, "world resolution scans only marker-matching configured tile")
expect(Binding.resolveWorld({ kind = "world", objectBindingId = "w1", x = 0, y = 0, z = 0, containerIndex = 2 }, { cell = cell }).status == "missing", "world resolution validates container index")

local placedContainer = {}
local item = { getID = function() return 42 end, getInventory = function() return placedContainer end }
local worldItem = { getItem = function() return item end }
square.worldObjects = { worldItem }
local placedBinding = { kind = "placedItem", itemId = 42, x = 0, y = 0, z = 0 }
local resolvedBag = Binding.resolvePlacedItem(placedBinding, { cell = cell })
expect(resolvedBag.status == "active" and resolvedBag.container == placedContainer, "placed bag is active with its ItemContainer on anchor tile")
square.worldObjects = {}
expect(Binding.resolvePlacedItem(placedBinding, { cell = cell }).status == "missing", "absent placed bag is inactive")
square.worldObjects = { worldItem }
expect(Binding.resolvePlacedItem(placedBinding, { cell = cell }).status == "active", "returned placed bag reactivates")
square.worldObjects = { { getItem = function() return { getID = function() return 43 end } end } }
expect(Binding.resolvePlacedItem({ kind = "placedItem", itemId = 43, x = 0, y = 0, z = 0 }, { cell = cell }).reason == "placed_item_not_container", "non-container placed item is rejected")
square.worldObjects = { worldItem }

local vehicleContainer = {}
local part = { getItemContainer = function() return vehicleContainer end }
local parts = { getPartById = function(_, id) return id == "TruckBed" and part or nil end }
local vehicle = {}
function vehicle:getSqlId() return 99 end
function vehicle:getParts() return parts end
function vehicle:getPoly() return { x1 = 0, y1 = 0, x2 = 1, y2 = 0, x3 = 1, y3 = 1, x4 = 0, y4 = 1, z = 0 } end
function vehicle:isIntersectingSquare(x, y, z) return x == 0 and y == 0 and z == 0 end
local vehicleBinding = { kind = "vehiclePart", vehicleSqlId = 99, partId = "TruckBed" }
expect(Binding.resolveVehiclePart(vehicleBinding, { vehicles = { vehicle } }).status == "active", "vehicle resolves by SQL ID and part ID")
expect(Binding.resolveVehiclePart(vehicleBinding, { vehicles = {} }).status == "missing", "unloaded vehicle is inactive")
assert(Registry.addArea(root, "alpha", { x = 10, y = 0, z = 0, w = 1, h = 1 }))
local c1 = assert(Registry.addContainer(root, "alpha", { id = "world", binding = worldBinding, categoryId = "cat", categoryRules = categoryRules("cat") }, { cell = cell }))
local c2 = assert(Registry.addContainer(root, "alpha", { id = "bag", binding = placedBinding, categoryId = "cat", categoryRules = categoryRules("cat") }, { cell = cell }))
local c3 = assert(Registry.addContainer(root, "alpha", { id = "vehicle", binding = vehicleBinding, categoryId = "cat", categoryRules = categoryRules("cat") }, { vehicles = { vehicle } }))
expect(c1.id == "world" and c2.id == "bag" and c3.id == "vehicle", "eligible configurations persist by ID")
local unresolvedWorldBinding = { kind = "world", objectBindingId = "missing", x = 0, y = 0, z = 0, containerIndex = 0 }
local unresolvedWorld, unresolvedWorldError = Registry.addContainer(root, "alpha", { id = "missing-world", binding = unresolvedWorldBinding, categoryId = "cat", categoryRules = categoryRules("cat") }, { cell = {} })
expect(not unresolvedWorld and unresolvedWorldError == "square_unavailable", "unresolved fixed-world binding cannot be configured")
square.worldObjects = {}
local unresolvedBagBinding = { kind = "placedItem", itemId = 99, x = 0, y = 0, z = 0 }
local unresolvedBag, unresolvedBagError = Registry.addContainer(root, "alpha", { id = "missing-bag", binding = unresolvedBagBinding, categoryId = "cat", categoryRules = categoryRules("cat") }, { cell = cell })
expect(not unresolvedBag and unresolvedBagError == "placed_item_missing", "unresolved placed-item binding cannot be configured")
local updated, updateError = Registry.updateContainer(root, "alpha", { id = "world", binding = worldBinding, categoryId = "cat", categoryRules = categoryRules("cat"), label = "new" }, { cell = {} })
expect(not updated and updateError == "square_unavailable" and root.zones.alpha.containers.world.label == nil, "unresolved binding cannot update existing configuration")
square.worldObjects = { worldItem }
expect(Registry.resolveContainer(root, "alpha", "vehicle", { vehicles = {} }).status == "missing", "unresolved vehicle configuration is retained but inactive")
for _, invalidId in ipairs({ "", 1 }) do
    local invalidResolved = Registry.resolveContainer(root, "alpha", invalidId, { cell = cell })
    expect(invalidResolved.status == "missing" and invalidResolved.reason == "invalid_container_id", "invalid container IDs return structured missing results")
end
local nilResolved = Registry.resolveContainer(root, "alpha", nil, { cell = cell })
expect(nilResolved.status == "missing" and nilResolved.reason == "invalid_container_id", "nil container IDs return structured missing results")
assert(Registry.removeArea(root, "alpha", { x = 0, y = 0, z = 0, w = 2, h = 2 }))
expect(root.zones.alpha.containers.world ~= nil and Registry.resolveContainer(root, "alpha", "world", { cell = cell }).status == "inactive", "geometry exclusion retains configured destination inactive")
expect(Registry.resolveContainer(root, "alpha", "vehicle", { vehicles = { vehicle } }).status == "inactive", "configured vehicle is inactive outside its zone")

local permissions = assert(Registry.getPermissions(alpha, "alice"))
expect(permissions.use and permissions.edit and permissions.build and permissions.manage, "owners receive all permissions")
local useOnly = Registry.newUseOnlyPermissions()
alpha.members.bob = useOnly
expect(Registry.can(alpha, "bob", "use") and not Registry.can(alpha, "bob", "edit"), "members use independent strict permissions")
alpha.members.charlie = { edit = true, use = "true", build = 1, manage = false }
expect(not Registry.can(alpha, "charlie", "use") and Registry.can(alpha, "charlie", "edit"), "malformed permissions do not imply use")
expect(not Registry.can(alpha, "nobody", "use"), "nonmembers have no permissions")

local duplicateRoot = Schema.newRoot()
assert(Registry.create(duplicateRoot, { id = "duplicate", name = "Duplicate", ownerAccount = "alice", routingMode = "nearest", areas = { { x = 0, y = 0, z = 0, w = 2, h = 2 } } }))
assert(Registry.addContainer(duplicateRoot, "duplicate", { id = "first", binding = worldBinding, categoryId = "cat", categoryRules = categoryRules("cat") }, { cell = cell }))
duplicateRoot.zones.duplicate.containers.first.binding.unrelated = true
local duplicateConfig, duplicateError = Registry.addContainer(duplicateRoot, "duplicate", { id = "second", binding = worldBinding, categoryId = "cat", categoryRules = categoryRules("cat") }, { cell = cell })
expect(not duplicateConfig and duplicateError == "duplicate_container_binding", "normalized bindings reject duplicates despite unknown persisted fields")
local distinctIndex = assert(Registry.addContainer(duplicateRoot, "duplicate", { id = "other-index", binding = { kind = "world", objectBindingId = "w1", x = 0, y = 0, z = 0, containerIndex = 0 }, categoryId = "cat", categoryRules = categoryRules("cat") }, { cell = cell }))
expect(distinctIndex.id == "other-index", "different fixed-container indices remain distinct")
local updateCollision, updateCollisionError = Registry.updateContainer(duplicateRoot, "duplicate", { id = "other-index", binding = worldBinding, categoryId = "cat", categoryRules = categoryRules("cat") }, { cell = cell })
expect(not updateCollision and updateCollisionError == "duplicate_container_binding", "updates cannot collide with another configured binding")

print("zone_registry_spec: ok")
