-------------------------------------------------------------------------------
--  EllesmereUIDelves_Data.lua
--
--  Manually curated, per-season data that the WoW API does not expose:
--    * difficulty -- a rough "fast" / "medium" / "slow" duration tag. Every
--      delve shares the same 1-11 tier picker at its entrance, so nothing in
--      the API says one zone runs quicker than another; this is community
--      knowledge only.
--    * storyAchievementID -- the numeric ID of the delve's "<Name> Stories"
--      achievement, used to show whether its companion narrative has been
--      completed. There is no API to look this ID up by delve name, so it
--      has to be entered by hand (e.g. via the in-game achievement UI, or
--      Wowhead's achievement pages).
--
--  Keyed by the EXACT delve name string the WoW API reports (accents,
--  apostrophes and punctuation must match). Use `/euidelves dump` in game to
--  print the exact names this season's delves report, then fill them in
--  below.
--
--  Delves are reshuffled every season -- this table needs a refresh each
--  time the roster changes. Entries left nil degrade gracefully: the delve
--  still lists, just without a difficulty tag or story checkmark.
-------------------------------------------------------------------------------
local EUI = EllesmereUI

EUI.DELVES_DATA = EUI.DELVES_DATA or {
    -- ["The Grudge Pit"] = { difficulty = "fast", storyAchievementID = 12345 },
}
