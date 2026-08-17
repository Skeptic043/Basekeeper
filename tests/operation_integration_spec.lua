local function expect(condition, message)
    if not condition then error(message, 2) end
end

dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/CategoryRules.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ContainerBinding.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ContainerConfig.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ZoneGeometry.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ZoneRegistry.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/OperationContext.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/ItemSnapshot.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/RoutingPlanner.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/shared/Basekeeper/StorageJobPlanner.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/client/Basekeeper/PlayerSourceBuilder.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/client/Basekeeper/OperationSource.lua")

local executorStarts = 0
Basekeeper.StorageJobExecutor = {
    start = function()
        executorStarts = executorStarts + 1
        error("no-work must not reach the executor")
    end,
}
Basekeeper.Settings = {
    getIncludeKeyRingKeysInUnloadAll = function() return false end,
    getHaulingMode = function() return "safe" end,
    getRestoreHeldItems = function() return true end,
}
dofile("Contents/mods/Basekeeper/42/media/lua/client/Basekeeper/OperationLauncher.lua")

local function emptyContainer()
    return {
        getItems = function() return {} end,
        getCapacityWeight = function() return 0 end,
        getEffectiveCapacity = function() return 20 end,
    }
end

local main = emptyContainer()
local destination = emptyContainer()
local worldObject = {
    getModData = function() return { ["Basekeeper.containerBindingId"] = "destination" } end,
    getContainerByIndex = function(_, index) return index == 0 and destination or nil end,
}
local square = { getObjects = function() return { worldObject } end }
local runtime = {
    getRoot = function()
        return {
            schemaVersion = 2, personal = {}, zones = {
                home = {
                    id = "home", ownerAccount = "local:0", routingMode = "nearest", revision = 1,
                    areas = { { x = 0, y = 0, z = 0, w = 3, h = 3 } }, members = {},
                    containers = {
                        destination = {
                            id = "destination", categoryId = "general",
                            categoryRules = { id = "general", kind = "custom", name = "General", includedCategories = {}, whitelist = {}, blacklist = {} },
                            binding = { kind = "world", objectBindingId = "destination", x = 1, y = 1, z = 0, containerIndex = 0 },
                        },
                    },
                },
            },
        }
    end,
    isClient = function() return false end,
    cell = { getGridSquare = function(_, x, y, z) return x == 1 and y == 1 and z == 0 and square or nil end },
}
local character = {
    getX = function() return 1 end, getY = function() return 1 end, getZ = function() return 0 end,
    getInventory = function() return main end,
}
local Launcher = Basekeeper.OperationLauncher
for _, command in ipairs({ "unload", "unloadAll" }) do
    local result = assert(Launcher.start({
        command = command, character = character, playerNum = 0, selectedContainer = main, side = "player",
    }, runtime))
    expect(result.status == "no_work" and #result.job.moves == 0,
        command .. " reaches no-work through real source/context/planner composition")
end
expect(executorStarts == 0, "no-work never enters the executor or timed-action queue boundary")

print("operation_integration_spec: ok")
