Basekeeper = Basekeeper or {}
if not Basekeeper.ContainerBinding then
    require "Basekeeper/ContainerBinding"
end
Basekeeper.ContainerConfig = Basekeeper.ContainerConfig or {}

local ContainerConfig = Basekeeper.ContainerConfig
local ContainerBinding = Basekeeper.ContainerBinding

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function isInteger(value)
    return type(value) == "number" and value == math.floor(value)
end

local function validFullType(value)
    return type(value) == "string" and value:match("^[^%s%.]+%.[^%s%.]+$") ~= nil
end

local function copyStockTargets(source)
    if source == nil then
        return {}
    end
    if type(source) ~= "table" then
        return nil, "invalid_stock_targets"
    end
    local targets = {}
    for fullType, quantity in pairs(source) do
        if not validFullType(fullType) or not isInteger(quantity) or quantity <= 0 then
            return nil, "invalid_stock_target"
        end
        targets[fullType] = quantity
    end
    return targets
end

function ContainerConfig.normalize(config)
    if type(config) ~= "table" or not nonEmptyString(config.id) or not nonEmptyString(config.categoryId) then
        return nil, "invalid_container_config"
    end
    local binding, bindingError = ContainerBinding.normalize(config.binding)
    if not binding then
        return nil, bindingError
    end
    local priority = config.priority == nil and 5 or config.priority
    if not isInteger(priority) or priority < 0 or priority > 10 then
        return nil, "invalid_priority"
    end
    if config.label ~= nil and type(config.label) ~= "string" then
        return nil, "invalid_label"
    end
    if config.icon ~= nil and type(config.icon) ~= "string" then
        return nil, "invalid_icon"
    end
    if config.locked ~= nil and type(config.locked) ~= "boolean" then
        return nil, "invalid_locked"
    end
    local stockTargets, stockError = copyStockTargets(config.stockTargets)
    if not stockTargets then
        return nil, stockError
    end
    return {
        id = config.id, binding = binding, categoryId = config.categoryId, priority = priority,
        label = config.label, icon = config.icon, locked = config.locked == true, stockTargets = stockTargets,
    }
end
