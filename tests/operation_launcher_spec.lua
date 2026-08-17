local function expect(condition, message)
    if not condition then error(message, 2) end
end

dofile("Contents/mods/Basekeeper/42/media/lua/client/Basekeeper/OperationSource.lua")
local Source = Basekeeper.OperationSource

local function square(x, y, z)
    return { getX = function() return x end, getY = function() return y end, getZ = function() return z end }
end
local playerAnchor = { x = 1, y = 2, z = 0 }
local playerContainer = {}
expect(Source.describe(playerContainer, "player", playerAnchor).kind == "carried", "player containers are carried sources")
local floor = { getType = function() return "floor" end }
expect(Source.describe(floor, "loot", playerAnchor).kind == "floor", "synthetic floor is a Floor source")
local vehicle = {
    getX = function() return 8.5 end, getY = function() return 9.5 end, getZ = function() return 0 end,
}
local directVehicle = { getVehiclePart = function() return { getVehicle = function() return vehicle end } end }
local vehicleSource = assert(Source.describe(directVehicle, "loot", playerAnchor))
expect(vehicleSource.kind == "vehicle" and vehicleSource.vehicle == vehicle and vehicleSource.anchor.x == 8.5,
    "direct vehicle compartments retain their live vehicle and anchor")
local nested = {
    getVehiclePart = function() return nil end,
    getOutermostContainer = function() return directVehicle end,
}
local nestedSource = assert(Source.describe(nested, "loot", playerAnchor))
expect(nestedSource.kind == "vehicle" and nestedSource.vehicle == vehicle and nestedSource.container == nested,
    "nested vehicle bags use their outer vehicle without becoming the direct compartment")
local placed = {
    getContainingItem = function() return { getWorldItem = function() return { getSquare = function() return square(5, 6, 0) end } end } end,
}
local placedSource = assert(Source.describe(placed, "loot", playerAnchor))
expect(placedSource.anchor.x == 5 and placedSource.anchor.y == 6, "placed items use their world item square")
expect(not Source.describe({}, "loot", playerAnchor), "unavailable loot identity rejects explicitly")

local calls = { builds = {}, starts = 0, all = 0, selected = 0 }
Basekeeper.OperationContext = {
    build = function(request)
        calls.context = request
        return {
            zoneId = "zone", zoneRevision = 7, routingMode = "nearest", destinations = { { config = { id = "dest" }, category = {}, container = {}, anchor = { x = 0, y = 0, z = 0 } } },
            selectedContainerId = calls.selectedId, selectedBindingKind = calls.selectedKind, unavailable = {},
        }
    end,
}
Basekeeper.PlayerSourceBuilder = {
    buildAll = function(character, anchor, include)
        calls.all = calls.all + 1; calls.include = include
        return { { key = "main", container = character:getInventory(), anchor = anchor, items = {} } }
    end,
    buildSelected = function(character, container, anchor)
        calls.selected = calls.selected + 1
        return { { key = "selected", container = container, anchor = anchor, items = {} } }
    end,
}
Basekeeper.StorageJobPlanner = {
    build = function(request)
        calls.builds[#calls.builds + 1] = request
        if calls.plannerError then return nil, calls.plannerError end
        return { moves = calls.moves or {} }
    end,
}
Basekeeper.StorageJobExecutor = {
    start = function(job, character, options)
        calls.starts = calls.starts + 1; calls.options = options
        if calls.executorError then return nil, calls.executorError end
        return { job = job }
    end,
}
Basekeeper.Settings = {
    getIncludeKeyRingKeysInUnloadAll = function() return true end,
    getHaulingMode = function() return "yolo" end,
    getRestoreHeldItems = function() return false end,
}
Basekeeper.ItemSnapshot = { directItems = function(container) return container.items or {} end }
Basekeeper.ZoneGeometry = { containsZone = function(_, x) return x >= 0 end }
dofile("Contents/mods/Basekeeper/42/media/lua/client/Basekeeper/OperationLauncher.lua")
local Launcher = Basekeeper.OperationLauncher

local main = { items = {} }
local character = {
    getX = function() return 1.9 end, getY = function() return 2.1 end, getZ = function() return 0 end,
    getInventory = function() return main end, getUsername = function() return "Alice" end,
}
local root = { schemaVersion = 2, personal = {}, zones = { zone = {} } }
local function request(command, side, selected)
    return { command = command, character = character, playerNum = 2, selectedContainer = selected or main, side = side or "player" }
end
local runtime = { getRoot = function() return root end, isClient = function() return false end }

calls.moves = {}
local noWork = assert(Launcher.start(request("unload"), runtime))
expect(noWork.status == "no_work" and calls.starts == 0 and calls.context.playerAnchor.x == 1 and calls.context.playerAnchor.y == 2,
    "standalone identity and integer player anchors build no-work without queue mutation")
expect(calls.context.accountKey == "local:2" and calls.selected == 1 and calls.builds[#calls.builds].kind == "unload",
    "selected player unload uses the player builder")

calls.moves = { { itemKey = "x" } }
local started = assert(Launcher.start(request("unloadAll"), runtime))
expect(started.status == "started" and calls.all == 1 and calls.include == true and calls.options.carryMode == "yolo"
    and calls.options.restoreHeldItems == false, "Unload All forwards current options and executor settings")

runtime.isClient = function() return true end
calls.moves = {}
assert(Launcher.start(request("unload"), runtime))
expect(calls.context.accountKey == "user:Alice", "multiplayer uses raw username presentation identity")
runtime.isClient = function() return false end

local loot = { getSourceGrid = function() return square(1, 1, 0) end, items = {} }
calls.selectedId, calls.selectedKind, calls.moves = nil, nil, {}
assert(Launcher.start(request("unload", "loot", loot), runtime))
expect(calls.builds[#calls.builds].sources[1].key == "source", "unconfigured loot unload uses one direct source")

calls.moves = {}
assert(Launcher.start(request("unload", "loot", directVehicle), runtime))
expect(calls.builds[#calls.builds].sources[1].anchor.x == 8.5 and calls.builds[#calls.builds].sources[1].anchor.y == 9.5,
    "unconfigured direct vehicle unload uses the vehicle anchor")
assert(Launcher.start(request("unload", "loot", nested), runtime))
expect(calls.builds[#calls.builds].sources[1].container == nested and calls.builds[#calls.builds].sources[1].anchor.x == 8.5,
    "unconfigured nested vehicle unload uses the outer vehicle anchor")

local floorItemIn = { getWorldItem = function() return { getSquare = function() return square(1, 0, 0) end } end }
local floorItemOut = { getWorldItem = function() return { getSquare = function() return square(-1, 0, 0) end } end }
floor.items = { floorItemIn, floorItemOut }
floor.getType = function() return "floor" end
calls.moves = {}
assert(Launcher.start(request("unload", "loot", floor), runtime))
local floorPlan = calls.builds[#calls.builds]
expect(#floorPlan.sources[1].items == 1 and floorPlan.sources[1].items[1] == floorItemIn,
    "Floor unload filters the displayed direct items at the zone edge")

calls.selectedId, calls.selectedKind, calls.moves = "vehicle", "vehiclePart", {}
assert(Launcher.start(request("unload", "loot", directVehicle), runtime))
expect(calls.builds[#calls.builds].kind == "organizeContainer", "configured vehicle Unload uses organizeContainer")
calls.selectedId, calls.selectedKind = "ordinary", "world"
local ordinary, ordinaryError = Launcher.start(request("unload", "loot", loot), runtime)
expect(not ordinary and ordinaryError == "configured_source_requires_organize", "configured ordinary sources reject Unload")
assert(Launcher.start(request("organize", "loot", loot), runtime))
expect(calls.builds[#calls.builds].kind == "organizeContainer", "Organize uses the selected configured nonvehicle")
assert(Launcher.start(request("organizeAll", "loot", loot), runtime))
expect(calls.builds[#calls.builds].kind == "organizeZone", "Organize All uses zone planning")
calls.selectedId, calls.selectedKind = nil, nil
local noOrganize, noOrganizeError = Launcher.start(request("organize", "loot", loot), runtime)
expect(not noOrganize and noOrganizeError == "organize_requires_configured_nonvehicle_source", "Organize requires configured storage")
local allLoot, allLootError = Launcher.start(request("unloadAll", "loot", loot), runtime)
expect(not allLoot and allLootError == "unload_all_requires_player_source", "Unload All is player-side only")

calls.plannerError = "planner_failed"
local failed, failedError = Launcher.start(request("unload"), runtime)
expect(not failed and failedError == "planner_failed", "planner failures return unchanged")
calls.plannerError, calls.moves, calls.executorError = nil, { { itemKey = "x" } }, "executor_failed"
local executionFailed, executionError = Launcher.start(request("unload"), runtime)
expect(not executionFailed and executionError == "executor_failed", "executor failures return unchanged")

print("operation_launcher_spec: ok")
