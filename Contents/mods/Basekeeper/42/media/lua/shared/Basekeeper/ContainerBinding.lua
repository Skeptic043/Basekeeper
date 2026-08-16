Basekeeper = Basekeeper or {}
Basekeeper.ContainerBinding = Basekeeper.ContainerBinding or {}

local ContainerBinding = Basekeeper.ContainerBinding

ContainerBinding.OBJECT_MARKER_KEY = "Basekeeper.containerBindingId"

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function isInteger(value)
    return type(value) == "number" and value == math.floor(value)
end

local function resolveCell(runtime)
    if type(runtime) == "table" and runtime.cell then
        return runtime.cell
    end
    if type(_G.getCell) == "function" then
        return _G.getCell()
    end
    return nil
end

local function getSquare(binding, runtime)
    local cell = resolveCell(runtime)
    if cell and type(cell.getGridSquare) == "function" then
        return cell:getGridSquare(binding.x, binding.y, binding.z)
    end
    return nil
end

local function eachValue(list, callback)
    if list and type(list.size) == "function" and type(list.get) == "function" then
        for index = 0, list:size() - 1 do
            if callback(list:get(index)) then
                return true
            end
        end
    elseif type(list) == "table" then
        for _, value in ipairs(list) do
            if callback(value) then
                return true
            end
        end
    end
    return false
end

function ContainerBinding.normalize(binding)
    if type(binding) ~= "table" then
        return nil, "invalid_binding"
    end
    if binding.kind == "world" then
        if not nonEmptyString(binding.objectBindingId)
            or not isInteger(binding.x) or not isInteger(binding.y) or not isInteger(binding.z)
            or not isInteger(binding.containerIndex) or binding.containerIndex < 0 then
            return nil, "invalid_world_binding"
        end
        return {
            kind = "world", objectBindingId = binding.objectBindingId,
            x = binding.x, y = binding.y, z = binding.z, containerIndex = binding.containerIndex,
        }
    end
    if binding.kind == "placedItem" then
        if not isInteger(binding.itemId)
            or not isInteger(binding.x) or not isInteger(binding.y) or not isInteger(binding.z) then
            return nil, "invalid_placed_item_binding"
        end
        return { kind = "placedItem", itemId = binding.itemId, x = binding.x, y = binding.y, z = binding.z }
    end
    if binding.kind == "vehiclePart" then
        if not isInteger(binding.vehicleSqlId) or binding.vehicleSqlId <= 0 or not nonEmptyString(binding.partId) then
            return nil, "invalid_vehicle_part_binding"
        end
        return { kind = "vehiclePart", vehicleSqlId = binding.vehicleSqlId, partId = binding.partId }
    end
    return nil, "invalid_binding_kind"
end

function ContainerBinding.markWorldObject(object, objectBindingId)
    if not object or type(object.getModData) ~= "function" or not nonEmptyString(objectBindingId) then
        return nil, "invalid_world_object"
    end
    local modData = object:getModData()
    if type(modData) ~= "table" then
        return nil, "invalid_world_mod_data"
    end
    local existingMarker = modData[ContainerBinding.OBJECT_MARKER_KEY]
    if existingMarker ~= nil then
        if not nonEmptyString(existingMarker) then
            return nil, "invalid_existing_world_marker"
        end
        if existingMarker ~= objectBindingId then
            return nil, "world_marker_conflict"
        end
        return existingMarker
    end
    modData[ContainerBinding.OBJECT_MARKER_KEY] = objectBindingId
    if type(object.transmitModData) == "function" then
        object:transmitModData()
    end
    return objectBindingId
end

function ContainerBinding.resolveWorld(binding, runtime)
    local normalized, errorCode = ContainerBinding.normalize(binding)
    if not normalized or normalized.kind ~= "world" then
        return { status = "missing", reason = errorCode or "invalid_world_binding" }
    end
    local square = getSquare(normalized, runtime)
    if not square or type(square.getObjects) ~= "function" then
        return { status = "missing", reason = "square_unavailable" }
    end
    local matchedObject = nil
    eachValue(square:getObjects(), function(object)
        local modData = object and type(object.getModData) == "function" and object:getModData() or nil
        if type(modData) == "table" and modData[ContainerBinding.OBJECT_MARKER_KEY] == normalized.objectBindingId then
            matchedObject = object
            return true
        end
    end)
    if not matchedObject then
        return { status = "missing", reason = "world_object_missing" }
    end
    local container = type(matchedObject.getContainerByIndex) == "function"
        and matchedObject:getContainerByIndex(normalized.containerIndex) or nil
    if not container then
        return { status = "missing", reason = "container_missing", object = matchedObject }
    end
    return { status = "active", object = matchedObject, container = container }
end

function ContainerBinding.resolvePlacedItem(binding, runtime)
    local normalized, errorCode = ContainerBinding.normalize(binding)
    if not normalized or normalized.kind ~= "placedItem" then
        return { status = "missing", reason = errorCode or "invalid_placed_item_binding" }
    end
    local square = getSquare(normalized, runtime)
    if not square or type(square.getWorldObjects) ~= "function" then
        return { status = "missing", reason = "square_unavailable" }
    end
    local found = nil
    eachValue(square:getWorldObjects(), function(worldObject)
        local item = worldObject and type(worldObject.getItem) == "function" and worldObject:getItem() or nil
        if item and type(item.getID) == "function" and item:getID() == normalized.itemId then
            local container = type(item.getInventory) == "function" and item:getInventory() or nil
            if not container then
                found = { status = "missing", reason = "placed_item_not_container", worldObject = worldObject, item = item }
            else
                found = { status = "active", worldObject = worldObject, item = item, container = container }
            end
            return true
        end
    end)
    return found or { status = "missing", reason = "placed_item_missing" }
end

function ContainerBinding.resolveVehiclePart(binding, runtime)
    local normalized, errorCode = ContainerBinding.normalize(binding)
    if not normalized or normalized.kind ~= "vehiclePart" then
        return { status = "missing", reason = errorCode or "invalid_vehicle_part_binding" }
    end
    local vehicles = type(runtime) == "table" and runtime.vehicles or nil
    if not vehicles then
        local cell = resolveCell(runtime)
        vehicles = cell and type(cell.getVehicles) == "function" and cell:getVehicles() or nil
    end
    local vehicle = nil
    eachValue(vehicles, function(candidate)
        if candidate and type(candidate.getSqlId) == "function"
            and candidate:getSqlId() == normalized.vehicleSqlId then
            vehicle = candidate
            return true
        end
    end)
    if not vehicle then
        return { status = "missing", reason = "vehicle_missing" }
    end
    local parts = type(vehicle.getParts) == "function" and vehicle:getParts() or nil
    local part = parts and type(parts.getPartById) == "function" and parts:getPartById(normalized.partId) or nil
    local container = part and type(part.getItemContainer) == "function" and part:getItemContainer() or nil
    if not part or not container then
        return { status = "missing", reason = "vehicle_part_missing", vehicle = vehicle }
    end
    return { status = "active", vehicle = vehicle, part = part, container = container }
end

function ContainerBinding.resolve(binding, runtime)
    if type(binding) ~= "table" then
        return { status = "missing", reason = "invalid_binding" }
    end
    if binding.kind == "world" then
        return ContainerBinding.resolveWorld(binding, runtime)
    elseif binding.kind == "placedItem" then
        return ContainerBinding.resolvePlacedItem(binding, runtime)
    elseif binding.kind == "vehiclePart" then
        return ContainerBinding.resolveVehiclePart(binding, runtime)
    end
    return { status = "missing", reason = "invalid_binding_kind" }
end
