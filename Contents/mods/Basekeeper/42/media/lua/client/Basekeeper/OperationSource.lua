Basekeeper = Basekeeper or {}
Basekeeper.OperationSource = Basekeeper.OperationSource or {}

local OperationSource = Basekeeper.OperationSource

local function finiteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function copyAnchor(anchor)
    if type(anchor) ~= "table" or not finiteNumber(anchor.x) or not finiteNumber(anchor.y) or not finiteNumber(anchor.z) then
        return nil
    end
    return { x = anchor.x, y = anchor.y, z = anchor.z }
end

local function isObject(value)
    local valueType = type(value)
    return valueType == "table" or valueType == "userdata"
end

local function squareAnchor(square)
    if not square or type(square.getX) ~= "function" or type(square.getY) ~= "function" or type(square.getZ) ~= "function" then
        return nil
    end
    return copyAnchor({ x = square:getX(), y = square:getY(), z = square:getZ() })
end

local function vehicleAnchor(vehicle)
    if not vehicle or type(vehicle.getX) ~= "function" or type(vehicle.getY) ~= "function" or type(vehicle.getZ) ~= "function" then
        return nil
    end
    return copyAnchor({ x = vehicle:getX(), y = vehicle:getY(), z = vehicle:getZ() })
end

local function floorContainer(container, runtime)
    if runtime and type(runtime.isFloorContainer) == "function" then
        return runtime.isFloorContainer(container) == true
    end
    return type(container.getType) == "function" and container:getType() == "floor"
end

local function sourceSquare(container)
    if type(container.getSourceGrid) == "function" then
        local grid = container:getSourceGrid()
        if grid then return grid end
    end
    if type(container.getParent) == "function" then
        local parent = container:getParent()
        if parent and type(parent.getSquare) == "function" then
            return parent:getSquare()
        end
        return parent
    end
    return nil
end

function OperationSource.describe(selectedContainer, side, playerAnchor, runtime)
    local anchor = copyAnchor(playerAnchor)
    if not anchor then return nil, "invalid_player_anchor" end
    if not isObject(selectedContainer) then return nil, "invalid_selected_container" end
    if side == "player" then
        return { kind = "carried", container = selectedContainer }
    end
    if side ~= "loot" then return nil, "invalid_side" end

    if floorContainer(selectedContainer, runtime) then
        return { kind = "floor", container = selectedContainer }
    end

    if type(selectedContainer.getVehiclePart) == "function" then
        local part = selectedContainer:getVehiclePart()
        if part then
            if type(part.getVehicle) ~= "function" then return nil, "invalid_source_vehicle" end
            local vehicle = part:getVehicle()
            if not vehicle then return nil, "invalid_source_vehicle" end
            local vehicleTile = vehicleAnchor(vehicle)
            if not vehicleTile then return nil, "invalid_source_vehicle_anchor" end
            return { kind = "vehicle", container = selectedContainer, vehicle = vehicle, anchor = vehicleTile }
        end
    end

    if type(selectedContainer.getOutermostContainer) == "function" then
        local outermost = selectedContainer:getOutermostContainer()
        if outermost and type(outermost.getVehiclePart) == "function" then
            local part = outermost:getVehiclePart()
            if part then
                if type(part.getVehicle) ~= "function" then return nil, "invalid_source_vehicle" end
                local vehicle = part:getVehicle()
                if not vehicle then return nil, "invalid_source_vehicle" end
                local vehicleTile = vehicleAnchor(vehicle)
                if not vehicleTile then return nil, "invalid_source_vehicle_anchor" end
                return { kind = "vehicle", container = selectedContainer, vehicle = vehicle, anchor = vehicleTile }
            end
        end
    end

    local containingItem = type(selectedContainer.getContainingItem) == "function" and selectedContainer:getContainingItem() or nil
    if containingItem and type(containingItem.getWorldItem) == "function" then
        local worldItem = containingItem:getWorldItem()
        if worldItem then
            local placedAnchor = squareAnchor(type(worldItem.getSquare) == "function" and worldItem:getSquare() or nil)
            if not placedAnchor then return nil, "source_square_unavailable" end
            return { kind = "tile", container = selectedContainer, anchor = placedAnchor }
        end
    end

    local tileAnchor = squareAnchor(sourceSquare(selectedContainer))
    if not tileAnchor then return nil, "source_square_unavailable" end
    return { kind = "tile", container = selectedContainer, anchor = tileAnchor }
end

return OperationSource
