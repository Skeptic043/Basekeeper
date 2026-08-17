Basekeeper = Basekeeper or {}
if not Basekeeper.ZoneGeometry then
    require "Basekeeper/ZoneGeometry"
end
if not Basekeeper.ContainerConfig then
    require "Basekeeper/ContainerConfig"
end
if not Basekeeper.ContainerBinding then
    require "Basekeeper/ContainerBinding"
end
Basekeeper.ZoneRegistry = Basekeeper.ZoneRegistry or {}

local ZoneRegistry = Basekeeper.ZoneRegistry
local ZoneGeometry = Basekeeper.ZoneGeometry
local ContainerConfig = Basekeeper.ContainerConfig
local ContainerBinding = Basekeeper.ContainerBinding

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function equalValue(a, b)
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= "table" then
        return a == b
    end
    for key, value in pairs(a) do
        if not equalValue(value, b[key]) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

local function validRoot(root)
    return type(root) == "table" and type(root.zones) == "table"
end

local function validRoutingMode(value)
    return value == "consolidate" or value == "balance" or value == "nearest"
end

local function normalizeAreas(areas)
    if type(areas) ~= "table" or #areas == 0 then
        return nil, "invalid_areas"
    end
    local normalized = {}
    for _, area in ipairs(areas) do
        local rect, errorCode = ZoneGeometry.normalizeRect(area)
        if not rect then
            return nil, errorCode
        end
        normalized[#normalized + 1] = rect
    end
    return normalized
end

local function rectIndex(areas, rect)
    for index, existing in ipairs(areas) do
        if equalValue(existing, rect) then
            return index
        end
    end
    return nil
end

local function increment(zone)
    zone.revision = zone.revision + 1
end

local function allPermissions(value)
    return { use = value, edit = value, build = value, manage = value }
end

function ZoneRegistry.newUseOnlyPermissions()
    return { use = true, edit = false, build = false, manage = false }
end

function ZoneRegistry.getPermissions(zone, accountKey)
    if type(zone) ~= "table" then
        return nil, "invalid_zone"
    end
    if not nonEmptyString(accountKey) then
        return nil, "invalid_account_key"
    end
    if zone.ownerAccount == accountKey then
        return allPermissions(true)
    end
    local member = type(zone.members) == "table" and zone.members[accountKey] or nil
    if type(member) ~= "table" then
        return allPermissions(false)
    end
    return {
        use = member.use == true,
        edit = member.edit == true,
        build = member.build == true,
        manage = member.manage == true,
    }
end

function ZoneRegistry.can(zone, accountKey, permissionName)
    if permissionName ~= "use" and permissionName ~= "edit"
        and permissionName ~= "build" and permissionName ~= "manage" then
        return false
    end
    local permissions = ZoneRegistry.getPermissions(zone, accountKey)
    return permissions ~= nil and permissions[permissionName] == true
end

function ZoneRegistry.get(root, zoneId)
    if not validRoot(root) or not nonEmptyString(zoneId) then
        return nil, "invalid_zone_id"
    end
    local zone = root.zones[zoneId]
    if type(zone) ~= "table" then
        return nil, "zone_not_found"
    end
    return zone
end

function ZoneRegistry.create(root, definition)
    if not validRoot(root) then
        return nil, "invalid_root"
    end
    if type(definition) ~= "table" or not nonEmptyString(definition.id) or not nonEmptyString(definition.name)
        or not nonEmptyString(definition.ownerAccount) or not validRoutingMode(definition.routingMode) then
        return nil, "invalid_zone"
    end
    if root.zones[definition.id] ~= nil then
        return nil, "zone_exists"
    end
    local areas, areaError = normalizeAreas(definition.areas)
    if not areas then
        return nil, areaError
    end
    for _, area in ipairs(areas) do
        local connected = ZoneGeometry.findConnectedZoneIds(root.zones, area)
        if #connected > 0 then
            return nil, "area_connects_zones", connected
        end
    end
    local zone = {
        id = definition.id, name = definition.name, ownerAccount = definition.ownerAccount,
        routingMode = definition.routingMode, revision = 1, areas = areas, members = {}, containers = {},
    }
    root.zones[zone.id] = zone
    return zone
end

function ZoneRegistry.remove(root, zoneId)
    local zone, errorCode = ZoneRegistry.get(root, zoneId)
    if not zone then
        return nil, errorCode
    end
    root.zones[zoneId] = nil
    return zone
end

function ZoneRegistry.findAreaConnections(root, zoneId, area)
    if not validRoot(root) then
        return nil, "invalid_root"
    end
    return ZoneGeometry.findConnectedZoneIds(root.zones, area, zoneId)
end

function ZoneRegistry.addArea(root, zoneId, area)
    local zone, zoneError = ZoneRegistry.get(root, zoneId)
    if not zone then
        return nil, zoneError
    end
    local rect, rectError = ZoneGeometry.normalizeRect(area)
    if not rect then
        return nil, rectError
    end
    local connected = ZoneGeometry.findConnectedZoneIds(root.zones, rect, zoneId)
    if #connected > 0 then
        return nil, "area_connects_zones", connected
    end
    if rectIndex(zone.areas, rect) then
        return zone
    end
    zone.areas[#zone.areas + 1] = rect
    increment(zone)
    return zone
end

function ZoneRegistry.removeArea(root, zoneId, area)
    local zone, zoneError = ZoneRegistry.get(root, zoneId)
    if not zone then
        return nil, zoneError
    end
    local rect, rectError = ZoneGeometry.normalizeRect(area)
    if not rect then
        return nil, rectError
    end
    local index = rectIndex(zone.areas, rect)
    if not index then
        return nil, "area_not_found"
    end
    if #zone.areas == 1 then
        return nil, "last_area"
    end
    table.remove(zone.areas, index)
    increment(zone)
    return zone
end

function ZoneRegistry.bindingIsEligibleResolved(zone, binding, resolved)
    if type(resolved) ~= "table" then
        return false, "invalid_resolved_binding"
    end
    if resolved.status ~= "active" then
        return false, resolved.reason
    end
    if binding.kind == "world" or binding.kind == "placedItem" then
        if ZoneGeometry.containsZone(zone, binding.x, binding.y, binding.z) then
            return true
        end
        return false, "binding_outside_zone"
    end
    if binding.kind == "vehiclePart" then
        local intersects, geometryError = ZoneGeometry.vehicleIntersectsZone(resolved.vehicle, zone)
        if intersects then
            return true
        end
        return false, geometryError or "binding_outside_zone"
    end
    return false, "invalid_binding_kind"
end

function ZoneRegistry.bindingIsEligible(zone, binding, runtime)
    local resolved = ContainerBinding.resolve(binding, runtime)
    return ZoneRegistry.bindingIsEligibleResolved(zone, binding, resolved)
end

local function hasBindingCollision(zone, config, ignoredId)
    for id, existing in pairs(zone.containers) do
        local existingBinding = type(existing) == "table" and ContainerBinding.normalize(existing.binding) or nil
        if id ~= ignoredId and existingBinding and equalValue(existingBinding, config.binding) then
            return true
        end
    end
    return false
end

function ZoneRegistry.addContainer(root, zoneId, definition, runtime)
    local zone, zoneError = ZoneRegistry.get(root, zoneId)
    if not zone then
        return nil, zoneError
    end
    local config, configError = ContainerConfig.normalize(definition)
    if not config then
        return nil, configError
    end
    if zone.containers[config.id] ~= nil then
        return nil, "container_exists"
    end
    if hasBindingCollision(zone, config) then
        return nil, "duplicate_container_binding"
    end
    local eligible, eligibilityError = ZoneRegistry.bindingIsEligible(zone, config.binding, runtime)
    if not eligible then
        return nil, eligibilityError
    end
    zone.containers[config.id] = config
    increment(zone)
    return config
end

function ZoneRegistry.updateContainer(root, zoneId, definition, runtime)
    local zone, zoneError = ZoneRegistry.get(root, zoneId)
    if not zone then
        return nil, zoneError
    end
    local config, configError = ContainerConfig.normalize(definition)
    if not config then
        return nil, configError
    end
    if type(zone.containers[config.id]) ~= "table" then
        return nil, "container_not_found"
    end
    if hasBindingCollision(zone, config, config.id) then
        return nil, "duplicate_container_binding"
    end
    local eligible, eligibilityError = ZoneRegistry.bindingIsEligible(zone, config.binding, runtime)
    if not eligible then
        return nil, eligibilityError
    end
    if equalValue(zone.containers[config.id], config) then
        return zone.containers[config.id]
    end
    zone.containers[config.id] = config
    increment(zone)
    return config
end

function ZoneRegistry.removeContainer(root, zoneId, containerId)
    local zone, zoneError = ZoneRegistry.get(root, zoneId)
    if not zone then
        return nil, zoneError
    end
    if not nonEmptyString(containerId) or type(zone.containers[containerId]) ~= "table" then
        return nil, "container_not_found"
    end
    local config = zone.containers[containerId]
    zone.containers[containerId] = nil
    increment(zone)
    return config
end

function ZoneRegistry.resolveContainer(root, zoneId, containerId, runtime)
    local zone, zoneError = ZoneRegistry.get(root, zoneId)
    if not zone then
        return { status = "missing", reason = zoneError }
    end
    local config = zone.containers[containerId]
    if type(config) ~= "table" then
        return { status = "missing", reason = "container_not_found" }
    end
    local resolved = ContainerBinding.resolve(config.binding, runtime)
    if resolved.status ~= "active" then
        return resolved
    end
    local eligible, eligibilityError = ZoneRegistry.bindingIsEligibleResolved(zone, config.binding, resolved)
    if not eligible then
        return { status = "inactive", reason = eligibilityError }
    end
    return resolved
end
