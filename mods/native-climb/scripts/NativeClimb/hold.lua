-- Input-only arming controller. Inject timer scheduler and callbacks for offline tests.
local M={}
function M.new(opts)
    local generation,down,pending=0,false,false
    local H={}
    function H.cancel()
        generation=generation+1; pending=false
    end
    function H.release()
        H.cancel(); down=false
    end
    function H.sync(held)
        H.cancel(); down=held and true or false
    end
    function H.isPending() return pending end
    function H.press()
        if down then return false end
        down=true; return true
    end
    function H.arm(delay,interval,window,attempt)
        H.cancel(); pending=true
        local token=generation
        local first=nil
        local function tick()
            if token~=generation or not pending then return end
            if not down or not opts.held() or not opts.valid(attempt) then H.cancel(); return end
            local now=opts.now()
            first=first or now
            if now-first>window+0.000001 then H.cancel(); return end
            local stop=opts.scan(attempt)
            if token~=generation or not pending then return end
            if stop then H.cancel(); return end
            -- Use elapsed simulation time, not an accumulating key-repeat count.
            if now-first+interval>window+0.000001 then H.cancel(); return end
            opts.schedule(interval,tick)
        end
        opts.schedule(delay,tick)
    end
    return H
end
return M
