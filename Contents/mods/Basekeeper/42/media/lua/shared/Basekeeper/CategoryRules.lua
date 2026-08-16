Basekeeper = Basekeeper or {}
Basekeeper.CategoryRules = Basekeeper.CategoryRules or {}

local CategoryRules = Basekeeper.CategoryRules

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function copySet(source)
    if source == nil then
        return {}
    end
    if type(source) ~= "table" then
        return nil, "invalid_set"
    end

    local copy = {}
    for key, value in pairs(source) do
        local entry = nil
        if type(key) == "number" and nonEmptyString(value) then
            entry = value
        elseif nonEmptyString(key) and value then
            entry = key
        elseif value then
            return nil, "invalid_set_entry"
        end
        if entry then
            copy[entry] = true
        end
    end
    return copy
end

function CategoryRules.getDisplayCategory(item)
    if not item then
        return nil
    end

    local displayCategory = nil
    if type(item.getDisplayCategory) == "function" then
        displayCategory = item:getDisplayCategory()
    end
    if nonEmptyString(displayCategory) then
        return displayCategory
    end
    if type(item.getCategory) == "function" then
        local baseCategory = item:getCategory()
        if nonEmptyString(baseCategory) then
            return baseCategory
        end
    end
    return nil
end

function CategoryRules.classify(item)
    local fullType = nil
    if item and type(item.getFullType) == "function" then
        fullType = item:getFullType()
    end
    if not nonEmptyString(fullType) then
        fullType = nil
    end

    return {
        fullType = fullType,
        displayCategory = CategoryRules.getDisplayCategory(item),
    }
end

function CategoryRules.normalize(definition)
    if type(definition) ~= "table" then
        return nil, "invalid_definition"
    end
    if not nonEmptyString(definition.id) then
        return nil, "invalid_id"
    end
    if definition.kind ~= "preset" and definition.kind ~= "custom" then
        return nil, "invalid_kind"
    end

    local normalized = {
        id = definition.id,
        kind = definition.kind,
    }
    if definition.kind == "preset" then
        if not nonEmptyString(definition.labelKey) then
            return nil, "invalid_label_key"
        end
        normalized.labelKey = definition.labelKey
    else
        if not nonEmptyString(definition.name) then
            return nil, "invalid_name"
        end
        normalized.name = definition.name
    end

    local includedCategories, categoryError = copySet(definition.includedCategories)
    if not includedCategories then
        return nil, categoryError
    end
    local whitelist, whitelistError = copySet(definition.whitelist)
    if not whitelist then
        return nil, whitelistError
    end
    local blacklist, blacklistError = copySet(definition.blacklist)
    if not blacklist then
        return nil, blacklistError
    end

    for fullType in pairs(blacklist) do
        whitelist[fullType] = nil
    end

    normalized.includedCategories = includedCategories
    normalized.whitelist = whitelist
    normalized.blacklist = blacklist
    return normalized
end

function CategoryRules.matches(definition, classificationOrItem)
    if type(definition) ~= "table" then
        return false
    end
    local classification = classificationOrItem
    if type(classificationOrItem) ~= "table"
        or classificationOrItem.fullType == nil and classificationOrItem.displayCategory == nil then
        classification = CategoryRules.classify(classificationOrItem)
    end

    local fullType = classification.fullType
    local displayCategory = classification.displayCategory
    if fullType and definition.blacklist and definition.blacklist[fullType] then
        return false
    end
    if fullType and definition.whitelist and definition.whitelist[fullType] then
        return true
    end
    if displayCategory and definition.includedCategories and definition.includedCategories[displayCategory] then
        return true
    end
    return false
end

local function validFullType(fullType)
    return nonEmptyString(fullType)
end

function CategoryRules.addWhitelist(definition, fullType)
    if type(definition) ~= "table" or not validFullType(fullType) then
        return false
    end
    definition.whitelist = definition.whitelist or {}
    definition.blacklist = definition.blacklist or {}
    definition.blacklist[fullType] = nil
    definition.whitelist[fullType] = true
    return true
end

function CategoryRules.removeWhitelist(definition, fullType)
    if type(definition) ~= "table" or not validFullType(fullType) then
        return false
    end
    if definition.whitelist then
        definition.whitelist[fullType] = nil
    end
    return true
end

function CategoryRules.addBlacklist(definition, fullType)
    if type(definition) ~= "table" or not validFullType(fullType) then
        return false
    end
    definition.whitelist = definition.whitelist or {}
    definition.blacklist = definition.blacklist or {}
    definition.whitelist[fullType] = nil
    definition.blacklist[fullType] = true
    return true
end

function CategoryRules.removeBlacklist(definition, fullType)
    if type(definition) ~= "table" or not validFullType(fullType) then
        return false
    end
    if definition.blacklist then
        definition.blacklist[fullType] = nil
    end
    return true
end
