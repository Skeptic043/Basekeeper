Basekeeper = Basekeeper or {}
if not Basekeeper.CategoryCatalog then
    require "Basekeeper/CategoryCatalog"
end
Basekeeper.Schema = Basekeeper.Schema or {}

local Schema = Basekeeper.Schema
local CategoryCatalog = Basekeeper.CategoryCatalog

Schema.VERSION = 2

function Schema.newRoot()
    return {
        schemaVersion = Schema.VERSION,
        personal = {},
        zones = {},
    }
end

function Schema.ensureRoot(root)
    if root == nil then
        return Schema.newRoot()
    end
    if type(root) ~= "table" then
        return Schema.newRoot()
    end
    if type(root.schemaVersion) == "number" then
        if root.schemaVersion < Schema.VERSION then
            return nil, "unsupported_schema_version"
        end
        if root.schemaVersion > Schema.VERSION then
            return nil, "future_schema_version"
        end
    end

    root.schemaVersion = Schema.VERSION
    if type(root.personal) ~= "table" then
        root.personal = {}
    end
    if type(root.zones) ~= "table" then
        root.zones = {}
    end
    return root
end

function Schema.createAccountLibrary(root, accountKey)
    if type(accountKey) ~= "string" or accountKey == "" then
        return nil, "invalid_account_key"
    end

    local repairedRoot, errorCode = Schema.ensureRoot(root)
    if not repairedRoot then
        return nil, errorCode
    end

    local library = repairedRoot.personal[accountKey]
    if type(library) ~= "table" then
        library = {
            categories = CategoryCatalog.newPresetCopies(),
        }
        repairedRoot.personal[accountKey] = library
    elseif type(library.categories) ~= "table" then
        library.categories = CategoryCatalog.newPresetCopies()
    end
    return library
end
