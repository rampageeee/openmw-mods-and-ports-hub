-- Native Climb prototype for OpenMW 0.51.
-- Movement backend derived from the separately tested LevitationProbe v0.1.
local self = require('openmw.self')
local types = require('openmw.types')
local core = require('openmw.core')
local input = require('openmw.input')
local async = require('openmw.async')
local camera = require('openmw.camera')
local util = require('openmw.util')
local ui = require('openmw.ui')
local ambient = require('openmw.ambient')
local I = require('openmw.interfaces')
local C = require('scripts.NativeClimb.config')
local settings = require('scripts.NativeClimb.settings')
local detector = require('scripts.NativeClimb.detector')
local markers = require('scripts.NativeClimb.markers')
local headMotion = require('scripts.NativeClimb.headMotion')
local Hold = require('scripts.NativeClimb.hold')
local Actor = types.Actor
local PREFIX = 'ag_nc_'
local UP_PITCH = -math.rad(89.5)
local state = 'idle'
local plan, startCell, startPos, hangPos, gripZ, targetZ
local sessionTime, phaseTime, checkTime, stallElapsed, stallSample = 0,0,0,0,0
local bestMetric, sampleMetric
local ownsControls, pitchOwned = false,false
local savedPitch, savedExtra
local yawCentre
local function wrapAngle(a) return (a+math.pi)%(2*math.pi)-math.pi end
local levId, fatId, pendingLev, armedNext
local debug = C.debug
local hold
local cleanupLeft, cleanupWait = 0,0
local missWatch, missSamples = 0,0
local cameraOwned = false
local CAMERA_TAG = "NativeClimb"
local raycasts = 0
local totalTime = 0
local shimmyTarget, shimmySign, shimmyBlocked, shimmyOrigin
local shimmyRate=0.2
local mountWasMoving, lastSupportPos = false,nil
local headMotionUsed = false
local function countResult(result,n) raycasts=raycasts+(n or 0); return result end
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function log(s) print('[NativeClimb] '..s) end
local function notify(s) log(s); ui.showMessage('[Climb] '..s) end
local markerFailed=false
local function markCall(fn,...)
    if markerFailed then return end
    local ok,err=pcall(fn,...)
    if not ok then
        log('MARKER disabled for this climb: '..tostring(err)); markerFailed=true
        pcall(markers.clear)
    end
end
local function markGrip()
    if not C.ledgeMarkers or not plan then return end
    markCall(markers.set,'grip','grip',util.vector3(plan.wall.x,plan.wall.y,plan.ledgeZ),'GRIP')
end
local function profileLedge()
    if not C.ledgeMarkers then return end
    local samples=countResult(detector.profile(plan))
    local highest,trace=nil,{}
    for _,sample in ipairs(samples) do
        trace[#trace+1]=string.format('+%d:%s',sample.depth,sample.z and string.format('%.1f',sample.z) or 'none')
        if sample.z and sample.z>plan.ledgeZ+2 and (not highest or sample.z>highest.z) then highest=sample end
    end
    log(string.format('PROFILE grip=(%.1f,%.1f,%.1f) clearance=%.1f | %s',plan.wall.x,plan.wall.y,plan.ledgeZ,plan.clearance or 0,table.concat(trace,' ')))
    markCall(markers.set,'higher','higher',highest and highest.pos or nil,'HIGHER SAMPLE')
end
local function menuOpen() return I.UI and I.UI.getMode and I.UI.getMode() ~= nil end
local function mag(id)
    local e = Actor.activeEffects(self):getEffect(id)
    return e and e.magnitude or 0
end
local function levitation() return mag(core.magic.EFFECT_TYPE.Levitate) end
local function fatigue() return Actor.stats.dynamic.fatigue(self) end
local function fatigueDiagnostics(tag)
    local f=fatigue()
    local attr=Actor.stats.attributes
    local expected=attr.strength(self).modified+attr.willpower(self).modified+
        attr.agility(self).modified+attr.endurance(self).modified
    log(string.format('FATIGUE %s current=%.2f base=%.2f modifier=%.2f modified=%.2f attributeSum=%.2f',
        tag,f.current,f.base,f.modifier,f.base+f.modifier,expected))
end
local function athletics() return clamp(types.NPC.stats.skills.athletics(self).modified,0,100) end
local function spellId(kind,n) return PREFIX..kind..'_'..string.format('%03d',n) end
local function ownId(id) return type(id)=='string' and id:lower():sub(1,#PREFIX)==PREFIX end
local function ownedSpells()
    local ids={}
    for key,sp in pairs(Actor.activeSpells(self)) do
        if ownId(sp.id) or ownId(key) then ids[#ids+1]=sp end
    end
    return ids
end
local function spellDiagnostics()
    log(string.format('MAGIC total Levitate=%.2f Damage Fatigue=%.2f Restore Fatigue=%.2f',levitation(),mag(core.magic.EFFECT_TYPE.DamageFatigue),mag(core.magic.EFFECT_TYPE.RestoreFatigue)))
    for key,sp in pairs(Actor.activeSpells(self)) do
        local relevant=ownId(sp.id) or ownId(key)
        for _,e in ipairs(sp.effects or {}) do
            if e.id==core.magic.EFFECT_TYPE.Levitate then relevant=true end
        end
        if relevant then log('SPELL source='..tostring(sp.id)..' instance='..tostring(sp.activeSpellId)..' temporary='..tostring(sp.temporary)) end
    end
end
local function removeSpells(only)
    local spells, ids = Actor.activeSpells(self),{}
    for key,s in pairs(spells) do
        if (ownId(s.id) or ownId(key)) and (not only or s.id==only or key==only) then
            if s.temporary then ids[#ids+1]=s.activeSpellId
            else log('WARN non-temporary owned spell: '..tostring(s.id)) end
        end
    end
    for _,id in ipairs(ids) do spells:remove(id) end
    return #ids
end
local function apply(id)
    assert(plan and (state=='arming' or state=='rescaling'), 'refusing spell outside validated climb')
    log('APPLY '..id)
    Actor.activeSpells(self):add({id=id,effects={0},ignoreResistances=true,
        ignoreSpellAbsorption=true,ignoreReflect=true,stackable=false})
end
local function active(id) return id and Actor.activeSpells(self):isSpellActive(id) end
local function stopMotion()
    self.controls.movement=0
    self.controls.sideMovement=0
    self.controls.jump=false
    self.controls.pitchChange=0
end
local function restorePitch()
    if not pitchOwned then return end
    headMotion.setPitchBase(savedExtra or 0)
    camera.setPitch(savedPitch or 0)
    self.controls.pitchChange=(savedPitch or 0)-self.rotation:getPitch()
    pitchOwned=false
end
local function ownPitch()
    if not pitchOwned then
        savedPitch=camera.getPitch()
        savedExtra=camera.getExtraPitch()
        pitchOwned=true
    end
end
local function playStep(right)
    if C.sounds then pcall(ambient.playSound,right and 'FootBareRight' or 'FootBareLeft',{volume=0.7}) end
end
local function clearWindow() if hold then hold.cancel() end end
local function bypassHeld()
    if C.bypassModifier=='Alt' then return input.isAltPressed() end
    if C.bypassModifier=='Ctrl' then return input.isCtrlPressed() end
    if C.bypassModifier=='Shift' then return input.isShiftPressed() end
    return false
end
local function queueCleanup()
    cleanupLeft=2; cleanupWait=0.1
end
local function supportedView()
    local mode=camera.getMode()
    return mode==camera.MODE.FirstPerson or (C.thirdPerson and (mode==camera.MODE.ThirdPerson or mode==camera.MODE.Preview))
end
local function lockCamera()
    if not I.Camera then return end
    cameraOwned=true
    for _,name in ipairs({'disableModeControl','disableStandingPreview','disableZoom'}) do
        if I.Camera[name] then I.Camera[name](CAMERA_TAG) end
    end
    if camera.getMode()==camera.MODE.Preview then camera.setMode(camera.MODE.ThirdPerson) end
end
local function unlockCamera()
    if not cameraOwned then return end
    if I.Camera then
        for _,name in ipairs({'enableModeControl','enableStandingPreview','enableZoom'}) do
            if I.Camera[name] then pcall(I.Camera[name],CAMERA_TAG) end
        end
    end
    cameraOwned=false
end
local function finish(reason, success)
    local wasActive=state~='idle' or ownsControls
    -- Stop work before attempting cleanup; independent cleanup calls.
    state='idle'; clearWindow(); missWatch,missSamples=0,0
    if not success then pcall(headMotion.stop) end
    pcall(markers.clear); markerFailed=false
    if ownsControls then
        pcall(stopMotion)
        local ok,err=pcall(restorePitch)
        if not ok then log('pitch cleanup error: '..tostring(err)); pitchOwned=false end
        ok,err=pcall(I.Controls.overrideMovementControls,false)
        if ok then ownsControls=false else log('control cleanup error: '..tostring(err)) end
    end
    if yawCentre then pcall(function() self.controls.yawChange=0 end) end
    unlockCamera()
    yawCentre=nil
    local ok,n=pcall(removeSpells)
    if not ok then log('spell cleanup error: '..tostring(n))
    elseif n>0 then log('CLEANUP requested '..n..' owned spell removal(s)') end
    -- Active spell operations are deferred: bounded cleanup catches an add queued
    -- in the same frame as an abort. No recurring work after this grace period.
    if wasActive then queueCleanup() end
    if success then
        if debug then pcall(fatigueDiagnostics,'before XP') end
        playStep(true)
        if C.skillXP then pcall(function()
            I.SkillProgression.skillUsed('athletics',{
                useType=I.SkillProgression.SKILL_USE_TYPES.Athletics_RunOneSecond,scale=2})
        end) end
        if debug then pcall(fatigueDiagnostics,'after XP call') end
    end
    if wasActive then notify((reason or 'Released.')..string.format(' | %.2fs; %d rays',totalTime,raycasts)) end
    shimmyTarget,shimmySign,shimmyBlocked,shimmyOrigin=nil,nil,nil,nil
    mountWasMoving,lastSupportPos=false,nil
    plan,startCell,startPos,hangPos=nil,nil,nil,nil
    levId,fatId,pendingLev,armedNext=nil,nil,nil,nil
end
local function phase(nextState)
    state=nextState; phaseTime=0; stallElapsed=0; stallSample=0
    bestMetric=nil; sampleMetric=nil
    log('STATE '..nextState)
end
local function fmtDelta(pos,origin)
    local d=pos-origin
    return string.format('dX=%.2f dY=%.2f dZ=%.2f',d.x,d.y,d.z)
end
local function flat(v) return util.vector3(v.x,v.y,0) end
local function flatForward()
    local f=flat(self.rotation*util.vector3(0,1,0))
    if f:length()<0.001 then return plan and plan.fwd or util.vector3(0,1,0) end
    return f:normalize()
end
local function setPitch(p)
    ownPitch()
    camera.setPitch(p)
    local actual=self.rotation:getPitch()
    self.controls.pitchChange=p-actual
    return math.abs(p-actual)<math.rad(3)
end
-- Steer toward a fixed world-space point using actor-relative forward/strafe.
-- Yaw is not forced, so player turning cannot redirect the traverse.
local function driveXY(pos,dest,speedCap,tolerance)
    local d=flat(dest-pos)
    local dist=d:length()
    if dist<=(tolerance or C.horizontalTolerance) then return true,dist end
    if setPitch(0) then
        local f=flatForward(); local right=util.vector3(f.y,-f.x,0)
        local direction=d*(1/dist)
        local speed=math.min(speedCap or 1,clamp(dist/24,0.12,1))
        self.controls.movement=direction:dot(f)*speed
        self.controls.sideMovement=direction:dot(right)*speed
    end
    return false,dist
end
local function driveUp(pos,z)
    if pos.z>=z then return true,0 end
    if setPitch(UP_PITCH) then self.controls.movement=1 end
    return false,z-pos.z
end
local function stalled(metric,dt)
    if phaseTime>C.phaseTimeout then return true end
    if not bestMetric or metric<bestMetric then bestMetric=metric end
    stallSample=stallSample+dt
    if stallSample>=0.25 then
        local span=stallSample; stallSample=0
        if sampleMetric and sampleMetric-bestMetric<1 then stallElapsed=stallElapsed+span
        else stallElapsed=0 end
        sampleMetric=bestMetric
    end
    return stallElapsed>=C.stallTime
end
local function blocked()
    if menuOpen() or core.isWorldPaused() then return 'menu' end
    if not supportedView() then return 'unsupported camera mode' end
    if not I.Controls or not I.Controls.overrideMovementControls then return 'missing Controls interface' end
    if Actor.isDead(self) then return 'dead' end
    if levitation()>0 then return 'already levitating' end
    if Actor.isSwimming(self) and not C.allowWater then return 'swimming disabled' end
    if Actor.getEncumbrance(self)>Actor.getCapacity(self) then return 'overencumbered' end
    if fatigue().current<C.minimumFatigue then return 'too tired' end
    if mag(core.magic.EFFECT_TYPE.Paralyze)>0 then return 'paralysed' end
end
local function fatigueMagnitude(a)
    local endurance=Actor.stats.attributes.endurance(self).modified
    local regen=core.getGMST('fFatigueReturnBase')+core.getGMST('fFatigueReturnMult')*endurance
    local extra=C.maxHangCost*(1-a/100)^2
    -- Integer static spell magnitudes; nearest rounding, not exact cancellation.
    local n=clamp(math.floor(regen+extra+0.5),0,100)
    log(string.format('Fatigue: regen=%.2f extra=%.2f selected Damage Fatigue=%d',regen,extra,n))
    return n
end
local function begin(p)
    settings.refresh()
    headMotionUsed=false
    plan=p; clearWindow(); missWatch,missSamples=0,0
    markerFailed=false; markGrip(); profileLedge()
    if C.ledgeMarkers then
        if p.hang then markCall(markers.set,'approach','approach',p.hang+util.vector3(0,0,60),'APPROACH CENTRE +60') end
        markCall(markers.set,'body','body',p.bodyHit,'BODY PROJECTION')
    end
    if debug then
        local h=p.hang or p.wall-p.fwd*C.wallClearance
        log(string.format('APPROACH PLAN projection=%.2f clearance=%.2f target=(%.2f,%.2f,%.2f) distance=%.2f',p.bodyProjection or 0,p.clearance or C.wallClearance,h.x,h.y,h.z,(h-p.start):length()))
    end
    -- getYaw uses object rotation convention: positive yaw towards +X.
    yawCentre=math.atan2(p.fwd.x,p.fwd.y)
    lockCamera()
    startCell=self.cell; startPos=self.position
    sessionTime,checkTime,totalTime=0,0,0
    -- A conservative grip position just outside the wall. Rise to an approximate
    -- hand-reach height, not yet synchronized to any custom animation.
    local hang=p.hang or (p.wall-p.fwd*C.wallClearance)
    hangPos=util.vector3(hang.x,hang.y,startPos.z)
    gripZ=math.max(startPos.z+C.hangRise,p.ledgeZ-C.handReach)
    targetZ=p.ledgeZ+C.topClearance
    shimmyTarget,shimmySign,shimmyBlocked,shimmyOrigin=nil,nil,nil,nil
    mountWasMoving,lastSupportPos=false,nil
    if gripZ>=targetZ then gripZ=targetZ-4 end
    shimmyRate=C.shimmySpeed*(0.6+0.4*athletics()/100)
    ownsControls=true
    I.Controls.overrideMovementControls(true)
    stopMotion()
    levId=spellId('lev',20)
    phase('arming'); armedNext='approach'
    apply(levId)
    if C.fatigueEnabled then
        local n=fatigueMagnitude(athletics())
        if n>0 then fatId=spellId('fat',n); apply(fatId) end
    end
    log(string.format('GRAB plan height=%.1f gripZ=%.1f targetZ=%.1f rays=%d clearance=%.1f detector=%s',p.height,gripZ,targetZ,raycasts,p.clearance or C.wallClearance,p.method or 'unknown'))
end
local function scan(originZ)
    local reason=blocked()
    if reason then if debug then log('Refused: '..reason) end; return false,true end
    local maxHeight=C.maxHeight
    if C.skillReach then
        local a=clamp(types.NPC.stats.skills.acrobatics(self).modified,0,100)
        maxHeight=math.max(C.minHeight,math.min(maxHeight,150+(maxHeight-150)*a/100))
    end
    -- Do not increase maximum world-space reach merely because the jump rose.
    if originZ then
        maxHeight=math.min(maxHeight,originZ+maxHeight-self.position.z)
        if maxHeight<C.minHeight then return false,false end
    end
    local p,why,n=detector.find(C.minHeight,maxHeight,C.allowWater)
    raycasts=raycasts+n
    if not p then
        if debug then log('SCAN miss: '..tostring(why)..' rays='..n..' (no climbing spell applied)') end
        return false,false
    end
    begin(p); return true,false
end
local function tangent() return util.vector3(plan.fwd.y,-plan.fwd.x,0) end
local function endShimmy(pos)
    if shimmyOrigin then
        local shift=tangent()*(pos-shimmyOrigin):dot(tangent())
        plan.wall=plan.wall+shift
        plan.hang=plan.hang+shift
        hangPos=pos
        markGrip(); markCall(markers.set,'approach','approach',nil,''); markCall(markers.set,'body','body',nil,''); markCall(markers.set,'higher','higher',nil,''); markCall(markers.set,'landing','landing',nil,''); markCall(markers.set,'blocked','blocked',nil,'')
    end
    shimmyOrigin,shimmyTarget,shimmySign=nil,nil,nil
    stopMotion()
end
local function shimmy(pos,dt)
    local sign=(input.isKeyPressed(input.KEY.D) and 1 or 0)-(input.isKeyPressed(input.KEY.A) and 1 or 0)
    if sign==0 or shimmySign and shimmySign~=sign then
        if shimmyOrigin then endShimmy(pos) end
        shimmyBlocked=nil
        if sign==0 then return end
    end
    if shimmyBlocked==sign then return end
    shimmyBlocked=nil
    if not shimmyTarget then
        local offset=tangent()*sign*C.shimmyStep
        local edge=plan.wall+offset
        -- Validate intermediate and endpoint sections. Preserve ledge normal;
        -- corners and changes of height require a fresh grab.
        if not countResult(detector.lip(plan,plan.wall+offset*0.5)) or not countResult(detector.lip(plan,edge)) then
            shimmyBlocked=sign
            if debug then log('SHIMMY stopped: ledge ends or changes height') end
            return
        end
        shimmyOrigin=pos; shimmySign=sign; shimmyTarget=pos+offset
        phaseTime,stallElapsed,stallSample=0,0,0; bestMetric,sampleMetric=nil,nil
    end
    if math.abs(pos.z-hangPos.z)>8 or math.abs((pos-shimmyOrigin):dot(plan.fwd))>8 then
        finish('Grip displaced during shimmy.'); return
    end
    local done,metric=driveXY(pos,shimmyTarget,shimmyRate,C.shimmyTolerance)
    if done or stalled(metric,dt) then
        if not done then shimmyBlocked=sign end
        endShimmy(pos)
    end
end
local function pullUp(continuous)
    if state~='hanging' or menuOpen() or core.isWorldPaused() then return end
    if shimmyOrigin then endShimmy(self.position) end
    local pos=self.position
    targetZ=plan.ledgeZ+C.topClearance
    plan.landingZ=nil
    -- The automatic attempt is at the original grip, already profiled on grab.
    if not continuous then profileLedge() end
    markCall(markers.set,'landing','landing',nil,''); markCall(markers.set,'blocked','blocked',nil,'')
    local candidate=countResult(detector.mountCandidate(plan,pos,targetZ))
    local function clearCandidate(c)
        if not c then return false end
        log(string.format('CANDIDATE depth=%.1f landingZ=%.1f targetZ=%.1f',c.depth or 0,c.landingZ,c.z))
        if C.ledgeMarkers then markCall(markers.set,'landing','landing',util.vector3(c.pos.x,c.pos.y,c.landingZ),'LANDING') end
        if countResult(detector.ascentClear(plan,pos,c.z)) then return true end
        local hit=detector.obstruction()
        if hit then
            log(string.format('CANDIDATE blocked at (%.1f,%.1f,%.1f)',hit.x,hit.y,hit.z))
            if C.ledgeMarkers then markCall(markers.set,'blocked','blocked',hit,'BLOCKED') end
        end
        return false
    end
    local accepted=clearCandidate(candidate)
    if not accepted and candidate and candidate.fallback then
        candidate=candidate.fallback; accepted=clearCandidate(candidate)
    end
    if accepted then
        markCall(markers.set,'blocked','blocked',nil,'')
        targetZ=candidate.z; plan.landingZ=candidate.landingZ
        if debug then log(string.format('MOUNT candidate landingZ=%.1f targetZ=%.1f',candidate.landingZ,targetZ)) end
    elseif continuous then
        return
    else
        if not countResult(detector.ascentClear(plan,pos,targetZ)) then
            local hit=detector.obstruction()
            if hit then
                log(string.format('ASCENT blocked at (%.1f,%.1f,%.1f)',hit.x,hit.y,hit.z))
                if C.ledgeMarkers then markCall(markers.set,'blocked','blocked',hit,'BLOCKED') end
            end
            notify('No upward clearance here. Move sideways or release.'); return
        end
        -- Uncertain standing geometry is not a reason to block a safe vertical
        -- ascent. Manual mounting remains bounded and requires actual support.
        markCall(markers.set,'landing','landing',nil,'')
        markCall(markers.set,'blocked','blocked',nil,'')
        if debug then log('MOUNT no predicted standing surface; bounded manual mount available') end
    end
    local f=fatigue(); local a=athletics()
    if f.current<math.max(C.minimumFatigue,C.fatigueEnabled and C.pullUpCost+1 or 0) then finish('Too exhausted to pull up.'); return end
    local ratio=clamp(f.current/math.max(1,f.base+f.modifier),0,1)
    local factor=0.25+0.75*ratio
    -- Magnitude is additive with Speed in native flying speed, not an exact
    -- multiplier on total movement speed. Quantized to the reusable spell bank.
    local desired=(1+a*0.5)*factor
    local n=clamp(math.floor(desired/5+0.5)*5,5,60)
    log(string.format('PULL UP athletics=%.1f fatigue=%.1f ratio=%.3f levitate=%d',a,f.current,ratio,n))
    if C.fatigueEnabled and C.pullUpCost>0 then
        f.current=math.max(0,f.current-C.pullUpCost)
    end
    local nextId=spellId('lev',n)
    if nextId~=levId then
        -- Apply replacement first; wait for it to be active before removing old.
        pendingLev=nextId
        phase('rescaling'); apply(pendingLev)
    else phase('ascending') end
    playStep(false)
end
local function startHeadMotion()
    if C.mantleHeadMotion and not headMotionUsed and camera.getMode()==camera.MODE.FirstPerson then
        headMotionUsed=true
        headMotion.start()
    end
end
local function updateMount(pos,dt,held)
    local depth=(pos-plan.wall):dot(plan.fwd)
    -- Check real support before the safety boundary. No selected candidate
    -- can terminate or slow motion. Support is sampled at actual feet.
    if depth>=-C.supportForwardReach and (not lastSupportPos or
        flat(pos-lastSupportPos):length()>math.max(0.001,C.mountProbeStep) or not held and mountWasMoving) then
        lastSupportPos=pos
        if countResult(detector.support(plan,pos)) then
            log(string.format('MOUNT support reached at depth %.2f',depth)); finish('Mantle complete.',true); return
        end
    end
    if pos.z<plan.ledgeZ-2 then finish('Lost vertical clearance.'); return end
    if depth>C.mountMaxDepth or math.abs(pos.z-targetZ)>15 then
        finish('Mount exceeded safe bounds.'); return
    end
    if not held then
        if mountWasMoving then
            stopMotion(); mountWasMoving=false; phase('above')
        end
        setPitch(savedPitch or camera.getPitch())
        return
    end
    if not mountWasMoving then
        mountWasMoving=true; lastSupportPos=nil; phase('mounting')
        startHeadMotion()
    end
    -- Only safety limit: no prevalidated destination, no deceleration.
    if stalled(C.mountMaxDepth-depth,dt) then
        finish('Mount obstructed or timed out.'); return
    end
    if setPitch(0) then
        local f=flatForward(); local right=util.vector3(f.y,-f.x,0)
        self.controls.movement=plan.fwd:dot(f)*C.mountSpeed
        self.controls.sideMovement=plan.fwd:dot(right)*C.mountSpeed
    end
end
local function update(dt)
    if dt<=0 then return end
    if state=='idle' then
        if cleanupLeft>0 then
            cleanupLeft=math.max(0,cleanupLeft-dt); cleanupWait=cleanupWait-dt
            if cleanupWait<=0 or cleanupLeft==0 then
                cleanupWait=0.1
                local remaining=#ownedSpells()
                if remaining>0 then removeSpells() end
                if ownsControls then I.Controls.overrideMovementControls(false); ownsControls=false end
                if (remaining==0 and cleanupLeft<=1.7) or cleanupLeft==0 then
                    cleanupLeft=0
                    log('CLEANUP verified remaining owned spells='..remaining..' total Levitate='..tostring(levitation()))
                    if remaining>0 or levitation()>0 then spellDiagnostics() end
                    if debug then pcall(fatigueDiagnostics,'cleanup') end
                end
            end
            return
        end
        -- Bounded diagnostics after an unsuccessful jump; not a flight-control loop.
        -- Never dispel unrelated levitation (potions, spells, other mods).
        if missSamples>0 then
            missWatch=missWatch-dt
            if missWatch<=0 then
                missSamples=missSamples-1; missWatch=0.55
                local owned=#ownedSpells(); local total=levitation()
                if owned>0 then
                    log('MISS WATCH: orphaned NativeClimb spells='..owned..' Levitate='..total)
                    spellDiagnostics(); removeSpells(); queueCleanup(); missSamples=0
                    return
                elseif total>0 then
                    log('MISS WATCH: non-owned Levitate='..total..'; no NativeClimb spell active')
                    spellDiagnostics(); missSamples=0
                elseif missSamples==0 then
                    log('MISS WATCH: no active Levitate or NativeClimb spells after missed Jump')
                end
            end
        end
        return
    end
    sessionTime=sessionTime+dt; totalTime=totalTime+dt
    if sessionTime>=C.maxSession then finish('Session safety timeout.'); return end
    if not supportedView() then finish('Unsupported view mode.'); return end
    if self.cell~=startCell then finish('Cell changed.'); return end
    if Actor.isDead(self) then finish('Actor dead.'); return end
    stopMotion()
    if menuOpen() or core.isWorldPaused() then return end
    phaseTime=phaseTime+dt
    if state=='arming' then
        if active(levId) and levitation()>0 and (not fatId or active(fatId)) then
            phase(armedNext)
        elseif phaseTime>2 then finish('Magic effects failed to activate.') end
        return
    elseif state=='rescaling' then
        if active(pendingLev) then
            local old=levId; levId=pendingLev; pendingLev=nil
            removeSpells(old); checkTime=0; phase('ascending')
        elseif phaseTime>2 then finish('Levitate replacement failed.') end
        return
    end
    checkTime=checkTime+dt
    if checkTime>=0.25 then
        checkTime=0
        if not active(levId) or levitation()<=0 or (fatId and not active(fatId)) then
            finish('Climbing effect lost.'); return
        end
        if fatigue().current<=0 or mag(core.magic.EFFECT_TYPE.Paralyze)>0 then finish('Grip lost.'); return end
        -- Detect an external Levitate effect gained after the grab. The selected
        -- spell may still overlap for one deferred update during replacement.
        local ownMagnitude=tonumber(levId:match('(%d+)$')) or 0
        if levitation()>ownMagnitude+0.1 then finish('External levitation detected.'); return end
    end
    if state=='hanging' then
        -- Own physical pitch throughout the climb, even when stationary.
        -- Controls override suppresses native pitchChange; use visible pitch.
        setPitch(savedPitch or camera.getPitch())
        if checkTime==0 and not shimmyOrigin and (self.position-hangPos):length()>20 then finish('Grip displaced.'); return end
        if shimmyTarget or input.isKeyPressed(input.KEY.A) or input.isKeyPressed(input.KEY.D) or shimmyBlocked then
            shimmy(self.position,dt)
        end
        return
    end
    local pos=self.position
    if pos.z<startPos.z-25 then finish('Fell during climb (levitation restriction or obstruction).'); return end
    if state=='approach' then
        local done,metric=driveXY(pos,hangPos)
        if done then phase('grabbing')
        elseif stalled(metric,dt) then
            log(string.format('APPROACH STALL remaining=%.2f planned clearance=%.2f current clearance=%.2f',metric,plan.clearance or 0,(plan.wall-pos):dot(plan.fwd)))
            finish('Approach obstructed: '..fmtDelta(pos,startPos)) end
    elseif state=='grabbing' then
        local done,metric=driveUp(pos,gripZ)
        if done then
            stopMotion(); hangPos=pos; phase('hanging')
            log('GRIP '..fmtDelta(pos,startPos))
            if C.continuousMantle and input.isKeyPressed(input.KEY.W) then pullUp(true) end
            if state=='hanging' then
                playStep(false); notify('Hanging. A/D shimmy; Space pull up; S/F8 release.')
            end
        elseif stalled(metric,dt) then finish('Grab ascent obstructed: '..fmtDelta(pos,startPos)) end
    elseif state=='ascending' then
        local done,metric=driveUp(pos,targetZ)
        if done then
            stopMotion(); log('ASCENT '..fmtDelta(pos,hangPos)); phase('above')
            mountWasMoving=false; lastSupportPos=pos
            -- If the actor is already over verified support, land without any forward input.
            if (pos-plan.wall):dot(plan.fwd)>=-C.supportForwardReach and countResult(detector.support(plan,pos)) then
                startHeadMotion()
                finish('Mantle complete (already supported).',true); return
            end
            if C.continuousMantle and input.isKeyPressed(input.KEY.W) then
                updateMount(pos,dt,true)
            else
                notify('Above ledge. Hold W to mount; S/F8 release.')
            end
        elseif stalled(metric,dt) then finish('Ascent obstructed: '..fmtDelta(pos,hangPos)) end
    elseif state=='above' or state=='mounting' then
        updateMount(pos,dt,input.isKeyPressed(input.KEY.W))
    else finish('Unexpected state '..tostring(state)) end
end
local function updateFrame(dt)
    if menuOpen() or core.isWorldPaused() then return end
    local climbPitch
    if state~='idle' then
        if yawCentre and C.yawLimit<360 then
            local maxYaw=math.rad(C.yawLimit/2)
            local delta=wrapAngle(camera.getYaw()-yawCentre)
            if math.abs(delta)>maxYaw then
                camera.setYaw(wrapAngle(yawCentre+clamp(delta,-maxYaw,maxYaw)))
            end
            local actorDelta=wrapAngle(self.rotation:getYaw()-yawCentre)
            if math.abs(actorDelta)>maxYaw then
                self.controls.yawChange=clamp(actorDelta,-maxYaw,maxYaw)-actorDelta
            end
        end
        if C.ledgeMarkers then markCall(markers.frame) end
        if pitchOwned and C.compensate then
            -- Keep mouse look independent of the physical pitch used for movement.
            if C.freePitch then
                savedPitch=clamp((savedPitch or 0)+input.getMouseMoveY()*C.mousePitchGain,
                    -math.rad(85),math.rad(85))
            end
            climbPitch=(savedPitch or 0)+(savedExtra or 0)-camera.getPitch()
        end
    end
    if headMotion.active then
        if camera.getMode()==camera.MODE.FirstPerson then
            headMotion.update(dt,climbPitch)
            return
        end
        headMotion.stop()
    end
    if climbPitch then camera.setExtraPitch(climbPitch) end
end
local function guarded(fn,...)
    local ok,err=pcall(fn,...)
    if not ok then log('ERROR '..tostring(err)); finish('Error; cleanup attempted.') end
end
hold=Hold.new{
    schedule=function(delay,fn)
        async:newUnsavableSimulationTimer(delay,function() guarded(fn) end)
    end,
    now=core.getSimulationTime,
    held=function() return input.isKeyPressed(input.KEY.Space) end,
    valid=function(attempt)
        return state=='idle' and cleanupLeft<=0 and not ownsControls and self.cell==attempt.cell
            and not menuOpen() and not core.isWorldPaused() and not bypassHeld()
    end,
    scan=function(attempt)
        if #ownedSpells()>0 then
            log('WARN leftover owned spells during armed grab; refusing climb')
            removeSpells(); queueCleanup(); return true
        end
        if not attempt.started then
            attempt.started=true
            if debug then log('HOLD armed; ledge search begins') end
        end
        local found,refused=scan(attempt.z)
        if not found and C.diagnoseMissedJump then missWatch,missSamples=0.15,2 end
        return found or refused
    end,
}
local function onSpace()
    -- Physical Space is the climb intent key; vanilla Jump remains untouched.
    -- Keep the press latch even when a grab succeeds so repeat events cannot pull up.
    if not hold.press() then return end
    if menuOpen() or core.isWorldPaused() then return end
    if state=='hanging' then pullUp(); return end
    if state~='idle' or cleanupLeft>0 or ownsControls or bypassHeld() then return end
    settings.refresh()
    raycasts=0; missWatch,missSamples=0,0
    hold.arm(C.grabHoldDelay,C.grabScanInterval,C.grabScanWindow,{cell=self.cell,z=self.position.z})
end
local function onKeyPress(key)
    if key.code==input.KEY.Space then onSpace(); return end
    if hold.isPending() and bypassHeld() then clearWindow() end
    if menuOpen() then return end
    if key.code==input.KEY.F8 or (key.code==input.KEY.S and state~='idle') then
        if state~='idle' or ownsControls then finish('Manual release.')
        elseif key.code==input.KEY.F8 then
            clearWindow(); spellDiagnostics(); removeSpells(); queueCleanup()
        end
    elseif key.code==input.KEY.F6 then
        local p=self.position
        log(string.format('STATUS %s pos=(%.2f,%.2f,%.2f) fatigue=%.2f levitate=%.2f rays=%d',state,p.x,p.y,p.z,fatigue().current,levitation(),raycasts))
        spellDiagnostics(); fatigueDiagnostics('F6')
    elseif key.code==input.KEY.F7 and state=='idle' then
        debug=not debug; notify('Debug scan logs '..(debug and 'ON' or 'OFF'))
    end
end
return {engineHandlers={
    onKeyPress=function(key) guarded(onKeyPress,key) end,
    onKeyRelease=function(key) if key.code==input.KEY.Space then hold.release() end end,
    onUpdate=function(dt)
        if state=='idle' and cleanupLeft<=0 and missSamples<=0 then return end
        guarded(update,dt)
    end,
    onFrame=function(dt)
        if state=='idle' and not headMotion.active then return end
        guarded(updateFrame,dt)
    end,
    onTeleported=function()
        clearWindow()
        if state~='idle' then guarded(finish,'Teleported; grip released.')
        else guarded(headMotion.stop) end
    end,
    onSave=function()
        return {active=state~='idle' or ownsControls,pitchOwned=pitchOwned,pitch=savedPitch,extra=savedExtra}
    end,
    onLoad=function(data)
        hold.sync(input.isKeyPressed(input.KEY.Space)); cleanupLeft=0; missWatch,missSamples=0,0
        guarded(headMotion.stop)
        if data and data.active then
            ownsControls=true; pitchOwned=data.pitchOwned or false; savedPitch=data.pitch; savedExtra=data.extra
            guarded(finish,'Saved climb released on load.')
        else
            guarded(removeSpells); queueCleanup()
        end
    end,
},eventHandlers={
    UiModeChanged=function()
        -- Cancel even if the menu opens and closes before a timer would fire.
        hold.sync(input.isKeyPressed(input.KEY.Space))
        guarded(headMotion.stop)
    end,
}}
