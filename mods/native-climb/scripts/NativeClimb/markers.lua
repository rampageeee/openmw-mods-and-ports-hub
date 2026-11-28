-- Screen-space diagnostics only. No world objects or collision queries.
local camera=require('openmw.camera')
local util=require('openmw.util')
local ui=require('openmw.ui')
local M={}
local points={}
local slots={grip=0,higher=1,landing=2,blocked=3,approach=4,body=5}
local colors={grip=util.color.rgb(1,.75,.22),higher=util.color.rgb(.38,.75,1),landing=util.color.rgb(.35,1,.48),blocked=util.color.rgb(1,.35,.3),approach=util.color.rgb(.9,.65,1),body=util.color.rgb(1,.55,.25)}
local function destroy(k)
    local e=points[k]
    points[k]=nil
    if e and e.widget then pcall(function() e.widget:destroy() end) end
end
function M.clear()
    for k in pairs(points) do destroy(k) end
end
function M.set(k,kind,pos,label)
    destroy(k)
    if not pos then return end
    local text=string.format('+ %s (Z %.1f)',label,pos.z)
    local widget=ui.create{layer='HUD',type=ui.TYPE.Text,props={
        relativePosition=util.vector2(0,0),anchor=util.vector2(.5,.5),
        text=text,textSize=18,textColor=colors[kind],textShadow=true,visible=false}}
    points[k]={pos=pos,widget=widget,text=text,slot=slots[kind] or 0}
    print(string.format("[NativeClimb] MARKER %s world=(%.1f,%.1f,%.1f)",label,pos.x,pos.y,pos.z))
end
function M.frame()
    if not next(points) then return end
    local cp=camera.getPosition()
    local forward=camera.viewportToWorldVector(util.vector2(.5,.5))
    -- 0.51 returns pixel coordinates, NOT normalized viewport coordinates.
    -- ui.screenSize uses the same resolution settings as the C++ projection.
    local screen=ui.screenSize()
    if screen.x<=0 or screen.y<=0 then return end
    for _,e in pairs(points) do
        local p=camera.worldToViewportVector(e.pos)
        local x,y=p.x/screen.x,p.y/screen.y
        local props=e.widget.layout.props
        local visible=(e.pos-cp):dot(forward)>0 and x>=0 and x<=1 and y>=0 and y<=1
        props.visible=true
        if visible then
            props.relativePosition=util.vector2(x,y)
            props.anchor=util.vector2(.5,.5)
            props.text=e.text
        else
            -- Explicit diagnostic fallback, not a projected world marker.
            props.relativePosition=util.vector2(.025,.20+e.slot*.04)
            props.anchor=util.vector2(0,0)
            props.text=e.text..' [off screen]'
        end
        e.widget:update()
    end
end
return M
