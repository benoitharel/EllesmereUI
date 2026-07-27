-------------------------------------------------------------------------------
--  EllesmereUIInterruptTracker.lua
--
--  Main module: DB bootstrap, roster tracking, spec detection, bar layout,
--  live CD tracking, failed-kick state machine, combat fade.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
if _G._EIT_Loaded then return end
_G._EIT_Loaded = true
local EIT = EllesmereUI.Lite.NewAddon(ADDON_NAME)

local PP = EllesmereUI.PP or EllesmereUI.PanelPP

local CLASS_ICON_TEX = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"
local MAX_BARS       = 40

local DEFAULTS = { profile = {
    enabled               = true,
    failedKickDetection   = true,
    assumeUnreadableCasts = true,
    growUpward          = false,
    barWidth            = 200,
    barHeight           = 20,
    barSpacing          = 2,
    iconSize            = 20,
    posX                = 0,
    posY                = 0,
    showInParty         = true,
    showInRaid          = false,
    showSolo            = true,
    soloOutOfCombat     = true,
    sortDescending      = false,
    announceChannel     = "PARTY",
    kickRotation        = {},
} }

-------------------------------------------------------------------------------
--  Runtime state
-------------------------------------------------------------------------------
local db
local containerFrame
local barPool        = {}
-- { [unit] = { name, classToken, guid, specID, data, cdStart, cdDuration, kickState, barFrame } }
local trackedPlayers = {}
-- { [petGUID] = ownerUnit }  — populated in RebuildRoster for pet-source interrupts
local petGuidToUnit      = {}
local petTokenToOwnerUnit = {}
-- { [casterName] = { time = T } }
local pendingKicks   = {}
-- { { time = T }, ... }  — enemy interrupted-cast timestamps for correlation
local recentInterrupts = {}

-------------------------------------------------------------------------------
--  CD ticker (0.1s interval, only active when there are tracked players)
-------------------------------------------------------------------------------
local cdTicker = nil

-------------------------------------------------------------------------------
--  Combat fade: lerp alpha 0 ↔ 1 over FADE_DURATION seconds via OnUpdate.
--  Always visible while inside an instance, regardless of combat state.
-------------------------------------------------------------------------------
local FADE_DURATION = 0.3
local fadeTarget    = 1   -- 1 = fully visible, 0 = transparent
local fadeAlpha     = 1
local inInstance    = false

local function RefreshFadeTarget()
    local p = db and db.profile
    if inInstance then
        fadeTarget = 1
    elseif p and p.soloOutOfCombat ~= false and not IsInGroup() then
        -- Solo in the open world: stay visible out of combat too, otherwise
        -- "Show When Solo" would look broken (the bar exists but is alpha 0).
        fadeTarget = 1
    else
        fadeTarget = InCombatLockdown() and 1 or 0
    end
end

local function CheckInstanceState()
    inInstance = IsInInstance()
    RefreshFadeTarget()
end

-------------------------------------------------------------------------------
--  Inspect throttle: 1 request per unit per 5 s
-------------------------------------------------------------------------------
local inspectQueue    = {}
local inspectCooldown = {}
local INSPECT_THROTTLE = 5

local function EnqueueInspect(unit)
    if not UnitExists(unit) or UnitIsUnit(unit, "player") then return end
    local guid = UnitGUID(unit)
    if not guid then return end
    local t = GetTime()
    if inspectCooldown[guid] and (t - inspectCooldown[guid]) < INSPECT_THROTTLE then return end
    inspectCooldown[guid] = t
    for _, u in ipairs(inspectQueue) do if u == unit then return end end
    inspectQueue[#inspectQueue + 1] = unit
end

local function ProcessInspectQueue()
    if #inspectQueue == 0 then return end
    local unit = table.remove(inspectQueue, 1)
    if UnitExists(unit) then
        NotifyInspect(unit)
    end
end

-------------------------------------------------------------------------------
--  Effective CD for a unit.
--
--  For the local player the game reports the true cooldown, with talent
--  reductions and any other modifier already applied — so we just read it.
--  For every other unit no API exposes cooldowns at all, so the static base
--  value is the best estimate available; it will be too long for a talented
--  member, and that is a hard limit of the client rather than an oversight.
-------------------------------------------------------------------------------
local function GetEffectiveCD(unit, data)
    if not data or data == false then return nil end
    if unit == "player" and EllesmereUI.SpellCD then
        local _, duration = EllesmereUI.SpellCD.GetReal(data.spellID)
        if duration then return duration end
    end
    return data.cd
end

-------------------------------------------------------------------------------
--  Format a remaining-seconds value into display text
-------------------------------------------------------------------------------
local function FormatCD(remaining)
    if remaining <= 0 then
        return "READY"
    else
        return string.format("%.1fs", remaining)
    end
end

-------------------------------------------------------------------------------
--  Purge recentInterrupts entries older than 0.5 s
-------------------------------------------------------------------------------
local function PurgeRecentInterrupts()
    local now = GetTime()
    local i = 1
    while i <= #recentInterrupts do
        if now - recentInterrupts[i].time > 0.5 then
            table.remove(recentInterrupts, i)
        else
            i = i + 1
        end
    end
end

local function HasRecentInterrupt()
    PurgeRecentInterrupts()
    return #recentInterrupts > 0
end

-------------------------------------------------------------------------------
--  Update a bar's recharge graph: black baseline, red fill grows from 0 to
--  full width as the tracked interrupt recharges; hidden once ready.
-------------------------------------------------------------------------------
local function UpdateBarCDGraph(bar, remaining, duration)
    if not bar or not bar.cdBarFill then return end

    if remaining <= 0 or not duration or duration <= 0 then
        bar.cdBarFill:Hide()
        return
    end

    -- Fraction of the cooldown STILL REMAINING: the red overlay covers the
    -- whole track the moment the interrupt is used and is eaten away by the
    -- black backing as it recharges, leaving an all-black bar when ready.
    local frac = remaining / duration
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end

    -- Measured against the visible track (right of the icons), not the whole
    -- bar -- see the graphInset note in LayoutBar.
    local width = (bar._cdFillMaxWidth or bar:GetWidth()) * frac
    if width <= 0 then
        bar.cdBarFill:Hide()
    else
        bar.cdBarFill:SetWidth(width)
        bar.cdBarFill:Show()
    end
end

-------------------------------------------------------------------------------
--  Update the CD text on one bar, applying kick-state colourisation.
--
--  Cooldowns are tracked from cast events for every unit. For the local player
--  we additionally CORRECT that bookkeeping against the client's own figures
--  when they are readable, which is what makes talent-reduced cooldowns and
--  reset effects accurate.
--
--  The API is only ever used to correct, never as the sole source: in Midnight
--  a spell's timing fields are frequently secret, and treating "unreadable" as
--  "ready" would wipe a valid running cooldown and show READY for its whole
--  duration. Only an explicit isActive == false clears the tracking.
-------------------------------------------------------------------------------
local function UpdateBarCDText(unit, info)
    local bar = info.barFrame
    if not bar or not bar.cdText then return end

    local data = info.data
    if not data or data == false then
        bar.cdText:SetText("|cff888888—|r")
        UpdateBarCDGraph(bar, 0, nil)
        return
    end

    if unit == "player" and EllesmereUI.SpellCD then
        local SpellCD = EllesmereUI.SpellCD
        -- NOTE: must not be written as `SpellCD and SpellCD.GetReal(...)` --
        -- an `and` expression yields a single value, dropping `duration`.
        local start, duration = SpellCD.GetReal(data.spellID)
        if start then
            info.cdStart, info.cdDuration = start, duration
        elseif SpellCD.IsActive(data.spellID) == false then
            -- Positively ready (finished, or reset by an ability).
            info.cdStart, info.cdDuration = nil, nil
        end
        -- Otherwise unreadable: keep what the cast event gave us.
    end

    local remaining = 0
    if info.cdStart and info.cdDuration then
        remaining = (info.cdStart + info.cdDuration) - GetTime()
        if remaining < 0 then remaining = 0 end
    end

    UpdateBarCDGraph(bar, remaining, info.cdDuration)

    -- Choose colour based on kick state (only when detection is enabled)
    local p = db and db.profile
    local color
    if p and p.failedKickDetection then
        local ks = info.kickState
        if ks == "success" then
            color = "|cff00ff00"
        elseif ks == "fail" then
            color = "|cffff4444"
        else
            color = "|cffffffff"
        end
    else
        color = "|cffffffff"
    end

    bar.cdText:SetText(color .. FormatCD(remaining) .. "|r")
end

-------------------------------------------------------------------------------
--  Ordering
--
--  Bars are sorted by REMAINING cooldown: ready interrupts (0 s) sit at the
--  top and the longest cooldown at the bottom, so the kicks you can actually
--  call on are always the ones nearest the top. Descending flips it.
--  Ties (e.g. several ready players) fall back to the unit token so the order
--  stays stable instead of shuffling between frames.
-------------------------------------------------------------------------------
local function GetRemaining(info)
    if not info or not info.cdStart or not info.cdDuration then return 0 end
    local r = (info.cdStart + info.cdDuration) - GetTime()
    if r < 0 then r = 0 end
    return r
end

local function SortEntries(entries)
    local desc = db and db.profile and db.profile.sortDescending
    table.sort(entries, function(a, b)
        local ra, rb = GetRemaining(a.info), GetRemaining(b.info)
        if ra ~= rb then
            if desc then return ra > rb end
            return ra < rb
        end
        return a.unit < b.unit
    end)
end

-- Signature of the currently displayed order, so the ticker can tell when the
-- ranking actually changed and only then pay for a relayout.
local displayedOrder = ""

local function BuildOrderKey(entries)
    local parts = {}
    for i, e in ipairs(entries) do parts[i] = e.unit end
    return table.concat(parts, "|")
end

local RebuildDisplay   -- forward declaration (UpdateAllCDs re-sorts through it)

-------------------------------------------------------------------------------
--  Ticker callback: refresh every tracked player's CD text, and re-sort when
--  ticking cooldowns have changed the ranking.
-------------------------------------------------------------------------------
local function UpdateAllCDs()
    if not db or not db.profile or not db.profile.enabled then return end
    for unit, info in pairs(trackedPlayers) do
        UpdateBarCDText(unit, info)
    end

    local entries = {}
    for unit, info in pairs(trackedPlayers) do
        entries[#entries + 1] = { unit = unit, info = info }
    end
    SortEntries(entries)
    if BuildOrderKey(entries) ~= displayedOrder then
        RebuildDisplay()
    end
end

-------------------------------------------------------------------------------
--  Start or stop the CD ticker based on current state
-------------------------------------------------------------------------------
local function RefreshTicker()
    local active = db and db.profile and db.profile.enabled and next(trackedPlayers) ~= nil
    if active and not cdTicker then
        cdTicker = C_Timer.NewTicker(0.1, UpdateAllCDs)
    elseif not active and cdTicker then
        cdTicker:Cancel()
        cdTicker = nil
    end
end

-------------------------------------------------------------------------------
--  Apply EllesmereUI's shared dark-theme font (Expressway + configured
--  outline/shadow) to a FontString, matching every other module's text
--  instead of falling back to Blizzard's default GameFontNormal.
-------------------------------------------------------------------------------
local function ApplyEUIFont(fs, size)
    if not (fs and fs.SetFont) then return end
    local useShadow = EllesmereUI.GetFontUseShadow and EllesmereUI.GetFontUseShadow()
    if EllesmereUI.PrimeFontShadow then EllesmereUI.PrimeFontShadow(fs, useShadow) end
    local path    = (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath())
                    or "Interface\\AddOns\\EllesmereUI\\media\\fonts\\Expressway.TTF"
    local outline = (EllesmereUI.GetFontOutlineFlag and EllesmereUI.GetFontOutlineFlag()) or ""
    fs:SetFont(path, size, outline)
end

-------------------------------------------------------------------------------
--  Bar pool helpers
-------------------------------------------------------------------------------
local function GetBarFrame(index, parent)
    if barPool[index] then return barPool[index] end
    local f = CreateFrame("Frame", nil, parent)

    -- Recharge graph: black backing, red overlay covering the part of the
    -- cooldown still remaining (full red on cast → all black when ready)
    local cdBarBG = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    cdBarBG:SetColorTexture(0, 0, 0, 1)
    f.cdBarBG = cdBarBG

    local cdBarFill = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    cdBarFill:SetColorTexture(0.8, 0.1, 0.1, 1)
    cdBarFill:Hide()
    f.cdBarFill = cdBarFill

    -- Standard 1px dark-theme border around the whole row (matches
    -- PP.CreateBorder usage across every other EllesmereUI module)
    if PP.CreateBorder then PP.CreateBorder(f, 0, 0, 0, 1, 1, "OVERLAY", 7) end

    local classIcon = f:CreateTexture(nil, "ARTWORK")
    classIcon:SetSnapToPixelGrid(false)
    classIcon:SetTexelSnappingBias(0)
    f.classIcon = classIcon

    -- Spell icon sits in its own frame so it can carry a standard 1px
    -- border (PP.CreateBorder needs a real frame, not a bare texture) —
    -- same wrapper pattern as EllesmereUIUnitFrames' castbar icon.
    local spellIconFrame = CreateFrame("Frame", nil, f)
    local spellIconBg = spellIconFrame:CreateTexture(nil, "BACKGROUND")
    spellIconBg:SetAllPoints()
    spellIconBg:SetColorTexture(0, 0, 0, 1)
    if PP.CreateBorder then PP.CreateBorder(spellIconFrame, 0, 0, 0, 1) end
    f.spellIconFrame = spellIconFrame

    local spellIcon = spellIconFrame:CreateTexture(nil, "ARTWORK")
    spellIcon:SetSnapToPixelGrid(false)
    spellIcon:SetTexelSnappingBias(0)
    PP.SetInside(spellIcon, spellIconFrame, 1, 1)
    f.spellIcon = spellIcon

    local nameText = f:CreateFontString(nil, "OVERLAY")
    ApplyEUIFont(nameText, 12)
    f.nameText = nameText

    local cdText = f:CreateFontString(nil, "OVERLAY")
    ApplyEUIFont(cdText, 12)
    cdText:SetText("")
    f.cdText = cdText

    -- Left-click → announce (wired to ns.HandleBarClick by the announce module)
    f:EnableMouse(true)
    f:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and ns.HandleBarClick then
            ns.HandleBarClick(self._eit_unit, self._eit_info)
        end
    end)
    -- Brief alpha flash driven by _eit_flashElapsed (set to 0 to trigger)
    f:SetScript("OnUpdate", function(self, elapsed)
        if not self._eit_flashElapsed then return end
        self._eit_flashElapsed = self._eit_flashElapsed + elapsed
        local t = self._eit_flashElapsed / 0.3
        if t >= 1 then
            self:SetAlpha(1)
            self._eit_flashElapsed = nil
            return
        end
        -- triangle wave: alpha 1 → 0.4 → 1 over the 0.3 s window
        self:SetAlpha(1 - 0.6 * (1 - math.abs(2 * t - 1)))
    end)

    barPool[index] = f
    return f
end

-------------------------------------------------------------------------------
--  Layout one bar for a tracked-player entry
-------------------------------------------------------------------------------
local function LayoutBar(bar, entry, p)
    local sz = p.iconSize
    local bh = p.barHeight
    local bw = p.barWidth

    bar:SetSize(bw, bh)

    -- Recharge graph: black backing across the whole row, red fill starting
    -- AFTER the icons and aligned with the name text. The icons draw on
    -- ARTWORK, above the BACKGROUND layer the fill lives on, so a fill
    -- anchored to the bar's left edge spends its first two icon widths
    -- completely hidden behind them.
    PP.SetInside(bar.cdBarBG, bar, 0, 0)

    -- class icon + gap + spell icon + gap -- same offsets the name text uses.
    local graphInset = sz + 2 + sz + 4
    bar._cdFillMaxWidth = math.max(bw - graphInset, 1)

    -- Anchored to the RIGHT edge: the red overlay is widest right after the
    -- cast and shrinks rightwards, so the black backing appears to fill the
    -- bar from the left as the interrupt recharges.
    bar.cdBarFill:ClearAllPoints()
    PP.Point(bar.cdBarFill, "TOPRIGHT", bar, "TOPRIGHT", 0, 0)
    PP.Point(bar.cdBarFill, "BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)

    -- Class icon
    bar.classIcon:SetSize(sz, sz)
    bar.classIcon:ClearAllPoints()
    PP.Point(bar.classIcon, "LEFT", bar, "LEFT", 0, 0)

    local data = entry.data

    if CLASS_ICON_TCOORDS and entry.classToken and CLASS_ICON_TCOORDS[entry.classToken] then
        bar.classIcon:SetTexture(CLASS_ICON_TEX)
        bar.classIcon:SetTexCoord(unpack(CLASS_ICON_TCOORDS[entry.classToken]))
        bar.classIcon:Show()
    else
        bar.classIcon:Hide()
    end

    -- Spell icon
    bar.spellIconFrame:SetSize(sz, sz)
    bar.spellIconFrame:ClearAllPoints()
    PP.Point(bar.spellIconFrame, "LEFT", bar.classIcon, "RIGHT", 2, 0)

    if data and data.spellID and data.spellID ~= 0 then
        local tex = C_Spell.GetSpellTexture(data.spellID)
        if tex then
            bar.spellIcon:SetTexture(tex)
            bar.spellIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            bar.spellIcon:SetDesaturated(false)
            bar.spellIcon:SetVertexColor(1, 1, 1, 1)
            bar.spellIconFrame:Show()
        else
            bar.spellIconFrame:Hide()
        end
    else
        bar.spellIconFrame:Hide()
    end

    -- Name text
    bar.nameText:ClearAllPoints()
    PP.Point(bar.nameText, "LEFT", bar.spellIconFrame, "RIGHT", 4, 0)
    bar.nameText:SetWidth(bw - sz - sz - 2 - 4 - 30)
    bar.nameText:SetJustifyH("LEFT")
    if data == false then
        bar.nameText:SetTextColor(0.5, 0.5, 0.5, 1)
    else
        bar.nameText:SetTextColor(1, 1, 1, 1)
    end
    bar.nameText:SetText(entry.name or "?")

    -- CD text (right-aligned; content filled by ticker)
    bar.cdText:ClearAllPoints()
    PP.Point(bar.cdText, "RIGHT", bar, "RIGHT", 0, 0)
    bar.cdText:SetJustifyH("RIGHT")
    if data == false then
        bar.cdText:SetText("|cff888888—|r")
    else
        bar.cdText:SetText("")
    end

    bar:Show()
end

-------------------------------------------------------------------------------
--  Rebuild and redraw all bars from trackedPlayers.
--  Stores a barFrame reference in each entry so the CD ticker can find it.
-------------------------------------------------------------------------------
function RebuildDisplay()
    if not containerFrame or not db or not db.profile then return end
    local p = db.profile
    if not p.enabled then
        containerFrame:Hide()
        return
    end

    local entries = {}
    for unit, info in pairs(trackedPlayers) do
        entries[#entries + 1] = { unit = unit, info = info }
    end
    SortEntries(entries)
    displayedOrder = BuildOrderKey(entries)

    local count = #entries
    local totalH = count * p.barHeight + (count > 0 and (count - 1) * p.barSpacing or 0)
    containerFrame:SetSize(p.barWidth, math.max(totalH, 1))

    for i, entry in ipairs(entries) do
        local bar = GetBarFrame(i, containerFrame)
        -- Attach bar reference so UpdateBarCDText can find it without re-sorting
        entry.info.barFrame = bar
        -- Expose unit token + info on the bar frame for the announce click handler
        bar._eit_unit = entry.unit
        bar._eit_info = entry.info

        bar:ClearAllPoints()
        if p.growUpward then
            PP.Point(bar, "BOTTOMLEFT", containerFrame, "BOTTOMLEFT", 0, (i - 1) * (p.barHeight + p.barSpacing))
        else
            PP.Point(bar, "TOPLEFT", containerFrame, "TOPLEFT", 0, -((i - 1) * (p.barHeight + p.barSpacing)))
        end

        LayoutBar(bar, entry.info, p)
    end

    for i = count + 1, #barPool do
        barPool[i]:Hide()
    end

    if count > 0 then
        containerFrame:Show()
    else
        containerFrame:Hide()
    end

    RefreshTicker()
end

-------------------------------------------------------------------------------
--  Roster rebuild
-------------------------------------------------------------------------------
local function RebuildPetGuidMap()
    wipe(petGuidToUnit)
    wipe(petTokenToOwnerUnit)
    for unit, info in pairs(trackedPlayers) do
        if info.data and info.data ~= false and info.data.source == "pet" then
            local petToken
            if unit == "player" then
                petToken = "pet"
            else
                local idx = unit:match("^party(%d+)$")
                if idx then petToken = "partypet" .. idx end
            end
            if petToken and UnitExists(petToken) then
                local guid = UnitGUID(petToken)
                if guid then petGuidToUnit[guid] = unit end
                petTokenToOwnerUnit[petToken] = unit
            end
        end
    end
end

local function RebuildRoster()
    if not db or not db.profile then return end
    local p      = db.profile
    local inRaid  = IsInRaid()
    local inParty = IsInGroup()

    trackedPlayers = {}
    if ns.ClearAnnounceLock then ns.ClearAnnounceLock() end

    if inRaid and p.showInRaid then
        local n = GetNumGroupMembers()
        for i = 1, n do
            local unit = "raid" .. i
            if UnitExists(unit) then
                local name = UnitName(unit) or unit
                local _, classToken = UnitClass(unit)
                trackedPlayers[unit] = {
                    name = name, classToken = classToken,
                    guid = UnitGUID(unit), specID = nil,
                    data = ns.GetInterruptData(classToken, nil),
                }
                EnqueueInspect(unit)
            end
        end
    elseif inParty and p.showInParty then
        local n = GetNumGroupMembers()
        for i = 1, n do
            local unit = "party" .. i
            if UnitExists(unit) then
                local name = UnitName(unit) or unit
                local _, classToken = UnitClass(unit)
                trackedPlayers[unit] = {
                    name = name, classToken = classToken,
                    guid = UnitGUID(unit), specID = nil,
                    data = ns.GetInterruptData(classToken, nil),
                }
                EnqueueInspect(unit)
            end
        end
    end

    -- Local player (spec known immediately). Always tracked while grouped;
    -- when ungrouped it is the only bar, so "Show When Solo" gates it.
    if inParty or p.showSolo ~= false then
        local _, classToken = UnitClass("player")
        local specIndex     = GetSpecialization()
        local specID        = specIndex and GetSpecializationInfo(specIndex) or nil
        trackedPlayers["player"] = {
            name = UnitName("player") or "Player",
            classToken = classToken,
            guid = UnitGUID("player"),
            specID = specID,
            data = ns.GetInterruptData(classToken, specID),
        }
    end

    -- Build pet-GUID → owner-unit map for pet-source interrupts (Warlock Demo/Felhunter)
    RebuildPetGuidMap()

    RebuildDisplay()
    C_Timer.After(0.2, ProcessInspectQueue)
end

-------------------------------------------------------------------------------
--  Apply: reposition container + rebuild display
-------------------------------------------------------------------------------
local function Apply()
    if not containerFrame or not db or not db.profile then return end
    local p = db.profile
    containerFrame:ClearAllPoints()
    PP.Point(containerFrame, "CENTER", UIParent, "CENTER", p.posX or 0, p.posY or 0)
    RebuildDisplay()
    -- Fade rules depend on profile options (solo visibility), so a settings
    -- change must re-evaluate them rather than wait for the next combat event.
    RefreshFadeTarget()
end

_G._EIT_Apply = Apply

-- Exposed for the options page: toggles that change WHICH units are tracked
-- need a roster rebuild, not just a redraw. Kept separate from Apply so frame
-- dragging in unlock mode stays cheap and never wipes running cooldowns.
_G._EIT_RebuildRoster = RebuildRoster

-------------------------------------------------------------------------------
--  Cast → tracked-spell matching.
--
--  Since Midnight the spellID on UNIT_SPELLCAST_* is a SECRET value for every
--  unit but the local player and its pet, so a plain numeric comparison is
--  impossible. EllesmereUI.SpellMatch runs a cascade (direct → name → base
--  spell → slider laundering); the name step is what actually resolves party
--  members' casts. See EllesmereUI_SpellMatch.lua.
--
--  Returns:
--    true            -- this cast IS the unit's tracked interrupt
--    false, "other"  -- resolved, and it is some OTHER spell
--    false, "unknown"-- could not be resolved either way
-------------------------------------------------------------------------------
local oneCandidate = {}   -- reused scratch array (handler is not re-entrant)

local function MatchesInterrupt(rawSpellID, data)
    local SM = EllesmereUI.SpellMatch
    if not SM or not data or data == false or not data.spellID then
        return false, "unknown"
    end
    oneCandidate[1] = data.spellID
    local matched, _, conclusive = SM.FindMatch(rawSpellID, oneCandidate)
    if matched then return true end
    -- `conclusive` means the cast was readable and is definitely another spell.
    return false, conclusive and "other" or "unknown"
end

-------------------------------------------------------------------------------
--  Last-resort corroboration for an unreadable party cast.
--
--  When the cascade cannot identify a cast at all, assume it was the unit's
--  tracked interrupt ONLY if that interrupt is currently READY. A spell that
--  is still on cooldown cannot have just been cast, so this can never stomp a
--  running timer -- the worst case is starting the CD on the first
--  unidentifiable cast after the interrupt came back up. Mirrors the same
--  trade-off BliZzi Party Tools makes (Core.lua:2519-2545); switch it off with
--  the "Assume Unreadable Casts" option if the false positives bother you.
-------------------------------------------------------------------------------
local DRIFT_GRACE = 0.5

local function InterruptIsReady(info)
    if not info.cdStart or not info.cdDuration then return true end
    local remaining = (info.cdStart + info.cdDuration) - GetTime()
    return remaining <= DRIFT_GRACE
end

-------------------------------------------------------------------------------
--  Commit a confirmed interrupt cast for a unit: start the tracked cooldown
--  and run the failed-kick state machine. Shared by the direct and the
--  pet-sourced cast paths.
-------------------------------------------------------------------------------
local function ApplyInterruptCast(unit, info)
    info.cdStart    = GetTime()
    info.cdDuration = GetEffectiveCD(unit, info.data)

    -- Failed-kick correlation window (0.05 s lets UNIT_SPELLCAST_INTERRUPTED
    -- arrive first).
    local p = db and db.profile
    if not (p and p.failedKickDetection) then
        UpdateBarCDText(unit, info)
        return
    end

    info.kickState = "pending"
    C_Timer.After(0.05, function()
        if trackedPlayers[unit] ~= info then return end
        info.kickState = HasRecentInterrupt() and "success" or "fail"
        UpdateBarCDText(unit, info)
        C_Timer.After(3, function()
            if trackedPlayers[unit] ~= info then return end
            if info.kickState == "success" or info.kickState == "fail" then
                info.kickState = nil
                UpdateBarCDText(unit, info)
            end
        end)
    end)
end

-------------------------------------------------------------------------------
--  Event frame
-------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")

eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("INSPECT_READY")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SENT")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "GROUP_ROSTER_UPDATE" then
        RebuildRoster()
        -- Joining/leaving a group flips the solo fade rule; re-evaluate now
        -- instead of waiting for the next combat or zone change.
        RefreshFadeTarget()

    elseif event == "INSPECT_READY" then
        local guid = ...
        for unit, info in pairs(trackedPlayers) do
            if info.guid == guid then
                local specID = GetInspectSpecialization(unit)
                if specID and specID ~= 0 then
                    info.specID = specID
                    info.data   = ns.GetInterruptData(info.classToken, specID)
                    RebuildPetGuidMap()
                end
                break
            end
        end
        RebuildDisplay()
        C_Timer.After(0.1, ProcessInspectQueue)

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        local unit = ...
        if unit == "player" and trackedPlayers["player"] then
            local specIndex = GetSpecialization()
            if specIndex then
                local info   = trackedPlayers["player"]
                local specID = GetSpecializationInfo(specIndex)
                info.specID  = specID
                info.data    = ns.GetInterruptData(info.classToken, specID)
                RebuildDisplay()
            end
        end

    elseif event == "SPELL_UPDATE_COOLDOWN" then
        -- UpdateBarCDText re-reads the player's real cooldown from the API, so
        -- it alone handles both "started" and "reset/ready" transitions.
        local playerInfo = trackedPlayers["player"]
        if playerInfo and playerInfo.data and playerInfo.data ~= false then
            UpdateBarCDText("player", playerInfo)
        end

    elseif event == "UNIT_SPELLCAST_SENT" then
        -- unit, target, castGUID, spellID
        local unit, _, _, spellID = ...
        local p = db and db.profile
        if not (p and p.failedKickDetection) then return end
        local info = trackedPlayers[unit]
        if info and info.data and info.data ~= false and MatchesInterrupt(spellID, info.data) then
            info.kickState = "pending"
            pendingKicks[info.name] = { time = GetTime() }
        end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- unit, castGUID, spellID
        local unit, _, spellID = ...

        -- Resolve the acting unit: a pet-sourced interrupt (Warlock Felhunter /
        -- Felguard) is credited to its owner's bar.
        local actor = petTokenToOwnerUnit[unit] or unit
        local info  = trackedPlayers[actor]
        if not info or not info.data or info.data == false then return end

        local matched, reason = MatchesInterrupt(spellID, info.data)
        if matched then
            ApplyInterruptCast(actor, info)
            return
        end
        if reason == "other" then return end   -- conclusively a different spell

        -- Genuinely UNREADABLE cast: the cascade could not identify the spell at
        -- all (readable-but-different casts already returned above, which is
        -- what keeps this from firing on every spell a member casts).
        --
        -- Credit it as their interrupt while that interrupt is ready. We
        -- deliberately do NOT require an interrupt to have actually landed:
        -- a whiffed kick still puts the ability on cooldown, and knowing it is
        -- unavailable is the whole point of the tracker. ApplyInterruptCast
        -- still colours the bar red for a whiff via its own success/fail check.
        --
        -- The "ready" gate bounds the damage: a wrong guess can never stomp a
        -- running timer, only start one early.
        local p = db and db.profile
        if p and p.assumeUnreadableCasts ~= false and InterruptIsReady(info) then
            ApplyInterruptCast(actor, info)
        end

    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        -- A cast was interrupted; record timestamp for the failed-kick correlation window
        recentInterrupts[#recentInterrupts + 1] = { time = GetTime() }

    elseif event == "PLAYER_REGEN_DISABLED" then
        RefreshFadeTarget()   -- fade in on combat start (always visible in instance)

    elseif event == "PLAYER_REGEN_ENABLED" then
        RefreshFadeTarget()   -- fade out on combat end (unless in instance)

    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        CheckInstanceState()
    end
end)

-------------------------------------------------------------------------------
--  Unlock element registration
-------------------------------------------------------------------------------
local function RegisterUnlockElements()
    if not EllesmereUI or not EllesmereUI.RegisterUnlockElements then return end
    if not containerFrame then return end

    local MK = EllesmereUI.MakeUnlockElement
    EllesmereUI:RegisterUnlockElements({
        MK({
            key   = "EIT_Container",
            label = "Interrupt Tracker",
            group = "Interrupt Tracker",
            order = 700,
            getFrame = function() return containerFrame end,
            getSize  = function()
                local p = db and db.profile
                return p and p.barWidth or 200, p and p.barHeight or 20
            end,
            savePos = function(key, point, relPoint, x, y)
                if db and db.profile then
                    db.profile.posX = x
                    db.profile.posY = y
                end
                Apply()
            end,
            loadPos = function()
                local p = db and db.profile
                if not p then return nil end
                return { point = "CENTER", relPoint = "CENTER", x = p.posX or 0, y = p.posY or 0 }
            end,
            clearPos = function()
                if db and db.profile then
                    db.profile.posX = 0
                    db.profile.posY = 0
                end
                Apply()
            end,
            applyPos = function() Apply() end,
        }),
    })
end

-------------------------------------------------------------------------------
--  Lifecycle
-------------------------------------------------------------------------------
function EIT:OnInitialize()
    self.db = EllesmereUI.Lite.NewDB("EllesmereUIInterruptTrackerDB", DEFAULTS, true)
    db = self.db
    ns.GetDB = function() return db end

    _G._EIT_AceDB = self.db
end

function EIT:OnEnable()
    containerFrame = CreateFrame("Frame", "EllesmereUIInterruptTrackerFrame", UIParent)
    containerFrame:SetSize(db.profile.barWidth, db.profile.barHeight)
    containerFrame:SetFrameStrata("MEDIUM")
    containerFrame:SetAlpha(1)
    fadeAlpha  = 1
    fadeTarget = 1

    -- Combat fade: hand-rolled alpha lerp over FADE_DURATION seconds
    containerFrame:SetScript("OnUpdate", function(self, elapsed)
        if fadeAlpha == fadeTarget then return end
        local step = elapsed / FADE_DURATION
        if fadeTarget == 1 then
            fadeAlpha = math.min(1, fadeAlpha + step)
        else
            fadeAlpha = math.max(0, fadeAlpha - step)
        end
        self:SetAlpha(fadeAlpha)
    end)

    -- Pre-allocate pool: never call CreateFrame in combat
    for i = 1, MAX_BARS do
        GetBarFrame(i, containerFrame):Hide()
    end

    CheckInstanceState()
    Apply()
    C_Timer.After(0, RebuildRoster)
    C_Timer.After(0.5, RegisterUnlockElements)
end
