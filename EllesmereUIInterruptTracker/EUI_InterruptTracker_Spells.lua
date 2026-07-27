-------------------------------------------------------------------------------
--  EUI_InterruptTracker_Spells.lua
--
--  Interrupt spell database: per-class defaults, spec overrides, talent CD
--  reductions, and the GetInterruptData resolver.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
if _G._EIT_Spells_Loaded then return end
_G._EIT_Spells_Loaded = true

-------------------------------------------------------------------------------
--  Default interrupt per class token
--  source = "self" | "pet"
-------------------------------------------------------------------------------
ns.CLASS_INTERRUPT = {
    DEATHKNIGHT = { spellID = 47528,  cd = 15, source = "self" },
    DEMONHUNTER = { spellID = 183752, cd = 15, source = "self" },
    DRUID       = { spellID = 106839, cd = 15, source = "self" },
    EVOKER      = { spellID = 351338, cd = 40, source = "self" },
    HUNTER      = { spellID = 147362, cd = 24, source = "self" }, -- BM/MM default
    MAGE        = { spellID = 2139,   cd = 24, source = "self" },
    MONK        = { spellID = 116705, cd = 15, source = "self" },
    PALADIN     = { spellID = 96231,  cd = 15, source = "self" },
    PRIEST      = { spellID = 15487,  cd = 45, source = "self" }, -- Shadow default
    ROGUE       = { spellID = 1766,   cd = 15, source = "self" },
    SHAMAN      = { spellID = 57994,  cd = 12, source = "self" },
    WARLOCK     = { spellID = 19647,  cd = 24, source = "pet"  }, -- Felhunter Spell Lock
    WARRIOR     = { spellID = 6552,   cd = 15, source = "self" },
}

-------------------------------------------------------------------------------
--  Spec overrides (keyed by WoW specID from GetSpecializationInfo /
--  GetInspectSpecialization).  false = no interrupt for this spec.
--
--  Spec IDs (verified against WoW Midnight 12.0 data):
--    256 = Discipline Priest
--    257 = Holy Priest
--    258 = Shadow Priest
--    255 = Survival Hunter
--    267 = Demonology Warlock
-------------------------------------------------------------------------------
ns.SPEC_OVERRIDE = {
    [255] = { spellID = 187707, cd = 15, source = "self" }, -- Survival Hunter  → Muzzle
    [267] = { spellID = 89766,  cd = 30, source = "pet"  }, -- Demo Warlock     → Axe Toss (Felguard)
    [258] = { spellID = 15487,  cd = 45, source = "self" }, -- Shadow Priest    → Silence (explicit)
    [257] = false,                                           -- Holy Priest      → no interrupt
    [256] = false,                                           -- Discipline Priest → no interrupt
}

-------------------------------------------------------------------------------
--  Talent CD reductions used to live here, keyed by talent spell ID. The table
--  never worked (every entry had talentSpellID = 0, so nothing could match) and
--  is now unnecessary: the local player's real cooldown is read straight from
--  C_Spell.GetSpellCooldown, which already accounts for talents and every other
--  modifier. Other players' cooldowns are not exposed by any API, so no amount
--  of talent data would let us compute theirs reliably.
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
--  GetInterruptData(classToken, specID) → data table | false | nil
--
--  Returns:
--    table  - interrupt data { spellID, cd, source }
--    false  - spec explicitly has no interrupt (Holy/Disc Priest)
--    nil    - classToken unknown
--
--  Spec override takes priority over class default.  specID may be nil when
--  not yet resolved (inspection pending); class default is used in that case.
-------------------------------------------------------------------------------
function ns.GetInterruptData(classToken, specID)
    if specID then
        local override = ns.SPEC_OVERRIDE[specID]
        if override ~= nil then -- explicit entry (could be false)
            return override
        end
    end
    return ns.CLASS_INTERRUPT[classToken] -- may be nil for unknown class
end
