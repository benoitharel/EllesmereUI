-------------------------------------------------------------------------------
--  EUI_InterruptTracker_Announce.lua
--
--  Click-to-announce: left-click a bar to broadcast that player's interrupt
--  status to the group channel.  Provides anti-spam lock, a brief alpha flash
--  on the bar, /skr slash commands, and inter-addon rotation sync via the
--  "EUI_KR" addon message prefix.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
if _G._EIT_Announce_Loaded then return end
_G._EIT_Announce_Loaded = true

-- { [unit] = true } while that unit's bar is locked against re-announce
local announceLock = {}
local announceLockGen = {}   -- { [unit] = current generation counter }

function ns.ClearAnnounceLock()
    wipe(announceLock)
    wipe(announceLockGen)
end

-------------------------------------------------------------------------------
--  Register rotation-sync prefix up front (safe to call at file load)
-------------------------------------------------------------------------------
C_ChatInfo.RegisterAddonMessagePrefix("EUI_KR")

-------------------------------------------------------------------------------
--  Safely resolve a spell name from a spell ID
-------------------------------------------------------------------------------
local function GetSpellName(spellID)
    if not spellID or spellID == 0 then return "Interrupt" end
    local info = C_Spell.GetSpellInfo(spellID)
    return (info and info.name) or "Interrupt"
end

-------------------------------------------------------------------------------
--  HandleBarClick  —  called from each bar's OnMouseUp (set up in the main
--  module's GetBarFrame when ns.HandleBarClick is defined).
-------------------------------------------------------------------------------
function ns.HandleBarClick(unit, info)
    if not unit or not info then return end
    if announceLock[unit] then return end

    local db = ns.GetDB and ns.GetDB()
    if not db or not db.profile then return end
    local p = db.profile

    local data = info.data
    if data == false then return end  -- spec has no interrupt; nothing to announce

    local channel = p.announceChannel or "PARTY"
    local name    = info.name or unit

    -- Compute remaining cooldown from the tracked start/duration pair
    local remaining = 0
    if info.cdStart and info.cdDuration then
        remaining = (info.cdStart + info.cdDuration) - GetTime()
        if remaining < 0 then remaining = 0 end
    end

    local spellName = (data and GetSpellName(data.spellID)) or "Interrupt"
    local msg
    if remaining <= 0 then
        msg = string.format("[Interrupt Tracker] %s \226\128\148 %s ready", name, spellName)
    else
        msg = string.format("[Interrupt Tracker] %s \226\128\148 %s on CD: %.1fs", name, spellName, remaining)
    end

    -- Deliver to the configured channel; fall back to SAY if not grouped
    if channel == "PARTY" and (IsInGroup() or IsInRaid()) then
        SendChatMessage(msg, "PARTY")
    else
        SendChatMessage(msg, "SAY")
    end

    -- Anti-spam: lock this bar for at least 3 s, or for the full remaining CD
    local lockDuration = math.max(remaining, 3)
    local gen = (announceLockGen[unit] or 0) + 1
    announceLockGen[unit] = gen
    announceLock[unit] = true
    C_Timer.After(lockDuration, function()
        if announceLockGen[unit] == gen then
            announceLock[unit] = nil
        end
    end)

    -- Trigger the bar's built-in flash OnUpdate by setting _eit_flashElapsed = 0
    local bar = info.barFrame
    if bar then
        bar._eit_flashElapsed = 0
    end
end

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

    -- Verify the sender is actually in the group (basic sanity check)
    local inGroup = false
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            if Ambiguate(UnitName("raid"  .. i) or "", "short") == senderShort then inGroup = true; break end
        end
    elseif IsInGroup() then
        for i = 1, GetNumGroupMembers() do
            if Ambiguate(UnitName("party" .. i) or "", "short") == senderShort then inGroup = true; break end
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
