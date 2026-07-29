-------------------------------------------------------------------------------
--  EllesmereUI_InspectThrottle.lua
--
--  Shared "1 inspect request per unit per N seconds" queue, used by any
--  module that needs to resolve a group member's spec via NotifyInspect
--  (Interrupt Tracker, Party Cooldowns). Each caller gets its own instance
--  (own queue/cooldown state) via EllesmereUI.NewInspectThrottle(seconds) --
--  the state itself is not shared, only the implementation.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...

function EllesmereUI.NewInspectThrottle(throttleSeconds)
    local queue, cooldown = {}, {}
    local self = {}

    function self:Enqueue(unit)
        if not UnitExists(unit) or UnitIsUnit(unit, "player") then return end
        local guid = UnitGUID(unit)
        if not guid then return end
        local t = GetTime()
        if cooldown[guid] and (t - cooldown[guid]) < throttleSeconds then return end
        cooldown[guid] = t
        for _, u in ipairs(queue) do if u == unit then return end end
        queue[#queue + 1] = unit
    end

    function self:Process()
        if #queue == 0 then return end
        local unit = table.remove(queue, 1)
        if UnitExists(unit) then NotifyInspect(unit) end
    end

    return self
end
