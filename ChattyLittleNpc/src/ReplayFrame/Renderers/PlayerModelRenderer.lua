---@class ChattyLittleNpc
local CLN = LibStub("AceAddon-3.0"):GetAddon("ChattyLittleNpc")

---@class ReplayFrame
local ReplayFrame = CLN.ReplayFrame

local M = {}
ReplayFrame.PlayerModelRenderer = M

local function safeCall(obj, method, ...)
    if not (obj and method and obj[method]) then return nil end
    local ok, res = pcall(obj[method], obj, ...)
    if ok then return res end
    return nil
end

local function debugf(fmt, ...)
    local U = CLN and CLN.Utils
    if not (U and U.ShouldLogAnimDebug and U:ShouldLogAnimDebug() and U.LogAnimDebug) then return end
    local ok, msg = pcall(string.format, tostring(fmt), ...)
    if not ok then msg = tostring(fmt) end
    pcall(U.LogAnimDebug, U, msg)
end

-- Create a PlayerModel backend (frame)
function M.Create(parent)
    local pm = CreateFrame("PlayerModel", nil, parent)
    pm:SetAllPoints(parent)
    return { kind = "player", frame = pm }
end

-- Attach a PlayerModel-like API to host that wraps the backend PlayerModel
function M.Attach(host, backend)
    host._backend = backend
    host._zoom = host._zoom or 0.65
    host._lastAnimId = nil

    function host:ClearModel()
        safeCall(backend.frame, "ClearModel")
    end

    function host:SetDisplayInfo(displayID)
        safeCall(backend.frame, "SetDisplayInfo", displayID)
    end

    function host:SetPortraitZoom(v)
        self._zoom = tonumber(v) or self._zoom or 0.65
        safeCall(backend.frame, "SetPortraitZoom", self._zoom)
    end

    function host:GetPortraitZoom()
        return self._zoom or 0.65
    end

    function host:SetPosition(x, y, z)
        safeCall(backend.frame, "SetPosition", x, y, z)
    end

    function host:SetRotation(rad)
        safeCall(backend.frame, "SetRotation", rad)
    end

    function host:SetAnimation(animId)
        self._lastAnimId = animId
    -- Respect ReplayFrame debug no-op animation mode
    local r = ReplayFrame
    if r and r._NoAnimDebugEnabled and r:_NoAnimDebugEnabled() then return end
    safeCall(backend.frame, "SetAnimation", animId)
    end

    function host:GetAnimation()
        return safeCall(backend.frame, "GetAnimation") or self._lastAnimId
    end

    function host:SetSheathed(b)
        safeCall(backend.frame, "SetSheathed", b and true or false)
    end

    function host:SetPaused(b)
        safeCall(backend.frame, "SetPaused", b and true or false)
    end

    function host:SetUnit(unit)
        safeCall(backend.frame, "SetUnit", unit)
    end

    -- Compatibility stubs used by presets/code calling scene-style helpers
    function host:PointCameraAtHead() end
    function host:FrameFullBodyFront()
        -- best-effort: use a reasonable zoom
        if self.SetPortraitZoom then self:SetPortraitZoom(self._zoom or 0.65) end
    end
    function host:FlipFacing() end
    function host:AutoFitToFrame() end
    function host:OnModelLoadedOnce(cb)
        if type(cb) == "function" then cb(self) end
    end

    function host:ApplyPreset(presetName)
        local name = tostring(presetName or "FullBody")
        local P = ReplayFrame and ReplayFrame.PlayerPresets
        if P and P[name] then return P[name](self) end
        -- Fallbacks
        if name == "FullBody" then return self:FrameFullBodyFront(0.1) end
    end

    -- Keep backend visibility in sync with the host so it actually renders when shown
    if host.HookScript then
        host:HookScript("OnShow", function()
            if backend.frame and backend.frame.Show then pcall(backend.frame.Show, backend.frame) end
        end)
        host:HookScript("OnHide", function()
            if backend.frame and backend.frame.Hide then pcall(backend.frame.Hide, backend.frame) end
        end)
    end
end

