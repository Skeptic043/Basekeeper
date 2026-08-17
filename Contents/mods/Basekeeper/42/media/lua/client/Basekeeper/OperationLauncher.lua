Basekeeper = Basekeeper or {}
if not Basekeeper.OperationSource then require "Basekeeper/OperationSource" end
if not Basekeeper.OperationContext then require "Basekeeper/OperationContext" end
if not Basekeeper.PlayerSourceBuilder then require "Basekeeper/PlayerSourceBuilder" end
if not Basekeeper.StorageJobPlanner then require "Basekeeper/StorageJobPlanner" end
if not Basekeeper.StorageJobExecutor then require "Basekeeper/StorageJobExecutor" end
if not Basekeeper.Settings then require "Basekeeper/Settings" end
if not Basekeeper.ItemSnapshot then require "Basekeeper/ItemSnapshot" end
if not Basekeeper.ZoneGeometry then require "Basekeeper/ZoneGeometry" end
Basekeeper.OperationLauncher = Basekeeper.OperationLauncher or {}

local OperationLauncher = Basekeeper.OperationLauncher
local OperationSource = Basekeeper.OperationSource
local OperationContext = Basekeeper.OperationContext
local PlayerSourceBuilder = Basekeeper.PlayerSourceBuilder
local StorageJobPlanner = Basekeeper.StorageJobPlanner
local StorageJobExecutor = Basekeeper.StorageJobExecutor
local Settings = Basekeeper.Settings
local ItemSnapshot = Basekeeper.ItemSnapshot
local ZoneGeometry = Basekeeper.ZoneGeometry

local function finiteInteger(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value == math.floor(value)
end

local function playerAnchor(character)
    if not character or type(character.getX) ~= "function" or type(character.getY) ~= "function" or type(character.getZ) ~= "function" then
        return nil
    end
    local x, y, z = character:getX(), character:getY(), character:getZ()
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" or x ~= x or y ~= y or z ~= z
        or x == math.huge or y == math.huge or z == math.huge or x == -math.huge or y == -math.huge or z == -math.huge then
        return nil
    end
    return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
end

local function runtimeValue(runtime, name)
    if runtime and runtime[name] ~= nil then return runtime[name] end
    return _G[name]
end

local function currentRoot(runtime)
    if runtime and type(runtime.getRoot) == "function" then return runtime.getRoot() end
    local modData = runtimeValue(runtime, "ModData")
    if modData and type(modData.get) == "function" then return modData.get("Basekeeper") end
    return nil, "root_unavailable"
end

local function accountKey(character, playerNum, runtime)
    local client = runtimeValue(runtime, "isClient")
    if type(client) == "function" and client() then
        if type(character.getUsername) ~= "function" then return nil, "invalid_username" end
        local username = character:getUsername()
        if type(username) ~= "string" or username == "" then return nil, "invalid_username" end
        return "user:" .. username
    end
    return "local:" .. tostring(playerNum)
end

local function floorItems(source, root, zoneId)
    local zone = type(root) == "table" and type(root.zones) == "table" and root.zones[zoneId] or nil
    if not zone then return nil, "active_zone_unavailable" end
    local directItems, itemsError = ItemSnapshot.directItems(source.container)
    if not directItems then return nil, itemsError end
    local selected = {}
    for _, item in ipairs(directItems) do
        local worldItem = type(item.getWorldItem) == "function" and item:getWorldItem() or nil
        local square = worldItem and type(worldItem.getSquare) == "function" and worldItem:getSquare() or nil
        if square and type(square.getX) == "function" and type(square.getY) == "function" and type(square.getZ) == "function"
            and ZoneGeometry.containsZone(zone, square:getX(), square:getY(), square:getZ()) then
            selected[#selected + 1] = item
        end
    end
    return selected
end

local function plannerRequest(kind, request, context, sources)
    local plan = {
        kind = kind, character = request.character, zoneId = context.zoneId, zoneRevision = context.zoneRevision,
        mode = context.routingMode, destinations = context.destinations,
    }
    if kind == "unload" then plan.sources = sources else plan.selectedContainerId = context.selectedContainerId end
    return plan
end

function OperationLauncher.start(request, runtime)
    if type(request) ~= "table" or (request.command ~= "unload" and request.command ~= "unloadAll"
        and request.command ~= "organize" and request.command ~= "organizeAll")
        or not request.character or not finiteInteger(request.playerNum) or request.playerNum < 0
        or request.selectedContainer == nil or (request.side ~= "player" and request.side ~= "loot")
        or (request.onFinished ~= nil and type(request.onFinished) ~= "function") then
        return nil, "invalid_request"
    end

    local anchor = playerAnchor(request.character)
    if not anchor then return nil, "invalid_player_anchor" end
    local root, rootError = currentRoot(runtime)
    if not root then return nil, rootError or "root_unavailable" end
    local key, keyError = accountKey(request.character, request.playerNum, runtime)
    if not key then return nil, keyError end
    local source, sourceError = OperationSource.describe(request.selectedContainer, request.side, anchor, runtime)
    if not source then return nil, sourceError end
    local context, contextError = OperationContext.build({
        root = root, accountKey = key, playerAnchor = anchor, source = source,
    }, runtime)
    if not context then return nil, contextError end

    local kind, sources
    if request.command == "unloadAll" then
        if request.side ~= "player" then return nil, "unload_all_requires_player_source" end
        sources, sourceError = PlayerSourceBuilder.buildAll(request.character, anchor, Settings.getIncludeKeyRingKeysInUnloadAll(), runtime)
        if not sources then return nil, sourceError end
        kind = "unload"
    elseif request.command == "unload" then
        if request.side == "player" then
            sources, sourceError = PlayerSourceBuilder.buildSelected(request.character, request.selectedContainer, anchor, runtime)
            if not sources then return nil, sourceError end
            kind = "unload"
        elseif context.selectedContainerId then
            if context.selectedBindingKind ~= "vehiclePart" then return nil, "configured_source_requires_organize" end
            kind = "organizeContainer"
        else
            kind = "unload"
            if source.kind == "floor" then
                local items, itemsError = floorItems(source, root, context.zoneId)
                if not items then return nil, itemsError end
                sources = { { key = "floor", container = source.container, anchor = anchor, items = items } }
            else
                sources = { { key = "source", container = source.container, anchor = source.anchor or anchor } }
            end
        end
    elseif request.command == "organize" then
        if not context.selectedContainerId or context.selectedBindingKind == "vehiclePart" then
            return nil, "organize_requires_configured_nonvehicle_source"
        end
        kind = "organizeContainer"
    else
        if not context.selectedContainerId then return nil, "organize_all_requires_configured_source" end
        kind = "organizeZone"
    end

    local job, jobError = StorageJobPlanner.build(plannerRequest(kind, request, context, sources), runtime)
    if not job then return nil, jobError end
    if #job.moves == 0 then return { status = "no_work", job = job, context = context } end
    local session, sessionError = StorageJobExecutor.start(job, request.character, {
        carryMode = Settings.getHaulingMode(), restoreHeldItems = Settings.getRestoreHeldItems(), onFinished = request.onFinished,
    }, runtime)
    if not session then return nil, sessionError end
    return { status = "started", job = job, context = context, session = session }
end

return OperationLauncher
