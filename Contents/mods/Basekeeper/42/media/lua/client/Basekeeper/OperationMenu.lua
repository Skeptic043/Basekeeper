Basekeeper = Basekeeper or {}
if not Basekeeper.OperationSource then require "Basekeeper/OperationSource" end
if not Basekeeper.ZoneGeometry then require "Basekeeper/ZoneGeometry" end
if not Basekeeper.ZoneRegistry then require "Basekeeper/ZoneRegistry" end
if not Basekeeper.ContainerBinding then require "Basekeeper/ContainerBinding" end
if not Basekeeper.OperationLauncher then require "Basekeeper/OperationLauncher" end
Basekeeper.OperationMenu = Basekeeper.OperationMenu or {}

local Menu = Basekeeper.OperationMenu
local Source, Geometry, Registry, Binding, Launcher = Basekeeper.OperationSource, Basekeeper.ZoneGeometry, Basekeeper.ZoneRegistry, Basekeeper.ContainerBinding, Basekeeper.OperationLauncher
local MARKER = "Basekeeper.containerBindingId"

local function text(key) return type(_G.getText) == "function" and getText(key) or key end
local function call(value, name) return value and type(value[name]) == "function" and value[name](value) or nil end
local function integer(value) return type(value) == "number" and value == math.floor(value) and value == value and value ~= math.huge and value ~= -math.huge end
local function anchor(character)
    local x, y, z = call(character, "getX"), call(character, "getY"), call(character, "getZ")
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" or x ~= x or y ~= y or z ~= z
        or x == math.huge or y == math.huge or z == math.huge or x == -math.huge or y == -math.huge or z == -math.huge then return nil end
    return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
end
local function account(character, playerNum, runtime)
    local client = runtime and runtime.isClient or _G.isClient
    if type(client) == "function" and client() then
        local name = call(character, "getUsername")
        return type(name) == "string" and name ~= "" and "user:" .. name or nil
    end
    return "local:" .. tostring(playerNum)
end
local function root(runtime)
    if runtime and type(runtime.getRoot) == "function" then return runtime.getRoot() end
    local modData = _G.ModData
    return modData and type(modData.get) == "function" and modData.get("Basekeeper") or nil
end
local function validZone(zone, id)
    return type(zone) == "table" and zone.id == id and type(zone.areas) == "table" and type(zone.containers) == "table"
        and integer(zone.revision) and zone.revision > 0 and #zone.areas > 0
        and (zone.routingMode == "consolidate" or zone.routingMode == "balance" or zone.routingMode == "nearest")
end
local function activeZone(rootValue, accountKey, player)
    if type(rootValue) ~= "table" or rootValue.schemaVersion ~= 2 or type(rootValue.zones) ~= "table" then return nil end
    local found
    for id, zone in pairs(rootValue.zones) do
        if not validZone(zone, id) then return nil end
        for _, area in ipairs(zone.areas) do if not Geometry.normalizeRect(area) then return nil end end
        if Geometry.containsZone(zone, player.x, player.y, player.z) and Registry.can(zone, accountKey, "use") then
            if found then return nil end
            found = zone
        end
    end
    return found
end
local function squareMatch(square, binding)
    return square and call(square, "getX") == binding.x and call(square, "getY") == binding.y and call(square, "getZ") == binding.z
end
local function containerIndex(parent, container)
    if type(parent.getContainerCount) ~= "function" or type(parent.getContainerByIndex) ~= "function" then return nil end
    local count = parent:getContainerCount()
    if not integer(count) or count < 0 then return nil end
    for index = 0, count - 1 do if parent:getContainerByIndex(index) == container then return index end end
end
local function matches(container, binding)
    binding = Binding.normalize(binding)
    if not binding then return false end
    local part = call(container, "getVehiclePart")
    if binding.kind == "vehiclePart" then
        local vehicle = call(part, "getVehicle")
        return part and call(vehicle, "getSqlId") == binding.vehicleSqlId and call(part, "getId") == binding.partId
    end
    if part then return false end -- nested vehicle bags are not direct compartments.
    local item = call(container, "getContainingItem")
    if binding.kind == "placedItem" then
        local world = call(item, "getWorldItem")
        return item and world and call(item, "getID") == binding.itemId and squareMatch(call(world, "getSquare"), binding)
    end
    if binding.kind == "world" then
        local parent = call(container, "getParent")
        local data = call(parent, "getModData")
        return parent and type(data) == "table" and data[MARKER] == binding.objectBindingId
            and containerIndex(parent, container) == binding.containerIndex and squareMatch(call(parent, "getSquare"), binding)
    end
    return false
end
local function configured(zone, container)
    local found, kind
    for _, config in pairs(zone.containers) do
        local binding = type(config) == "table" and config.binding or nil
        if matches(container, binding) then
            if found then return nil, "ambiguous" end
            found, kind = config, binding.kind
        end
    end
    return found, kind
end
local function commands(request, runtime)
    local player = anchor(request.character)
    local key = player and account(request.character, request.playerNum, runtime)
    local zone = player and key and activeZone(root(runtime), key, player)
    if not zone then return nil end
    local source = Source.describe(request.selectedContainer, request.side, player, runtime)
    if not source then return nil end
    if source.kind == "tile" and not Geometry.containsZone(zone, source.anchor.x, source.anchor.y, source.anchor.z) then return nil end
    if source.kind == "vehicle" then
        local intersects = Geometry.vehicleIntersectsZone(source.vehicle, zone)
        if not intersects then return nil end
    end
    local config, kind = configured(zone, request.selectedContainer)
    if kind == "ambiguous" then return nil end
    if request.side == "player" then return { "unload", "unloadAll" } end
    if not config then return { "unload" } end
    if kind == "vehiclePart" then return { "unload", "organizeAll" } end
    return { "organize", "organizeAll" }
end
local labels = { unload = "UI_Basekeeper_Unload", unloadAll = "UI_Basekeeper_UnloadAll", organize = "UI_Basekeeper_Organize", organizeAll = "UI_Basekeeper_OrganizeAll" }
local function feedback(result, errorCode, character, runtime)
    local halo = runtime and runtime.halo or _G.HaloTextHelper
    if not halo or type(halo.addText) ~= "function" then return end
    if result and result.status == "no_work" then halo.addText(character, text("UI_Basekeeper_NoWork")) end
    if not result and errorCode then halo.addText(character, text("UI_Basekeeper_UnableToStart")) end
end
function Menu.append(context, request, runtime)
    if not context or type(context.options) ~= "table" then return false end
    for _, option in ipairs(context.options) do if option.BasekeeperParent then return false end end
    local options = commands(request, runtime)
    if not options or #options == 0 then return false end
    local parent = context:addOption(text("UI_Basekeeper_Menu"))
    local submenu = context:getNew(context)
    context:addSubMenu(parent, submenu)
    parent.BasekeeperParent = true
    for _, command in ipairs(options) do
        submenu:addOption(text(labels[command]), nil, function()
            local result, errorCode = Launcher.start({ command = command, character = request.character, playerNum = request.playerNum,
                selectedContainer = request.selectedContainer, side = request.side }, runtime)
            feedback(result, errorCode, request.character, runtime)
        end)
    end
    return true
end
function Menu.commandsForTests(request, runtime) return commands(request, runtime) end
return Menu
