local function expect(condition, message)
    if not condition then error(message, 2) end
end

dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/CategoryRules.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ContainerBinding.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ContainerConfig.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ZoneGeometry.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ZoneRegistry.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/OperationContext.lua")

local Binding = Basekeeper.ContainerBinding
local Context = Basekeeper.OperationContext

local function category(id)
    return { id = id, kind = "custom", name = "Test", includedCategories = {}, whitelist = {}, blacklist = {} }
end

local function config(id, binding)
    return { id = id, categoryId = "cat", categoryRules = category("cat"), binding = binding }
end

local containerA = { getItems = function() error("context must not read destination items") end }
local containerB = { getItems = function() error("context must not read destination items") end }
local sourceContainer = { getItems = function() error("context must not read source items") end }
local resolvedById = {
    a = { status = "active", container = containerA },
    b = { status = "active", container = containerB },
    missing = { status = "missing", reason = "container_missing" },
}
local resolves = 0
local vehicleResolves = 0
local originalResolve = Binding.resolve
Binding.resolve = function(binding)
    if binding.kind == "vehiclePart" then
        vehicleResolves = vehicleResolves + 1
        return resolvedById.vehicle
    end
    resolves = resolves + 1
    return resolvedById[binding.objectBindingId]
end

local root = {
    schemaVersion = 2,
    personal = {},
    zones = {
        alpha = {
            id = "alpha", ownerAccount = "alice", routingMode = "nearest", revision = 4,
            areas = { { x = 0, y = 0, z = 0, w = 4, h = 4 } },
            members = { bob = { use = true } },
            containers = {
                b = config("b", { kind = "world", objectBindingId = "b", x = 1, y = 1, z = 0, containerIndex = 0 }),
                a = config("a", { kind = "world", objectBindingId = "a", x = 0, y = 0, z = 0, containerIndex = 0 }),
                missing = config("missing", { kind = "world", objectBindingId = "missing", x = 2, y = 2, z = 0, containerIndex = 0 }),
                broken = { id = "broken", categoryId = "cat", binding = { kind = "world", objectBindingId = "a", x = 0, y = 0, z = 0, containerIndex = 0 } },
            },
        },
    },
}

local function request(source)
    return { root = root, accountKey = "bob", playerAnchor = { x = 1, y = 1, z = 0 }, source = source }
end

local context = assert(Context.build(request({ kind = "carried", container = containerB }), {}))
expect(context.zoneId == "alpha" and context.zoneRevision == 4 and context.routingMode == "nearest", "context exposes active-zone metadata")
expect(#context.destinations == 2 and context.destinations[1].config.id == "a" and context.destinations[2].config.id == "b",
    "active destinations use deterministic config ID order")
expect(#context.unavailable == 2 and context.unavailable[1].containerId == "broken" and context.unavailable[2].containerId == "missing",
    "corrupt and missing configurations report ordered diagnostics")
expect(context.selectedContainerId == "b" and context.selectedBindingKind == "world", "selected configured container matches by identity")
expect(resolves == 3, "each valid configured binding resolves exactly once")
context.destinations[1].config.binding.x = 99
context.destinations[1].category.whitelist["Base.Nails"] = true
context.destinations[1].anchor.x = 99
expect(root.zones.alpha.containers.a.binding.x == 0 and not root.zones.alpha.containers.a.categoryRules.whitelist["Base.Nails"],
    "context copies persisted configuration and category output")

resolves = 0
local unconfigured = assert(Context.build(request({ kind = "carried", container = sourceContainer }), {}))
expect(unconfigured.selectedContainerId == nil and resolves == 3, "unconfigured selected containers remain explicit and content is never read")
expect(Context.build(request({ kind = "tile", container = sourceContainer, anchor = { x = 1, y = 1, z = 0 } }), {}), "tile sources require and accept same-zone anchors")
local outsideTile, outsideTileError = Context.build(request({ kind = "tile", container = sourceContainer, anchor = { x = 9, y = 9, z = 0 } }), {})
expect(not outsideTile and outsideTileError == "source_outside_zone", "tile sources outside the active zone reject")
expect(Context.build(request({ kind = "floor", container = sourceContainer }), {}), "floor sources qualify from player anchor")

local sourceVehicle = {}
function sourceVehicle:getPoly() return { x1 = 0, y1 = 0, x2 = 1, y2 = 0, x3 = 1, y3 = 1, x4 = 0, y4 = 1, z = 0 } end
function sourceVehicle:isIntersectingSquare(x, y, z) return x == 0 and y == 0 and z == 0 end
expect(Context.build(request({ kind = "vehicle", container = sourceContainer, vehicle = sourceVehicle }), {}), "vehicle sources require same-zone intersection")

local destinationVehicle = {}
function destinationVehicle:getPoly() return { x1 = 0, y1 = 0, x2 = 1, y2 = 0, x3 = 1, y3 = 1, x4 = 0, y4 = 1, z = 0 } end
function destinationVehicle:isIntersectingSquare(x, y, z) return x == 0 and y == 0 and z == 0 end
function destinationVehicle:getX() return 0.5 end
function destinationVehicle:getY() return 1.5 end
function destinationVehicle:getZ() return 0 end
local vehicleContainer = {}
resolvedById.vehicle = { status = "active", container = vehicleContainer, vehicle = destinationVehicle }
local vehicleRoot = {
    schemaVersion = 2, personal = {}, zones = {
        vehicles = {
            id = "vehicles", ownerAccount = "bob", routingMode = "balance", revision = 1,
            areas = { { x = 0, y = 0, z = 0, w = 4, h = 4 } }, members = {},
            containers = { vehicle = config("vehicle", { kind = "vehiclePart", vehicleSqlId = 1, partId = "TruckBed" }) },
        },
    },
}
vehicleResolves = 0
local vehicleContext = assert(Context.build({ root = vehicleRoot, accountKey = "bob", playerAnchor = { x = 1, y = 1, z = 0 }, source = { kind = "carried", container = sourceContainer } }, {}))
expect(vehicleResolves == 1 and vehicleContext.destinations[1].container == vehicleContainer
    and vehicleContext.destinations[1].anchor.x == 0.5 and vehicleContext.destinations[1].anchor.y == 1.5
    and vehicleContext.destinations[1].anchor.z == 0, "active vehicle destinations expose a live finite anchor after one resolution")

local function invalidMetadataZone(values)
    values = values or {}
    return {
        id = values.id == nil and "alpha" or values.id, ownerAccount = "alice",
        routingMode = values.routingMode or "nearest", revision = values.revision == nil and 1 or values.revision,
        areas = values.areas == nil and { { x = 0, y = 0, z = 0, w = 2, h = 2 } } or values.areas,
        members = { bob = { use = true } },
        containers = values.containers == nil and {} or values.containers,
    }
end
for _, invalidZone in ipairs({
    invalidMetadataZone({ id = "wrong" }),
    invalidMetadataZone({ revision = 0 }),
    invalidMetadataZone({ routingMode = "invalid" }),
    invalidMetadataZone({ containers = "invalid" }),
    invalidMetadataZone({ areas = "invalid" }),
    invalidMetadataZone({ areas = { { x = 0, y = 0, z = 0, w = math.huge, h = 2 } } }),
}) do
    local invalidMetadata, invalidMetadataError = Context.build({
        root = { schemaVersion = 2, personal = {}, zones = { alpha = invalidZone } }, accountKey = "bob",
        playerAnchor = { x = 1, y = 1, z = 0 }, source = { kind = "carried", container = sourceContainer },
    }, {})
    expect(not invalidMetadata and invalidMetadataError == "invalid_zone_metadata", "active zones reject corrupt metadata")
end

local unreachableCorruptZone, unreachableCorruptError = Context.build({
    root = {
        schemaVersion = 2, personal = {}, zones = {
            alpha = invalidMetadataZone(),
            broken = invalidMetadataZone({ id = "broken", areas = "invalid" }),
        },
    },
    accountKey = "bob", playerAnchor = { x = 1, y = 1, z = 0 }, source = { kind = "carried", container = sourceContainer },
}, {})
expect(not unreachableCorruptZone and unreachableCorruptError == "invalid_zone_metadata",
    "all operation-context zones validate metadata before geometry access")

local unauthorized, unauthorizedError = Context.build({ root = root, accountKey = "eve", playerAnchor = { x = 1, y = 1, z = 0 }, source = { kind = "carried", container = sourceContainer } }, {})
expect(not unauthorized and unauthorizedError == "outside_usable_zone", "unauthorized players have no active zone")
local overlapping = {
    schemaVersion = 2, personal = {}, zones = {
        alpha = root.zones.alpha,
        two = { id = "two", ownerAccount = "bob", routingMode = "balance", revision = 1, areas = { { x = 0, y = 0, z = 0, w = 2, h = 2 } }, members = {}, containers = {} },
    },
}
local ambiguousZone, ambiguousZoneError = Context.build({ root = overlapping, accountKey = "bob", playerAnchor = { x = 1, y = 1, z = 0 }, source = { kind = "carried", container = sourceContainer } }, {})
expect(not ambiguousZone and ambiguousZoneError == "ambiguous_active_zone", "overlapping usable zones never choose arbitrarily")

resolvedById.a = { status = "active", container = containerB }
local ambiguousContainer, ambiguousContainerError = Context.build(request({ kind = "carried", container = containerB }), {})
expect(not ambiguousContainer and ambiguousContainerError == "ambiguous_selected_container", "duplicate selected live containers reject")
Binding.resolve = originalResolve

print("operation_context_spec: ok")
