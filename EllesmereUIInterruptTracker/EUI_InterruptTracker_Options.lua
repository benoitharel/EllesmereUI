-------------------------------------------------------------------------------
--  EUI_InterruptTracker_Options.lua
--
--  Full options panel: layout controls, announce channel, kick rotation editor.
--  Replaces the Phase 1 stub.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
if _G._EIT_Options_Loaded then return end
_G._EIT_Options_Loaded = true

local PAGE = "Interrupt Tracker"

-- Maximum number of rotation entries the pre-allocated row pool supports
local MAX_ROTATION_ROWS = 20

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    if not EllesmereUI or not EllesmereUI.RegisterModule then return end

    -- db resolved lazily so it is always current (OnInitialize may fire after this)
    local db
    local function DB()
        if not db then db = _G._EIT_AceDB end
        return db and db.profile
    end

    local function Refresh()
        if _G._EIT_Apply then _G._EIT_Apply() end
        if EllesmereUI.RefreshPage then EllesmereUI:RefreshPage() end
    end

    local PP = EllesmereUI.PP or EllesmereUI.PanelPP

    ---------------------------------------------------------------------------
    --  Kick rotation editor: row pool pre-allocated in BuildPage, rebuilt in
    --  RebuildRotationRows whenever the list changes.
    ---------------------------------------------------------------------------
    local rowPool        = {}    -- { [i] = frame with ._idxLabel ._nameLabel ._upBtn ._downBtn ._removeBtn }
    local addRow         = nil   -- the "add player" row at the bottom
    local editorContainer = nil  -- parent frame for all editor rows

    local function RebuildRotationRows()
        if not editorContainer then return end
        local rotation = DB() and DB().kickRotation or {}
        local ROW_H    = 22
        local GAP      = 2
        local yOff     = -28  -- start below the section label inside the container

        for i = 1, MAX_ROTATION_ROWS do
            local row  = rowPool[i]
            if not row then break end
            local name = rotation[i]
            if name then
                row._idxLabel:SetText(i .. ".")
                row._nameLabel:SetText(name)
                row._upBtn:SetEnabled(i > 1)
                row._downBtn:SetEnabled(i < #rotation)

                -- Rewire callbacks with the current capture of i
                local idx = i
                row._upBtn:SetScript("OnClick", function()
                    local rot = DB() and DB().kickRotation
                    if not rot or idx <= 1 then return end
                    rot[idx], rot[idx - 1] = rot[idx - 1], rot[idx]
                    RebuildRotationRows()
                    Refresh()
                end)
                row._downBtn:SetScript("OnClick", function()
                    local rot = DB() and DB().kickRotation
                    if not rot or idx >= #rot then return end
                    rot[idx], rot[idx + 1] = rot[idx + 1], rot[idx]
                    RebuildRotationRows()
                    Refresh()
                end)
                row._removeBtn:SetScript("OnClick", function()
                    local rot = DB() and DB().kickRotation
                    if not rot then return end
                    table.remove(rot, idx)
                    RebuildRotationRows()
                    Refresh()
                end)

                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", editorContainer, "TOPLEFT", 10, yOff)
                row:Show()
                yOff = yOff - (ROW_H + GAP)
            else
                row:Hide()
            end
        end

        -- Position the add-row just below the last visible entry
        if addRow then
            addRow:ClearAllPoints()
            PP.Point(addRow, "TOPLEFT", editorContainer, "TOPLEFT", 10, yOff)
            yOff = yOff - 30
        end

        editorContainer:SetHeight(math.abs(yOff) + 8)
    end

    ---------------------------------------------------------------------------
    --  BuildPage: called once by RegisterModule when the panel is opened
    ---------------------------------------------------------------------------
    local function BuildPage(pageName, parent, yOffset)
        local W = EllesmereUI.Widgets
        local y = yOffset

        -- Master enable/disable
        local _, h = W:Toggle(parent, "Enable Interrupt Tracker", y,
            function() return DB() and DB().enabled ~= false end,
            function(v) local p = DB(); if p then p.enabled = v end; Refresh() end,
            "Show or hide the Interrupt Tracker frame.")
        y = y - h

        -- Failed kick detection
        _, h = W:Toggle(parent, "Failed Kick Detection", y,
            function() return DB() and DB().failedKickDetection ~= false end,
            function(v) local p = DB(); if p then p.failedKickDetection = v end; Refresh() end,
            "Colour the CD text green on a successful interrupt and red on a whiffed kick.")
        y = y - h

        -- Assume unreadable casts
        _, h = W:Toggle(parent, "Assume Unreadable Casts", y,
            function() return DB() and DB().assumeUnreadableCasts ~= false end,
            function(v) local p = DB(); if p then p.assumeUnreadableCasts = v end; Refresh() end,
            "Since Midnight, a group member's spell ID is sometimes completely unreadable. When that happens, credit the cast as their interrupt if their interrupt is currently ready. Keeps failed kicks tracked (a whiff still starts the cooldown), at the cost of the occasional early start. Turn off for stricter tracking.")
        y = y - h

        -- Show in Party / Show in Raid (dual row)
        _, h = W:DualRow(parent, y,
            {
                type     = "toggle",
                text     = "Show in Party",
                getValue = function() return DB() and DB().showInParty ~= false end,
                setValue = function(v) local p = DB(); if p then p.showInParty = v end; Refresh() end,
                tooltip  = "Track interrupts when in a party.",
            },
            {
                type     = "toggle",
                text     = "Show in Raid",
                getValue = function() return DB() and DB().showInRaid end,
                setValue = function(v) local p = DB(); if p then p.showInRaid = v end; Refresh() end,
                tooltip  = "Track interrupts when in a raid.",
            })
        y = y - h

        -- Show When Solo / Keep Visible Out of Combat (dual row)
        _, h = W:DualRow(parent, y,
            {
                type     = "toggle",
                text     = "Show When Solo",
                getValue = function() return DB() and DB().showSolo ~= false end,
                setValue = function(v)
                    local p = DB(); if p then p.showSolo = v end
                    -- Changes which units are tracked, so redraw alone is not enough.
                    if _G._EIT_RebuildRoster then _G._EIT_RebuildRoster() end
                    Refresh()
                end,
                tooltip  = "Show your own interrupt bar when you are not in a group.",
            },
            {
                type     = "toggle",
                text     = "Solo: Keep Out of Combat",
                getValue = function() return DB() and DB().soloOutOfCombat ~= false end,
                setValue = function(v) local p = DB(); if p then p.soloOutOfCombat = v end; Refresh() end,
                tooltip  = "While solo in the open world, stay visible out of combat instead of fading away. Has no effect in a group; instances are always visible.",
            })
        y = y - h

        -- Bar Width
        _, h = W:Slider(parent, "Bar Width", y, 50, 400, 1,
            function() return DB() and DB().barWidth or 200 end,
            function(v) local p = DB(); if p then p.barWidth = v end; Refresh() end,
            "Width of each player bar in pixels.")
        y = y - h

        -- Bar Height
        _, h = W:Slider(parent, "Bar Height", y, 12, 40, 1,
            function() return DB() and DB().barHeight or 20 end,
            function(v) local p = DB(); if p then p.barHeight = v end; Refresh() end,
            "Height of each player bar in pixels.")
        y = y - h

        -- Bar Spacing
        _, h = W:Slider(parent, "Bar Spacing", y, 0, 20, 1,
            function() return DB() and DB().barSpacing or 2 end,
            function(v) local p = DB(); if p then p.barSpacing = v end; Refresh() end,
            "Vertical gap between bars in pixels.")
        y = y - h

        -- Icon Size
        _, h = W:Slider(parent, "Icon Size", y, 12, 40, 1,
            function() return DB() and DB().iconSize or 20 end,
            function(v) local p = DB(); if p then p.iconSize = v end; Refresh() end,
            "Size of the class and spell icons in pixels.")
        y = y - h

        -- Grow Upward
        _, h = W:Toggle(parent, "Grow Upward", y,
            function() return DB() and DB().growUpward end,
            function(v) local p = DB(); if p then p.growUpward = v end; Refresh() end,
            "Stack bars from the bottom up instead of top down.")
        y = y - h

        -- Sort Order dropdown
        _, h = W:Dropdown(parent, "Sort Order", y,
            { ASC = "Ready first", DESC = "Longest cooldown first" },
            function() return (DB() and DB().sortDescending) and "DESC" or "ASC" end,
            function(v) local p = DB(); if p then p.sortDescending = (v == "DESC") end; Refresh() end,
            { "ASC", "DESC" },
            "Bars are ordered by remaining cooldown. \"Ready first\" puts usable interrupts at the top and the longest cooldown at the bottom; the reverse flips it.")
        y = y - h

        -- Announce Channel dropdown
        _, h = W:Dropdown(parent, "Announce Channel", y,
            { PARTY = "Party", SAY = "Say" },
            function() return DB() and DB().announceChannel or "PARTY" end,
            function(v) local p = DB(); if p then p.announceChannel = v end; Refresh() end,
            { "PARTY", "SAY" },
            "Channel used when left-clicking a bar to announce interrupt status.")
        y = y - h

        ---------------------------------------------------------------------------
        --  Kick Rotation editor
        ---------------------------------------------------------------------------
        -- Section header
        local rotHeader = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        PP.Point(rotHeader, "TOPLEFT", parent, "TOPLEFT", 20, y - 12)
        rotHeader:SetText("Kick Rotation Order")
        rotHeader:SetTextColor(1, 0.82, 0, 1)
        y = y - 36

        -- Container frame (height adjusted dynamically by RebuildRotationRows)
        editorContainer = CreateFrame("Frame", nil, parent)
        PP.Point(editorContainer, "TOPLEFT", parent, "TOPLEFT", 0, y)
        editorContainer:SetWidth(parent:GetWidth() > 0 and parent:GetWidth() or 340)
        editorContainer:SetHeight(50)

        -- Section label inside the container
        local listHeader = editorContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        listHeader:SetPoint("TOPLEFT", editorContainer, "TOPLEFT", 10, -8)
        listHeader:SetText("Order   Player                                Up  Down  Remove")
        listHeader:SetTextColor(0.6, 0.6, 0.6, 1)

        -- Pre-allocate the row pool (never created mid-combat)
        local ROW_H = 22
        for i = 1, MAX_ROTATION_ROWS do
            local row = CreateFrame("Frame", nil, editorContainer)
            row:SetSize(320, ROW_H)
            row:Hide()

            local idxLbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            idxLbl:SetPoint("LEFT", row, "LEFT", 0, 0)
            idxLbl:SetWidth(18)
            idxLbl:SetJustifyH("RIGHT")
            row._idxLabel = idxLbl

            local nameLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            nameLbl:SetPoint("LEFT", row, "LEFT", 22, 0)
            nameLbl:SetWidth(148)
            nameLbl:SetJustifyH("LEFT")
            row._nameLabel = nameLbl

            local upBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            upBtn:SetSize(24, 18)
            upBtn:SetPoint("LEFT", row, "LEFT", 176, 0)
            upBtn:SetText("^")
            row._upBtn = upBtn

            local downBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            downBtn:SetSize(24, 18)
            downBtn:SetPoint("LEFT", row, "LEFT", 202, 0)
            downBtn:SetText("v")
            row._downBtn = downBtn

            local removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            removeBtn:SetSize(24, 18)
            removeBtn:SetPoint("LEFT", row, "LEFT", 232, 0)
            removeBtn:SetText("X")
            row._removeBtn = removeBtn

            rowPool[i] = row
        end

        -- Add-player row: EditBox + Add + Clear
        addRow = CreateFrame("Frame", nil, editorContainer)
        addRow:SetSize(320, 22)

        local nameBox = CreateFrame("EditBox", nil, addRow, "InputBoxTemplate")
        nameBox:SetSize(145, 20)
        nameBox:SetPoint("LEFT", addRow, "LEFT", 0, 0)
        nameBox:SetAutoFocus(false)
        nameBox:SetMaxLetters(64)
        nameBox:SetText("")

        local addBtn = CreateFrame("Button", nil, addRow, "UIPanelButtonTemplate")
        addBtn:SetSize(50, 20)
        addBtn:SetPoint("LEFT", nameBox, "RIGHT", 4, 0)
        addBtn:SetText("Add")
        addBtn:SetScript("OnClick", function()
            local name = strtrim(nameBox:GetText() or "")
            if name == "" then return end
            local p = DB()
            if not p then return end
            p.kickRotation = p.kickRotation or {}
            for _, existing in ipairs(p.kickRotation) do
                if existing == name then nameBox:SetText(""); return end
            end
            if #p.kickRotation >= MAX_ROTATION_ROWS then
                print(string.format("|cff0cd29f[Interrupt Tracker]|r Rotation limit reached (%d players).", MAX_ROTATION_ROWS))
                return
            end
            p.kickRotation[#p.kickRotation + 1] = name
            nameBox:SetText("")
            RebuildRotationRows()
            Refresh()
        end)
        nameBox:SetScript("OnEnterPressed", function() addBtn:Click() end)

        local clearBtn = CreateFrame("Button", nil, addRow, "UIPanelButtonTemplate")
        clearBtn:SetSize(50, 20)
        clearBtn:SetPoint("LEFT", addBtn, "RIGHT", 4, 0)
        clearBtn:SetText("Clear")
        clearBtn:SetScript("OnClick", function()
            local p = DB()
            if p then p.kickRotation = {} end
            RebuildRotationRows()
            Refresh()
        end)

        RebuildRotationRows()

        y = y - (editorContainer:GetHeight() + 10)
        parent:SetHeight(math.abs(y - yOffset) + 20)
    end

    ---------------------------------------------------------------------------
    --  Module registration
    ---------------------------------------------------------------------------
    EllesmereUI:RegisterModule("EllesmereUIInterruptTracker", {
        title       = "Interrupt Tracker",
        description = "Track group interrupt cooldowns and detect failed kicks.",
        pages       = { PAGE },
        buildPage   = BuildPage,
        onReset     = function()
            if EllesmereUIDB and EllesmereUIDB.profiles then
                local profile = EllesmereUIDB.activeProfile or "Default"
                local p = EllesmereUIDB.profiles[profile]
                if p and p.addons and p.addons.EllesmereUIInterruptTracker then
                    wipe(p.addons.EllesmereUIInterruptTracker)
                end
            end
            Refresh()
        end,
    })
end)
