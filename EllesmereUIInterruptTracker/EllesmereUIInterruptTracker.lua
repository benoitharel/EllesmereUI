if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIInterruptTracker.lua
--
--  Main module: DB bootstrap, roster tracking, spec detection, bar layout,
--  live CD tracking, failed-kick state machine, combat fade.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
EllesmereUI._ModuleNS[ADDON_NAME] = ns  -- LOD options files read this module ns via the registry
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
-- { { time = T, guid = <interrupter GUID or nil>, consumed = bool }, ... }
-- — enemy interrupted-cast signals for the failed-kick correlation window
local recentInterrupts = {}
-- Timestamp of the local player's last CONCLUSIVELY matched interrupt cast,
-- and the window in which it outranks an unreadable party-member cast.
local lastPlayerKickCast = 0
local PLAYER_PRECEDENCE  = 0.06

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
--  Group spec intel over addon comms (LibSpecialization).
--
--  Inspect is not a usable source any more: NotifyInspect on group members is
--  throttled into uselessness and GetInspectSpecialization answers for almost
--  none of them, which is exactly why Party Cooldowns was retired. The other
--  interrupt trackers made the same move -- BliZzi Party Tools deleted its
--  inspect queue outright, Exwind resolves specs through LibSpecialization and
--  LibOpenRaid.
--
--  The lib handles every bit of transmission itself (request on group join,
--  broadcast on spec change, chat-lockdown deferral); registering the callback
--  IS the integration, so its request functions are never called from here.
--
--  Keys match how the lib keys senders: "Name" same-realm, "Name-Realm"
--  cross-realm. Entries self-heal (a rejoining player rebroadcasts) and growth
--  is bounded (name -> number), so the cache needs no pruning. Same shape as
--  EllesmereUIAuraBuffReminders' EABR._groupSpecs / EABR.GroupSpecFor.
-------------------------------------------------------------------------------
local isSecret   = issecretvalue or function() return false end
local groupSpecs = {}

local function SpecKeyForUnit(unit)
    local n, r = UnitNameUnmodified(unit)
    if n == nil or isSecret(n) then return nil end
    if r ~= nil and not isSecret(r) and r ~= "" then n = n .. "-" .. r end
    return n
end

local function GroupSpecFor(unit)
    local key = SpecKeyForUnit(unit)
    return key and groupSpecs[key] or nil
end

-------------------------------------------------------------------------------
--  Clean class token for a unit.
--
--  UnitClass can hand back a SECRET string for a group member, and a secret
--  used as a table key THROWS on the index -- which would take the whole roster
--  rebuild down with it (upstream hit the same thing in the raid frames, commit
--  262a64ce). Both the interrupt database and the class-icon coords are keyed
--  by class token, so the token has to be laundered before either lookup.
--
--  The comm spec is the better source once it arrives: GetSpecializationInfoByID
--  returns a plain class file name that never went through a unit token. Fall
--  back to UnitClass, and give up rather than index with a secret.
-------------------------------------------------------------------------------
local function CleanClassToken(unit, specID)
    if specID and GetSpecializationInfoByID then
        local classFile = select(6, GetSpecializationInfoByID(specID))
        if classFile and not isSecret(classFile) then return classFile end
    end
    local _, token = UnitClass(unit)
    if token == nil or isSecret(token) then return nil end
    return token
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

-------------------------------------------------------------------------------
--  Resolve an interrupter GUID to the tracked unit it belongs to, following
--  pet GUIDs back to their owner (a Felhunter's Spell Lock is the warlock's
--  kick). Secret GUIDs resolve to nothing -- they are anonymous by design and
--  must never be compared or used as a table key.
-------------------------------------------------------------------------------
local function InterrupterUnitFor(guid)
    if guid == nil or isSecret(guid) then return nil end
    for unit, info in pairs(trackedPlayers) do
        if info.guid == guid then return unit end
    end
    return petGuidToUnit[guid]
end

-------------------------------------------------------------------------------
--  Outcome of a just-committed kick, resolved against the interrupt signals
--  collected in the correlation window. Each signal is consumed by at most one
--  kick, so two members kicking within the same window can no longer both read
--  as a success.
--
--  Returns "success", "fail", or nil when the signals are too ambiguous to
--  call (the bar then shows no verdict rather than a wrong one).
-------------------------------------------------------------------------------
local CLUSTER_WINDOW = 0.02

local function ClaimKickOutcome(unit)
    PurgeRecentInterrupts()

    -- Direct attribution: since 12.x the interrupt events carry the
    -- interrupter's GUID whenever the client is willing to reveal it.
    local anonymous = {}
    for i = 1, #recentInterrupts do
        local sig = recentInterrupts[i]
        if not sig.consumed then
            local owner = InterrupterUnitFor(sig.guid)
            if owner == unit then
                sig.consumed = true
                return "success"
            elseif owner == nil then
                anonymous[#anonymous + 1] = sig
            end
            -- owner is some OTHER tracked unit: their signal, leave it alone.
        end
    end

    if #anonymous == 0 then return "fail" end

    -- An AoE stun interrupts several casts at once; those signals arrive in a
    -- tight cluster and cannot be told apart from a real kick landing at the
    -- same moment. Consume them and report no verdict rather than crediting a
    -- whiffed kick as a success.
    local freshest = anonymous[#anonymous]
    for i = 1, #anonymous do
        if anonymous[i].time > freshest.time then freshest = anonymous[i] end
    end
    local clustered = 0
    for i = 1, #anonymous do
        if math.abs(anonymous[i].time - freshest.time) <= CLUSTER_WINDOW then
            clustered = clustered + 1
        end
    end
    if clustered > 1 then
        for i = 1, #anonymous do anonymous[i].consumed = true end
        return nil
    end

    freshest.consumed = true
    return "success"
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

-- Forward declarations: RebuildDisplay lives further down (bar layout needs
-- LayoutBar/GetBarFrame first); ScheduleExpiry lives right after SortEntries.
-- Both are referenced from UpdateBarCDText below, hence the early declare.
local RebuildDisplay
local ScheduleExpiry

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
--
--  Returns true when cdStart/cdDuration actually changed, so the caller knows
--  the sort order may need to be recomputed (see ScheduleExpiry / UpdateAllCDs
--  below -- the ranking is re-evaluated only on these transitions, never by
--  polling every tick).
-------------------------------------------------------------------------------
local function UpdateBarCDText(unit, info)
    local bar = info.barFrame
    if not bar or not bar.cdText then return false end

    local data = info.data
    if not data or data == false then
        bar.cdText:SetText("|cff888888—|r")
        UpdateBarCDGraph(bar, 0, nil)
        return false
    end

    local changed = false
    if unit == "player" and EllesmereUI.SpellCD then
        local SpellCD = EllesmereUI.SpellCD
        -- NOTE: must not be written as `SpellCD and SpellCD.GetReal(...)` --
        -- an `and` expression yields a single value, dropping `duration`.
        local start, duration = SpellCD.GetReal(data.spellID)
        if start then
            if info.cdStart ~= start or info.cdDuration ~= duration then
                info.cdStart, info.cdDuration = start, duration
                changed = true
            end
        elseif SpellCD.IsActive(data.spellID) == false and info.cdStart then
            -- Positively ready (finished, or reset by an ability).
            info.cdStart, info.cdDuration = nil, nil
            changed = true
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

    if changed and info.cdStart and info.cdDuration then
        ScheduleExpiry(unit, info)
    end
    return changed
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

-------------------------------------------------------------------------------
--  Event-driven re-sort.
--
--  Two running cooldowns never swap order relative to each other -- both
--  count down at the same real-time rate, so their relative ranking can only
--  change at three known instants: (1) a new cast starts (ApplyInterruptCast
--  calls RebuildDisplay directly), (2) a tracked cooldown reaches 0 (this
--  one-shot timer), or (3) the local player's real API cooldown is corrected
--  (UpdateBarCDText calls this when that happens). There is therefore no need
--  to poll "did the order change?" every 0.1 s tick -- the ranking is
--  recomputed exactly when it can possibly change, and not otherwise.
--
--  `expiryGen` invalidates a stale timer instead of cancelling it outright
--  (same generation-counter pattern as the announce lock elsewhere in this
--  addon family): if the cooldown is re-armed by a newer cast or correction
--  before the old timer fires, the old one becomes a no-op.
-------------------------------------------------------------------------------
local expiryGen = {}   -- [unit] = current generation

function ScheduleExpiry(unit, info)
    local gen = (expiryGen[unit] or 0) + 1
    expiryGen[unit] = gen
    C_Timer.After(info.cdDuration, function()
        if expiryGen[unit] ~= gen then return end        -- superseded
        if trackedPlayers[unit] ~= info then return end   -- roster changed
        RebuildDisplay()
    end)
end

-------------------------------------------------------------------------------
--  Ticker callback: refresh every tracked player's CD text every 0.1 s (kept
--  at this cadence purely so the "12.3s" label stays visually smooth -- see
--  UpdateBarCDText). The ranking itself is only rebuilt when UpdateBarCDText
--  reports an actual cdStart/cdDuration change, never unconditionally.
-------------------------------------------------------------------------------
local function UpdateAllCDs()
    if not db or not db.profile or not db.profile.enabled then return end
    local needsRebuild = false
    for unit, info in pairs(trackedPlayers) do
        if UpdateBarCDText(unit, info) then needsRebuild = true end
    end
    if needsRebuild then RebuildDisplay() end
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

    local count = #entries
    local totalH = count * p.barHeight + (count > 0 and (count - 1) * p.barSpacing or 0)
    containerFrame:SetSize(p.barWidth, math.max(totalH, 1))

    for i, entry in ipairs(entries) do
        local bar = GetBarFrame(i, containerFrame)
        -- Attach bar reference so UpdateBarCDText can find it without re-sorting
        entry.info.barFrame = bar

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

-------------------------------------------------------------------------------
--  Carry over live cooldown state (cdStart/cdDuration/kickState/barFrame)
--  from the previous roster snapshot onto a freshly-built entry, but ONLY
--  when the same unit token still holds the same player (guid match) -- a
--  roster event unrelated to this unit (someone else joining/leaving) must
--  never wipe a running interrupt cooldown, but a genuine occupant change on
--  that slot (old member left, someone else took "party2") must never
--  inherit the departed player's cooldown either.
-------------------------------------------------------------------------------
local function CarryOver(previous, unit, entry)
    local prev = previous[unit]
    if prev and prev.guid and prev.guid == entry.guid then
        entry.cdStart, entry.cdDuration = prev.cdStart, prev.cdDuration
        entry.kickState, entry.barFrame  = prev.kickState, prev.barFrame
        if entry.cdStart and entry.cdDuration then
            ScheduleExpiry(unit, entry)
        end
    end
    return entry
end

local function RebuildRoster()
    if not db or not db.profile then return end
    local p      = db.profile
    local inRaid  = IsInRaid()
    local inParty = IsInGroup()

    local previous = trackedPlayers
    trackedPlayers = {}

    if inRaid and p.showInRaid then
        local n = GetNumGroupMembers()
        for i = 1, n do
            local unit = "raid" .. i
            if UnitExists(unit) then
                local name = UnitName(unit) or unit
                local specID = GroupSpecFor(unit)
                local classToken = CleanClassToken(unit, specID)
                trackedPlayers[unit] = CarryOver(previous, unit, {
                    name = name, classToken = classToken,
                    guid = UnitGUID(unit), specID = specID,
                    data = ns.GetInterruptData(classToken, specID),
                })
            end
        end
    elseif inParty and p.showInParty then
        local n = GetNumGroupMembers()
        for i = 1, n do
            local unit = "party" .. i
            if UnitExists(unit) then
                local name = UnitName(unit) or unit
                local specID = GroupSpecFor(unit)
                local classToken = CleanClassToken(unit, specID)
                trackedPlayers[unit] = CarryOver(previous, unit, {
                    name = name, classToken = classToken,
                    guid = UnitGUID(unit), specID = specID,
                    data = ns.GetInterruptData(classToken, specID),
                })
            end
        end
    end

    -- Local player (spec known immediately). Always tracked while grouped;
    -- when ungrouped it is the only bar, so "Show When Solo" gates it.
    if inParty or p.showSolo ~= false then
        local specIndex     = GetSpecialization()
        local specID        = specIndex and GetSpecializationInfo(specIndex) or nil
        local classToken    = CleanClassToken("player", specID)
        trackedPlayers["player"] = CarryOver(previous, "player", {
            name = UnitName("player") or "Player",
            classToken = classToken,
            guid = UnitGUID("player"),
            specID = specID,
            data = ns.GetInterruptData(classToken, specID),
        })
    end

    -- Build pet-GUID → owner-unit map for pet-source interrupts (Warlock Demo/Felhunter)
    RebuildPetGuidMap()

    RebuildDisplay()
end

-------------------------------------------------------------------------------
--  Re-resolve tracked members against the comm spec cache. Called whenever
--  LibSpecialization delivers new data: specs arrive asynchronously, so the
--  roster is first built on class-only data and sharpened here as answers come
--  in. Class-only never under-counts (GetInterruptData falls back to the class
--  default), so an unknown spec degrades the estimate rather than losing the bar.
-------------------------------------------------------------------------------
local function ApplyGroupSpecs()
    local changed = false
    for unit, info in pairs(trackedPlayers) do
        if unit ~= "player" then
            local specID = GroupSpecFor(unit)
            if specID and specID ~= info.specID then
                info.specID = specID
                -- The spec also yields a clean class token, which is the only
                -- one available when UnitClass came back secret.
                info.classToken = CleanClassToken(unit, specID) or info.classToken
                info.data       = ns.GetInterruptData(info.classToken, specID)
                changed         = true
            end
        end
    end
    if changed then
        RebuildPetGuidMap()
        RebuildDisplay()
    end
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

    -- A new cast can reorder the bars immediately (this unit's remaining time
    -- just jumped); don't wait for the next tick or the expiry timer.
    if info.cdDuration then ScheduleExpiry(unit, info) end
    RebuildDisplay()

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
        info.kickState = ClaimKickOutcome(unit)
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
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SENT")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
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
            -- The local player's own spellID is never secret, so this branch is
            -- always conclusive for them; remember it for the precedence rule
            -- guarding the fallback below.
            if actor == "player" then lastPlayerKickCast = GetTime() end
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
        if not (p and p.assumeUnreadableCasts ~= false and InterruptIsReady(info)) then return end

        -- Player precedence: nearly every party-member cast arrives unreadable,
        -- so a member's unrelated spell landing alongside OUR kick would run the
        -- fallback and start their cooldown for a kick they never pressed. When
        -- the local player has a clean interrupt cast in the same window, that
        -- one is the real kick and the guess is dropped.
        if actor ~= "player" and (GetTime() - lastPlayerKickCast) <= PLAYER_PRECEDENCE then return end

        ApplyInterruptCast(actor, info)

    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        -- unit, castGUID, spellID, interruptedBy
        local _, _, _, interruptedBy = ...
        -- CHANNEL_STOP also fires when a channel simply ENDS; only an
        -- interrupter GUID tells the two apart, so a bare stop is dropped
        -- rather than counted as a kick landing. INTERRUPTED always means a
        -- real interrupt and is kept even when the GUID is withheld.
        if event == "UNIT_SPELLCAST_CHANNEL_STOP" and interruptedBy == nil then return end
        recentInterrupts[#recentInterrupts + 1] = { time = GetTime(), guid = interruptedBy }

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

    -- Group spec intel over addon comms. Registering the callback is the whole
    -- integration -- the lib requests and rebroadcasts on its own, so nothing
    -- here ever calls its request functions. Writes only refresh the display on
    -- an actual CHANGE, so the burst of answers on a group join costs table
    -- writes plus a single rebuild.
    local LS = LibStub and LibStub("LibSpecialization", true)
    if LS then
        LS.RegisterGroup(EIT, function(specID, _, _, playerName)
            if type(specID) == "number" and type(playerName) == "string" then
                if groupSpecs[playerName] ~= specID then
                    groupSpecs[playerName] = specID
                    ApplyGroupSpecs()
                end
            end
        end)
    end

    CheckInstanceState()
    Apply()
    C_Timer.After(0, RebuildRoster)
    C_Timer.After(0.5, RegisterUnlockElements)
end
