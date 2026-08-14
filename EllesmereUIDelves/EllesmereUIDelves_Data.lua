-------------------------------------------------------------------------------
--  EllesmereUIDelves_Data.lua
--
--  Manually curated, per-season data that the WoW API does not expose:
--    * difficulty -- a rough "fast" / "medium" / "slow" duration tag. Every
--      delve shares the same 1-11 tier picker at its entrance, so nothing in
--      the API says one zone runs quicker than another; this is community
--      knowledge only, sourced from farming-route tier lists (see below).
--    * storyAchievementID -- the numeric ID of the delve's "<Name> Stories"
--      achievement, used to show whether its companion narrative has been
--      completed. There is no API to look this ID up by delve name, so it
--      has to be entered by hand (e.g. via the in-game achievement UI, or
--      Wowhead's achievement pages). Left nil for now -- fill in as you
--      confirm them in game.
--
--  Keyed by the EXACT delve name string the WoW API reports, which is
--  LOCALE-DEPENDENT (French client -> French names, no English fallback).
--  Accents and the apostrophe character must match exactly -- a mismatch
--  fails silently (delve still lists, just without a difficulty tag), so
--  run `/euidelves dump` in game and diff the printed names against the
--  keys below if something still shows "?". Confirmed live: the French
--  client uses the typographic apostrophe (’, U+2019), not a plain ' --
--  a first pass with plain apostrophes silently missed every entry that
--  had one (Atal'Aman, l'Ombre-Garde, L'enclave).
--
--  Delves are reshuffled every season -- this table needs a refresh each
--  time the roster changes.
-------------------------------------------------------------------------------
local EUI = EllesmereUI

-------------------------------------------------------------------------------
--  Midnight Season 2 (live as of this writing -- Season 2 added The Ring of
--  Glory, Gnarldor Isle and the Venomfall Deeps Nemesis delve on top of the
--  10 Season 1 delves, which stayed in rotation).
--
--  Difficulty/speed tags for the 10 Season 1 delves come from community
--  farming-route tier lists (e.g. aoeah's Midnight Delve Tier List) and
--  reflect each delve's typical/fastest-known story variant, not every
--  variant equally -- the story column in the popup shows which variant is
--  active today so you can cross-check. The Ring of Glory / Gnarldor Isle
--  are brand new this season; no tier-list data exists yet.
-------------------------------------------------------------------------------
EUI.DELVES_DATA = EUI.DELVES_DATA or {
    -- Fast (S/A tier: ~1:10-1:15 clears on their quick variant)
    ["Sombrevoie"]            = { difficulty = "fast" }, -- The Darkway
    ["Calamité Universitaire"] = { difficulty = "fast" }, -- Collegiate Calamity
    ["Le golfe du Souvenir"]  = { difficulty = "fast" },  -- The Gulf of Memory

    -- Medium (B tier)
    ["Sanctum des Tue-Soleil"] = { difficulty = "medium" }, -- Sunkiller Sanctum
    ["Place Parhélion"]       = { difficulty = "medium" },  -- Parhelion Plaza
    ["Cryptes du Crépuscule"] = { difficulty = "medium" },  -- Twilight Crypts

    -- Slow (C tier)
    ["Atal’Aman"]             = { difficulty = "slow" }, -- typographic apostrophe (U+2019), not '
    ["Halte de l’Ombre-Garde"] = { difficulty = "slow" }, -- Shadowguard Point
    ["La fosse de la Rancœur"] = { difficulty = "slow" }, -- The Grudge Pit
    ["L’enclave Ombreuse"]    = { difficulty = "slow" },  -- The Shadow Enclave

    -- New in Season 2 -- no community speed data yet.
    ["Arène de la Gloire"]    = {}, -- The Ring of Glory
    ["Île Torsadine"]         = {}, -- Gnarldor Isle
}

-------------------------------------------------------------------------------
--  Nemesis/boss delves to hide from the list entirely (irrelevant to
--  "fastest delve for the weekly vault"). Exact names go in DELVES_EXCLUDE;
--  DELVES_EXCLUDE_PATTERNS holds plain Lua patterns for names not yet
--  confirmed via `/euidelves dump` (the in-game popup showed this one
--  truncated as "Profondeurs de Chute-...").
-------------------------------------------------------------------------------
EUI.DELVES_EXCLUDE = EUI.DELVES_EXCLUDE or {
    -- ["Torment's Rise (French name TBD)"] = true,
}

EUI.DELVES_EXCLUDE_PATTERNS = EUI.DELVES_EXCLUDE_PATTERNS or {
    "^Profondeurs de Chute", -- Venomfall Deeps, Season 2 Nemesis delve
}
