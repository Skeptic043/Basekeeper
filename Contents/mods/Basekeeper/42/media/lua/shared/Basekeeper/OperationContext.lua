Basekeeper = Basekeeper or {}
if not Basekeeper.ContainerConfig then
    require "Basekeeper/ContainerConfig"
end
if not Basekeeper.ContainerBinding then
    require "Basekeeper/ContainerBinding"
end
if not Basekeeper.CategoryRules then
    require "Basekeeper/CategoryRules"
end
if not Basekeeper.ZoneGeometry then
    require "Basekeeper/ZoneGeometry"
end
if not Basekeeper.ZoneRegistry then
    require "Basekeeper/ZoneRegistry"
end
Basekeeper.OperationContext = Basekeeper.OperationContext or {}

local OperationContext = Basekeeper.OperationContext
local ContainerConfig = Basekeeper.ContainerConfig
local ContainerBinding = Basekeeper.ContainerBinding
local CategoryRules = Basekeeper.CategoryRules
local ZoneGeometry = Basekeeper.ZoneGeometry
local ZoneRegistry = Basekeeper.ZoneRegistry

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function finiteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function copyAnchor(anchor)
    if type(anchor) ~= "table" or not finiteNumber(anchor.x) or not finiteNumber(anchor.y) or not finiteNumber(anchor.z) then
        return nil
    end
    return { x = anchor.x, y = anchor.y, z = anchor.z }
end

local function sortedKeys(values)
    local keys = {}
    if type(values) == "table" then
        for key in pairs(values) do
            if type(key) == "string" then
                keys[#keys + 1] = key
            end
        end
    end
    table.sort(keys)
    return keys
end

local function validRoot(root)
    return type(root) == "table" and root.schemaVersion == 2
        and type(root.personal) == "table" and type(root.zones) == "table"
end

local function positiveInteger(value)
    return finiteNumber(value) and value == math.floor(value) and value > 0
end

local function validZoneMetadata(zone, zoneId)
    return type(zone) == "table" and nonEmptyString(zone.id) and zone.id == zoneId
        and positiveInteger(zone.revision)
        and (zone.routingMode == "consolidate" or zone.routingMode == "balance" or zone.routingMode == "nearest")
        and type(zone.containers) == "table"
end

local function findActiveZone(root, accountKey, playerAnchor)
    local found = nil
    for _, zoneId in ipairs(sortedKeys(root.zones)) do
        local zone = root.zones[zoneId]
        if ZoneGeometry.containsZone(zone, playerAnchor.x, playerAnchor.y, playerAnchor.z)
            and ZoneRegistry.can(zone, accountKey, "use") then
            if not validZoneMetadata(zone, zoneId) then
                return nil, "invalid_zone_metadata"
            end
            if found then
                return nil, "ambiguous_active_zone"
            end
            found = { id = zoneId, zone = zone }
        end
    end
    if not found then
        return nil, "outside_usable_zone"
    end
    return found.zone, nil, found.id
end

local function sourceIsInZone(source, playerAnchor, zone)
    if type(source) ~= "table" or source.container == nil then
        return nil, "invalid_source"
    end
    if source.kind == "carried" or source.kind == "floor" then
        return true
    end
    if source.kind == "tile" then
        local anchor = copyAnchor(source.anchor)
        if not anchor then
            return nil, "invalid_source_anchor"
        end
        if not ZoneGeometry.containsZone(zone, anchor.x, anchor.y, anchor.z) then
            return nil, "source_outside_zone"
        end
        return true
    end
    if source.kind == "vehicle" then
        if not source.vehicle then
            return nil, "invalid_source_vehicle"
        end
        local intersects, errorCode = ZoneGeometry.vehicleIntersectsZone(source.vehicle, zone)
        if not intersects then
            return nil, errorCode or "source_outside_zone"
        end
        return true
    end
    return nil, "invalid_source_kind"
end

local function destinationAnchor(config, resolved)
    if config.binding.kind == "world" or config.binding.kind == "placedItem" then
        return copyAnchor(config.binding)
    end
    local vehicle = resolved.vehicle
    if not vehicle or type(vehicle.getX) ~= "function" or type(vehicle.getY) ~= "function"
        or type(vehicle.getZ) ~= "function" then
        return nil
    end
    return copyAnchor({ x = vehicle:getX(), y = vehicle:getY(), z = vehicle:getZ() })
end

function OperationContext.build(request, runtime)
    if type(request) ~= "table" or not validRoot(request.root) then
        return nil, "invalid_root"
    end
    if not nonEmptyString(request.accountKey) then
        return nil, "invalid_account_key"
    end
    local playerAnchor = copyAnchor(request.playerAnchor)
    if not playerAnchor then
        return nil, "invalid_player_anchor"
    end

    local zone, zoneError, zoneId = findActiveZone(request.root, request.accountKey, playerAnchor)
    if not zone then
        return nil, zoneError
    end
    local sourceOk, sourceError = sourceIsInZone(request.source, playerAnchor, zone)
    if not sourceOk then
        return nil, sourceError
    end

    local destinations = {}
    local unavailable = {}
    local selectedId = nil
    local selectedKind = nil
    for _, containerId in ipairs(sortedKeys(zone.containers)) do
        local config, configError = ContainerConfig.normalize(zone.containers[containerId])
        if not config then
            unavailable[#unavailable + 1] = { containerId = containerId, reason = configError }
        else
            local resolved = ContainerBinding.resolve(config.binding, runtime)
            if resolved.status ~= "active" then
                unavailable[#unavailable + 1] = { containerId = containerId, reason = resolved.reason or "container_missing" }
            else
                local eligible, eligibilityError = ZoneRegistry.bindingIsEligibleResolved(zone, config.binding, resolved)
                if not eligible then
                    unavailable[#unavailable + 1] = { containerId = containerId, reason = eligibilityError }
                else
                    local anchor = destinationAnchor(config, resolved)
                    if not anchor then
                        unavailable[#unavailable + 1] = { containerId = containerId, reason = "vehicle_anchor_unavailable" }
                    else
                        local category = CategoryRules.normalize(config.categoryRules)
                        destinations[#destinations + 1] = {
                            config = config,
                            category = category,
                            container = resolved.container,
                            anchor = anchor,
                        }
                        if resolved.container == request.source.container then
                            if selectedId then
                                return nil, "ambiguous_selected_container"
                            end
                            selectedId = containerId
                            selectedKind = config.binding.kind
                        end
                    end
                end
            end
        end
    end
    return {
        zoneId = zoneId,
        zoneRevision = zone.revision,
        routingMode = zone.routingMode,
        destinations = destinations,
        selectedContainerId = selectedId,
        selectedBindingKind = selectedKind,
        unavailable = unavailable,
    }
end
