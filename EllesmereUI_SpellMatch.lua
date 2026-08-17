if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUI_SpellMatch.lua
--
--  Shared "is this cast one of the spells I track?" resolver.
--
--  Since Midnight (12.0) the spellID delivered by UNIT_SPELLCAST_* events is a
--  SECRET value for every unit other than the local player and its pet. A
--  secret value cannot be compared or used as a table key, so the naive
--  `castSpellID == knownSpellID` test throws, and simply bailing out when the
--  value is secret means party/raid members are never tracked at all.
--
--  This module resolves the cast against a caller-supplied list of known spell
--  IDs using a cascade of techniques, cheapest and most reliable first. Every
--  step is failure-tolerant: a step that cannot produce a clean answer falls
--  through to the next one, and the whole thing returns nil rather than
--  erroring when nothing works.
--
--    1. direct    -- value is not secret; plain numeric comparison.
--    2. name      -- C_Spell.GetSpellName() on a secret ID very often returns a
--                    CLEAN string; compare it against the (always clean) names
--                    of the candidate IDs. This is the workhorse for party
--                    members and the step that makes the whole thing viable.
--    3. base      -- C_Spell.GetBaseSpell() sometimes yields a clean base ID,
--                    and additionally normalises talent-modified variants back
--                    to the spell we actually track.
--    4. launder   -- push the value through a hidden Slider's OnValueChanged so
--                    the C++ side re-emits an untainted copy. Undocumented
--                    engine behaviour, kept strictly as a last resort: if
--                    Blizzard closes it this step just stops producing answers.
--
--  Callers that need to cope with a total resolution failure should implement
--  their own corroboration (e.g. "assume it was the tracked spell, but only if
--  that spell is currently off cooldown") -- see EllesmereUI.SpellMatch.Failed.
-------------------------------------------------------------------------------

local SpellMatch = {}
EllesmereUI.SpellMatch = SpellMatch

-- Set true (e.g. from a slash command) to print which cascade step resolved
-- each cast. Useful to confirm the name step is doing the party-member work.
SpellMatch.debug = false

local function Debug(msg)
    if SpellMatch.debug then
        print("|cff0cd29f[EUI SpellMatch]|r " .. msg)
    end
end

-------------------------------------------------------------------------------
--  Clean-name cache for known (static, never secret) spell IDs
-------------------------------------------------------------------------------
local nameCache = {}

local function KnownSpellName(spellID)
    if not spellID or spellID == 0 then return nil end
    local cached = nameCache[spellID]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    local ok, name = pcall(C_Spell.GetSpellName, spellID)
    if ok and name and name ~= "" then
        nameCache[spellID] = name
        return name
    end
    -- Cache the miss as `false` so a spell the client cannot name (not yet
    -- loaded, removed from the game) is not re-queried on every single cast.
    nameCache[spellID] = false
    return nil
end

-------------------------------------------------------------------------------
--  Slider laundering (last resort)
-------------------------------------------------------------------------------
local Launder
do
    local slider = CreateFrame("Slider", nil, UIParent)
    slider:SetMinMaxValues(0, 9999999)
    slider:SetSize(1, 1)
    slider:Hide()

    local result
    slider:SetScript("OnValueChanged", function(_, v) result = v end)

    local function IsClean(n)
        if type(n) ~= "number" then return false end
        local ok = pcall(function() local _ = ({ [n] = true })[n] end)
        return ok
    end

    function Launder(raw)
        if raw == nil then return nil end
        if type(raw) == "number" and IsClean(raw) then return raw end

        -- string.format strips the taint off numeric primitives on many builds.
        local okF, s = pcall(string.format, "%.0f", raw)
        if okF and s then
            local okN, num = pcall(tonumber, s)
            if okN and num and IsClean(num) then return num end
        end

        -- The two SetValue calls MUST sit in separate pcalls: sharing one means
        -- a successful reset-to-0 followed by a silently failing tainted
        -- SetValue(raw) would leave `result` stuck on the stale 0 and report a
        -- false clean value instead of a failure.
        result = nil
        pcall(slider.SetValue, slider, 0)
        result = nil
        local okS = pcall(slider.SetValue, slider, raw)
        if okS and result and result ~= 0 then
            local okN, num = pcall(tonumber, result)
            if okN and num and IsClean(num) then return num end
        end

        return nil
    end
end

SpellMatch.Launder = Launder

-------------------------------------------------------------------------------
--  IsSecret(value) -- safe wrapper; issecretvalue is absent on older clients.
-------------------------------------------------------------------------------
local function IsSecret(v)
    if type(issecretvalue) ~= "function" then return false end
    local ok, res = pcall(issecretvalue, v)
    return ok and res == true
end

SpellMatch.IsSecret = IsSecret

-------------------------------------------------------------------------------
--  EllesmereUI.SpellCD -- real cooldown readout for the LOCAL PLAYER's spells.
--
--  Contrary to a widespread assumption, C_Spell.GetSpellCooldown's startTime /
--  duration ARE readable in Midnight for spells the player owns -- only other
--  units' cooldowns are unavailable (no API exposes them at all). Reading the
--  API instead of a hardcoded base cooldown makes the player's own timers exact
--  for free: talent reductions, spec modifiers, haste scaling and reset effects
--  are all already baked into what the game reports.
--
--  Every field goes through ReadNum, which rejects both non-numbers and secret
--  values, so a spell the client decides to hide simply yields nil instead of
--  tainting the caller.
-------------------------------------------------------------------------------
local SpellCD = {}
EllesmereUI.SpellCD = SpellCD

local function ReadNum(t, key)
    local ok, v = pcall(function() return t and t[key] end)
    if not ok or type(v) ~= "number" then return nil end
    if IsSecret(v) then return nil end
    return v
end

-- GetReal(spellID) → startTime, duration  (nil when unreadable)
--
-- A duration at or below the global cooldown means we are only seeing the GCD
-- ticking, not the spell's own cooldown, so it is reported as "no real CD".
function SpellCD.GetReal(spellID)
    if not spellID or spellID == 0 then return nil end
    if not C_Spell or not C_Spell.GetSpellCooldown then return nil end

    local ok, cd = pcall(C_Spell.GetSpellCooldown, spellID)
    if not ok or not cd then return nil end

    local start    = ReadNum(cd, "startTime")
    local duration = ReadNum(cd, "duration")
    if not start or not duration then return nil end
    if duration <= 1.5 then return nil end

    return start, duration
end

-- IsActive(spellID) → true | false | nil
--
--   true  -- the spell is on cooldown right now
--   false -- the spell is ready
--   nil   -- UNREADABLE (the client is hiding it)
--
-- Crucial companion to GetReal: that function also returns nil when the timing
-- fields are secret, and "unreadable" must never be mistaken for "ready" --
-- doing so wipes a perfectly good cooldown that was tracked from the cast
-- event and shows the spell as available while it is not. isActive is a plain
-- boolean and commonly survives when startTime/duration do not.
function SpellCD.IsActive(spellID)
    if not spellID or spellID == 0 then return nil end
    if not C_Spell or not C_Spell.GetSpellCooldown then return nil end

    local ok, cd = pcall(C_Spell.GetSpellCooldown, spellID)
    if not ok or not cd then return nil end

    local okA, active = pcall(function() return cd.isActive end)
    if not okA or type(active) ~= "boolean" then return nil end
    if IsSecret(active) then return nil end
    return active
end

-------------------------------------------------------------------------------
--  FindMatch(rawSpellID, candidates) → matchedID, method, conclusive
--
--  `candidates` is an array of known, clean spell IDs (our own static data).
--
--  Returns:
--    matchedID   -- the candidate the cast resolved to, or nil
--    method      -- which cascade step produced it
--                   ("direct" | "name" | "base" | "launder"), or nil
--    conclusive  -- only meaningful when matchedID is nil:
--                     true  = the cast WAS readable and is definitely some
--                             other spell -- callers should ignore it.
--                     false = the cast could not be read at all -- callers may
--                             apply their own corroboration to guess.
--
--  Distinguishing those two nil cases matters a lot: a group member casts
--  constantly, and treating every "no match" as unreadable would make any
--  guess-based fallback fire on nearly every spell they use.
-------------------------------------------------------------------------------
function SpellMatch.FindMatch(rawSpellID, candidates)
    if rawSpellID == nil or type(candidates) ~= "table" or #candidates == 0 then
        return nil, nil, false
    end

    local secret = IsSecret(rawSpellID)
    -- Set as soon as ANY step manages to read the cast's identity, whether or
    -- not it matched one of our candidates.
    local readable = false

    -- 1. Direct numeric comparison (local player / pet path).
    if not secret and type(rawSpellID) == "number" then
        readable = true
        for _, id in ipairs(candidates) do
            if id == rawSpellID then
                Debug("direct hit " .. id)
                return id, "direct", true
            end
        end
    end

    -- 2. Name comparison. A secret ID commonly yields a CLEAN name string --
    --    this is the step that carries party members.
    local okN, castName = pcall(C_Spell.GetSpellName, rawSpellID)
    if okN and castName and not IsSecret(castName) and castName ~= "" then
        readable = true
        for _, id in ipairs(candidates) do
            if KnownSpellName(id) == castName then
                Debug("name hit " .. id .. " (" .. castName .. ")")
                return id, "name", true
            end
        end
    end

    -- 3. Base spell: normalises talent-modified variants and can hand back a
    --    clean ID even when the event's own value stays secret.
    local okB, baseID = pcall(C_Spell.GetBaseSpell, rawSpellID)
    if okB and baseID and not IsSecret(baseID) and type(baseID) == "number" then
        readable = true
        for _, id in ipairs(candidates) do
            if id == baseID then
                Debug("base hit " .. id)
                return id, "base", true
            end
        end
    end

    -- 4. Slider laundering, last resort.
    if secret then
        local clean = Launder(rawSpellID)
        if clean then
            readable = true
            for _, id in ipairs(candidates) do
                if id == clean then
                    Debug("launder hit " .. id)
                    return id, "launder", true
                end
            end
        end
    end

    Debug(readable and "readable, not one of ours"
                    or ("UNREADABLE cast (secret=" .. tostring(secret) .. ")"))
    return nil, nil, readable
end

-------------------------------------------------------------------------------
--  MatchesOne(rawSpellID, knownSpellID) → boolean
--  Convenience wrapper for the single-candidate case.
-------------------------------------------------------------------------------
local oneShot = {}
function SpellMatch.MatchesOne(rawSpellID, knownSpellID)
    if not knownSpellID or knownSpellID == 0 then return false end
    oneShot[1] = knownSpellID
    local matched = SpellMatch.FindMatch(rawSpellID, oneShot)
    return matched ~= nil
end

-------------------------------------------------------------------------------
--  Slash command to flip the debug print on/off at runtime.
-------------------------------------------------------------------------------
SLASH_EUISPELLMATCH1 = "/euispellmatch"
SlashCmdList.EUISPELLMATCH = function()
    SpellMatch.debug = not SpellMatch.debug
    print("|cff0cd29f[EUI SpellMatch]|r debug " .. (SpellMatch.debug and "ON" or "OFF"))
end
