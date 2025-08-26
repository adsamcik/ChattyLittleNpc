---@class ChattyLittleNpc
local CLN = LibStub("AceAddon-3.0"):GetAddon("ChattyLittleNpc")

---@class ReplayFrame
local ReplayFrame = CLN.ReplayFrame

local M = {}
ReplayFrame.ModelSceneRenderer = M

local function safeCall(obj, method, ...)
    if not (obj and method and obj[method]) then return nil end
    local ok, res = pcall(obj[method], obj, ...)
    if ok then return res end
    return nil
end

local function debugf(category, fmt, ...)
    local U = CLN and CLN.Utils
    if not (U and U.ShouldLogAnimDebug and U:ShouldLogAnimDebug(category) and U.LogAnimDebug) then return end
    local ok, msg = pcall(string.format, tostring(fmt), ...)
    if not ok then msg = tostring(fmt) end
    pcall(U.LogAnimDebug, U, category, msg)
end

-- Create a ModelScene + Actor backend or return nil on failure
function M.Create(parent)
    local ok, scene = pcall(CreateFrame, "ModelScene", nil, parent)
    if not (ok and scene) then return nil end
    -- Ensure the scene fills its parent host and renders above siblings
    safeCall(scene, "SetAllPoints", parent)
    if scene.SetFrameStrata then
        local strata = (parent and parent.GetFrameStrata and parent:GetFrameStrata()) or "HIGH"
        pcall(scene.SetFrameStrata, scene, strata)
    end
    if scene.SetFrameLevel and parent and parent.GetFrameLevel then
        pcall(scene.SetFrameLevel, scene, (parent:GetFrameLevel() or 0) + 1)
    end
    local actor
    if scene.CreateActor then
        local okA, a = pcall(scene.CreateActor, scene, "ModelSceneActorTemplate")
        if okA and a then actor = a end
        if not actor then
            local okB, b = pcall(scene.CreateActor, scene)
            if okB and b then actor = b end
        end
    end
    if not actor and scene.GetPlayerActor then
        local okP, a = pcall(scene.GetPlayerActor, scene)
        if okP and a then actor = a end
    end
    if not actor then
        local U = CLN and CLN.Utils
        if U and U.ShouldLogAnimDebug and U:ShouldLogAnimDebug("host") and U.LogAnimDebug then
            U:LogAnimDebug("host", "ModelSceneRenderer: failed to create/get actor")
        end
        return nil
    end
    if scene.Show then pcall(scene.Show, scene) end
    if actor.Show then pcall(actor.Show, actor) end
    if actor.SetUseCenterForOrigin then pcall(actor.SetUseCenterForOrigin, actor, true, true, true) end
    if scene.SetCameraNearClip then pcall(scene.SetCameraNearClip, scene, 0.1) end
    if scene.SetCameraFarClip then pcall(scene.SetCameraFarClip, scene, 100) end
    if scene.SetCameraFieldOfView then pcall(scene.SetCameraFieldOfView, scene, 0.8) end
    if scene.SetLightVisible then pcall(scene.SetLightVisible, scene, true) end
    if scene.SetLightDiffuseColor then pcall(scene.SetLightDiffuseColor, scene, 1, 1, 1) end
    if scene.SetLightAmbientColor then pcall(scene.SetLightAmbientColor, scene, 0.6, 0.6, 0.6) end
    if scene.SetLightType and _G.LE_MODEL_LIGHT_TYPE_DIRECTIONAL then
        pcall(scene.SetLightType, scene, _G.LE_MODEL_LIGHT_TYPE_DIRECTIONAL)
    end
    if scene.SetLightDirection then pcall(scene.SetLightDirection, scene, 0, -1, -0.5) end
    return { kind = "scene", frame = scene, actor = actor }
end

-- Attach the full scene-based API and camera utilities to host
function M.Attach(host, backend)
    host._backend = backend
    host._lastAnimId = nil
    host._zoom = host._zoom or 0.65
    host._camBaseZ = host._camBaseZ or 1.0
    host._camDist = host._camDist or 2.5
    host._camDir = host._camDir or 1
    host._compBias = host._compBias ~= nil and host._compBias or -0.25

    local function _normalize(x, y, z)
        local len = math.sqrt((x or 0)^2 + (y or 0)^2 + (z or 0)^2)
        if len <= 1e-6 then return 0, 0, 0, 0 end
        return x / len, y / len, z / len, len
    end
    local function _cross(ax, ay, az, bx, by, bz)
        return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
    end

    -- Forward declaration for projection helper used by coverage functions
    local _projectPoint

    -- Compute coverage stats and screen bbox for current camera
    local function _coverageStats(cx, cy, cz, sx, sy, sz, frameW, frameH)
        if backend.kind ~= "scene" or not (backend.frame and backend.frame.Project3DPointTo2D) then return 0, 0, nil, nil, nil, nil end
        local hx = (sx and sx > 0) and (sx * 0.5) or 1
        local hy = (sy and sy > 0) and (sy * 0.5) or 1
        local hz = (sz and sz > 0) and (sz * 0.5) or 1
        local yCenter = cy or 0
        local inside, total = 0, 0
        local minPX, minPY, maxPX, maxPY = 1/0, 1/0, -1/0, -1/0
        for sxn = -1, 1, 2 do
            for syn = -1, 1, 2 do
                for szn = -1, 1, 2 do
                    local x = (cx or 0) + sxn * hx
                    local y = yCenter + syn * hy
                    local z = (cz or 0) + szn * hz
                    local ok, px, py = _projectPoint(backend.frame, x, y, z)
                    total = total + 1
                    if ok then
                        if px < minPX then minPX = px end
                        if px > maxPX then maxPX = px end
                        if py < minPY then minPY = py end
                        if py > maxPY then maxPY = py end
                        if frameW and frameH and px >= 0 and px <= frameW and py >= 0 and py <= frameH then
                            inside = inside + 1
                        end
                    end
                end
            end
        end
        return inside, total, minPX, minPY, maxPX, maxPY
    end

    function host:_ScheduleCameraSnapshotLog(delay)
        delay = tonumber(delay) or 1.0
        if self._camLogTimer and self._camLogTimer.Cancel then
            pcall(self._camLogTimer.Cancel, self._camLogTimer)
        end
        if C_Timer and C_Timer.NewTimer then
            self._camLogTimer = C_Timer.NewTimer(delay, function()
                self._camLogTimer = nil
                if self._lastCamSnapshot then
                    local s = self._lastCamSnapshot
                    debugf("camera", "CameraFinalDelayed: pos=(%.2f,%.2f,%.2f) target=(%.2f,%.2f,%.2f) vfov=%.3f hfov=%.3f bounds=(cx=%.2f,cz=%.2f,sx=%.2f,sz=%.2f) dist=%.3f pad=%.2f axis=%s",
                        s.px or 0, s.py or 0, s.pz or 0, s.tx or 0, s.ty or 0, s.tz or 0,
                        s.vfov or 0, s.hfov or 0, s.cx or 0, s.cz or 0, s.sx or 0, s.sz or 0, s.dist or 0, s.pad or 0, tostring(s.axis))
                    local fw, fh = self:GetSize()
                    if self._DebugCheckProjection then
                        self:_DebugCheckProjection(s.cx, s.cy, s.cz, s.sx, s.sy, s.sz, fw, fh, s.pad)
                    end
                end
            end)
        elseif C_Timer and C_Timer.After then
            C_Timer.After(delay, function()
                self._camLogTimer = nil
                if self._lastCamSnapshot then
                    local s = self._lastCamSnapshot
                    debugf("camera", "CameraFinalDelayed: pos=(%.2f,%.2f,%.2f) target=(%.2f,%.2f,%.2f) vfov=%.3f hfov=%.3f bounds=(cx=%.2f,cz=%.2f,sx=%.2f,sz=%.2f) dist=%.3f pad=%.2f axis=%s",
                        s.px or 0, s.py or 0, s.pz or 0, s.tx or 0, s.ty or 0, s.tz or 0,
                        s.vfov or 0, s.hfov or 0, s.cx or 0, s.cz or 0, s.sx or 0, s.sz or 0, s.dist or 0, s.pad or 0, tostring(s.axis))
                    local fw, fh = self:GetSize()
                    if self._DebugCheckProjection then
                        self:_DebugCheckProjection(s.cx, s.cy, s.cz, s.sx, s.sy, s.sz, fw, fh, s.pad)
                    end
                end
            end)
        end
    end

    function host:_ApplyCameraLookAt(px, py, pz, tx, ty, tz)
        if backend.kind ~= "scene" or not backend.frame then return end
        if backend.frame.SetCameraPosition then
            pcall(backend.frame.SetCameraPosition, backend.frame, px, py, pz)
        end
        local fx, fy, fz = _normalize((tx or 0) - (px or 0), (ty or 0) - (py or 0), (tz or 0) - (pz or 0))
        if fx == 0 and fy == 0 and fz == 0 then fx, fy, fz = 0, 1, 0 end
        local upRefX, upRefY, upRefZ = 0, 0, 1
        if math.abs(fx * upRefX + fy * upRefY + fz * upRefZ) > 0.999 then upRefX, upRefY, upRefZ = 0, 1, 0 end
        local rx, ry, rz = _cross(fx, fy, fz, upRefX, upRefY, upRefZ)
        rx, ry, rz = _normalize(rx, ry, rz)
        local ux, uy, uz = _cross(rx, ry, rz, fx, fy, fz)
        if backend.frame.SetCameraOrientationByAxisVectors then
            pcall(backend.frame.SetCameraOrientationByAxisVectors, backend.frame, fx, fy, fz, rx, ry, rz, ux, uy, uz)
        elseif backend.frame.SetCameraOrientationByYawPitchRoll then
            local yaw = math.atan2(fy, fx)
            local pitch = math.atan2(fz, math.sqrt(fx * fx + fy * fy))
            pcall(backend.frame.SetCameraOrientationByYawPitchRoll, backend.frame, yaw, pitch, 0)
        end
        if self._logBasisOnce and backend.frame.GetCameraForward and backend.frame.GetCameraRight and backend.frame.GetCameraUp then
            local okF, ffx, ffy, ffz = pcall(backend.frame.GetCameraForward, backend.frame)
            local okR, rrx, rry, rrz = pcall(backend.frame.GetCameraRight, backend.frame)
            local okU, uux, uuy, uuz = pcall(backend.frame.GetCameraUp, backend.frame)
            if okF and okR and okU then
                local function dot(ax, ay, az, bx, by, bz) return ax * bx + ay * by + az * bz end
                local function len(ax, ay, az) return math.sqrt(ax * ax + ay * ay + az * az) end
                debugf("camera", "CamBasis: |f|=%.3f |r|=%.3f |u|=%.3f fr=%.3f fu=%.3f ru=%.3f",
                    len(ffx, ffy, ffz), len(rrx, rry, rrz), len(uux, uuy, uuz),
                    dot(ffx, ffy, ffz, rrx, rry, rrz), dot(ffx, ffy, ffz, uux, uuy, uuz), dot(rrx, rry, rrz, uux, uuy, uuz))
            end
            self._logBasisOnce = false
        end
    end

    function host:PointCameraAtHead()
        if backend.kind ~= "scene" or not backend.frame then return end
        local px, py, pz = 0, (host._camDir or 1) * (host._camDist or 2.5), (host._camBaseZ or 1.0)
        local tx, ty, tz = 0, 0, (host._camBaseZ or 1.0)
        self:_ApplyCameraLookAt(px, py, pz, tx, ty, tz)
    end

    local function _getVFOV(scene)
        if scene and scene.GetCameraFieldOfView then
            local ok, f = pcall(scene.GetCameraFieldOfView, scene)
            if ok and type(f) == "number" and f > 0.05 and f < 3.0 then return f end
        end
        return 0.8
    end

    local function _getBounds(actor)
        if not actor then return end
        local minX, minY, minZ, maxX, maxY, maxZ
        local function assign(a, b, c, d, e, f)
            if type(a) == "table" and type(b) == "table" then
                return a.x or 0, a.y or 0, a.z or 0, b.x or 0, b.y or 0, b.z or 0
            end
            if type(a) == "number" and type(b) == "number" and type(c) == "number" and type(d) == "number" and type(e) == "number" and type(f) == "number" then
                return a, b, c, d, e, f
            end
            return nil
        end
        if actor.GetMaxBoundingBox then
            local ok, a, b, c, d, e, f = pcall(actor.GetMaxBoundingBox, actor)
            if ok then
                local x1, y1, z1, x2, y2, z2 = assign(a, b, c, d, e, f)
                if x1 then minX, minY, minZ, maxX, maxY, maxZ = x1, y1, z1, x2, y2, z2 end
            end
        end
        if not minX and actor.GetActiveBoundingBox then
            local ok, a, b, c, d, e, f = pcall(actor.GetActiveBoundingBox, actor)
            if ok then
                local x1, y1, z1, x2, y2, z2 = assign(a, b, c, d, e, f)
                if x1 then minX, minY, minZ, maxX, maxY, maxZ = x1, y1, z1, x2, y2, z2 end
            end
        end
        if not minX and actor.GetModelBounds then
            local ok, a, b, c, d, e, f = pcall(actor.GetModelBounds, actor)
            if ok then
                local x1, y1, z1, x2, y2, z2 = assign(a, b, c, d, e, f)
                if x1 then minX, minY, minZ, maxX, maxY, maxZ = x1, y1, z1, x2, y2, z2 end
            end
        end
        if not minX then return end
        local cx, cy, cz = (minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5
        local sx, sy, sz = math.abs(maxX - minX), math.abs(maxY - minY), math.abs(maxZ - minZ)
        return cx, cy, cz, sx, sy, sz
    end

    local function _horizontalFOV(vfov, aspect)
        local t = math.tan(vfov * 0.5) * math.max(1e-3, aspect or 1)
        return 2 * math.atan(t)
    end

    function _projectPoint(scene, x, y, z)
        if not (scene and scene.Project3DPointTo2D) then return false end
        local ok, px, py = pcall(scene.Project3DPointTo2D, scene, x, y, z)
        if not ok then return false end
        if type(px) ~= "number" or type(py) ~= "number" then return false end
        if px ~= px or py ~= py then return false end
        return true, px, py
    end

    -- Guard helper to avoid propagating NaNs or infinities to camera state
    local function _finite(x, fb)
        if type(x) ~= "number" then return fb end
        if x ~= x or x == 1/0 or x == -1/0 then return fb end
        return x
    end

    function host:_DebugCheckProjection(cx, cy, cz, sx, sy, sz, frameW, frameH, pad)
        if backend.kind ~= "scene" or not (backend.frame and backend.frame.Project3DPointTo2D) then return end
        local okSize = (type(frameW) == "number" and frameW > 0 and type(frameH) == "number" and frameH > 0)
    local hx = (sx and sx > 0) and (sx * 0.5) or 1
    local hy = (sy and sy > 0) and (sy * 0.5) or 1
    local hz = (sz and sz > 0) and (sz * 0.5) or 1
    local yCenter = cy or 0
        local minPX, minPY, maxPX, maxPY = 1/0, 1/0, -1/0, -1/0
        local insideCount, total = 0, 0
        local anyProjected = false
        for sxn = -1, 1, 2 do
            for syn = -1, 1, 2 do
                for szn = -1, 1, 2 do
                    local x = (cx or 0) + sxn * hx
                    local y = yCenter + syn * hy
                    local z = (cz or 0) + szn * hz
                    local ok, px, py = _projectPoint(backend.frame, x, y, z)
                    total = total + 1
                    if ok then
                        anyProjected = true
                        if px < minPX then minPX = px end
                        if px > maxPX then maxPX = px end
                        if py < minPY then minPY = py end
                        if py > maxPY then maxPY = py end
                        if okSize and px >= 0 and px <= frameW and py >= 0 and py <= frameH then
                            insideCount = insideCount + 1
                        end
                    end
                end
            end
        end
        if not anyProjected then
            debugf("projection", "Proj2D bbox: projection unavailable; skipping bounds check")
            return
        end
        local verdict = okSize and (insideCount == total) and "IN" or "OUT"
        debugf("projection", "Proj2D bbox: min=(%.1f,%.1f) max=(%.1f,%.1f) frame=(%.0f,%.0f) inside=%d/%d pad=%.2f [%s]",
            minPX, minPY, maxPX, maxPY, frameW or -1, frameH or -1, insideCount, total, tonumber(pad) or 0, verdict)
    end

    -- Return inside coverage count for the current camera, using a simple AABB corner sampling
    local function _computeInsideCount(cx, cy, cz, sx, sy, sz, frameW, frameH)
        if backend.kind ~= "scene" or not (backend.frame and backend.frame.Project3DPointTo2D) then return 0, 0 end
        local hx = (sx and sx > 0) and (sx * 0.5) or 1
        local hy = (sy and sy > 0) and (sy * 0.5) or 1
        local hz = (sz and sz > 0) and (sz * 0.5) or 1
        local yCenter = cy or 0
        local inside, total = 0, 0
        for sxn = -1, 1, 2 do
            for syn = -1, 1, 2 do
                for szn = -1, 1, 2 do
                    local x = (cx or 0) + sxn * hx
                    local y = yCenter + syn * hy
                    local z = (cz or 0) + szn * hz
                    local ok, px, py = _projectPoint(backend.frame, x, y, z)
                    total = total + 1
                    if ok and frameW and frameH and px >= 0 and px <= frameW and py >= 0 and py <= frameH then
                        inside = inside + 1
                    end
                end
            end
        end
        return inside, total
    end

    function host:FlipFacing()
        self._frontYaw = (self._frontYaw or 0) + math.pi
        if backend.kind == "scene" and backend.actor and backend.actor.SetYaw then
            pcall(backend.actor.SetYaw, backend.actor, self._frontYaw)
        end
    end

    function host:FrameFullBodyFront_ClosedForm(paddingFrac)
        if backend.kind ~= "scene" or not (backend.frame and backend.actor) then return end
        local pad = tonumber(paddingFrac) or 0.10

        -- Frame size & aspect
        local w, h = self:GetSize()
        if not (w and h and w > 0 and h > 0) then w, h = 300, 150 end
        local aspect = w / h

        -- Helpers
        local function FOVPair_FromF(F, assumeHorizontal)
            if assumeHorizontal then
                local hf = _finite(F, 0.8)
                local vf = 2 * math.atan(math.tan(hf * 0.5) / math.max(1e-3, aspect))
                return _finite(vf, 0.8), _finite(hf, 0.8)
            else
                local vf = _finite(F, 0.8)
                local hf = 2 * math.atan(math.tan(vf * 0.5) * math.max(1e-3, aspect))
                return _finite(vf, 0.8), _finite(hf, 0.8)
            end
        end

        local function getFRaw(scene)
            if scene and scene.GetCameraFieldOfView then
                local ok, f = pcall(scene.GetCameraFieldOfView, scene)
                if ok and type(f) == "number" and f > 0.05 and f < 3.0 then return f end
            end
            return 0.8
        end

        local function solveAxis(axis, vfov, hfov, halfX, halfY, halfZ)
            -- Map world axes -> screen axes per spec
            local wHalf, hHalf, depthHalf
            if axis == "Y" then
                -- looking along ±Y → screen X uses X, screen Y uses Z, depth=Y
                wHalf     = halfX * (1 + pad)
                hHalf     = halfZ * (1 + pad)
                depthHalf = halfY
            else -- "X"
                -- looking along ±X → screen X uses Y, screen Y uses Z, depth=X
                wHalf     = halfY * (1 + pad)
                hHalf     = halfZ * (1 + pad)
                depthHalf = halfX
            end
            local dV = hHalf / math.max(1e-4, math.tan(vfov * 0.5))
            local dH = wHalf / math.max(1e-4, math.tan(hfov * 0.5))
            local dRect = math.max(dV, dH)
            local nearWanted = math.max(0.05, 0.02 * dRect)
            local safety = 0.25
            local d = math.max(dRect, depthHalf + nearWanted + safety)
            return d, dV, dH, depthHalf
        end

        -- Bounds
    local cx, cy, cz, sx, sy, sz = _getBounds(backend.actor)
        if not cx then
            -- Safe fallback aim (no NaNs)
            local distY = _finite(self._camDist or 2.5, 2.5)
            self._logBasisOnce = true
            self:_ApplyCameraLookAt(0, (self._camDir and self._camDir < 0) and -distY or distY, _finite(self._camBaseZ or 1.0, 1.0), 0, 0, _finite(self._camBaseZ or 1.0, 1.0))
            if backend.frame.SetCameraNearClip then pcall(backend.frame.SetCameraNearClip, backend.frame, math.max(0.05, 0.02 * distY)) end
            if backend.frame.SetCameraFarClip  then pcall(backend.frame.SetCameraFarClip,  backend.frame, distY + 20) end
            self._lastCamSnapshot = { px=0, py=distY, pz=(self._camBaseZ or 1.0), tx=0, ty=0, tz=(self._camBaseZ or 1.0), vfov=0, hfov=0, cx=0, cz=(self._camBaseZ or 1.0), sx=0, sz=0, dist=distY, pad=pad, axis="Y+" }
            self:_ScheduleCameraSnapshotLog(1.0)
            return
        end

        -- Half extents (guarded)
        local halfX = (sx and sx > 0) and (sx * 0.5) or 1
        local halfY = (sy and sy > 0) and (sy * 0.5) or 0
        local halfZ = (sz and sz > 0) and (sz * 0.5) or 1

    debugf("framing", "bounds: c=(%.2f,%.2f,%.2f) s=(%.2f,%.2f,%.2f) half=(%.2f,%.2f,%.2f)", cx or 0, cy or 0, cz or 0, sx or 0, sy or 0, sz or 0, halfX, halfY, halfZ)

        -- Read ambiguous FOV and create both interpretations
    local returnedF = getFRaw(backend.frame)
        local defaultAssumeHorizontal = (self._fovIsHorizontal == true)
        local vf_assumed, hf_assumed = FOVPair_FromF(returnedF, defaultAssumeHorizontal)
    debugf("framing", "fov: raw=%.3f assumeH=%s -> vfov=%.3f hfov=%.3f", returnedF or -1, tostring(defaultAssumeHorizontal), vf_assumed or -1, hf_assumed or -1)

        -- Closed-form: try both axes, pick smaller d
        local dY, dV_Y, dH_Y, depthHalfY = solveAxis("Y", vf_assumed, hf_assumed, halfX, halfY, halfZ)
        local dX, dV_X, dH_X, depthHalfX = solveAxis("X", vf_assumed, hf_assumed, halfX, halfY, halfZ)
        local axis, d, dV_sel, dH_sel, depthHalf =
            (dY <= dX) and "Y" or "X",
            (dY <= dX) and dY  or dX,
            (dY <= dX) and dV_Y or dV_X,
            (dY <= dX) and dH_Y or dH_X,
            (dY <= dX) and depthHalfY or depthHalfX

        d = _finite(d, self._camDist or 2.5)

        debugf("framing", "fit: axis=%s dV=%.3f dH=%.3f d=%.3f halfX=%.2f halfY=%.2f halfZ=%.2f aspect=%.3f",
            axis, dV_sel, dH_sel, d, halfX, halfY, halfZ, aspect)

        -- Initial target with composition bias
    local compBias = (self._compBias ~= nil) and self._compBias or -0.25
        local halfView = d * math.tan(vf_assumed * 0.5)
        local extra    = math.max(0, halfView - halfZ)
        local tz       = _finite(cz + compBias * extra, cz)
    local tx, ty   = _finite(cx, cx), _finite(cy, 0)

        debugf("framing", "aim0: cy=%.3f cz=%.3f halfView=%.3f halfZ=%.3f extra=%.3f compBias=%.3f tz=%.3f",
            cy or 0, cz, halfView, halfZ, extra, compBias, tz)

        -- Place camera along chosen axis with sign from self._camDir
        local sign = (self._camDir and self._camDir < 0) and -1 or 1
    local px, py, yaw
        if axis == "Y" then
            px, py, yaw = cx, (cy or 0) + sign * d, (sign > 0) and 0 or math.pi
        else
            px, py, yaw = cx + sign * d, (cy or 0), (sign > 0) and (-math.pi * 0.5) or (math.pi * 0.5)
        end
    debugf("framing", "place0: axis=%s sign=%d pos=(%.2f,%.2f,%.2f) target=(%.2f,%.2f,%.2f) yaw=%.2f", axis, sign, px or 0, py or 0, tz or 0, tx or 0, ty or 0, tz or 0, yaw or 0)

        -- Sanitize everything before apply
    px = _finite(px, cx);  py = _finite(py, (cy or 0))
        local pz = _finite(tz, cz)
        self._logBasisOnce = true
        self:_ApplyCameraLookAt(px, py, pz, tx, ty, tz)
        if backend.actor and backend.actor.SetYaw then
            pcall(backend.actor.SetYaw, backend.actor, (self._frontYaw or 0) + yaw)
        end

        local nearWanted = math.max(0.05, 0.02 * d)
        if backend.frame.SetCameraNearClip then pcall(backend.frame.SetCameraNearClip, backend.frame, nearWanted) end
        if backend.frame.SetCameraFarClip  then pcall(backend.frame.SetCameraFarClip,  backend.frame, math.max(40, d + depthHalf + pad * 2 + 20)) end

        self._camAxis  = axis .. ((sign > 0) and "+" or "-")
        self._camDist  = d
        self._camBaseZ = cz
        self._camDir   = sign
        self._lastCamSnapshot = {
            px=px, py=py, pz=pz, tx=tx, ty=ty, tz=tz,
            vfov=_finite(vf_assumed, 0.8), hfov=_finite(hf_assumed, 0.8),
            cx=cx, cy=cy, cz=cz, sx=sx, sy=sy, sz=sz, dist=d, pad=pad, axis=self._camAxis
        }

        -- Probe projector coverage (without relying on it if it's not ready)
    local inside, total, minPX, minPY, maxPX, maxPY = _coverageStats(cx, cy, cz, sx, sy, sz, w, h)
        local projectorReady = (minPX ~= 1/0 and minPY ~= 1/0 and maxPX ~= -1/0 and maxPY ~= -1/0)

        if projectorReady then
            debugf("framing", "bbox: min=(%.1f,%.1f) max=(%.1f,%.1f) frame=(%d,%d) inside=%d/%d",
                minPX, minPY, maxPX, maxPY, w, h, inside or 0, total or 0)
        else
            -- Optional first-paint cushion when projector is nil (keep it in the closed-form stage)
            local dCush = _finite(d * 1.03, d)
            if dCush ~= d then
                d = dCush
                local halfView2 = d * math.tan(vf_assumed * 0.5)
                local slack2    = math.max(0, halfView2 - halfZ)
                tz = _finite(cz + compBias * slack2, cz)
                if axis == "Y" then px, py = cx, (cy or 0) + sign * d else px, py = cx + sign * d, (cy or 0) end
                px=_finite(px,cx); py=_finite(py,(cy or 0)); pz=_finite(tz,cz)
                self:_ApplyCameraLookAt(px, py, pz, tx, ty, tz)
                if backend.frame.SetCameraNearClip then pcall(backend.frame.SetCameraNearClip, backend.frame, math.max(0.05, 0.02 * d)) end
                if backend.frame.SetCameraFarClip  then pcall(backend.frame.SetCameraFarClip,  backend.frame, math.max(40, d + depthHalf + pad * 2 + 20)) end
                self._camDist = d
                self._lastCamSnapshot.dist = d
                self._lastCamSnapshot.px, self._lastCamSnapshot.py, self._lastCamSnapshot.pz = px, py, pz
                self._lastCamSnapshot.tz = tz
            end
            debugf("projection", "proj: not ready; deferring correction pass (A/B/C)")
        end

        -- If projector is ready, do exactly one correction pass (A/B/C)
        if projectorReady and total and total > 0 then
            -- (A) FOV convention correction, one shot
            if inside and inside < total then
                local triedHorizontal = (self._fovIsHorizontal == true)
                local vf2, hf2 = FOVPair_FromF(returnedF, not triedHorizontal) -- swap convention
                debugf("framing", "FOV correction: swapping %s-FOV ↔ %s-FOV and re-solving (inside=%d/%d).",
                    triedHorizontal and "H" or "V", triedHorizontal and "V" or "H", inside or -1, total or -1)

                -- Re-solve and place again using the swapped pair
                dY, dV_Y, dH_Y, depthHalfY = solveAxis("Y", vf2, hf2, halfX, halfY, halfZ)
                dX, dV_X, dH_X, depthHalfX = solveAxis("X", vf2, hf2, halfX, halfY, halfZ)
                axis, d, dV_sel, dH_sel, depthHalf =
                    (dY <= dX) and "Y" or "X",
                    (dY <= dX) and dY  or dX,
                    (dY <= dX) and dV_Y or dV_X,
                    (dY <= dX) and dH_Y or dH_X,
                    (dY <= dX) and depthHalfY or depthHalfX
                d = _finite(d, self._camDist or 2.5)

                -- Aim again (bias kept)
                halfView = d * math.tan(vf2 * 0.5)
                extra    = math.max(0, halfView - halfZ)
                tz       = _finite(cz + compBias * extra, cz)
                if axis == "Y" then px, py, yaw = cx, (cy or 0) + sign * d, (sign > 0) and 0 or math.pi
                else px, py, yaw = cx + sign * d, (cy or 0), (sign > 0) and (-math.pi * 0.5) or (math.pi * 0.5) end
                px=_finite(px,cx); py=_finite(py,(cy or 0)); pz=_finite(tz,cz)
                self:_ApplyCameraLookAt(px, py, pz, tx, ty, tz)
                if backend.actor and backend.actor.SetYaw then
                    pcall(backend.actor.SetYaw, backend.actor, (self._frontYaw or 0) + yaw)
                end
                if backend.frame.SetCameraNearClip then pcall(backend.frame.SetCameraNearClip, backend.frame, math.max(0.05, 0.02 * d)) end
                if backend.frame.SetCameraFarClip  then pcall(backend.frame.SetCameraFarClip,  backend.frame, math.max(40, d + depthHalf + pad * 2 + 20)) end

                -- Snapshot + recompute coverage
                self._camAxis  = axis .. ((sign > 0) and "+" or "-")
                self._camDist  = d
                self._camBaseZ = cz
                self._lastCamSnapshot = {
                    px=px, py=py, pz=pz, tx=tx, ty=ty, tz=tz,
                    vfov=_finite(vf2, 0.8), hfov=_finite(hf2, 0.8),
                    cx=cx, cy=cy, cz=cz, sx=sx, sy=sy, sz=sz, dist=d, pad=pad, axis=self._camAxis
                }
                inside, total, minPX, minPY, maxPX, maxPY = _coverageStats(cx, cy, cz, sx, sy, sz, w, h)
                debugf("framing", "FOV post: bbox min=(%.1f,%.1f) max=(%.1f,%.1f) inside=%d/%d",
                    minPX or -1, minPY or -1, maxPX or -1, maxPY or -1, inside or -1, total or -1)

                -- Memoize convention *only* if projector confirms full fit
                if (minPX ~= 1/0 and maxPX ~= -1/0) and inside == total then
                    self._fovIsHorizontal = (not triedHorizontal) -- we swapped and it worked
                end
            else
                -- If the first assumption already produced a full fit, memoize it
                if inside == total then
                    self._fovIsHorizontal = defaultAssumeHorizontal
                end
            end

            -- (B) One-shot distance scale if bbox overfills
            if (minPX ~= 1/0 and minPY ~= 1/0 and maxPX ~= -1/0 and maxPY ~= -1/0) then
                local curW = math.max(1, (maxPX or 0) - (minPX or 0))
                local curH = math.max(1, (maxPY or 0) - (minPY or 0))
                local scale = math.max(curW / math.max(1, w), curH / math.max(1, h), 1.0)
                if scale > 1.001 then
                    local d2 = _finite(self._camDist or d, d) * scale
                    debugf("framing", "scale: overfill=%.3f -> factor=%.3f d:%.3f->%.3f", math.max(curW / math.max(1, w), curH / math.max(1, h)), scale, self._camDist or d, d2)
                    local vfFix = _finite(self._lastCamSnapshot and self._lastCamSnapshot.vfov or vf_assumed, vf_assumed)
                    local halfView2 = d2 * math.tan(vfFix * 0.5)
                    local slack2 = math.max(0, halfView2 - halfZ)
                    tz = _finite(cz + compBias * slack2, cz)
                    -- keep axis & sign
                    if axis == "Y" then px, py = cx, (cy or 0) + sign * d2 else px, py = cx + sign * d2, (cy or 0) end
                    px=_finite(px,cx); py=_finite(py,(cy or 0)); pz=_finite(tz,cz)
                    self:_ApplyCameraLookAt(px, py, pz, tx, ty, tz)
                    if backend.frame.SetCameraNearClip then pcall(backend.frame.SetCameraNearClip, backend.frame, math.max(0.05, 0.02 * d2)) end
                    if backend.frame.SetCameraFarClip  then pcall(backend.frame.SetCameraFarClip,  backend.frame, math.max(40, d2 + depthHalf + pad * 2 + 20)) end
                    self._camDist = d2
                    self._lastCamSnapshot.dist = d2
                    self._lastCamSnapshot.px, self._lastCamSnapshot.py, self._lastCamSnapshot.pz = px, py, pz
                    self._lastCamSnapshot.tz = tz
                    -- refresh coverage
                    inside, total, minPX, minPY, maxPX, maxPY = _coverageStats(cx, cy, cz, sx, sy, sz, w, h)
                    debugf("framing", "bbox: min=(%.1f,%.1f) max=(%.1f,%.1f) frame=(%d,%d) inside=%d/%d",
                        minPX, minPY, maxPX, maxPY, w, h, inside or 0, total or 0)
                end

                -- (C) One-shot vertical centering (exact), then reapply headroom
                local s = self._lastCamSnapshot
                -- Use actual axis-based distance to avoid any stale d
                local dFix
                if axis == "Y" then
                    dFix = math.abs(_finite((s and s.py), py) - _finite((s and s.ty), ty))
                else
                    dFix = math.abs(_finite((s and s.px), px) - _finite((s and s.tx), tx))
                end
                dFix = _finite(dFix, self._camDist or d)
                local vfFix = _finite((s and s.vfov) or vf_assumed, vf_assumed)
                local halfViewFix = dFix * math.tan(vfFix * 0.5)
                local midPix   = 0.5 * ((minPY or 0) + (maxPY or 0))
                local desired  = h * 0.5
                local dz_world = (desired - midPix) * (2 * halfViewFix / h)
                tz = _finite((s and s.tz) or cz, cz)
                local tz_before = tz
                -- Screen Y increases downward; to move content down, decrease tz
                tz = tz - dz_world
                tz = _finite(tz, cz)
                self:_ApplyCameraLookAt(_finite(s and s.px, px), _finite(s and s.py, py), tz, cx, (cy or 0), tz)
                if self._lastCamSnapshot then
                    self._lastCamSnapshot.tz = tz
                    self._lastCamSnapshot.pz = tz
                end
                debugf("framing", "center: curH=%.1f/%d mid=%.1f dz=%.2f -> tz=%.2f (dFix=%.3f halfView=%.3f)",
                    math.max(1, (maxPY or 0) - (minPY or 0)), h, midPix or -1, (tz - tz_before), tz, dFix or -1, halfViewFix or -1)

                -- One more micro-pass if still off (use fresh coverage)
                local in2, tot2, minPX2, minPY2, maxPX2, maxPY2 = _coverageStats(cx, cy, cz, sx, sy, sz, w, h)
                if (minPX2 ~= 1/0 and minPY2 ~= 1/0 and maxPX2 ~= -1/0 and maxPY2 ~= -1/0) then
                    local midPix2 = 0.5 * ((minPY2 or 0) + (maxPY2 or 0))
                    local dz2 = ( (h * 0.5) - midPix2 ) * (2 * halfViewFix / h)
                    if math.abs(dz2) > 0.05 then
                        -- Same sign convention as above
                        tz = _finite(tz - dz2, cz)
                        self:_ApplyCameraLookAt(_finite(s and s.px, px), _finite(s and s.py, py), tz, cx, (cy or 0), tz)
                        if self._lastCamSnapshot then
                            self._lastCamSnapshot.tz = tz
                            self._lastCamSnapshot.pz = tz
                        end
                        debugf("framing", "center micro: dz2=%.3f -> tz=%.2f", dz2, tz)
                    end
                    -- Final coverage check after centering
                    local finIn, finTot, finMinX, finMinY, finMaxX, finMaxY = _coverageStats(cx, cy, cz, sx, sy, sz, w, h)
                    debugf("framing", "center bbox: min=(%.1f,%.1f) max=(%.1f,%.1f) inside=%d/%d",
                        finMinX or -1, finMinY or -1, finMaxX or -1, finMaxY or -1, finIn or -1, finTot or -1)
                end
            end
        end

        -- Optional dev diagnostics (delayed)
        local U = CLN and CLN.Utils
        if U and U.ShouldLogAnimDebug and U:ShouldLogAnimDebug() then
            local fw, fh = self:GetSize()
            self:_DebugCheckProjection(cx, cy, cz, sx, sy, sz, fw, fh, pad)
        end
        self:_ScheduleCameraSnapshotLog(1.0)
    end

    -- Wrapper to keep old callsites; swap in an iterative debug variant here if you keep one around.
    function host:FrameFullBodyFront(paddingFrac)
        -- If you still have an old iterative solver, you can gate it here, e.g.:
        -- if self._useIterativeForDebug and self.FrameFullBodyFront_Iterative then
        --     return self:FrameFullBodyFront_Iterative(paddingFrac)
        -- end
        return self:FrameFullBodyFront_ClosedForm(paddingFrac)
    end

    function host:ClearModel()
        if backend.actor and backend.actor.ClearModel then pcall(backend.actor.ClearModel, backend.actor) end
    end

    function host:SetDisplayInfo(displayID)
        local a = backend.actor
        if a and a.SetModelByCreatureDisplayID then
            pcall(a.SetModelByCreatureDisplayID, a, displayID)
            local defer = false
            if a and a.IsLoaded then
                local okL, loadedL = pcall(a.IsLoaded, a)
                defer = (not okL) or (not loadedL)
            end
            if defer then self._cameraLogDefer = true end
            self:FrameFullBodyFront(0.12)
            if self._RefitWhenProjectorReady then self:_RefitWhenProjectorReady(0.12) end
            if self.OnModelLoadedOnce then
                self:OnModelLoadedOnce(function(h)
                    if h and h.FrameFullBodyFront then h:FrameFullBodyFront(0.12) end
                    if h and h._RefitWhenProjectorReady then h:_RefitWhenProjectorReady(0.12) end
                end)
            end
        else
            if self._SwitchToPlayerBackendAndApplyDisplay then
                self:_SwitchToPlayerBackendAndApplyDisplay(displayID)
            else
                error("ModelSceneRenderer: actor lacks SetModelByCreatureDisplayID")
            end
        end
    end

    function host:SetPortraitZoom(v)
        self._zoom = tonumber(v) or self._zoom or 0.65
        local z = self._zoom
        self._camDist = math.max(1.2, 3.2 - (z * 2.6))
        self:PointCameraAtHead()
    end

    function host:GetPortraitZoom()
        return self._zoom or 0.65
    end

    function host:SetPosition(x, y, z)
        local tz = tonumber(z) or 0
        host._camBaseZ = (host._camBaseZ or 1.0) + tz
        self:PointCameraAtHead()
    end

    function host:SetRotation(rad)
        if backend.actor and backend.actor.SetYaw then pcall(backend.actor.SetYaw, backend.actor, rad or 0) end
    end

    function host:SetAnimation(animId)
        self._lastAnimId = animId
        -- Respect ReplayFrame debug no-op animation mode
        local r = ReplayFrame
        if r and r._NoAnimDebugEnabled and r:_NoAnimDebugEnabled() then return end
        if backend.actor and backend.actor.SetAnimation then
            local okLoaded = backend.actor.IsLoaded and backend.actor:IsLoaded()
            if okLoaded or not backend.actor.IsLoaded then
                pcall(backend.actor.SetAnimation, backend.actor, animId)
            end
        end
    end

    function host:GetAnimation()
        return self._lastAnimId
    end

    function host:SetSheathed(b)
        -- Not generally supported on ModelScene actors; ignore
    end

    function host:SetPaused(b)
        if backend.actor and backend.actor.SetPaused then pcall(backend.actor.SetPaused, backend.actor, b and true or false) end
    end

    function host:SetUnit(unit)
        if backend.actor and backend.actor.SetModelByUnit then
            pcall(backend.actor.SetModelByUnit, backend.actor, unit, false, true)
            local defer = false
            if backend.actor and backend.actor.IsLoaded then
                local okL, loadedL = pcall(backend.actor.IsLoaded, backend.actor)
                defer = (not okL) or (not loadedL)
            end
            if defer then self._cameraLogDefer = true end
            self:FrameFullBodyFront(0.12)
            if self._RefitWhenProjectorReady then self:_RefitWhenProjectorReady(0.12) end
            if self.OnModelLoadedOnce then
                self:OnModelLoadedOnce(function(h)
                    if h and h.FrameFullBodyFront then h:FrameFullBodyFront(0.12) end
                    if h and h._RefitWhenProjectorReady then h:_RefitWhenProjectorReady(0.12) end
                end)
            end
        end
    end

    -- Schedule a one-shot refit once the 2D projector starts returning numbers
    function host:_RefitWhenProjectorReady(pad)
        if not (backend.frame and backend.frame.Project3DPointTo2D) then return end
        if self._refitScheduled then return end
        self._refitScheduled = true
        local tries, ticker = 0, nil
        ticker = C_Timer.NewTicker(0.05, function()
            tries = tries + 1
            local ok, px, py = pcall(backend.frame.Project3DPointTo2D, backend.frame, 0, 0, 0)
            if ok and type(px) == "number" and type(py) == "number" then
                if ticker and ticker.Cancel then ticker:Cancel() end
                self._refitScheduled = false
                if self.FrameFullBodyFront_ClosedForm then
                    self:FrameFullBodyFront_ClosedForm(pad or 0.12)
                end
            elseif tries > 40 then
                if ticker and ticker.Cancel then ticker:Cancel() end
                self._refitScheduled = false
            end
        end)
    end

    function host:AutoFitToFrame()
        local a = backend.actor
        if not a then return end
        local minX, minY, minZ, maxX, maxY, maxZ
        local function assign(a1, b1, c1, d1, e1, f1)
            if type(a1) == "table" and type(b1) == "table" then
                return a1.x or 0, a1.y or 0, a1.z or 0, b1.x or 0, b1.y or 0, b1.z or 0
            end
            if type(a1) == "number" and type(b1) == "number" and type(c1) == "number" and type(d1) == "number" and type(e1) == "number" and type(f1) == "number" then
                return a1, b1, c1, d1, e1, f1
            end
            return nil
        end
        if a.GetActiveBoundingBox then
            local ok, a1, b1, c1, d1, e1, f1 = pcall(a.GetActiveBoundingBox, a)
            if ok then
                local x1, y1, z1, x2, y2, z2 = assign(a1, b1, c1, d1, e1, f1)
                if x1 then minX, minY, minZ, maxX, maxY, maxZ = x1, y1, z1, x2, y2, z2 end
            end
        elseif a.GetModelBounds then
            local ok, a1, b1, c1, d1, e1, f1 = pcall(a.GetModelBounds, a)
            if ok then
                local x1, y1, z1, x2, y2, z2 = assign(a1, b1, c1, d1, e1, f1)
                if x1 then minX, minY, minZ, maxX, maxY, maxZ = x1, y1, z1, x2, y2, z2 end
            end
        end
        if minX and maxX then
            local sizeZ = math.abs((maxZ or 0) - (minZ or 0))
            if sizeZ > 0 and a.SetScale then
                local targetScale = 1.0
                if sizeZ > 2.0 then targetScale = 2.0 / sizeZ end
                pcall(a.SetScale, a, targetScale)
            end
        end
        self:PointCameraAtHead()
    end

    function host:OnModelLoadedOnce(cb)
        if type(cb) ~= "function" then return end
        if not (backend.actor and backend.actor.IsLoaded) then return end
        local a = backend.actor
        local ok, loaded = pcall(a.IsLoaded, a)
        if ok and loaded then cb(self); return end
        local ticker
        ticker = C_Timer.NewTicker(0.05, function()
            local ok2, loaded2 = pcall(a.IsLoaded, a)
            if ok2 and loaded2 then
                if ticker and ticker.Cancel then ticker:Cancel() end
                cb(self)
            end
        end)
    end

    function host:ApplyPreset(presetName)
        local name = tostring(presetName or "FullBody")
        local P = ReplayFrame and ReplayFrame.ScenePresets
        if P and P[name] then return P[name](self) end
        if name == "FullBody" then return self:FrameFullBodyFront(0.1) end
    end

    -- Keep scene visibility in sync with the host so the actor actually renders when shown
    if host.HookScript then
        host:HookScript("OnShow", function()
            local f, a = backend.frame, backend.actor
            -- Diagnostics: log visibility and z-order when becoming visible
            local U = CLN and CLN.Utils
            if U and U.ShouldLogAnimDebug and U:ShouldLogAnimDebug("host") and U.LogAnimDebug then
                local strata = f and f.GetFrameStrata and f:GetFrameStrata() or "?"
                local lvl = f and f.GetFrameLevel and f:GetFrameLevel() or -1
                local pStrata = host and host.GetFrameStrata and host:GetFrameStrata() or "?"
                local pLvl = host and host.GetFrameLevel and host:GetFrameLevel() or -1
                pcall(U.LogAnimDebug, U, "host", string.format("Host OnShow: host(shown=%s,vis=%s,strata=%s,level=%d) scene(shown=%s,vis=%s,strata=%s,level=%d) actor(shown=%s)",
                    tostring(host and host.IsShown and host:IsShown()), tostring(host and host.IsVisible and host:IsVisible()), tostring(pStrata), tonumber(pLvl) or -1,
                    tostring(f and f.IsShown and f:IsShown()), tostring(f and f.IsVisible and f:IsVisible()), tostring(strata), tonumber(lvl) or -1,
                    tostring(a and a.IsShown and a:IsShown())))
            end
            if f and f.Show then pcall(f.Show, f) end
            if a and a.Show then pcall(a.Show, a) end
        end)
        host:HookScript("OnHide", function()
            local f, a = backend.frame, backend.actor
            if a and a.Hide then pcall(a.Hide, a) end
            if f and f.Hide then pcall(f.Hide, f) end
        end)
    end
end

