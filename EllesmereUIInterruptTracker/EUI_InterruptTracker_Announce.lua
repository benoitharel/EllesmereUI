if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_InterruptTracker_Announce.lua
--
--  Kick rotation sync: /skr slash commands and inter-addon rotation
--  broadcast/receive via the "EUI_KR" addon message prefix.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
if _G._EIT_Announce_Loaded then return end
_G._EIT_Announce_Loaded = true

-------------------------------------------------------------------------------
--  Register rotation-sync prefix up front (safe to call at file load)
-------------------------------------------------------------------------------
C_ChatInfo.RegisterAddonMessagePrefix("EUI_KR")

-------------------------------------------------------------------------------
--  BroadcastRotation  —  send the configured kick rotation to the group.
--  Only the group leader or a raid officer may broadcast.
-------------------------------------------------------------------------------
local function BroadcastRotation()
    if InCombatLockdown() then
        print("|cff0cd29f[Interrupt Tracker]|r Cannot sync rotation while in combat.")
        return
    end
    if not (UnitIsGroupLeader("player") or UnitIsRaidOfficer("player")) then
        print("|cff0cd29f[Interrupt Tracker]|r Only the group leader or raid officer can sync the rotation.")
        return
    end
    if not (IsInGroup() or IsInRaid()) then
        print("|cff0cd29f[Interrupt Tracker]|r Must be in a group to sync the rotation.")
        return
    end

    local db = ns.GetDB and ns.GetDB()
    if not db or not db.profile then return end
    local rotation = db.profile.kickRotation
    if not rotation or #rotation == 0 then
        print("|cff0cd29f[Interrupt Tracker]|r No kick rotation configured.")
        return
    end

    local payload = "ROTATION:" .. table.concat(rotation, ":")
    C_ChatInfo.SendAddonMessage("EUI_KR", payload, "PARTY")
    print(string.format("|cff0cd29f[Interrupt Tracker]|r Kick rotation synced (%d players).", #rotation))
end

-------------------------------------------------------------------------------
--  Slash commands: /synckickrotation and /skr
-------------------------------------------------------------------------------
SLASH_EUITKR1 = "/synckickrotation"
SLASH_EUITKR2 = "/skr"
SlashCmdList.EUITKR = function()
    C_Timer.After(0, BroadcastRotation)
end

-------------------------------------------------------------------------------
--  Receive rotation sync from a group leader / officer
-------------------------------------------------------------------------------
local addonMsgFrame = CreateFrame("Frame")
addonMsgFrame:RegisterEvent("CHAT_MSG_ADDON")
addonMsgFrame:SetScript("OnEvent", function(self, event, prefix, payload, channel, sender)
    if prefix ~= "EUI_KR" then return end
    if not payload or payload:sub(1, 9) ~= "ROTATION:" then return end

    -- Ignore messages that originated from this client
    local playerName  = UnitName("player")
    local senderShort = Ambiguate(sender, "short")
    if senderShort == playerName then return end

    -- Verify the sender is actually in the group (basic sanity check).
    -- UnitName can hand back a SECRET string for a group member; comparing one
    -- is not an addon-side operation, so the roster name is skipped rather than
    -- matched when it comes back secret.
    local isSecret = issecretvalue or function() return false end
    local function RosterMatches(unit)
        local n = UnitName(unit)
        if n == nil or isSecret(n) then return false end
        return Ambiguate(n, "short") == senderShort
    end

    local inGroup = false
    local prefixToken = IsInRaid() and "raid" or (IsInGroup() and "party" or nil)
    if prefixToken then
        for i = 1, GetNumGroupMembers() do
            if RosterMatches(prefixToken .. i) then inGroup = true; break end
        end
    end
    if not inGroup then return end

    local db = ns.GetDB and ns.GetDB()
    if not db or not db.profile then return end

    -- Parse "ROTATION:<name1>:<name2>:..." into an ordered table
    local names = {}
    local rest  = payload:sub(10)  -- strip the "ROTATION:" prefix
    for name in rest:gmatch("[^:]+") do
        names[#names + 1] = name
    end
    if #names == 0 then return end

    db.profile.kickRotation = names
    print(string.format("|cff0cd29f[Interrupt Tracker]|r Received kick rotation from %s (%d players).", senderShort, #names))
    if _G._EIT_Apply then _G._EIT_Apply() end
end)
