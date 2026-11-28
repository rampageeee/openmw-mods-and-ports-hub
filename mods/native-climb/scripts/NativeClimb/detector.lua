-- Native Climb face-first detector. Scene queries run only on explicit calls.
local self = require('openmw.self')
local nearby = require('openmw.nearby')
local Actor = require('openmw.types').Actor
local vec = require('openmw.util').vector3
local C = require('scripts.NativeClimb.config')

local UP = vec(0, 0, 1)
local BODY_HEIGHT, BODY_RADIUS = 130, 32
local MIN_FACING = math.cos(math.rad(50))
local DETECTION_BUDGET, LANDING_BUDGET = 60, 48
local SIDE_ANGLE = math.rad(20)
local SIDE_COS, SIDE_SIN = math.cos(SIDE_ANGLE), math.sin(SIDE_ANGLE)
local BODY_BANDS = {14, 65, 118}
local FACE_BANDS = {14, 66, 78, 102, 122}
local RETREAT_STEPS = {8, 16, 32, 48, 64}
local PROFILE_DEPTHS = {2, 8, 16, 24, 40, 56}
local LANDING_DEPTHS = {8, 20, 34, 50, 66}

local function atZ(p, z)
    return vec(p.x, p.y, z)
end

local function sideOf(dir)
    return vec(dir.y, -dir.x, 0)
end

local function ray(q, from, to)
    if q.count >= q.limit then
        q.exhausted = true
        return nil
    end
    q.count = q.count + 1
    return nearby.castRay(from, to, q.options)
end

local function query(limit)
    return {count = 0, limit = limit or math.huge, options = {ignore = self.object}}
end

local function solid(hit, normalZ)
    return hit and hit.hit and hit.hitNormal.z >= normalZ and
        not (hit.hitObject and Actor.objectIsInstance(hit.hitObject))
end

local function floor(q, p, high, low)
    local hit = ray(q, atZ(p, high), atZ(p, low))
    if solid(hit, 0.7) then return hit.hitPos.z end
end

local function clear(q, from, to)
    local hit = ray(q, from, to)
    return hit and not hit.hit
end

local function wall(q, from, direction, length, facing)
    local hit = ray(q, from, from + direction * length)
    if not solid(hit, -0.28) or hit.hitNormal.z > 0.28 then return nil end
    local into = -atZ(hit.hitNormal, 0):normalize()
    if into:dot(facing) < MIN_FACING then return nil end
    return hit.hitPos, into
end

local function clearance(q, p, inward, high, bottom)
    if not clear(q, atZ(p, bottom), atZ(p, high)) then return false end
    local front = p + inward * (BODY_RADIUS - 5)
    local shoulder = sideOf(inward) * 11
    for _, sign in ipairs({-1, 1}) do
        local sample = front + shoulder * sign
        if not clear(q, atZ(sample, bottom), atZ(sample, high)) then return false end
    end
    return true
end

local function hangAt(q, feet, edge, inward, z, distance)
    local hang = atZ(edge - inward * distance, feet.z)
    if (hang - feet):length() > C.scanReach then return nil end
    local gripZ = math.max(feet.z + C.hangRise, z - C.handReach)
    if not clearance(q, hang, inward, gripZ + BODY_HEIGHT, feet.z + 5) then return nil end

    -- The actor travels to the hang point before rising. Sample that corridor
    -- at body heights and check both shoulders near the approach endpoint.
    local travel = hang - feet
    if travel:length() > 1 then
        for _, height in ipairs(BODY_BANDS) do
            local start = feet + UP * height
            local stop = hang + inward * (BODY_RADIUS - 6) + UP * height
            if not clear(q, start, stop) then return nil end
        end
    end
    return hang
end

local function planForFace(q, feet, edge, inward, low, high, projection, bodyHit)
    if (edge - feet):dot(inward) < BODY_RADIUS - 8 then return nil, 'face too close' end
    local z = floor(q, edge + inward * 6, high + 12, low)
    if not z or z > high then return nil, 'no reachable top' end
    local near = edge + inward * 6
    local shoulder = sideOf(inward) * 12
    if not floor(q, near + shoulder, z + 8, z - 8)
        and not floor(q, near - shoulder, z + 8, z - 8) then return nil, 'lip too narrow' end
    if floor(q, edge - inward * 8, z + 3, z - 18) then return nil, 'no exposed front edge' end

    local distance = math.max(BODY_RADIUS + 2, C.wallClearance)
    local hang = hangAt(q, feet, edge, inward, z, distance)
    if not hang then
        local maxDistance = projection > 0 and C.maxCorniceClearance or C.maxWallClearance
        for _, offset in ipairs(RETREAT_STEPS) do
            if distance + offset > maxDistance or q.exhausted then break end
            hang = hangAt(q, feet, edge, inward, z, distance + offset)
            if hang then distance = distance + offset; break end
        end
    end
    if not hang then return nil, 'approach or grip obstructed' end
    return {
        start = feet, wall = edge, fwd = inward, hang = hang,
        clearance = distance, bodyProjection = projection, bodyHit = bodyHit,
        ledgeZ = z, height = z - feet.z,
        method = projection > 0 and 'projecting face' or 'wall face',
    }
end

local function probeDirection(q, feet, direction, facing, low, high, waist)
    local hit, inward = wall(q, feet + UP * waist, direction, C.scanReach, facing)
    if not hit then
        -- Floating lips can leave both the waist and head rays in open air.
        hit, inward = wall(q, feet + UP * math.min(78, waist + 30), direction, C.scanReach, facing)
        if not hit then hit, inward = wall(q, feet + UP * 110, direction, C.scanReach, facing) end
        if not hit then return nil, 'no wall in reach' end
    end
    local face = atZ(hit, feet.z)
    local nearestDepth = (face - feet):dot(direction)
    local projection, projectionNormal
    -- A fascia, shelf or cornice can sit in front of the wall hit. Use the
    -- foremost facing surface seen through the approach heights.
    for _, height in ipairs(FACE_BANDS) do
        local raised, into = wall(q, feet + UP * height, direction, nearestDepth + 1, facing)
        if raised then
            local depth = (raised - feet):dot(direction)
            if depth < nearestDepth - 4 then
                projection, projectionNormal, nearestDepth = raised, into, depth
            end
        end
    end
    if projection then
        -- Probe the upper face first. A thin lip may be grippable even when the
        -- taller wall behind it has no usable landing.
        local edge = atZ(projection, feet.z)
        local protrusion = math.max(5, (face - edge):dot(projectionNormal))
        local plan = planForFace(q, feet, edge, projectionNormal, low, high, protrusion, projection)
        if plan then return plan end
    end
    return planForFace(q, feet, face, inward, low, high, 0)
end

local function find(minHeight, maxHeight, allowWater)
    local q = query(DETECTION_BUDGET)
    local feet = self.position
    local facing = atZ(self.rotation * vec(0, 1, 0), 0)
    if facing:length() < 0.001 then return nil, 'no horizontal facing direction', 0 end
    facing = facing:normalize()
    if allowWater and Actor.isSwimming(self) then minHeight = math.min(30, minHeight) end
    if minHeight > maxHeight then return nil, 'empty reach window', 0 end
    local low, high = feet.z + minHeight, feet.z + maxHeight
    local waist = math.max(18, math.min(48, minHeight * 0.68))
    local plan, reason = probeDirection(q, feet, facing, facing, low, high, waist)
    if not plan and not q.exhausted then
        local across = sideOf(facing) * SIDE_SIN
        local centre = facing * SIDE_COS
        plan = probeDirection(q, feet, centre + across, facing, low, high, waist)
        if not plan and not q.exhausted then
            plan = probeDirection(q, feet, centre - across, facing, low, high, waist)
        end
    end
    if plan then plan.maxReach = maxHeight end
    if not plan and q.exhausted then reason = 'grab ray budget reached' end
    if plan then return plan, nil, q.count end
    return nil, reason, q.count
end

local function lip(plan, edge)
    local q = query()
    local z, tolerance = plan.ledgeZ, C.shimmyHeightTolerance
    local inside = edge + plan.fwd * 6
    local across = sideOf(plan.fwd) * 8
    for _, offset in ipairs({0, -1, 1}) do
        if not floor(q, inside + across * offset, z + tolerance, z - tolerance) then
            return false, q.count
        end
    end
    local outside = floor(q, edge - plan.fwd * 8, z + 4, z - tolerance)
    return outside == nil, q.count
end

local function headroom(q, pos, inward)
    local across = sideOf(inward) * 13
    for _, sign in ipairs({0, -1, 1}) do
        local p = pos + across * sign
        if not clear(q, p + UP * 3, p + UP * BODY_HEIGHT) then return false end
    end
    return true
end

local function supportAt(q, pos, footprint, inward, expectedZ, knownHeight)
    local tolerance = C.mountSupportTolerance
    local bottom, upper = expectedZ - tolerance, pos.z + 2
    local height = knownHeight or floor(q, footprint, upper, bottom)
    if not height or math.abs(height - expectedZ) > tolerance or
        pos.z - height > C.topClearance + tolerance + 5 then return false end
    local across = sideOf(inward) * 11
    local other = floor(q, footprint + across, upper, bottom)
    if not other or math.abs(other - height) > tolerance then
        other = floor(q, footprint - across, upper, bottom)
        if not other or math.abs(other - height) > tolerance then return false end
    end
    return headroom(q, pos, inward)
end

local function support(plan, pos)
    local q = query()
    local expected = plan.landingZ or plan.ledgeZ
    local valid = supportAt(q, pos, pos, plan.fwd, expected)
    if not valid and C.supportForwardReach > 0 then
        valid = supportAt(q, pos, pos + plan.fwd * C.supportForwardReach, plan.fwd, expected)
    end
    return valid, q.count
end

local lastObstruction
local function ascentClear(plan, pos, targetZ)
    local q = query()
    lastObstruction = nil
    local inward = plan.fwd
    local shoulder = sideOf(inward) * 11
    local front = pos + inward * (BODY_RADIUS - 5)
    for _, p in ipairs({pos, front + shoulder, front - shoulder}) do
        local hit = ray(q, atZ(p, pos.z + 6), atZ(p, targetZ + BODY_HEIGHT))
        if hit.hit then lastObstruction = hit.hitPos; return false, q.count end
    end
    return true, q.count
end

local function traversable(q, pos, inward, destination)
    local across = sideOf(inward) * 11
    for _, height in ipairs({4, 68, 124}) do
        if not clear(q, atZ(pos, destination.z + height),
            destination + UP * height) then return false end
    end
    -- Confirm that the upper body also clears alongside the movement line.
    for _, sign in ipairs({-1, 1}) do
        local offset = across * sign + UP * 90
        if not clear(q, atZ(pos, destination.z) + offset, destination + offset) then return false end
    end
    local ankle = destination + UP * 4
    return clear(q, ankle, ankle + inward * (BODY_RADIUS - 4))
end

local function mountCandidate(plan, pos, targetZ)
    local q = query(LANDING_BUDGET)
    local low, high = plan.ledgeZ - C.mountSupportTolerance, plan.ledgeZ + C.mountStepUp
    local ordinary, raised, preferred
    local previousDepth
    for _, sample in ipairs(LANDING_DEPTHS) do
        local depth = math.min(sample, C.mountMaxDepth)
        if depth <= 0 or depth == previousDepth or q.exhausted then break end
        previousDepth = depth
        local point = plan.wall + plan.fwd * depth
        local height = floor(q, point, high + 2, low)
        if height and height <= high then
            local destination = atZ(point, math.max(targetZ, height + C.topClearance))
            local ahead = point + plan.fwd * math.max(12, C.supportForwardReach)
            local nextHeight = floor(q, ahead, high + 4, low)
            if not q.exhausted and (not nextHeight or nextHeight <= height + 2)
                and supportAt(q, destination, point, plan.fwd, height, height)
                and traversable(q, pos, plan.fwd, destination) then
                local candidate = {pos = destination, z = destination.z, depth = depth, landingZ = height}
                if destination.z <= targetZ then
                    if not C.preferBackedLanding then return candidate, q.count end
                    ordinary = ordinary or candidate
                else
                    if not raised or height < raised.landingZ then raised = candidate end
                    if C.preferBackedLanding and height > plan.ledgeZ + 2
                        and height <= plan.start.z + plan.maxReach and depth + 12 <= C.mountMaxDepth
                        and nextHeight and math.abs(nextHeight - height) <= 2 then
                        local middle = floor(q, point + plan.fwd * 6, height + 3, height - 3)
                        if middle and (not preferred or height > preferred.landingZ) then
                            preferred = candidate
                        end
                    end
                end
            end
        end
    end
    if preferred then
        if ordinary then preferred.fallback = ordinary
        elseif raised ~= preferred then preferred.fallback = raised end
    end
    return preferred or ordinary or raised, q.count
end

local function profile(plan)
    local q = query()
    local samples = {}
    for _, depth in ipairs(PROFILE_DEPTHS) do
        local p = plan.wall + plan.fwd * depth
        local height = floor(q, p, plan.start.z + plan.maxReach + 12, plan.ledgeZ - 16)
        samples[#samples + 1] = {depth = depth, z = height, pos = height and atZ(p, height)}
    end
    return samples, q.count
end

return {
    find = find,
    lip = lip,
    support = support,
    ascentClear = ascentClear,
    obstruction = function() return lastObstruction end,
    mountCandidate = mountCandidate,
    profile = profile,
}
