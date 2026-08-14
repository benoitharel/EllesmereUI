-------------------------------------------------------------------------------
--  EllesmereUIDelves_Data.lua
--
--  Manually curated, per-season data that the WoW API does not expose:
--    * difficulty -- a rough "fast" / "medium" / "slow" duration tag. Every
--      delve shares the same 1-11 tier picker at its entrance, so nothing in
--      the API says one zone runs quicker than another; this is community
--      knowledge only, sourced from farming-route tier lists (see below).
--    * isBoss -- marks the season's Nemesis/"boss" delve (the one built from
--      that season's delve bosses, e.g. Midnight S1's Torment's Rise, or
--      Profondeurs de Chute-Venin/Venomfall Deeps in S2). Shown with a skull
--      icon in the popup.
--    * storyAchievementID -- the numeric ID of the delve's "<Name> Stories"
--      achievement, used to show whether its companion narrative has been
--      completed. There is no API to look this ID up by delve name, so it
--      has to be entered by hand (e.g. via the in-game achievement UI, or
--      Wowhead's achievement pages). Left nil for now -- fill in as you
--      confirm them in game.
--
--  Keyed by the EXACT delve name string the WoW API reports (accents,
--  apostrophes and punctuation must match). Use `/euidelves dump` in game to
--  print the exact names this season's delves report (and, for the boss
--  delve, whether it was actually detected live), then adjust the keys here
--  if anything doesn't match.
--
--  Delves are reshuffled every season -- this table needs a refresh each
--  time the roster changes. Entries left nil degrade gracefully: the delve
--  still lists, just without a difficulty tag or story checkmark.
-------------------------------------------------------------------------------
local EUI = EllesmereUI

-------------------------------------------------------------------------------
--  Midnight Season 1 (current as of 2026-08-14; Season 2 opens 2026-08-18
--  and adds The Ring of Glory, Gnarldor Isle and the Venomfall Deeps Nemesis
--  delve -- this table will need updating then).
--
--  Difficulty/speed tags below come from community farming-route tier lists
--  (e.g. aoeah's Midnight Delve Tier List). They reflect each delve's
--  typical/fastest-known story variant, not every variant equally -- the
--  story column in the popup shows which variant is active today so you can
--  cross-check.
-------------------------------------------------------------------------------
EUI.DELVES_DATA = EUI.DELVES_DATA or {
    -- Fast (S/A tier: ~1:10-1:15 clears on their quick variant)
    ["The Darkway"]          = { difficulty = "fast" },
    ["Collegiate Calamity"]  = { difficulty = "fast" },
    ["The Gulf of Memory"]   = { difficulty = "fast" },

    -- Medium (B tier)
    ["Sunkiller Sanctum"]    = { difficulty = "medium" },
    ["Parhelion Plaza"]      = { difficulty = "medium" },
    ["Twilight Crypts"]      = { difficulty = "medium" },

    -- Slow (C tier)
    ["Atal'Aman"]            = { difficulty = "slow" },
    ["Shadowguard Point"]    = { difficulty = "slow" },
    ["The Grudge Pit"]       = { difficulty = "slow" },
    ["The Shadow Enclave"]   = { difficulty = "slow" },

    -- Season 1 Nemesis/boss delve (Voidstorm). Only unlocks after clearing a
    -- Tier 7 delve with 1 life remaining -- no difficulty/speed tag since
    -- it's a fixed boss gauntlet, not a farming route.
    ["Torment's Rise"]       = { isBoss = true },
}

-- Known boss/Nemesis delve names for the current season. CollectDelves()
-- always lists these even if the live API scan doesn't surface them (e.g.
-- while still locked), so the boss delve is never silently missing.
EUI.DELVES_ALWAYS_SHOW = EUI.DELVES_ALWAYS_SHOW or {
    "Torment's Rise",
}
