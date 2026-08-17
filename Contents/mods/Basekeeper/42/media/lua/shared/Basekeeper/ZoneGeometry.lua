Basekeeper = Basekeeper or {}
Basekeeper.ZoneGeometry = Basekeeper.ZoneGeometry or {}

local ZoneGeometry = Basekeeper.ZoneGeometry

local function isInteger(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
        and value == math.floor(value)
end

function ZoneGeometry.normalizeRect(rect)
    if type(rect) ~= "table"
        or not isInteger(rect.x) or not isInteger(rect.y) or not isInteger(rect.z)
        or not isInteger(rect.w) or rect.w <= 0
        or not isInteger(rect.h) or rect.h <= 0 then
        return nil, "invalid_rect"
    end
    return { x = rect.x, y = rect.y, z = rect.z, w = rect.w, h = rect.h }
end

function ZoneGeometry.containsRect(rect, x, y, z)
    return type(rect) == "table"
        and isInteger(x) and isInteger(y) and isInteger(z)
        and rect.z == z
        and x >= rect.x and x < rect.x + rect.w
        and y >= rect.y and y < rect.y + rect.h
end

function ZoneGeometry.containsZone(zone, x, y, z)
    if type(zone) ~= "table" or type(zone.areas) ~= "table" then
        return false
    end
    for _, rect in ipairs(zone.areas) do
        if ZoneGeometry.containsRect(rect, x, y, z) then
            return true
        end
    end
    return false
end

function ZoneGeometry.rectsShareTiles(first, second)
    return type(first) == "table" and type(second) == "table"
        and first.z == second.z
        and first.x < second.x + second.w and second.x < first.x + first.w
        and first.y < second.y + second.h and second.y < first.y + first.h
end

function ZoneGeometry.findConnectedZoneIds(zones, proposedRect, excludedZoneId)
    local rect, errorCode = ZoneGeometry.normalizeRect(proposedRect)
    if not rect then
        return nil, errorCode
    end
    local ids = {}
    if type(zones) ~= "table" then
        return ids
    end
    for id, zone in pairs(zones) do
        if id ~= excludedZoneId and type(id) == "string" and type(zone) == "table"
            and type(zone.areas) == "table" then
            for _, area in ipairs(zone.areas) do
                if ZoneGeometry.rectsShareTiles(rect, area) then
                    ids[#ids + 1] = id
                    break
                end
            end
        end
    end
    table.sort(ids)
    return ids
end

function ZoneGeometry.vehicleIntersectsZone(vehicle, zone)
    if not vehicle or type(vehicle.getPoly) ~= "function"
        or type(vehicle.isIntersectingSquare) ~= "function" then
        return false, "vehicle_footprint_unavailable"
    end
    local poly = vehicle:getPoly()
    if not poly or not isInteger(poly.z)
        or type(poly.x1) ~= "number" or type(poly.x2) ~= "number"
        or type(poly.x3) ~= "number" or type(poly.x4) ~= "number"
        or type(poly.y1) ~= "number" or type(poly.y2) ~= "number"
        or type(poly.y3) ~= "number" or type(poly.y4) ~= "number" then
        return false, "vehicle_footprint_unavailable"
    end
    local minX = math.floor(math.min(poly.x1, poly.x2, poly.x3, poly.x4))
    local maxX = math.ceil(math.max(poly.x1, poly.x2, poly.x3, poly.x4))
    local minY = math.floor(math.min(poly.y1, poly.y2, poly.y3, poly.y4))
    local maxY = math.ceil(math.max(poly.y1, poly.y2, poly.y3, poly.y4))
    for x = minX, maxX do
        for y = minY, maxY do
            if ZoneGeometry.containsZone(zone, x, y, poly.z)
                and vehicle:isIntersectingSquare(x, y, poly.z) then
                return true
            end
        end
    end
    return false
end
