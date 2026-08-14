-------------------------------------------------------------------------------
--  EllesmereUIDelves.lua
--  /euidelves slash command: an overview popup listing this season's Delves,
--  their bountiful status, story-completion state and (once hand-filled in
--  EllesmereUIDelves_Data.lua) a difficulty/duration tag -- so the player can
--  see at a glance which delve is fastest to complete for the weekly vault
--  and which one they haven't done the story for yet.
-------------------------------------------------------------------------------
local EUI = EllesmereUI
local PP = EUI and EUI.PP

-------------------------------------------------------------------------------
--  Delve discovery
--
--  Delve area-POIs are queried per zone map, not globally, and Blizzard
--  reshuffles the delve roster (and the zones that host them) every season.
--  Rather than hardcode continent/zone map IDs -- which would need updating
--  right alongside the per-delve data table -- we walk up from the player's
--  current zone to its continent, then query every zone under that
--  continent. This stays correct across expansions and season resets with no
--  maintenance.
-------------------------------------------------------------------------------
local function FindContinentMapID()
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local guard = 0
    while mapID and guard < 10 do
        local info = C_Map.GetMapInfo(mapID)
        if not info then return nil end
        if info.mapType == Enum.UIMapType.Continent then return mapID end
        if not info.parentMapID or info.parentMapID == 0 then return mapID end
        mapID = info.parentMapID
        guard = guard + 1
    end
    return mapID
end

local function CollectZoneMapIDs()
    local continentMapID = FindContinentMapID()
    if not continentMapID then return {} end
    local zones = { continentMapID }
    if C_Map.GetMapChildrenInfo then
        local children = C_Map.GetMapChildrenInfo(continentMapID, Enum.UIMapType.Zone, true)
        if children then
            for _, z in ipairs(children) do zones[#zones + 1] = z.mapID end
        end
    end
    return zones
end

-------------------------------------------------------------------------------
--  Story-variant text
--
--  AreaPOIInfo.description is NOT the story name for delves -- in game it
--  shows the generic "Delve" type label. The actual story name lives in the
--  POI's tooltipWidgetSet, read out the same way the open-source addon
--  "wow-delverview" (kemayo) does it, confirmed against a live client:
--
--    * Delve entrances only ever carry TextWithState widgets.
--    * orderIndex 0 is the story-variant line, text formatted as
--      "Story Variant: |cnWHITE_FONT_COLOR:<name>|r" -- strip the color code
--      to get the bare name.
--    * orderIndex 1 (when present) is the bountiful/coffer-key/timer line;
--      its mere presence is a secondary bountiful signal.
--
--  (GameTooltip_AddWidgetSet itself was avoided -- per wow-delverview's
--  author it can run into "secret value" protections when called outside a
--  real tooltip hover; reading the widget data directly via
--  C_UIWidgetManager sidesteps that.)
-------------------------------------------------------------------------------
local function ExtractDelveStoryVariant(widgetSetID)
    if not widgetSetID or not (C_UIWidgetManager and C_UIWidgetManager.GetAllWidgetsBySetID) then
        return nil, false
    end
    local widgets = C_UIWidgetManager.GetAllWidgetsBySetID(widgetSetID)
    if not widgets then return nil, false end

    local variant, hasSecondLine
    for _, w in ipairs(widgets) do
        if w.widgetType == Enum.UIWidgetVisualizationType.TextWithState then
            local ok, info = pcall(C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo, w.widgetID)
            if ok and info and info.text then
                if info.orderIndex == 0 then
                    variant = info.text:match("|cnWHITE_FONT_COLOR:(.+)|r")
                        or info.text:match("|cnWHITE_FONT_COLOR:(.+)$")
                        or info.text
                elseif info.orderIndex == 1 then
                    hasSecondLine = true
                end
            end
        end
    end
    return variant, hasSecondLine
end

local function StoryDoneFor(data)
    if not (data and data.storyAchievementID) then return nil end
    local _, _, _, completed = GetAchievementInfo(data.storyAchievementID)
    return completed and true or false
end

-- Season-specific delves we never want listed (Nemesis/boss gauntlets --
-- irrelevant to "fastest delve for the weekly vault"). Matched against the
-- exact name first, then against EUI.DELVES_EXCLUDE_PATTERNS (plain Lua
-- patterns, for names not yet confirmed via `/euidelves dump`).
local function IsExcluded(name)
    if EUI.DELVES_EXCLUDE and EUI.DELVES_EXCLUDE[name] then return true end
    if EUI.DELVES_EXCLUDE_PATTERNS then
        for _, pattern in ipairs(EUI.DELVES_EXCLUDE_PATTERNS) do
            if name:find(pattern) then return true end
        end
    end
    return false
end

local function MakeEntry(name, zoneMapID, info)
    local data = EUI.DELVES_DATA and EUI.DELVES_DATA[name]
    local variant, hasSecondWidgetLine = ExtractDelveStoryVariant(info.tooltipWidgetSet)
    return {
        name = name,
        bountiful = (info.atlasName == "delves-bountiful") or info.shouldGlow or hasSecondWidgetLine or false,
        storyVariant = variant,
        tooltipWidgetSet = info.tooltipWidgetSet,
        zoneMapID = zoneMapID,
        difficulty = data and data.difficulty,
        storyDone = StoryDoneFor(data),
    }
end

-- One entry per delve found under the player's current continent.
local function CollectDelves()
    local results = {}
    local seen = {}

    if C_AreaPoiInfo and C_AreaPoiInfo.GetDelvesForMap and C_AreaPoiInfo.GetAreaPOIInfo then
        for _, zoneMapID in ipairs(CollectZoneMapIDs()) do
            local poiIDs = C_AreaPoiInfo.GetDelvesForMap(zoneMapID)
            if poiIDs then
                for _, poiID in ipairs(poiIDs) do
                    local info = C_AreaPoiInfo.GetAreaPOIInfo(zoneMapID, poiID)
                    if info and info.name and not seen[info.name] and not IsExcluded(info.name) then
                        seen[info.name] = true
                        results[#results + 1] = MakeEntry(info.name, zoneMapID, info)
                    end
                end
            end
        end
    end

    table.sort(results, function(a, b)
        if a.bountiful ~= b.bountiful then return a.bountiful end
        return a.name < b.name
    end)
    return results
end

-------------------------------------------------------------------------------
--  Weekly vault progress (delve/world activity row)
-------------------------------------------------------------------------------
local function DelveVaultProgress()
    if not (C_WeeklyRewards and C_WeeklyRewards.GetActivities) then return nil end
    local GV_WORLD = (Enum and Enum.WeeklyRewardChestThresholdType and Enum.WeeklyRewardChestThresholdType.World) or 6
    local acts = C_WeeklyRewards.GetActivities(GV_WORLD)
    if type(acts) ~= "table" or #acts == 0 then return nil end
    local progress, threshold = 0, 0
    for _, a in ipairs(acts) do
        progress = math.max(progress, tonumber(a.progress) or 0)
        threshold = math.max(threshold, tonumber(a.threshold) or 0)
    end
    return progress, threshold
end

-------------------------------------------------------------------------------
--  Difficulty tag display
-------------------------------------------------------------------------------
local DIFFICULTY_LABEL = { fast = "Fast", medium = "Medium", slow = "Slow" }
local DIFFICULTY_COLOR = {
    fast   = { 0.12, 1, 0 },
    medium = { 0.98, 0.82, 0.16 },
    slow   = { 1, 0.35, 0.25 },
}

-------------------------------------------------------------------------------
--  Popup UI (row-pool list inside a scroll frame, same shape as the
--  Keystones popup in EllesmereUIQoL/EllesmereUIQoL_Keys.lua)
-------------------------------------------------------------------------------
local POPUP_W  = 420
local ROW_H    = 20
local ROW_GAP  = 4
local TITLE_H  = 27
local PAD      = 10
local HDR_H    = 16
local MAX_CONTENT_H = 360

local popup, rowFrames
local ShowDelvesPopup -- forward declaration

local function ResolveFont()
    return (EUI and EUI.GetFontPath and EUI.GetFontPath("extras")) or "Fonts\\FRIZQT__.TTF"
end

local function ResolveOutline()
    return (EUI and EUI.GetFontOutlineFlag and EUI.GetFontOutlineFlag("extras")) or ""
end

local function MakeLabel(parent, size, flagsArg, r, g, b, a)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    local flags = flagsArg or ResolveOutline()
    if EUI and EUI.PrimeFontShadow then EUI.PrimeFontShadow(fs, flags == "") end
    fs:SetFont(ResolveFont(), size, flags)
    if r then fs:SetTextColor(r, g or 1, b or 1, a or 1) end
    return fs
end

local function MakeSolid(parent, layer, r, g, b, a, sub)
    local t = parent:CreateTexture(nil, layer, nil, sub or 0)
    t:SetColorTexture(r, g, b, a)
    return t
end

local function BuildPopup()
    if popup then return popup end
    rowFrames = {}

    popup = CreateFrame("Frame", "EUIDelvesPopup", UIParent)
    popup:SetSize(POPUP_W, 100)
    popup:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    popup:SetFrameStrata("DIALOG")
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", function(s) s:StartMoving() end)
    popup:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)

    local bg = popup:CreateTexture(nil, "BACKGROUND", nil, 0)
    bg:SetAllPoints()
    bg:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\modern_blizz.png")
    bg:SetTexCoord(0.25, 1, 0, 0.75)
    local overlay = popup:CreateTexture(nil, "BACKGROUND", nil, 1)
    overlay:SetAllPoints()
    overlay:SetColorTexture(0, 0, 0, 0.55)

    if PP and PP.CreateBorder then PP.CreateBorder(popup, 0.1, 0.1, 0.1, 1, 1, "OVERLAY", 7) end

    local hdrBg = MakeSolid(popup, "BORDER", 0, 0, 0, 0.25)
    hdrBg:SetPoint("TOPLEFT", 1, -1); hdrBg:SetPoint("TOPRIGHT", -1, 0); hdrBg:SetHeight(TITLE_H)

    local title = MakeLabel(popup, 11, "OUTLINE", 1, 1, 1, 1)
    title:SetPoint("TOPLEFT", PAD, -8); title:SetText("EllesmereUI Delves")

    popup._vaultFS = MakeLabel(popup, 10, nil, 0.7, 0.7, 0.7, 1)
    popup._vaultFS:SetPoint("LEFT", title, "RIGHT", 10, 0)

    local ICON_SZ = 14
    local ICON_ALPHA = 0.5

    local xBtn = CreateFrame("Button", nil, popup)
    xBtn:SetSize(ICON_SZ, ICON_SZ)
    xBtn:SetPoint("RIGHT", hdrBg, "RIGHT", -8, 0)
    local xTex = xBtn:CreateTexture(nil, "ARTWORK")
    xTex:SetAllPoints()
    xTex:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-close.png")
    xTex:SetAlpha(ICON_ALPHA)
    xBtn:SetScript("OnEnter", function() xTex:SetAlpha(1) end)
    xBtn:SetScript("OnLeave", function() xTex:SetAlpha(ICON_ALPHA) end)
    xBtn:SetScript("OnClick", function() popup:Hide() end)

    local refBtn = CreateFrame("Button", nil, popup)
    refBtn:SetSize(ICON_SZ, ICON_SZ)
    refBtn:SetPoint("RIGHT", xBtn, "LEFT", -6, 0)
    local refTex = refBtn:CreateTexture(nil, "ARTWORK")
    refTex:SetAllPoints()
    refTex:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\icons\\unlock-reset.png")
    refTex:SetAlpha(ICON_ALPHA)
    refBtn:SetScript("OnEnter", function()
        refTex:SetAlpha(1)
        if EUI and EUI.ShowWidgetTooltip then EUI.ShowWidgetTooltip(refBtn, "Refresh") end
    end)
    refBtn:SetScript("OnLeave", function()
        refTex:SetAlpha(ICON_ALPHA)
        if EUI and EUI.HideWidgetTooltip then EUI.HideWidgetTooltip() end
    end)
    refBtn:SetScript("OnClick", function() ShowDelvesPopup() end)

    if EUI and EUI.RegisterEscapeClose then EUI.RegisterEscapeClose(popup) end

    local sf = CreateFrame("ScrollFrame", nil, popup)
    sf:SetPoint("TOPLEFT", PAD, -(TITLE_H + 8))
    sf:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local child = self:GetScrollChild()
        local maxS = math.max(0, (child and child:GetHeight() or 0) - self:GetHeight())
        self:SetVerticalScroll(math.max(0, math.min(maxS, cur - delta * 20)))
    end)
    popup._body = CreateFrame("Frame", nil, sf)
    popup._body:SetWidth(POPUP_W - PAD * 2)
    popup._body:SetHeight(1)
    sf:SetScrollChild(popup._body)
    popup._sf = sf

    popup:Hide()
    return popup
end

local function AcquireRow(i)
    if rowFrames[i] then return rowFrames[i] end
    local p = BuildPopup()
    local r = CreateFrame("Frame", nil, p._body)
    r:SetHeight(ROW_H)

    if i % 2 == 0 then
        local alt = MakeSolid(r, "BACKGROUND", 0, 0, 0, 0.15)
        alt:SetAllPoints()
    end

    r._bountyFS = MakeLabel(r, 11, "OUTLINE", 0.98, 0.82, 0.16, 1)
    r._bountyFS:SetPoint("LEFT", 2, 0); r._bountyFS:SetWidth(14); r._bountyFS:SetJustifyH("LEFT")

    r._nameFS = MakeLabel(r, 11, nil, 1, 1, 1, 0.9)
    r._nameFS:SetPoint("LEFT", r._bountyFS, "RIGHT", 2, 0); r._nameFS:SetWidth(150); r._nameFS:SetJustifyH("LEFT")
    r._nameFS:SetWordWrap(false)

    r._storyVariantFS = MakeLabel(r, 10, nil, 0.6, 0.6, 0.6, 1)
    r._storyVariantFS:SetPoint("LEFT", r._nameFS, "RIGHT", 6, 0); r._storyVariantFS:SetWidth(140); r._storyVariantFS:SetJustifyH("LEFT")
    r._storyVariantFS:SetWordWrap(false)

    r._difficultyFS = MakeLabel(r, 10, nil, 0.7, 0.7, 0.7, 1)
    r._difficultyFS:SetPoint("LEFT", r._storyVariantFS, "RIGHT", 6, 0); r._difficultyFS:SetWidth(55); r._difficultyFS:SetJustifyH("LEFT")

    r._storyDoneFS = MakeLabel(r, 11, "OUTLINE", 1, 1, 1, 1)
    r._storyDoneFS:SetPoint("RIGHT", -2, 0); r._storyDoneFS:SetJustifyH("RIGHT")

    local sep = r:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(1, 1, 1, 0.10)
    if PP and PP.DisablePixelSnap then PP.DisablePixelSnap(sep) end
    sep:SetHeight((PP and PP.mult) or 1)
    local gapMid = -math.floor(ROW_GAP / 2)
    sep:SetPoint("BOTTOMLEFT", 0, gapMid); sep:SetPoint("BOTTOMRIGHT", 0, gapMid)

    rowFrames[i] = r
    return r
end

local function PopulateRow(r, e)
    r._bountyFS:SetText(e.bountiful and "\226\152\133" or "") -- star glyph
    r._nameFS:SetText(e.name)
    r._nameFS:SetTextColor(e.bountiful and 0.98 or 1, e.bountiful and 0.82 or 1, e.bountiful and 0.16 or 1, 1)
    r._storyVariantFS:SetText(e.storyVariant or "")

    if e.difficulty and DIFFICULTY_LABEL[e.difficulty] then
        local c = DIFFICULTY_COLOR[e.difficulty]
        r._difficultyFS:SetText(DIFFICULTY_LABEL[e.difficulty])
        r._difficultyFS:SetTextColor(c[1], c[2], c[3], 1)
    else
        r._difficultyFS:SetText("?")
        r._difficultyFS:SetTextColor(0.5, 0.5, 0.5, 0.7)
    end

    if e.storyDone == true then
        r._storyDoneFS:SetText("\226\156\147") -- check mark
        r._storyDoneFS:SetTextColor(0.12, 1, 0, 1)
    elseif e.storyDone == false then
        r._storyDoneFS:SetText("\226\128\148") -- em dash
        r._storyDoneFS:SetTextColor(0.6, 0.6, 0.6, 0.7)
    else
        r._storyDoneFS:SetText("?")
        r._storyDoneFS:SetTextColor(0.5, 0.5, 0.5, 0.5)
    end
end

ShowDelvesPopup = function()
    local p = BuildPopup()
    local body = p._body
    local contentW = POPUP_W - PAD * 2

    local progress, threshold = DelveVaultProgress()
    if progress then
        p._vaultFS:SetText(("Vault: %d/%d"):format(progress, threshold))
    else
        p._vaultFS:SetText("")
    end

    local entries = CollectDelves()

    for i = 1, #rowFrames do rowFrames[i]:Hide() end

    local curY = 0
    if #entries == 0 then
        local r = AcquireRow(1)
        r._bountyFS:SetText(""); r._storyVariantFS:SetText(""); r._difficultyFS:SetText(""); r._storyDoneFS:SetText("")
        r._nameFS:SetText("No delves found on this continent")
        r._nameFS:SetWidth(contentW)
        r._nameFS:SetTextColor(0.5, 0.5, 0.5, 0.7)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", body, "TOPLEFT", 0, curY)
        r:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, curY)
        r:Show()
        curY = curY - ROW_H
    else
        for idx, e in ipairs(entries) do
            local r = AcquireRow(idx)
            PopulateRow(r, e)
            r._nameFS:SetWidth(150)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", body, "TOPLEFT", 0, curY)
            r:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, curY)
            r:Show()
            curY = curY - (ROW_H + ROW_GAP)
        end
        curY = curY + ROW_GAP
    end

    local totalH = math.abs(curY)
    body:SetHeight(totalH)
    local visH = math.min(totalH, MAX_CONTENT_H)
    p:SetHeight(TITLE_H + 8 + math.max(visH, HDR_H) + PAD)

    p:Show()
end

-------------------------------------------------------------------------------
--  Slash commands
--    /euidelves       -- open the overview popup
--    /euidelves dump  -- print the exact delve names found this session, to
--                         help fill in EllesmereUIDelves_Data.lua by hand
-------------------------------------------------------------------------------
SLASH_EUIDELVES1 = "/euidelves"
SlashCmdList["EUIDELVES"] = function(msg)
    if msg and msg:lower():match("^%s*dump%s*$") then
        local entries = CollectDelves()
        if #entries == 0 then
            print("|cff0cd29fEllesmereUI Delves:|r no delves found on this continent.")
            return
        end
        print("|cff0cd29fEllesmereUI Delves:|r found " .. #entries .. " delve(s) this session:")
        for _, e in ipairs(entries) do
            print(("  [%s] bountiful=%s story=%s widgetSet=%s"):format(
                e.name, tostring(e.bountiful), tostring(e.storyVariant), tostring(e.tooltipWidgetSet)))
        end
        return
    end
    ShowDelvesPopup()
end
