-- Settings are sampled on Space press and once per grab, never polled during ordinary gameplay.
local I = require('openmw.interfaces')
local storage = require('openmw.storage')
local C = require('scripts.NativeClimb.config')
local M={}
local key='SettingsNativeClimb'
local section
local defaults={ledgeMarkers=C.ledgeMarkers,preferBackedLanding=C.preferBackedLanding,freePitch=C.freePitch,yawLimit=C.yawLimit,mousePitchGain=C.mousePitchGain,grabHoldDelay=C.grabHoldDelay,grabScanInterval=C.grabScanInterval,grabScanWindow=C.grabScanWindow,mantleHeadMotion=C.mantleHeadMotion}
if I.Settings then
    local ok,err=pcall(function()
        I.Settings.registerPage{key='NativeClimb',l10n='NativeClimb',name='pageName',description='pageDescription'}
        I.Settings.registerGroup{key=key,page='NativeClimb',l10n='NativeClimb',name='groupName',permanentStorage=true,settings={
            {key='grabHoldDelay',renderer='number',name='grabHoldDelay',description='grabHoldDelayDesc',default=defaults.grabHoldDelay,argument={min=0.1,max=1.5}},
            {key='grabScanInterval',renderer='number',name='grabScanInterval',description='grabScanIntervalDesc',default=defaults.grabScanInterval,argument={min=0.1,max=0.5}},
            {key='grabScanWindow',renderer='number',name='grabScanWindow',description='grabScanWindowDesc',default=defaults.grabScanWindow,argument={min=0,max=2}},
            {key='mantleHeadMotion',renderer='checkbox',name='mantleHeadMotion',description='mantleHeadMotionDesc',default=defaults.mantleHeadMotion},
            {key='ledgeMarkers',renderer='checkbox',name='ledgeMarkers',description='ledgeMarkersDesc',default=defaults.ledgeMarkers},
            {key='preferBackedLanding',renderer='checkbox',name='preferBackedLanding',description='preferBackedLandingDesc',default=defaults.preferBackedLanding},
            {key='freePitch',renderer='checkbox',name='freePitch',description='freePitchDesc',default=defaults.freePitch},
            {key='yawLimit',renderer='number',name='yawLimit',description='yawLimitDesc',default=defaults.yawLimit,argument={min=60,max=360,integer=true}},
            {key='mousePitchGain',renderer='number',name='mousePitchGain',description='mousePitchGainDesc',default=defaults.mousePitchGain*256,argument={min=-5,max=5}},
        }}
        section=storage.playerSection(key)
    end)
    if not ok then print('[NativeClimb] Settings unavailable; using config.lua: '..tostring(err)) end
end
function M.refresh()
    if not section then return end
    for _,k in ipairs({'ledgeMarkers','preferBackedLanding','freePitch','yawLimit','mousePitchGain','grabHoldDelay','grabScanInterval','grabScanWindow','mantleHeadMotion'}) do
        local v=section:get(k)
        if k=='grabHoldDelay' then
            if type(v)=='number' then C[k]=math.max(0.1,math.min(1.5,v)) end
        elseif k=='grabScanInterval' then
            if type(v)=='number' then C[k]=math.max(0.1,math.min(0.5,v)) end
        elseif k=='grabScanWindow' then
            if type(v)=='number' then C[k]=math.max(0,math.min(2,v)) end
        elseif k=='mousePitchGain' then
            if type(v)=='number' then C[k]=math.max(-5,math.min(5,v))/256 end
        elseif k=='yawLimit' then
            if type(v)=='number' then C[k]=math.max(60,math.min(360,v)) end
        elseif type(v)=='boolean' then C[k]=v end
    end
end
return M
