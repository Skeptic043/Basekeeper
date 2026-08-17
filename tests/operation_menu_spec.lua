local function expect(value, message) if not value then error(message, 2) end end
Basekeeper = {}
Basekeeper.ZoneGeometry = {
    containsZone = function(_, x, y, z) return x >= 0 and x <= 2 and y >= 0 and y <= 2 and z == 0 end,
    vehicleIntersectsZone = function() return true end,
    normalizeRect = function(area) return type(area) == "table" and area.x and area.y and area.z and area.w and area.h and area or nil end,
}
local permitted = true
Basekeeper.ZoneRegistry = { can = function() return permitted end }
Basekeeper.ContainerBinding = { normalize = function(binding)
    if type(binding) ~= "table" then return nil end
    if binding.kind == "world" and type(binding.objectBindingId) == "string" and type(binding.containerIndex) == "number" then return binding end
    if binding.kind == "placedItem" and type(binding.itemId) == "number" then return binding end
    if binding.kind == "vehiclePart" and type(binding.vehicleSqlId) == "number" and type(binding.partId) == "string" then return binding end
end }
Basekeeper.OperationSource = { describe = function(container, side, anchor)
    if side == "player" then return { kind = "carried", container = container } end
    if type(container.getType) == "function" and container:getType() == "floor" then return { kind = "floor", container = container } end
    return { kind = container.vehicle and "vehicle" or "tile", container = container, anchor = { x = 1, y = 1, z = 0 }, vehicle = container.vehicle }
end }
local started = {}
local launcherError = nil
Basekeeper.OperationLauncher = { start = function(request)
    started[#started + 1] = request
    if launcherError then return nil, launcherError end
    return { status = "no_work" }
end }
getText = function(key) return key end
dofile("Contents/mods/Basekeeper/42/media/lua/client/Basekeeper/OperationMenu.lua")
dofile("Contents/mods/Basekeeper/42/media/lua/client/Basekeeper/InventoryTabContext.lua")
local Menu, Bridge = Basekeeper.OperationMenu, Basekeeper.InventoryTabContext
local character = { getX=function() return 1 end, getY=function() return 1 end, getZ=function() return 0 end }
local root = { schemaVersion=2, personal={}, zones={ z={ id="z", revision=1, routingMode="nearest", ownerAccount="local:0", members={}, areas={{x=0,y=0,z=0,w=3,h=3}}, containers={} } } }
local halo = {}
local runtime = { getRoot=function() return root end, halo={ addText=function(_, message) halo[#halo + 1] = message end } }
local function cmds(side, container)
    return Menu.commandsForTests({character=character,playerNum=0,selectedContainer=container or {},side=side}, runtime)
end
local player = cmds("player")
expect(#player == 2 and player[1] == "unload" and player[2] == "unloadAll", "player order is Unload then Unload All")
expect(cmds("loot")[1] == "unload", "unconfigured loot exposes Unload")
local floor = { getType = function() return "floor" end }
expect(cmds("loot", floor)[1] == "unload", "Floor exposes Unload when the player is in an active usable zone")
permitted = false
expect(not cmds("loot"), "unauthorized players have no menu")
permitted = true
character.getX = function() return 9 end
expect(not cmds("loot"), "players outside every active zone have no menu")
character.getX = function() return 1 end
runtime.getRoot = function() return nil end
expect(not cmds("loot"), "absent shared roots have no menu")
runtime.getRoot = function() return root end
Basekeeper.ZoneGeometry.vehicleIntersectsZone = function() return false end
expect(not cmds("loot", { vehicle = {} }), "vehicles outside the active zone have no menu")
Basekeeper.ZoneGeometry.vehicleIntersectsZone = function() return true end
root.zones.z.routingMode = "invalid"
expect(not cmds("loot"), "malformed routing mode hides the menu")
root.zones.z.routingMode = "nearest"
root.zones.z.containers.one={binding={kind="world",objectBindingId="a",containerIndex=0,x=1,y=1,z=0}}
local parent={getModData=function() return { ["Basekeeper.containerBindingId"]="a" } end,getSquare=function() return {getX=function()return 1 end,getY=function()return 1 end,getZ=function()return 0 end} end,getContainerCount=function()return 1 end}
local fixed={getParent=function()return parent end}
parent.getContainerByIndex=function(_, index) return index == 0 and fixed or nil end
local organized=cmds("loot", fixed)
expect(organized[1]=="organize" and organized[2]=="organizeAll", "configured fixed storage organizes")
local world={getSquare=function() return {getX=function()return 1 end,getY=function()return 1 end,getZ=function()return 0 end} end}
local placedItem={getID=function()return 7 end,getWorldItem=function()return world end}
local placed={getContainingItem=function()return placedItem end}
root.zones.z.containers.placed={binding={kind="placedItem",itemId=7,x=1,y=1,z=0}}
expect(cmds("loot",placed)[1]=="organize","placed binding matches without resolution")
root.zones.z.containers.placed=nil
local vehicle={getSqlId=function()return 9 end}
local part={getVehicle=function()return vehicle end,getId=function()return "TruckBed" end}
local vehicleContainer={vehicle=vehicle,getVehiclePart=function()return part end}
root.zones.z.containers.vehicle={binding={kind="vehiclePart",vehicleSqlId=9,partId="TruckBed"}}
local vehicleCommands=cmds("loot",vehicleContainer)
expect(vehicleCommands[1]=="unload" and vehicleCommands[2]=="organizeAll","direct vehicle uses its settled labels")
local nestedVehicleBag={vehicle=vehicle,getVehiclePart=function() return nil end,getOutermostContainer=function()return vehicleContainer end}
expect(cmds("loot",nestedVehicleBag)[1]=="unload","nested vehicle bag is never a direct vehicle binding")
root.zones.z.containers.vehicle=nil
root.zones.z.containers.two={binding={kind="world",objectBindingId="a",containerIndex=0,x=1,y=1,z=0}}
expect(not cmds("loot",fixed), "ambiguous bindings hide the menu")
root.zones.z.containers.two=nil
local reads=0
fixed.getItems=function() reads=reads+1 return {} end
cmds("loot",fixed); expect(reads==0,"availability never reads items")
local function context()
    local result={options={}}
    function result:addOption(label, target, onSelect) local value={label=label,target=target,onSelect=onSelect}; self.options[#self.options+1]=value; return value end
    function result:getNew() return context() end
    function result:addSubMenu(parent, submenu) parent.submenu=submenu end
    function result:setVisible(value) self.visible=value end
    return result
end
local c=context()
expect(Menu.append(c,{character=character,playerNum=0,selectedContainer=fixed,side="loot"},runtime),"menu appends")
expect(#c.options==1 and not c.options[1].onSelect and #c.options[1].submenu.options==2,"parent is callback-free with submenu")
expect(not Menu.append(c,{character=character,playerNum=0,selectedContainer=fixed,side="loot"},runtime),"duplicate parents are prevented")
c.options[1].submenu.options[1].onSelect(c.options[1].submenu.options[1].target)
expect(started[1].command=="organize" and started[1].selectedContainer==fixed and started[1].side=="loot","callback forwards exact launcher request")
expect(halo[#halo] == "UI_Basekeeper_NoWork", "no-work callbacks show the localized halo feedback")
launcherError = "planner_failed"
c.options[1].submenu.options[1].onSelect(c.options[1].submenu.options[1].target)
expect(halo[#halo] == "UI_Basekeeper_UnableToStart", "launcher errors show one generic localized halo feedback")
launcherError = nil
c.options = {}
expect(Menu.append(c,{character=character,playerNum=0,selectedContainer=fixed,side="loot"},runtime),"cleared context can receive a fresh parent")
local prior=0; local button={inventory=fixed,onRightMouseDown=function()prior=prior+1 end}; local page={playerObj=character,playerNum=0,onCharacter=false,backpacks={button}}
local mouse=context(); Bridge.refresh(page,"buttonsAdded",{contextFor=function()return mouse end,getRoot=runtime.getRoot,halo=runtime.halo})
button:onRightMouseDown(2,3)
expect(prior==1 and #mouse.options==1 and mouse.visible,"wrapped button preserves vanilla and reopens context")
local wrapped=button.onRightMouseDown; Bridge.refresh(page,"buttonsAdded",{contextFor=function()return mouse end}); expect(button.onRightMouseDown==wrapped,"pooled button does not recursively wrap")
expect(started[#started].side=="loot","loot page backpacks retain the loot side")
local controller=context(); local controllerPage={playerObj=character,playerNum=0,inventoryPane={inventory=fixed}}
local controllerRuntime={JoypadState={players={{}}},getJoypadFocus=function()return controllerPage end,getPlayerInventory=function()return controllerPage end,getPlayerLoot=function()return {} end,getRoot=runtime.getRoot,halo=runtime.halo}
expect(Bridge.controller(0,controller,{},controllerRuntime),"controller accepts only the exact inventory focus")
controllerRuntime.getJoypadFocus=function()return {} end
expect(not Bridge.controller(0,context(),{},controllerRuntime),"controller rejects arbitrary focused objects")
controllerRuntime.JoypadState={players={}}
expect(not Bridge.controller(0,context(),{},controllerRuntime),"controller requires a bound JoypadState player")
character.getX=function()return 0/0 end
expect(not cmds("loot",fixed),"malformed player input hides without throwing")
print("operation_menu_spec: ok")
