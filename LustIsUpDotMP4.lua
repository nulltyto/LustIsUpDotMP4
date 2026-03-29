local addonName = ...

------------------------------------------------------------
-- Constants
------------------------------------------------------------
local LUST_DURATION = 40

local LUST_DEBUFFS = {
    [57723]  = true, -- Exhaustion (Bloodlust / Heroism)
    [390435] = true, -- Exhaustion (Fury of the Aspects)
    [57724]  = true, -- Sated
    [80354]  = true, -- Temporal Displacement (Time Warp)
    [95809]  = true, -- Insanity (Ancient Hysteria)
    [160455] = true, -- Fatigued (Drums)
    [264689] = true, -- Fatigued (variant)
}

local AUDIO_CHANNELS = { "Master", "SFX", "Music", "Ambience" }

-- Sprite sheet config uses the Blizzard Timer.lua pattern:
--   w, h     = pixel size of a single cell/frame
--   texW, texH = pixel size of the entire texture
--   frames   = total number of animation frames
--   fps      = animation speed
-- UV per cell = w/texW horizontally, h/texH vertically.
-- Cells that don't fill the full texture (whitespace) are handled
-- automatically because we use cell pixel size, not row/col fractions.
local MEDIA_PACKS = {
    {
        name   = "nflonfox",
        tga    = "Interface\\AddOns\\LustIsUpDotMP4\\media\\nflonfox\\nflonfox.tga",
        audio  = "Interface\\AddOns\\LustIsUpDotMP4\\media\\nflonfox\\nflonfox.mp3",
        w = 192, h = 192, texW = 1024, texH = 2048, cols = 4, frames = 32, fps = 12,
        audioDuration = 39,
    },
    {
        name   = "oopsiekitty",
        tga    = "Interface\\AddOns\\LustIsUpDotMP4\\media\\oopsiekitty\\OopsieKitty.tga",
        audio  = "Interface\\AddOns\\LustIsUpDotMP4\\media\\oopsiekitty\\OopsieKitty.wav",
        w = 256, h = 256, texW = 4096, texH = 4096, cols = 16, frames = 256, fps = 24,
        audioDuration = 39,
    },
    {
        name   = "pedro",
        tga    = "Interface\\AddOns\\LustIsUpDotMP4\\media\\pedro\\pedro.tga",
        audio  = "Interface\\AddOns\\LustIsUpDotMP4\\media\\pedro\\pedrolust.mp3",
        w = 192, h = 192, texW = 1024, texH = 2048, cols = 4, frames = 32, fps = 8,
        audioDuration = 39,
    },
}

local DEFAULTS = {
    pack    = "pedro",
    mode    = "both",
    channel = "Master",
    scale   = 1.0,
    x       = nil,
    y       = nil,
}

local SCALE_MIN, SCALE_MAX = 0.25, 3.0
local INDICATOR_BASE = 200

------------------------------------------------------------
-- State
------------------------------------------------------------
local db
local lustActive    = false
local soundHandle   = nil
local audioTicker   = nil
local lustTimer     = nil
local hadDebuff     = false
local unlocked      = false

-- Animation state
local animFrame     = 0
local animElapsed   = 0
local animPlaying   = false
local activePack    = nil  -- resolved pack for current lust (supports "random")

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function GetPack(name)
    for _, p in ipairs(MEDIA_PACKS) do
        if p.name == name then return p end
    end
    return MEDIA_PACKS[1]
end

local function PickRandomPack()
    return MEDIA_PACKS[math.random(#MEDIA_PACKS)]
end

local function GetActivePack()
    return activePack or GetPack(db.pack)
end

local function DefaultPosition()
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    return sw * 0.75, -sh * 0.75
end

------------------------------------------------------------
-- Visual Indicator Frame
-- Anchor frame (scale 1.0) handles positioning.
-- Indicator child handles display and is scaled independently.
------------------------------------------------------------
local anchor = CreateFrame("Frame", "LustIsUpAnchor", UIParent)
anchor:SetSize(1, 1)
anchor:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
anchor:SetFrameStrata("HIGH")

local indicator = CreateFrame("Frame", "LustIsUpIndicator", anchor)
indicator:SetSize(INDICATOR_BASE, INDICATOR_BASE)
indicator:SetPoint("CENTER", anchor, "CENTER", 0, 0)
indicator:SetFrameStrata("HIGH")
indicator:Hide()

local indicatorTex = indicator:CreateTexture(nil, "ARTWORK")
indicatorTex:SetAllPoints()

------------------------------------------------------------
-- Sprite sheet animation (Blizzard Timer.lua pattern)
--
-- UV coords per cell:
--   texCoW = w / texW   (fraction of texture width per cell)
--   texCoH = h / texH   (fraction of texture height per cell)
--   columns = floor(texW / w)
--
-- For frame N:
--   col = N % columns
--   row = floor(N / columns)
--   left  = col * texCoW,  right = left + texCoW
--   top   = row * texCoH,  bottom = top + texCoH
------------------------------------------------------------
local function SetAnimFrame(frame, pack)
    local texCoW = pack.w / pack.texW
    local texCoH = pack.h / pack.texH
    local columns = pack.cols
    local totalFrames = pack.frames

    if totalFrames <= 1 then
        indicatorTex:SetTexCoord(0, texCoW, 0, texCoH)
        return
    end

    frame = frame % totalFrames
    local col = frame % columns
    local row = math.floor(frame / columns)

    local l = col * texCoW
    local r = l + texCoW
    local t = row * texCoH
    local b = t + texCoH

    indicatorTex:SetTexCoord(l, r, t, b)
end

local function StartAnimation()
    local pack = GetActivePack()
    animFrame = 0
    animElapsed = 0
    animPlaying = true
    SetAnimFrame(0, pack)
    indicator:SetScript("OnUpdate", function(_, elapsed)
        if not animPlaying then return end
        local p = GetActivePack()
        local fps = p.fps or 15
        if fps <= 0 then fps = 1 end
        animElapsed = animElapsed + elapsed
        local frameDuration = 1 / fps
        while animElapsed >= frameDuration do
            animElapsed = animElapsed - frameDuration
            animFrame = animFrame + 1
            if p.frames > 0 then
                animFrame = animFrame % p.frames
            end
        end
        SetAnimFrame(animFrame, p)
    end)
end

local function StopAnimation()
    animPlaying = false
    indicator:SetScript("OnUpdate", nil)
end

------------------------------------------------------------
-- Drag support
------------------------------------------------------------
anchor:SetMovable(true)
anchor:EnableMouse(false)
anchor:RegisterForDrag("LeftButton")
anchor:SetScript("OnDragStart", function(self) self:StartMoving() end)
anchor:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if db then
        db.x = self:GetLeft()
        db.y = -(UIParent:GetHeight() - self:GetTop())
    end
end)

local function ApplyPosition()
    anchor:ClearAllPoints()
    local x, y = db.x, db.y
    if not x or not y then
        x, y = DefaultPosition()
        db.x, db.y = x, y
    end
    anchor:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, y)
end

local function ApplyFrameSize()
    -- Indicator matches the cell's aspect ratio
    local pack = GetActivePack()
    if pack.w >= pack.h then
        indicator:SetSize(INDICATOR_BASE, INDICATOR_BASE * (pack.h / pack.w))
    else
        indicator:SetSize(INDICATOR_BASE * (pack.w / pack.h), INDICATOR_BASE)
    end
end

local function ApplyScale()
    indicator:SetScale(db.scale)
end

local function ApplyTexture()
    local pack = GetActivePack()
    indicatorTex:SetTexture(pack.tga)
    ApplyFrameSize()
    SetAnimFrame(0, pack)
end

------------------------------------------------------------
-- Audio
------------------------------------------------------------
local function StopAudio()
    if soundHandle then
        StopSound(soundHandle)
        soundHandle = nil
    end
    if audioTicker then
        audioTicker:Cancel()
        audioTicker = nil
    end
end

local function StartAudioLoop()
    StopAudio()
    if db.mode == "visual" then return end
    local pack = GetActivePack()
    local duration = pack.audioDuration or 40
    local startTime = GetTime()

    local willPlay, handle = PlaySoundFile(pack.audio, db.channel)
    if willPlay then
        soundHandle = handle
    end

    -- Poll every second; replay when the track's duration has elapsed
    audioTicker = C_Timer.NewTicker(1, function()
        if not lustActive then
            StopAudio()
            return
        end
        local elapsed = GetTime() - startTime
        if elapsed >= duration then
            -- Previous playback should be done; start fresh
            if soundHandle then
                StopSound(soundHandle)
                soundHandle = nil
            end
            local wp, h = PlaySoundFile(pack.audio, db.channel)
            if wp then
                soundHandle = h
            end
            startTime = GetTime()
        end
    end)
end

------------------------------------------------------------
-- Debuff scanning
------------------------------------------------------------
local function FindLustDebuff()
    for spellID in pairs(LUST_DEBUFFS) do
        local aura = C_UnitAuras.GetPlayerAuraBySpellID(spellID)
        if aura then return aura end
    end
    return nil
end

local function CancelLustTimer()
    if lustTimer then
        lustTimer:Cancel()
        lustTimer = nil
    end
end

------------------------------------------------------------
-- Lust activation / deactivation
------------------------------------------------------------
local function ActivateLust()
    if lustActive then return end
    lustActive = true
    if db.pack == "random" then
        activePack = PickRandomPack()
    else
        activePack = GetPack(db.pack)
    end
    if db.mode ~= "audio" then
        ApplyTexture()
        ApplyScale()
        ApplyPosition()
        indicator:Show()
        StartAnimation()
    end
    StartAudioLoop()
end

local function DeactivateLust()
    if not lustActive then return end
    lustActive = false
    activePack = nil
    CancelLustTimer()
    indicator:Hide()
    StopAnimation()
    StopAudio()
end

local function CheckLust()
    local aura = FindLustDebuff()
    local hasDebuff = aura ~= nil

    -- Debuff found with valid timing info: calculate remaining lust window
    if aura and aura.duration and aura.duration > 0
       and aura.expirationTime and aura.expirationTime > 0 then
        local startedAt = aura.expirationTime - aura.duration
        local remaining = (startedAt + LUST_DURATION) - GetTime()

        hadDebuff = true

        if remaining > 0 then
            ActivateLust()
            CancelLustTimer()
            lustTimer = C_Timer.NewTimer(remaining, function()
                lustTimer = nil
                DeactivateLust()
            end)
        else
            DeactivateLust()
        end
        return
    end

    -- New debuff without timing (edge case): assume full duration
    if hasDebuff and not hadDebuff then
        ActivateLust()
        CancelLustTimer()
        lustTimer = C_Timer.NewTimer(LUST_DURATION, function()
            lustTimer = nil
            DeactivateLust()
        end)
    end

    hadDebuff = hasDebuff
end

------------------------------------------------------------
-- Settings Panel
------------------------------------------------------------
local panel = CreateFrame("Frame", "LustIsUpPanel", UIParent, "BackdropTemplate")
panel:SetSize(356, 1) -- height set after layout is built
panel:SetPoint("CENTER")
panel:SetFrameStrata("DIALOG")
panel:SetBackdrop({
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
panel:SetBackdropColor(0.12, 0.12, 0.14, 0.95)
panel:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
panel:EnableMouse(true)
panel:SetMovable(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
panel:Hide()
tinsert(UISpecialFrames, "LustIsUpPanel")

-- Title
local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -14)
title:SetText("LustIsUpDotMP4")
title:SetTextColor(0.9, 0.9, 0.9, 1)

-- Close button
local closeBtn = CreateFrame("Button", nil, panel)
closeBtn:SetSize(20, 20)
closeBtn:SetPoint("TOPRIGHT", -10, -10)
local closeTex = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
closeTex:SetPoint("CENTER")
closeTex:SetText("X")
closeTex:SetTextColor(0.7, 0.7, 0.7, 1)
closeBtn:SetScript("OnClick", function() panel:Hide() end)
panel:SetScript("OnHide", function()
    if unlocked then
        unlocked = false
        anchor:EnableMouse(false)
        anchor:SetSize(1, 1)
        if not lustActive then
            activePack = nil
            indicator:Hide()
            StopAnimation()
        end
    end
end)
closeBtn:SetScript("OnEnter", function() closeTex:SetTextColor(1, 0.3, 0.3, 1) end)
closeBtn:SetScript("OnLeave", function() closeTex:SetTextColor(0.7, 0.7, 0.7, 1) end)

-- Helpers
local function CreateDivider(yOff)
    local div = panel:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(0.3, 0.3, 0.35, 1)
    div:SetSize(324, 1)
    div:SetPoint("TOPLEFT", 16, yOff)
end

local function CreatePanelSlider(parent, yOff, label, minVal, maxVal, step, formatStr, onChange)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", 16, yOff)
    lbl:SetText(label)
    lbl:SetTextColor(0.7, 0.7, 0.7, 1)

    local val = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    val:SetPoint("TOPRIGHT", -16, yOff)
    val:SetTextColor(0.9, 0.9, 0.9, 1)

    local s = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    s:SetSize(324, 14)
    s:SetPoint("TOPLEFT", 16, yOff - 18)
    s:SetOrientation("HORIZONTAL")
    s:SetMinMaxValues(minVal, maxVal)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)
    s:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    s:SetBackdropColor(0.2, 0.2, 0.22, 1)
    s:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)

    local thumb = s:CreateTexture(nil, "ARTWORK")
    thumb:SetSize(12, 18)
    thumb:SetColorTexture(0.4, 0.75, 1, 1)
    s:SetThumbTexture(thumb)

    s:SetScript("OnValueChanged", function(_, v)
        local snapped = math.floor(v / step + 0.5) * step
        val:SetText(string.format(formatStr, snapped))
        onChange(snapped)
    end)

    return s, val
end

CreateDivider(-38)

------------------------------------------------------------
-- Media Pack Grid
------------------------------------------------------------
local packLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
packLabel:SetPoint("TOPLEFT", 16, -46)
packLabel:SetText("Media Pack")
packLabel:SetTextColor(0.7, 0.7, 0.7, 1)

local packButtons = {}
local TILE_SIZE = 72
local TILE_PAD  = 8
local TILE_LABEL_H = 16
local TILE_ROW_H = TILE_SIZE + TILE_LABEL_H + TILE_PAD
local TILES_PER_ROW = 4
local SCROLL_VISIBLE_ROWS = 2
local SCROLL_HEIGHT = SCROLL_VISIBLE_ROWS * TILE_ROW_H

-- Scrollable container for pack tiles
local packScroll = CreateFrame("ScrollFrame", nil, panel)
packScroll:SetSize(324, SCROLL_HEIGHT)
packScroll:SetPoint("TOPLEFT", 16, -64)

local packChild = CreateFrame("Frame", nil, packScroll)
packChild:SetSize(324, SCROLL_HEIGHT)
packScroll:SetScrollChild(packChild)

packScroll:EnableMouseWheel(true)
packScroll:SetScript("OnMouseWheel", function(self, delta)
    local cur = self:GetVerticalScroll()
    local maxScroll = self:GetVerticalScrollRange()
    local step = TILE_ROW_H
    local newScroll = math.max(0, math.min(cur - delta * step, maxScroll))
    self:SetVerticalScroll(newScroll)
end)

local function UpdatePackSelection()
    for _, btn in ipairs(packButtons) do
        if btn.packName == db.pack then
            btn.border:SetColorTexture(0.4, 0.75, 1, 1)
        else
            btn.border:SetColorTexture(0.3, 0.3, 0.35, 1)
        end
    end
end

local function CreatePackTile(i, packName, setupVisual, onClickFn)
    local col = (i - 1) % TILES_PER_ROW
    local row = math.floor((i - 1) / TILES_PER_ROW)
    local xOff = 2 + col * (TILE_SIZE + TILE_PAD)
    local yOff = -(2 + row * TILE_ROW_H)

    local btn = CreateFrame("Button", nil, packChild)
    btn:SetSize(TILE_SIZE, TILE_SIZE)
    btn:SetPoint("TOPLEFT", xOff, yOff)
    btn.packName = packName

    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetPoint("BOTTOMRIGHT", 2, -2)
    border:SetColorTexture(0.3, 0.3, 0.35, 1)
    btn.border = border

    setupVisual(btn)

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOP", btn, "BOTTOM", 0, -2)
    label:SetText(packName)
    label:SetTextColor(0.6, 0.6, 0.6, 1)

    btn:SetScript("OnClick", onClickFn)

    btn:SetScript("OnEnter", function()
        if btn.packName ~= db.pack then
            border:SetColorTexture(0.35, 0.55, 0.8, 1)
        end
    end)

    btn:SetScript("OnLeave", function()
        if btn.packName ~= db.pack then
            border:SetColorTexture(0.3, 0.3, 0.35, 1)
        end
    end)

    packButtons[#packButtons + 1] = btn
    return btn
end

for i, pack in ipairs(MEDIA_PACKS) do
    CreatePackTile(i, pack.name, function(btn)
        local thumb = btn:CreateTexture(nil, "ARTWORK")
        thumb:SetAllPoints()
        thumb:SetTexture(pack.tga)
        thumb:SetTexCoord(0, pack.w / pack.texW, 0, pack.h / pack.texH)
    end, function()
        db.pack = pack.name
        UpdatePackSelection()
        if unlocked or lustActive then
            ApplyTexture()
            if animPlaying then
                StartAnimation()
            end
        end
    end)
end

-- "Random" tile
CreatePackTile(#MEDIA_PACKS + 1, "random", function(btn)
    local bg = btn:CreateTexture(nil, "ARTWORK")
    bg:SetAllPoints()
    bg:SetColorTexture(0.18, 0.18, 0.2, 1)

    local question = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    question:SetPoint("CENTER", 0, 2)
    question:SetText("?")
    question:SetTextColor(0.7, 0.7, 0.7, 1)
end, function()
    db.pack = "random"
    UpdatePackSelection()
    if unlocked then
        activePack = PickRandomPack()
        ApplyTexture()
        if animPlaying then
            StartAnimation()
        end
    end
end)

-- Size scroll area to fit content (up to SCROLL_VISIBLE_ROWS)
local totalTiles = #MEDIA_PACKS + 1  -- +1 for random
local totalRows = math.ceil(totalTiles / TILES_PER_ROW)
local visibleRows = math.min(totalRows, SCROLL_VISIBLE_ROWS)
local scrollH = visibleRows * TILE_ROW_H + 4  -- +4 for border inset
packScroll:SetHeight(scrollH)
packChild:SetHeight(totalRows * TILE_ROW_H + 4)

local packGridBottom = -64 - scrollH - 10

------------------------------------------------------------
-- Mode Toggle
------------------------------------------------------------
CreateDivider(packGridBottom)

local modeLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
modeLabel:SetPoint("TOPLEFT", 16, packGridBottom - 8)
modeLabel:SetText("Mode")
modeLabel:SetTextColor(0.7, 0.7, 0.7, 1)

local MODES = { "audio", "visual", "both" }
local MODE_LABELS = { audio = "Audio", visual = "Visual", both = "Both" }
local modeButtons = {}

local function UpdateModeSelection()
    for _, mb in ipairs(modeButtons) do
        if mb.mode == db.mode then
            mb:SetBackdropColor(0.3, 0.6, 0.9, 1)
            mb.label:SetTextColor(1, 1, 1, 1)
        else
            mb:SetBackdropColor(0.2, 0.2, 0.22, 1)
            mb.label:SetTextColor(0.6, 0.6, 0.6, 1)
        end
    end
end

local MODE_BTN_GAP = 4
local MODE_BTN_W = math.floor((324 - (#MODES - 1) * MODE_BTN_GAP) / #MODES)

for i, mode in ipairs(MODES) do
    local btn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    btn:SetSize(MODE_BTN_W, 26)
    btn:SetPoint("TOPLEFT", 16 + (i - 1) * (MODE_BTN_W + MODE_BTN_GAP), packGridBottom - 24)
    btn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    btn:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
    btn.mode = mode

    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("CENTER")
    lbl:SetText(MODE_LABELS[mode])
    btn.label = lbl

    btn:SetScript("OnClick", function()
        db.mode = mode
        UpdateModeSelection()
    end)

    modeButtons[#modeButtons + 1] = btn
end

local modeBottom = packGridBottom - 58

------------------------------------------------------------
-- Audio Channel
------------------------------------------------------------
CreateDivider(modeBottom)

local channelLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
channelLabel:SetPoint("TOPLEFT", 16, modeBottom - 8)
channelLabel:SetText("Audio Channel")
channelLabel:SetTextColor(0.7, 0.7, 0.7, 1)

local channelButtons = {}

local function UpdateChannelSelection()
    for _, cb in ipairs(channelButtons) do
        if cb.channel == db.channel then
            cb:SetBackdropColor(0.3, 0.6, 0.9, 1)
            cb.label:SetTextColor(1, 1, 1, 1)
        else
            cb:SetBackdropColor(0.2, 0.2, 0.22, 1)
            cb.label:SetTextColor(0.6, 0.6, 0.6, 1)
        end
    end
end

local CH_BTN_GAP = 4
local CH_BTN_W = math.floor((324 - (#AUDIO_CHANNELS - 1) * CH_BTN_GAP) / #AUDIO_CHANNELS)

for i, ch in ipairs(AUDIO_CHANNELS) do
    local btn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    btn:SetSize(CH_BTN_W, 26)
    btn:SetPoint("TOPLEFT", 16 + (i - 1) * (CH_BTN_W + CH_BTN_GAP), modeBottom - 24)
    btn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    btn:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
    btn.channel = ch

    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("CENTER")
    lbl:SetText(ch)
    btn.label = lbl

    btn:SetScript("OnClick", function()
        db.channel = ch
        UpdateChannelSelection()
    end)

    channelButtons[#channelButtons + 1] = btn
end

local channelBottom = modeBottom - 58

------------------------------------------------------------
-- Scale Slider
------------------------------------------------------------
CreateDivider(channelBottom)

local scaleSlider = CreatePanelSlider(
    panel, channelBottom - 8, "Scale", SCALE_MIN, SCALE_MAX, 0.05, "%.2f",
    function(v)
        if db then
            db.scale = v
            ApplyScale()
        end
    end
)

local scaleBottom = channelBottom - 42

------------------------------------------------------------
-- Unlock Toggle
------------------------------------------------------------
CreateDivider(scaleBottom)

local unlockBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
unlockBtn:SetSize(324, 28)
unlockBtn:SetPoint("TOPLEFT", 16, scaleBottom - 10)
unlockBtn:SetBackdrop({
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
unlockBtn:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)

local unlockLabel = unlockBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
unlockLabel:SetPoint("CENTER")

local function UpdateUnlockState()
    if unlocked then
        unlockBtn:SetBackdropColor(0.8, 0.5, 0.2, 1)
        unlockLabel:SetText("Lock Position")
        unlockLabel:SetTextColor(1, 1, 1, 1)
        if db.pack == "random" then
            activePack = PickRandomPack()
        else
            activePack = GetPack(db.pack)
        end
        ApplyTexture()
        ApplyScale()
        ApplyPosition()
        indicator:Show()
        StartAnimation()
        anchor:EnableMouse(true)
        local w, h = indicator:GetSize()
        anchor:SetSize(w * db.scale, h * db.scale)
    else
        unlockBtn:SetBackdropColor(0.2, 0.2, 0.22, 1)
        unlockLabel:SetText("Unlock Position")
        unlockLabel:SetTextColor(0.6, 0.6, 0.6, 1)
        anchor:EnableMouse(false)
        anchor:SetSize(1, 1)
        if not lustActive then
            activePack = nil
            indicator:Hide()
            StopAnimation()
        end
    end
end

unlockBtn:SetScript("OnClick", function()
    unlocked = not unlocked
    UpdateUnlockState()
end)

-- Set panel height to fit all controls
panel:SetHeight(-(scaleBottom - 10) + 28 + 16)

------------------------------------------------------------
-- Panel open/close logic
------------------------------------------------------------
local function OpenPanel()
    if not db then return end
    UpdatePackSelection()
    UpdateModeSelection()
    UpdateChannelSelection()
    scaleSlider:SetValue(db.scale)
    unlocked = false
    UpdateUnlockState()
    panel:Show()
end

local function TogglePanel()
    if panel:IsShown() then
        panel:Hide()
    else
        OpenPanel()
    end
end

------------------------------------------------------------
-- Event Handler
------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == addonName then
            if not LustIsUpDotMP4DB then
                LustIsUpDotMP4DB = {}
            end
            db = LustIsUpDotMP4DB
            for k, v in pairs(DEFAULTS) do
                if db[k] == nil then
                    db[k] = v
                end
            end
            if not db.x or not db.y then
                db.x, db.y = DefaultPosition()
            end

            local found = (db.pack == "random")
            if not found then
                for _, p in ipairs(MEDIA_PACKS) do
                    if p.name == db.pack then found = true; break end
                end
            end
            if not found then
                db.pack = MEDIA_PACKS[1].name
            end

            ApplyTexture()
            ApplyScale()
            ApplyPosition()
            C_Timer.After(1, CheckLust)
            self:UnregisterEvent("ADDON_LOADED")
        end

    elseif event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" then
            CheckLust()
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        hadDebuff = false
        DeactivateLust()
        C_Timer.After(1, CheckLust)
    end
end)

------------------------------------------------------------
-- Slash Command
------------------------------------------------------------
SLASH_LUSTISUP1 = "/lust"
SlashCmdList["LUSTISUP"] = function()
    TogglePanel()
end
