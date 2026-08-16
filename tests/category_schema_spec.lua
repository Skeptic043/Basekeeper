local function expect(condition, message)
    if not condition then
        error(message, 2)
    end
end

dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/CategoryRules.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/CategoryCatalog.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/Schema.lua")

local mockedRoot = { schemaVersion = 1, personal = {}, zones = {} }
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
expect(repaired.schemaVersion == 1, "partial root should migrate to schema version 1")
expect(repaired.personal ~= nil and repaired.zones ~= nil, "partial root should receive required tables")
expect(repaired.retained == retained, "migration should retain Basekeeper-owned unknown keys")

local futureRoot, futureError = Schema.ensureRoot({ schemaVersion = 2, personal = {}, zones = {} })
expect(futureRoot == nil, "future schema must fail")
expect(futureError == "future_schema_version", "future schema error must be explicit")

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
