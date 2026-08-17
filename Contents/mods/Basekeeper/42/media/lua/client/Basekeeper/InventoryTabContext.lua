Basekeeper = Basekeeper or {}
if not Basekeeper.OperationMenu then require "Basekeeper/OperationMenu" end
Basekeeper.InventoryTabContext = Basekeeper.InventoryTabContext or {}
local Bridge, Menu = Basekeeper.InventoryTabContext, Basekeeper.OperationMenu
local function playerNum(page) return page and (page.playerNum or page.player or 0) or 0 end
local function character(page) return page and (page.playerObj or page.character or (type(_G.getSpecificPlayer) == "function" and getSpecificPlayer(playerNum(page)))) end
local function contextFor(page, x, y, runtime)
    if runtime and type(runtime.contextFor) == "function" then return runtime.contextFor(page, x, y) end
    return type(_G.getPlayerContextMenu) == "function" and getPlayerContextMenu(playerNum(page)) or nil
end
local function visible(context)
    if not context then return end
    if type(context.setVisible) == "function" then context:setVisible(true) end
    context.visible = true
    if type(context.bringToTop) == "function" then context:bringToTop() end
end
function Bridge.append(page, container, side, context, runtime)
    return Menu.append(context, { character = character(page), playerNum = playerNum(page), selectedContainer = container, side = side }, runtime)
end
function Bridge.wrapButton(page, button, side, runtime)
    if not button or not button.inventory then return end
    local prior = button.onRightMouseDown
    if button.BasekeeperWrappedCallback == prior then return end
    local function wrapped(self, x, y, ...)
        local result = prior and prior(self, x, y, ...) or nil
        local context = contextFor(page, x, y, runtime)
        if Bridge.append(page, button.inventory, side, context, runtime) then visible(context) end
        return result
    end
    button.onRightMouseDown, button.BasekeeperWrappedCallback = wrapped, wrapped
end
function Bridge.refresh(page, stage, runtime)
    if stage ~= "buttonsAdded" or not page then return end
    local function wrap(buttons, side)
        if type(buttons) == "table" then for _, button in pairs(buttons) do Bridge.wrapButton(page, button, side, runtime) end end
    end
    wrap(page.backpacks, page.onCharacter == true and "player" or "loot")
end
function Bridge.controller(playerNumValue, context, items, runtime)
    local state = runtime and runtime.JoypadState or _G.JoypadState
    local bound = runtime and runtime.isControllerBound and runtime.isControllerBound(playerNumValue)
        or state and type(state.players) == "table" and state.players[playerNumValue + 1] ~= nil
    local focus = runtime and runtime.getJoypadFocus and runtime.getJoypadFocus(playerNumValue)
        or type(_G.getJoypadFocus) == "function" and getJoypadFocus(playerNumValue)
    local inventory = runtime and runtime.getPlayerInventory and runtime.getPlayerInventory(playerNumValue)
        or type(_G.getPlayerInventory) == "function" and getPlayerInventory(playerNumValue)
    local loot = runtime and runtime.getPlayerLoot and runtime.getPlayerLoot(playerNumValue)
        or type(_G.getPlayerLoot) == "function" and getPlayerLoot(playerNumValue)
    if not bound or (focus ~= inventory and focus ~= loot) then return false end
    local page, side = focus, focus == inventory and "player" or "loot"
    local container = page and page.inventoryPane and page.inventoryPane.inventory
    if not container or (side ~= "player" and side ~= "loot") then return false end
    return Bridge.append(page, container, side, context, runtime)
end
if _G.Events then
    if Events.OnRefreshInventoryWindowContainers then Events.OnRefreshInventoryWindowContainers.Add(function(page, stage) Bridge.refresh(page, stage) end) end
    if Events.OnFillInventoryObjectContextMenu then Events.OnFillInventoryObjectContextMenu.Add(function(player, context, items) Bridge.controller(player, context, items) end) end
end
return Bridge
