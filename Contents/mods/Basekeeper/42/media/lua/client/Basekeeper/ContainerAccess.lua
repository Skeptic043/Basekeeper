Basekeeper = Basekeeper or {}
Basekeeper.ContainerAccess = Basekeeper.ContainerAccess or {}

local ContainerAccess = Basekeeper.ContainerAccess

local function runtimeCall(runtime, name, ...)
    if runtime and type(runtime[name]) == "function" then return runtime[name](...) end
end

local function invoke(value, name, ...)
    if value and type(value[name]) == "function" then return value[name](value, ...) end
end

local function isFloor(container, runtime)
    local adapted = runtimeCall(runtime, "isLocalFloor", container)
    if adapted ~= nil then return adapted == true end
    return invoke(container, "getType") == "floor"
end

local function closeEnough(character, parent, runtime)
    local adapted = runtimeCall(runtime, "distToProper", character, parent)
    if adapted ~= nil then return type(adapted) == "number" and adapted < 2 end
    local characterSquare = runtimeCall(runtime, "getCurrentSquare", character) or invoke(character, "getCurrentSquare")
    local parentSquare = runtimeCall(runtime, "getSquare", parent) or invoke(parent, "getSquare")
    if not characterSquare or not parentSquare then return false end
    local distance = invoke(parentSquare, "DistToProper", characterSquare)
    return type(distance) == "number" and distance < 2
end

local function pathFixed(character, parent, runtime)
    local adapted = runtimeCall(runtime, "pathAdjacentToMultiTileObject", character, parent, true)
    if adapted ~= nil then return adapted end
    if ISPathFindAction and type(ISPathFindAction.pathAdjacentToMultiTileObject) == "function" then
        return ISPathFindAction:pathAdjacentToMultiTileObject(character, parent, true)
    end
end

local function pathPlaced(character, square, runtime)
    local adapted = runtimeCall(runtime, "pathAdjacentToSquares", character, { square }, true)
    if adapted ~= nil then return adapted end
    if ISPathFindAction and type(ISPathFindAction.pathAdjacentToSquares) == "function" then
        return ISPathFindAction:pathAdjacentToSquares(character, { square }, true)
    end
end

local function prepareVehicle(part, character, runtime)
    local vehicle = runtimeCall(runtime, "getVehicle", part) or invoke(part, "getVehicle")
    local area = runtimeCall(runtime, "getVehiclePartArea", part) or invoke(part, "getArea")
    local index = runtimeCall(runtime, "getVehiclePartIndex", part) or invoke(part, "getIndex")
    if not vehicle or not area or index == nil then return nil, "inaccessible_vehicle" end
    local current = runtimeCall(runtime, "getCharacterVehicle", character) or invoke(character, "getVehicle")
    if current and current ~= vehicle then return nil, "inaccessible_vehicle" end
    local function accessible()
        local adapted = runtimeCall(runtime, "canAccessVehiclePart", vehicle, index, character)
        if adapted ~= nil then return adapted == true end
        return invoke(vehicle, "canAccessContainer", index, character) == true
    end
    if accessible() then return { ready = true } end
    local action = runtimeCall(runtime, "pathToVehicleArea", character, vehicle, area)
    if action == nil and ISPathFindAction and type(ISPathFindAction.pathToVehicleArea) == "function" then
        action = ISPathFindAction:pathToVehicleArea(character, vehicle, area)
    end
    if not action then return nil, "inaccessible_vehicle" end
    return { action = action, recheck = accessible }
end

function ContainerAccess.prepare(container, character, runtime)
    if not container or not character then return nil, "invalid_access_request" end
    local carried = runtimeCall(runtime, "isInCharacterInventory", container, character)
    if carried == nil then carried = invoke(container, "isInCharacterInventory", character) end
    if carried == true or isFloor(container, runtime) then return { ready = true } end

    local part = runtimeCall(runtime, "getVehiclePart", container) or invoke(container, "getVehiclePart")
    if part then return prepareVehicle(part, character, runtime) end

    local item = runtimeCall(runtime, "getContainingItem", container) or invoke(container, "getContainingItem")
    if item then
        local object = runtimeCall(runtime, "getItemWorldObject", item) or invoke(item, "getWorldItem")
        local square = runtimeCall(runtime, "getSquare", object or item) or invoke(object or item, "getSquare")
        if not square then return nil, "inaccessible_placed_item" end
        if closeEnough(character, object or item, runtime) then return { ready = true } end
        local action = pathPlaced(character, square, runtime)
        if not action then return nil, "inaccessible_placed_item" end
        return { action = action, recheck = function() return closeEnough(character, object or item, runtime) end }
    end

    local parent = runtimeCall(runtime, "getContainerParent", container) or invoke(container, "getParent")
    if not parent or not (runtimeCall(runtime, "getSquare", parent) or invoke(parent, "getSquare")) then
        return nil, "inaccessible_parent"
    end
    if closeEnough(character, parent, runtime) then return { ready = true } end
    local action = pathFixed(character, parent, runtime)
    if not action then return nil, "inaccessible_parent" end
    return { action = action, recheck = function() return closeEnough(character, parent, runtime) end }
end

return ContainerAccess
