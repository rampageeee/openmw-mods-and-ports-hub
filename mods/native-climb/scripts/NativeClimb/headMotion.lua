local camera = require('openmw.camera')

local M = {active = false}
local riseTime, duration = 0.13, 0.38
local dip, tilt = math.rad(6), math.rad(1.4)
local elapsed, pitchOffset
local pitchBase, rollBase, appliedPitch, appliedRoll

local function stillApplied(current, applied)
    return applied ~= nil and math.abs(current - applied) < 0.000001
end

function M.start()
    elapsed = 0
    M.active = true
end

function M.stop()
    if not M.active then return end
    M.active = false
    local oldPitch, oldRoll = appliedPitch, appliedRoll
    appliedPitch, appliedRoll = nil, nil
    if oldPitch and stillApplied(camera.getExtraPitch(), oldPitch) then
        camera.setExtraPitch(pitchBase)
    end
    if oldRoll and stillApplied(camera.getExtraRoll(), oldRoll) then
        camera.setExtraRoll(rollBase)
    end
end

-- Physical pitch changes at the controls handoff. Preserve the visual offset
-- until the pulse settles while using the restored base for subsequent frames.
function M.setPitchBase(base)
    if appliedPitch then
        pitchBase = base
        appliedPitch = base + pitchOffset
        camera.setExtraPitch(appliedPitch)
    else
        camera.setExtraPitch(base)
    end
end

function M.update(dt, climbPitch)
    elapsed = elapsed + dt
    if elapsed >= duration then
        M.stop()
        if climbPitch then camera.setExtraPitch(climbPitch) end
        return
    end

    local t
    if elapsed < riseTime then
        t = elapsed / riseTime
    else
        t = (duration - elapsed) / (duration - riseTime)
    end
    local weight = t * t * (3 - 2 * t)
    pitchOffset = dip * weight
    if climbPitch then
        pitchBase = climbPitch
    else
        local current = camera.getExtraPitch()
        if not stillApplied(current, appliedPitch) then pitchBase = current end
    end
    local current = camera.getExtraRoll()
    if not stillApplied(current, appliedRoll) then rollBase = current end
    appliedPitch, appliedRoll = pitchBase + pitchOffset, rollBase + tilt * weight
    camera.setExtraPitch(appliedPitch)
    camera.setExtraRoll(appliedRoll)
end

return M
