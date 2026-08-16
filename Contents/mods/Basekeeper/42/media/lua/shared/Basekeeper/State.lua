Basekeeper = Basekeeper or {}
if not Basekeeper.Schema then
    require "Basekeeper/Schema"
end
Basekeeper.State = Basekeeper.State or {}

local State = Basekeeper.State
local Schema = Basekeeper.Schema

State.ROOT_KEY = "Basekeeper"

local function isAuthority()
    return not (type(isClient) == "function" and isClient())
end

local function getOrCreateRoot()
    return ModData.getOrCreate(State.ROOT_KEY)
end

local function transmitRoot()
    if type(isServer) == "function" and isServer() then
        ModData.transmit(State.ROOT_KEY)
    end
end

function State.getRoot()
    return getOrCreateRoot()
end

function State.ensureRoot()
    local root = getOrCreateRoot()
    if not isAuthority() then
        return root
    end

    local repairedRoot, errorCode = Schema.ensureRoot(root)
    if not repairedRoot then
        return nil, errorCode
    end
    return repairedRoot
end

function State.createAccountLibrary(accountKey)
    if not isAuthority() then
        return nil, "read_only_client"
    end
    local root, errorCode = State.ensureRoot()
    if not root then
        return nil, errorCode
    end
    local libraryNeedsCreation = false
    if type(accountKey) == "string" and accountKey ~= "" then
        local existingLibrary = root.personal[accountKey]
        libraryNeedsCreation = type(existingLibrary) ~= "table"
            or type(existingLibrary.categories) ~= "table"
    end
    local library, libraryError = Schema.createAccountLibrary(root, accountKey)
    if library and libraryNeedsCreation then
        transmitRoot()
    end
    return library, libraryError
end

function State.initialize()
    local root = State.ensureRoot()
    if root then
        transmitRoot()
    end
end

if Events and Events.OnInitGlobalModData then
    Events.OnInitGlobalModData.Add(State.initialize)
end
