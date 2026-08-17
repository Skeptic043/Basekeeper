local function expect(condition, message)
    if not condition then
        error(message, 2)
    end
end

dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/CategoryRules.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/CategoryCatalog.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ContainerBinding.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ContainerConfig.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/Schema.lua")

local mockedRoot = { schemaVersion = 2, personal = {}, zones = {} }
local transmittedRoots = {}
local clientMode = true
local serverMode = false
local initHooks = {}
ModData = {
    getOrCreate = function(key)
        expect(key == "Basekeeper", "state should use the Basekeeper root key")
        return mockedRoot
    end,
    transmit = function(key)
        expect(key == "Basekeeper", "state should only transmit the Basekeeper root")
        table.insert(transmittedRoots, mockedRoot)
    end,
}
isClient = function() return clientMode end
isServer = function() return serverMode end
Events = {
    OnInitGlobalModData = {
        Add = function(callback)
            table.insert(initHooks, callback)
        end,
    },
}
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/State.lua")

local Rules = Basekeeper.CategoryRules
local Catalog = Basekeeper.CategoryCatalog
local Config = Basekeeper.ContainerConfig
local Schema = Basekeeper.Schema
local State = Basekeeper.State

local preferredCategoryItem = {
    getFullType = function() return "Base.Test" end,
    getDisplayCategory = function() return "Food" end,
    getCategory = function() return "Fallback" end,
}
expect(Rules.classify(preferredCategoryItem).displayCategory == "Food", "display category should win")

local fallbackCategoryItem = {
    getFullType = function() return "Base.Fallback" end,
    getDisplayCategory = function() return nil end,
    getCategory = function() return "Fallback" end,
}
expect(Rules.classify(fallbackCategoryItem).displayCategory == "Fallback", "base category should be fallback")

local dualInput = {
    id = "basekeeper:custom:test",
    kind = "custom",
    name = "Test",
    includedCategories = { Food = true },
    whitelist = { ["Base.Test"] = true },
    blacklist = { ["Base.Test"] = true },
}
local normalized = assert(Rules.normalize(dualInput))
expect(normalized.blacklist["Base.Test"], "blacklist should retain dual-list type")
expect(not normalized.whitelist["Base.Test"], "dual-list type should leave whitelist")
expect(not Rules.matches(normalized, preferredCategoryItem), "blacklist should beat category inclusion")

Rules.addWhitelist(normalized, "Base.Whitelisted")
expect(Rules.matches(normalized, { fullType = "Base.Whitelisted", displayCategory = "Other" }), "whitelist should beat category non-membership")

dualInput.includedCategories.Food = nil
dualInput.whitelist["Base.Other"] = true
dualInput.blacklist["Base.Test"] = nil
expect(normalized.includedCategories.Food, "normalized categories must not share caller table")
expect(not normalized.whitelist["Base.Other"], "normalized whitelist must not share caller table")
expect(normalized.blacklist["Base.Test"], "normalized blacklist must not share caller table")

local expectedPresetIds = {
    "basekeeper:preset:food",
    "basekeeper:preset:medical",
    "basekeeper:preset:tools",
    "basekeeper:preset:weapons",
    "basekeeper:preset:ammunition",
    "basekeeper:preset:clothing",
    "basekeeper:preset:literature",
    "basekeeper:preset:mechanics",
    "basekeeper:preset:crafting_materials",
}
local root = Schema.newRoot()
local alice = assert(Schema.createAccountLibrary(root, "alice"))
local bob = assert(Schema.createAccountLibrary(root, "bob"))
for _, id in ipairs(expectedPresetIds) do
    expect(alice.categories[id] ~= nil, "missing stable preset " .. id)
    expect(alice.categories[id] ~= bob.categories[id], "account preset copies must be independent")
end
alice.categories["basekeeper:preset:food"].includedCategories.Food = nil
expect(bob.categories["basekeeper:preset:food"].includedCategories.Food, "account mutations must not leak")
expect(#Catalog.getPresetIds() == #expectedPresetIds, "catalog should expose all preset IDs")

local retained = { value = true }
local partialRoot = { retained = retained, personal = "bad" }
local repaired = assert(Schema.ensureRoot(partialRoot))
expect(repaired.schemaVersion == 2, "partial root should repair to schema version 2")
expect(repaired.personal ~= nil and repaired.zones ~= nil, "partial root should receive required tables")
expect(repaired.retained == retained, "migration should retain Basekeeper-owned unknown keys")

local oldRoot, oldError = Schema.ensureRoot({ schemaVersion = 1, personal = {}, zones = {} })
expect(oldRoot == nil and oldError == "unsupported_schema_version", "explicit old schema must fail")
local futureRoot, futureError = Schema.ensureRoot({ schemaVersion = 3, personal = {}, zones = {} })
expect(futureRoot == nil, "future schema must fail")
expect(futureError == "future_schema_version", "future schema error must be explicit")
for _, version in ipairs({ "two", false, 2.5, math.huge, -math.huge, 0 / 0 }) do
    local malformed = { schemaVersion = version, personal = {}, zones = {} }
    local malformedRoot, malformedError = Schema.ensureRoot(malformed)
    local versionPreserved = version ~= version and malformed.schemaVersion ~= malformed.schemaVersion or malformed.schemaVersion == version
    expect(not malformedRoot and malformedError == "invalid_schema_version" and versionPreserved,
        "explicit malformed schema versions must not be repaired")
end

local categoryInput = {
    id = "basekeeper:custom:tools", kind = "custom", name = "Tools",
    includedCategories = { Tools = true }, whitelist = {}, blacklist = {},
}
local configInput = {
    id = "tools", categoryId = "basekeeper:custom:tools", categoryRules = categoryInput,
    binding = { kind = "placedItem", itemId = 1, x = 0, y = 0, z = 0 },
    stockTargets = { ["Base.Nails"] = 4 },
}
local config = assert(Config.normalize(configInput))
expect(config.categoryRules ~= categoryInput and config.categoryRules.whitelist["Base.Nails"],
    "configured categories are copied and stock targets are exact whitelist entries")
configInput.categoryRules.includedCategories.Tools = nil
configInput.stockTargets["Base.Screws"] = 1
expect(config.categoryRules.includedCategories.Tools and not config.categoryRules.whitelist["Base.Screws"],
    "configured category snapshots do not share caller tables")
local mismatched = { id = "wrong", kind = "custom", name = "Wrong", includedCategories = {}, whitelist = {}, blacklist = {} }
local mismatchConfig, mismatchError = Config.normalize({
    id = "bad", categoryId = "basekeeper:custom:tools", categoryRules = mismatched,
    binding = configInput.binding,
})
expect(not mismatchConfig and mismatchError == "category_id_mismatch", "category IDs must match their snapshots")
local blacklisted = { id = "basekeeper:custom:tools", kind = "custom", name = "Tools", includedCategories = {}, whitelist = {}, blacklist = { ["Base.Nails"] = true } }
local blacklistConfig, blacklistError = Config.normalize({
    id = "bad", categoryId = "basekeeper:custom:tools", categoryRules = blacklisted,
    binding = configInput.binding, stockTargets = { ["Base.Nails"] = 1 },
})
expect(not blacklistConfig and blacklistError == "stock_target_blacklisted", "stock targets cannot override blacklists")

local clientLibrary, clientError = State.createAccountLibrary("client")
expect(clientLibrary == nil and clientError == "read_only_client", "MP clients must be read-only")
expect(mockedRoot.personal.client == nil, "MP client must not mutate the root")
expect(#transmittedRoots == 0, "MP client must not transmit the root")
expect(#initHooks == 1, "state should register one initialization hook")

clientMode = false
serverMode = true
local serverLibrary = assert(State.createAccountLibrary("server"))
expect(serverLibrary == mockedRoot.personal.server, "server should create the account library in the root")
expect(#transmittedRoots == 1, "server account creation should transmit once")
expect(transmittedRoots[1].personal.server.categories["basekeeper:preset:food"] ~= nil,
    "server should transmit the post-mutation root")
assert(State.createAccountLibrary("server"))
expect(#transmittedRoots == 1, "existing server library should not transmit again")

print("category_schema_spec: ok")
