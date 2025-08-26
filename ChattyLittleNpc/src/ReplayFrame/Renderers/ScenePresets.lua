---@class ChattyLittleNpc
local CLN = LibStub("AceAddon-3.0"):GetAddon("ChattyLittleNpc")

---@class ReplayFrame
local ReplayFrame = CLN.ReplayFrame

-- Scene (ModelScene + Actor) renderer preset implementations
-- Exposes: ReplayFrame.ScenePresets with functions(host, paddingFrac) -> ()

ReplayFrame = ReplayFrame or {}
ReplayFrame.ScenePresets = {}
local P = ReplayFrame.ScenePresets

-- Contract: host is a ModelHost created with scene backend (kind == "scene").
-- Functions position camera and yaw. They should be robust to missing bounds.

local function getVFOV(scene)
    if scene and scene.GetCameraFieldOfView then
        local ok, f = pcall(scene.GetCameraFieldOfView, scene)
        if ok and type(f) == "number" and f > 0.05 and f < 3.0 then return f end
    end
    return 0.8
end

local function getHFOV(scene, vfov, aspect)
    local t = math.tan((vfov or 0.8) * 0.5) * math.max(1e-3, aspect or 1)
    return 2 * math.atan(t)
end

local function project(scene, x, y, z)
    if not (scene and scene.Project3DPointTo2D) then return false end
    local ok, px, py = pcall(scene.Project3DPointTo2D, scene, x, y, z)
    if not ok or type(px) ~= "number" or type(py) ~= "number" or px ~= px or py ~= py then return false end
    return true, px, py
end

local function getBounds(actor)
    if not actor then return end
    local function assign(a,b,c,d,e,f)
        if type(a)=="table" and type(b)=="table" then return a.x or 0,a.y or 0,a.z or 0,b.x or 0,b.y or 0,b.z or 0 end
        if type(a)=="number" and type(f)=="number" then return a,b,c,d,e,f end
    end
    local minX,minY,minZ,maxX,maxY,maxZ
    if actor.GetMaxBoundingBox then
        local ok,a,b,c,d,e,f = pcall(actor.GetMaxBoundingBox, actor)
        if ok then
            local x1,y1,z1,x2,y2,z2 = assign(a,b,c,d,e,f)
            if x1 then minX,minY,minZ,maxX,maxY,maxZ = x1,y1,z1,x2,y2,z2 end
        end
    end
    if not minX and actor.GetActiveBoundingBox then
        local ok,a,b,c,d,e,f = pcall(actor.GetActiveBoundingBox, actor)
        if ok then
            local x1,y1,z1,x2,y2,z2 = assign(a,b,c,d,e,f)
            if x1 then minX,minY,minZ,maxX,maxY,maxZ = x1,y1,z1,x2,y2,z2 end
        end
    end
    if not minX and actor.GetModelBounds then
        local ok,a,b,c,d,e,f = pcall(actor.GetModelBounds, actor)
        if ok then
            local x1,y1,z1,x2,y2,z2 = assign(a,b,c,d,e,f)
            if x1 then minX,minY,minZ,maxX,maxY,maxZ = x1,y1,z1,x2,y2,z2 end
        end
    end
    if not minX then return end
    local cx,cy,cz = (minX+maxX)*0.5,(minY+maxY)*0.5,(minZ+maxZ)*0.5
    local sx,sy,sz = math.abs(maxX-minX), math.abs(maxY-minY), math.abs(maxZ-minZ)
    return cx,cy,cz,sx,sy,sz
end

-- Helper to call the host’s look-at
local function lookAt(host, px,py,pz, tx,ty,tz)
    if host and host._ApplyCameraLookAt then host:_ApplyCameraLookAt(px,py,pz, tx,ty,tz) end
end

-- Shared distance solve based on bounds and FOV
local function solveDistance(scene, cx,cz, sx,sz, pad)
    local w,h = scene:GetSize()
    if not (w and h and w>0 and h>0) then w,h = 300,150 end
    local vfov = getVFOV(scene)
    local hfov = getHFOV(scene, vfov, w/h)
    local halfH = math.max(1e-3, (sz>0 and sz*0.5 or 1) * (1 + (pad or 0)))
    local halfW = math.max(1e-3, (sx>0 and sx*0.5 or 1) * (1 + (pad or 0)))
    local dV = halfH / math.tan(vfov*0.5)
    local dH = halfW / math.tan(hfov*0.5)
    return math.max(dV, dH), vfov, hfov
end

-- Preset: Full Body
function P.FullBody(host, pad)
    local b = host._backend; if not (b and b.kind=="scene") then return end
    local cx,_,cz,sx,sy,sz = getBounds(b.actor)
    if not cx then host:PointCameraAtHead(); return end
    local d,vfov = solveDistance(b.frame, cx,cz,sx,sz, pad or 0.1)
    local halfView = d*math.tan(vfov*0.5)
    local extra = math.max(0, halfView - (sz*0.5))
    local bias = host._compBias or -0.25
    local tz = cz + bias*extra
    local px,py,pz = cx, d, tz
    if b.actor and b.actor.SetYaw then pcall(b.actor.SetYaw, b.actor, host._frontYaw or 0) end
    lookAt(host, px,py,pz, cx,0,tz)
end

-- Preset: Upper Body (closer crop)
function P.UpperBody(host, pad)
    local b = host._backend; if not (b and b.kind=="scene") then return end
    local cx,_,cz,sx,sy,sz = getBounds(b.actor)
    if not cx then host:PointCameraAtHead(); return end
    local d,vfov = solveDistance(b.frame, cx,cz,sx,sz, (pad or 0.05))
    d = d * 0.55 -- closer
    local halfView = d*math.tan(vfov*0.5)
    local extra = math.max(0, halfView - (sz*0.5))
    local tz = cz + (host._compBias or -0.2) * extra
    if b.actor and b.actor.SetYaw then pcall(b.actor.SetYaw, b.actor, host._frontYaw or 0) end
    lookAt(host, cx, d, tz, cx, 0, tz)
end

-- Preset: Wave (slight zoom-out with more top verticality)
function P.Wave(host, pad)
    local b = host._backend; if not (b and b.kind=="scene") then return end
    local cx,_,cz,sx,sy,sz = getBounds(b.actor)
    if not cx then host:PointCameraAtHead(); return end
    local d,vfov = solveDistance(b.frame, cx,cz,sx,sz, (pad or 0.15))
    d = d * 1.1 -- step back a bit
    local halfView = d*math.tan(vfov*0.5)
    local extra = math.max(0, halfView - (sz*0.5))
    local tz = cz + math.min(0.4, math.max(-0.4, (host._compBias or -0.15))) * extra
    if b.actor and b.actor.SetYaw then pcall(b.actor.SetYaw, b.actor, host._frontYaw or 0) end
    lookAt(host, cx, d, tz, cx, 0, tz)
end

return P
