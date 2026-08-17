Basekeeper = Basekeeper or {}
if not Basekeeper.ContainerBinding then
    require "Basekeeper/ContainerBinding"
end
if not Basekeeper.CategoryRules then
    require "Basekeeper/CategoryRules"
end
Basekeeper.ContainerConfig = Basekeeper.ContainerConfig or {}

local ContainerConfig = Basekeeper.ContainerConfig
local ContainerBinding = Basekeeper.ContainerBinding
local CategoryRules = Basekeeper.CategoryRules

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function isInteger(value)
    return type(value) == "number" and value == math.floor(value)
end

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
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

local function copyRange(source)
    if type(source) ~= "table" then
        return nil, "invalid_advanced_filter_range"
    end
    for key in pairs(source) do
        if key ~= "min" and key ~= "max" then
            return nil, "invalid_advanced_filter_range"
        end
    end
    if not isFiniteNumber(source.min) or not isFiniteNumber(source.max)
        or source.min < 0 or source.max > 100 or source.min > source.max then
        return nil, "invalid_advanced_filter_range"
    end
    return { min = source.min, max = source.max }
end

local function copyAdvancedFilters(source)
    if source == nil then
        return {}
    end
    if type(source) ~= "table" then
        return nil, "invalid_advanced_filters"
    end
    local filters = {}
    for key, range in pairs(source) do
        if key ~= "condition" and key ~= "remaining" then
            return nil, "invalid_advanced_filters"
        end
        local copiedRange, rangeError = copyRange(range)
        if not copiedRange then
            return nil, rangeError
        end
        filters[key] = copiedRange
    end
    return filters
end

function ContainerConfig.normalize(config)
    if type(config) ~= "table" or not nonEmptyString(config.id) or not nonEmptyString(config.categoryId) then
        return nil, "invalid_container_config"
    end
    local categoryRules, categoryError = CategoryRules.normalize(config.categoryRules)
    if not categoryRules then
        return nil, categoryError
    end
    if categoryRules.id ~= config.categoryId then
        return nil, "category_id_mismatch"
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
    for fullType in pairs(stockTargets) do
        if categoryRules.blacklist[fullType] then
            return nil, "stock_target_blacklisted"
        end
        categoryRules.whitelist[fullType] = true
    end
    local advancedFilters, filtersError = copyAdvancedFilters(config.advancedFilters)
    if not advancedFilters then
        return nil, filtersError
    end
    return {
        id = config.id, binding = binding, categoryId = config.categoryId, categoryRules = categoryRules, priority = priority,
        label = config.label, icon = config.icon, locked = config.locked == true, stockTargets = stockTargets,
        advancedFilters = advancedFilters,
    }
end
