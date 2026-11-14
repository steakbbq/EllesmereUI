if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
-- EllesmereUIQoL_OutgoingCombatTextPreview.lua
-- WoW FOREVER ONLY: the Outgoing Combat Text options preview. Three mobs and
-- three group frames in a running solo fight, drawn 1:1 with the game world
-- as the nameplate preview is, with the same messages the game shows. The
-- mobs wear EllesmereUI Nameplates' look and the group frames Raid Frames'.
-- Only plain numbers reach Emit here. Nothing exists until an options page
-- calls OCT.Preview(host); the fight runs on the preview's OnUpdate, which
-- runs only while the host shows, so it stops when its page hides.
--
--   OCT.Preview(host)         draw the scene inside host, a Frame the page owns
--                             (call it again each time host shows)
--   OCT.PreviewHide(host)     stop the scene (host nil: wherever it is)
--   OCT.PreviewHeight(page)   the height host needs for the current settings, in
--                             page's units (the scene is drawn smaller when
--                             host is shorter)
-------------------------------------------------------------------------------
local _, ns = ...
local EllesmereUI = _G.EllesmereUI
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
local OCT = EllesmereUI.OutgoingCombatText
local I = ns.OCT_I
if not (OCT and I) then return end

local S, Get, Emit, NewPool, ClearPool = I.S, I.Get, I.Emit, I.NewPool, I.ClearPool
local Guard, ReadSettings, IconFor, avoidLabel = I.Guard, I.ReadSettings, I.IconFor, I.avoidLabel
local TOP_FRAC, LOW_FRAC, LINE_H, LINE_GAP = I.TOP_FRAC, I.LOW_FRAC, I.LINE_H, I.LINE_GAP
local CRIT_POP, HEAL_RISE, SWING_SPELL = I.CRIT_POP, I.HEAL_RISE, I.SWING_SPELL

-- x across the mob area as a fraction; y in px above the mobs' base line (a
-- plate's health bar bottom edge). The mobs and the group frames stand low,
-- so the numbers have the room above them.
local PV_MOBS = {
    { name = "Kobold Miner",  hp = 0.31, x = 0.5, y = 24, target = true },
    { name = "Defias Thug",   hp = 0.78, x = 0,   y = 0 },
    { name = "Murloc Raider", hp = 0.55, x = 1,   y = 12 },
}
-- Preview room in game px: the margin at the box edges, the gap between
-- group frames and the box's inset on the page (top and bottom). PV_STACK:
-- how many lines (and how many of them crits) a stack of fast hits may push
-- a number along, on a mob and on a group frame, with Merge on and off.
local PV_MARGIN, PV_PARTY_GAP, PV_INSET = 10, 4, 6
local PV_STACK = {
    mob  = { on = { 2, 2 }, off = { 9, 2 } },
    heal = { on = { 2, 1 }, off = { 3, 1 } },
}
local PV_FRIENDS = {
    { name = "Brannoc", hp = 0.64, class = "WARRIOR" },
    { name = "Moira",   hp = 0.92, class = "PRIEST" },
    { name = "Tessaly", hp = 0.71, class = "DRUID" },
}
-- Each preview icon: the spell's own texture, else a stand-in file
local PV_ICON = {
    swing = { SWING_SPELL, "Interface\\Icons\\INV_Sword_04" },
    exo   = { 879,   "Interface\\Icons\\Spell_Holy_Excorcism_02" },
    fol   = { 19750, "Interface\\Icons\\Spell_Holy_FlashHeal" },
    hl    = { 635,   "Interface\\Icons\\Spell_Holy_HolyBolt" },
    cons  = { 26573, "Interface\\Icons\\Spell_Holy_InnerFire" },
    pet   = { 3110,  "Interface\\Icons\\Spell_Fire_FireBolt" },
}
local WHITE = "Interface\\Buttons\\WHITE8x8"
local pv, pvStage, pvPool
local pvMobs, pvFriends, pvQueue = {}, {}, {}
local pvNext, pvNextOther = 0, 0
-- Sizes from the last skin, for the layout: party frame, plate width, a mob's
-- frame height (plate and name) and the target's scale
local pvPartyW, pvPartyH, pvPlateW = 125, 60, 156
local pvMobH, pvTargetScale = 36, 1

local function PvIcon(key)
    local e = PV_ICON[key]
    return IconFor(e[1]) or e[2]
end

-- A module's namespace and saved profile; nil when it is not loaded
local function ModuleProfile(name)
    local mns = EllesmereUI._ModuleNS and EllesmereUI._ModuleNS[name]
    local db = mns and rawget(mns, "db")
    return mns, db and db.profile
end

local function RGB(t, r, g, b)
    if type(t) == "table" then return t.r or r, t.g or g, t.b or b end
    return r, g, b
end

local function BarTexture(mns, key)
    local list = mns and rawget(mns, "healthBarTextures")
    if list and key then
        return EllesmereUI.ResolveTexturePath(list, key, WHITE) or WHITE
    end
    return WHITE
end

local function SetPvFont(fs, key, size)
    local path = EllesmereUI.GetFontPath(key)
    local flags = EllesmereUI.GetFontOutlineFlag(key) or "OUTLINE"
    if path then fs:SetFont(path, size, flags) end
    if not fs:GetFont() then fs:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE") end
end

local function ClassRGB(token)
    local c = EllesmereUI.GetClassColor(token)
    if not c and RAID_CLASS_COLORS then c = RAID_CLASS_COLORS[token] end
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

-- A status bar over a background, with four edge lines and one text
local function PvBarFrame(parent)
    local f = CreateFrame("Frame", nil, parent)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bar = CreateFrame("StatusBar", nil, f)
    f.bar:SetAllPoints()
    f.bar:SetMinMaxValues(0, 1)
    local e = {}
    for i = 1, 4 do e[i] = f.bar:CreateTexture(nil, "OVERLAY", nil, 7) end
    e[1]:SetPoint("TOPLEFT"); e[1]:SetPoint("TOPRIGHT")
    e[2]:SetPoint("BOTTOMLEFT"); e[2]:SetPoint("BOTTOMRIGHT")
    e[3]:SetPoint("TOPLEFT"); e[3]:SetPoint("BOTTOMLEFT")
    e[4]:SetPoint("TOPRIGHT"); e[4]:SetPoint("BOTTOMRIGHT")
    f.edges = e
    f.text = f.bar:CreateFontString(nil, "OVERLAY")
    return f
end

local function SkinBar(f, w, h, tex, r, g, b, value, br, bg, bb, ba)
    f:SetSize(w, h)
    f.bar:SetStatusBarTexture(tex)
    f.bar:SetStatusBarColor(r, g, b)
    f.bar:SetValue(value)
    f.bg:SetColorTexture(br, bg, bb, ba)
end

local function SkinEdges(f, size, r, g, b, a)
    local e = f.edges
    for i = 1, 4 do
        e[i]:SetColorTexture(r, g, b, a)
        e[i]:SetShown(size > 0)
    end
    if size > 0 then
        e[1]:SetHeight(size); e[2]:SetHeight(size)
        e[3]:SetWidth(size); e[4]:SetWidth(size)
    end
end

-- Enemy plates as EllesmereUI Nameplates draws them: bar, border, name above,
-- health percent inside, and the target's glow, highlight and scale.
local function PvSkinPlates()
    local mns, p = ModuleProfile("EllesmereUINameplates")
    local function v(k, d)
        local x = p and p[k]
        if x == nil then return d end
        return x
    end
    local w = (mns and rawget(mns, "BAR_W") or 150) + v("healthBarWidth", 6)
    local h = v("healthBarHeight", 17)
    local tex = BarTexture(mns, v("healthBarTexture", "none"))
    local fr, fg, fb = RGB(v("enemyInCombat"), 0.8, 0.137, 0.137)
    local br, bg, bb = RGB(v("bgColor"), 0.12, 0.12, 0.12)
    local ba = v("bgAlpha", 1)
    local bs = v("showBorder", true) and v("borderSize", 1) or 0
    local er, eg, eb = RGB(v("borderColor"), 0.067, 0.067, 0.067)
    local nameSize, nameY = v("textSlotTopSize", 12), v("textSlotTopYOffset", 3)
    local nr, ng, nb = RGB(v("textSlotTopColor"), 1, 1, 1)
    local hpSize = v("textSlotRightSize", 10)
    local gr, gg, gb = RGB(v("targetGlowColor"), 0.41, 0.67, 1)
    local hr, hg, hb = RGB(v("targetHighlightColor"), 1, 1, 1)
    local ha = v("targetHighlightAlpha", 0.2)
    -- Stored as a percent; a small number is a plain factor
    local ts = v("targetScale", 100)
    if ts > 5 then ts = ts / 100 end
    for i = 1, #pvMobs do
        local mob, d = pvMobs[i], PV_MOBS[i]
        local plate = mob.plate
        SkinBar(plate, w, h, tex, fr, fg, fb, d.hp, br, bg, bb, ba)
        SkinEdges(plate, bs, er, eg, eb, 1)
        SetPvFont(plate.text, "nameplates", hpSize)
        plate.text:SetText(math.floor(d.hp * 100 + 0.5) .. "%")
        SetPvFont(mob.name, "nameplates", nameSize)
        mob.name:SetText(d.name)
        mob.name:SetTextColor(nr, ng, nb)
        mob.name:ClearAllPoints()
        mob.name:SetPoint("BOTTOM", plate, "TOP", 0, nameY)
        mob.glow:SetVertexColor(gr, gg, gb, 0.45)
        mob.glow:SetShown(d.target == true)
        mob.hl:SetColorTexture(hr, hg, hb, ha)
        mob.hl:SetShown(d.target == true)
        mob:SetSize(w, h + nameY + nameSize + 4)
        mob:SetScale(d.target and ts or 1)
    end
    pvPlateW = w
    pvMobH, pvTargetScale = h + nameY + nameSize + 4, ts
end

local ANCHOR_OK = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
    RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }

-- Party frames as EllesmereUI Raid Frames draws them: size, bar texture, fill
-- mode, background, border and name (party section settings first)
local function PvSkinParty()
    local rns, p = ModuleProfile("EllesmereUIRaidFrames")
    local function v(k, d)
        local x
        if p then
            x = rawget(p, "party_" .. k)
            if x == nil then x = p[k] end
        end
        if x == nil then return d end
        return x
    end
    local w = p and (p.partyFrameWidth or p.frameWidth) or 125
    local h = p and (p.partyFrameHeight or p.frameHeight) or 60
    local tex = BarTexture(rns, v("healthBarTexture", "atrocity"))
    local mode = v("healthColorMode", "class")
    local cr, cg, cb = RGB(v("customFillColor"), 0.145, 0.757, 0.114)
    local br, bg, bb = RGB(v("customBgColor"), 0.067, 0.067, 0.067)
    local ba = v("bgDarkness", 50) / 100
    local bs = v("borderSize", 1)
    local er, eg, eb = RGB(v("borderColor"), 0, 0, 0)
    local ea = v("borderAlpha", 1)
    local nameSize = v("nameSize", 10)
    local pos = string.upper(tostring(v("namePosition", "topleft")))
    if not ANCHOR_OK[pos] then pos = "TOPLEFT" end
    local px = pos:find("LEFT") and 4 or (pos:find("RIGHT") and -4 or 0)
    local py = pos:find("TOP") and -4 or (pos:find("BOTTOM") and 4 or 0)
    px, py = px + v("nameOffsetX", 0), py + v("nameOffsetY", 0)
    local nameMode = v("nameColorMode", "custom")
    local nr, ng, nb = RGB(v("nameCustomColor"), 1, 1, 1)
    for i = 1, #pvFriends do
        local f, d = pvFriends[i], PV_FRIENDS[i]
        local r, g, b = ClassRGB(d.class)
        if mode == "dark" then
            r, g, b = 0.2, 0.2, 0.2
        elseif mode == "classic" then
            r, g, b = 0, 0.8, 0
        elseif mode == "custom" or mode == "customDynamic" then
            r, g, b = cr, cg, cb
        end
        SkinBar(f, w, h, tex, r, g, b, d.hp, br, bg, bb, ba)
        SkinEdges(f, bs, er, eg, eb, ea)
        SetPvFont(f.text, "raidFrames", nameSize)
        f.text:SetText(d.name)
        f.text:ClearAllPoints()
        f.text:SetPoint(pos, f, pos, px, py)
        if nameMode == "class" then
            f.text:SetTextColor(ClassRGB(d.class))
        else
            f.text:SetTextColor(nr, ng, nb)
        end
    end
    pvPartyW, pvPartyH = w, h
end

-- The scene's height in game px for the current settings, and the base
-- lines of the mobs and of the group frames in it. Every number's whole path
-- fits: its start (a mob's top or a group frame's centre, plus Text Offset),
-- its motion's highest and lowest point, a stack of fast hits pushing it
-- along, a crit at its pop size and the crit shake. Reads the saved settings,
-- so it works while the feature is off.
local function PvGeometry()
    local size, rise, anim, offset = Get("size"), Get("rise"), Get("anim"), Get("offset")
    local line = size * LINE_H
    local critH = size * Get("critScale") * LINE_H
    local critLine = critH * CRIT_POP
    local shake = Get("critShake") and Get("shakeAmount") * 0.4 or 0
    -- A kind of number whose starts lie from lo0 to hi0 above its frames'
    -- base line: how far above and below that line its paths reach. A stack
    -- (PV_STACK: lines, crits among them) pushes numbers along their way: up,
    -- or down for Down.
    local function Reach(lo0, hi0, dist, mode, scale, stack)
        local push = stack[1] * (line * scale + LINE_GAP) + stack[2] * (critH - line) * scale
        local down = mode == "down"
        local hi = hi0 + dist * (TOP_FRAC[mode] or 1) + critLine * scale + shake
        local lo = lo0 + dist * (LOW_FRAC[mode] or 0) - shake
        if down then lo = lo - push else hi = hi + push end
        return hi, lo
    end
    -- Mobs: damage starts at a mob frame's top (bar and name)
    local tLo, tHi, fLo
    for i = 1, #PV_MOBS do
        local d = PV_MOBS[i]
        local s = d.target and pvTargetScale or 1
        local top = d.y + pvMobH * s
        if not tLo or top < tLo then tLo = top end
        if not tHi or top > tHi then tHi = top end
        if not fLo or d.y < fLo then fLo = d.y end
    end
    local merge = Get("merge") and "on" or "off"
    local stack = PV_STACK.mob[merge]
    local hi, lo = Reach(tLo + offset, tHi + offset, rise, anim, 1, stack)
    if Get("others") then
        local oAnim, oOff = Get("othersAnim"), Get("othersOffset")
        if oAnim == "__same" then oAnim = anim end
        local hi2, lo2 = Reach(tLo + oOff, tHi + oOff, rise, oAnim, Get("othersScale"), stack)
        if hi2 > hi then hi = hi2 end
        if lo2 < lo then lo = lo2 end
    end
    local mobBase = math.max(PV_MARGIN - fLo, 2 - lo)
    local mobTop = mobBase + math.max(hi, tHi)
    -- Group frames: heals start at a frame's centre and travel half as far
    local pitch = pvPartyH + PV_PARTY_GAP
    local stackH = (#PV_FRIENDS - 1) * pitch
    local pHi, pLo = Reach(pvPartyH / 2 + offset, stackH + pvPartyH / 2 + offset,
        rise * HEAL_RISE, anim, 1, PV_STACK.heal[merge])
    local partyBase = math.max(PV_MARGIN, 2 - pLo)
    local partyTop = partyBase + math.max(pHi, stackH + pvPartyH)
    return math.ceil(math.max(mobTop, partyTop) + PV_MARGIN), mobBase, partyBase
end

-- Places the group frames (left) and the mobs (the width right of them) on
-- their base lines. The stage is 1:1 with the game world (its scale cancels
-- the host's), or smaller when the scene is taller than the host.
local function PvLayout()
    local base = UIParent:GetEffectiveScale() / pv:GetEffectiveScale()
    local room, sceneH = (pv:GetHeight() or 0) / base, PvGeometry()
    local scale = base
    if room > 0 and sceneH > room then scale = base * room / sceneH end
    -- Only a real change: a new scale resizes the stage, which runs this again
    if math.abs(pvStage:GetScale() - scale) > 0.001 then pvStage:SetScale(scale) end
    local w = pvStage:GetWidth()
    if not w or w < 1 then return end
    local _, mobBase, partyBase = PvGeometry()
    for i = 1, #pvFriends do
        local f = pvFriends[i]
        f:Show()
        f:ClearAllPoints()
        f:SetPoint("BOTTOMLEFT", pvStage, "BOTTOMLEFT", 12,
            partyBase + (#pvFriends - i) * (pvPartyH + PV_PARTY_GAP))
    end
    local left = pvPartyW + 24 + pvPlateW / 2
    local span = w - left - pvPlateW / 2 - 12
    for i = 1, #pvMobs do
        local d, mob = PV_MOBS[i], pvMobs[i]
        -- A scaled frame's offsets are in its own units
        local ms = mob:GetScale()
        mob:ClearAllPoints()
        mob:SetPoint("BOTTOM", pvStage, "BOTTOMLEFT", (left + span * d.x) / ms, (mobBase + d.y) / ms)
    end
end

local function PvRand(a, b) return a + math.random() * (b - a) end

local function PvLater(sec, fn)
    pvQueue[#pvQueue + 1] = { t = GetTime() + sec, fn = fn }
end

-- Preview merge keys are strings: a stand-in icon is a file path
-- look: "pet" or "dot" (that look), else the school's
local function PvHit(mob, amount, crit, school, iconKey, look)
    if not S.damage then return end
    Emit(pvPool, mob, "TOP", 1, "%s", math.floor(amount), nil, look or school, crit,
        iconKey and PvIcon(iconKey), (iconKey or "none") .. school, school)
end

local function PvSwing(crit)
    PvHit(pvMobs[1], PvRand(55, 80) * (crit and 2 or 1), crit, 1, "swing")
end

-- The step a dice roll x picks
local function PvStep(x)
    local target = pvMobs[1]
    if x < 0.34 then
        PvSwing(math.random() < 0.15)
        -- Your pet's hit (an imp's Firebolt) a moment later, in its own look
        if S.petLook and math.random() < 0.5 then
            PvLater(0.3, function() PvHit(target, PvRand(30, 45), false, 4, "pet", "pet") end)
        end
    elseif x < 0.46 then
        local crit = math.random() < 0.18
        PvHit(target, PvRand(92, 118) * (crit and 1.5 or 1), crit, 2, "exo")
    elseif x < 0.52 then
        if S.avoid then
            Emit(pvPool, target, "TOP", 1, "%s", nil, avoidLabel.DODGE, "avoid",
                false, PvIcon("swing"), nil)
        end
    elseif x < 0.56 then
        -- Consecration: four ticks on every mob, with its icon (a ground effect)
        for t = 0, 3 do
            for i = 1, #pvMobs do
                PvLater(t + (i - 1) * 0.03, function()
                    PvHit(pvMobs[i], PvRand(9, 13), false, 2, "cons", S.dotLook and "dot" or nil)
                end)
            end
        end
    elseif x < 0.59 then
        for i = 0, 4 do
            PvLater(i * 0.09, function() PvSwing(math.random() < 0.15) end)
        end
    elseif S.heal then
        local crit = math.random() < 0.15
        local big = crit or math.random() < 0.35
        local key = big and "hl" or "fol"
        local amount = (big and PvRand(430, 520) or PvRand(180, 220)) * (crit and 1.5 or 1)
        Emit(pvPool, pvFriends[math.random(#pvFriends)], "CENTER", HEAL_RISE, "+%s",
            math.floor(amount), nil, "heal", crit, PvIcon(key), key)
    end
end

-- Another player's hit on a random mob, while Others' Damage is on
local function PvOther()
    if not S.others then return end
    local crit = math.random() < 0.12
    Emit(pvPool, pvMobs[math.random(#pvMobs)], "TOP", 1, "%s",
        math.floor(PvRand(40, 140) * (crit and 2 or 1)), nil, "other", crit, nil, "o1")
end

local function PvOnUpdate()
    local now = GetTime()
    local i = 1
    while i <= #pvQueue do
        local q = pvQueue[i]
        if now >= q.t then
            table.remove(pvQueue, i)
            q.fn()
        else
            i = i + 1
        end
    end
    if now >= pvNext then
        pvNext = now + PvRand(0.45, 1.2)
        PvStep(math.random())
    end
    if now >= pvNextOther then
        pvNextOther = now + PvRand(0.3, 0.9)
        PvOther()
    end
end

local function PvOnShow()
    I.previewShown = true
    -- 1:1 with the game world: the stage's scale cancels the host's
    -- (PvLayout draws a scene taller than the host smaller)
    pvStage:SetScale(UIParent:GetEffectiveScale() / pv:GetEffectiveScale())
    -- Above the nameplate and frame layers, as the game's numbers are
    local lvl = pvStage:GetFrameLevel() + 60
    pvPool.level = lvl
    for i = 1, #pvPool.msgs do pvPool.msgs[i]:SetFrameLevel(lvl) end
    ReadSettings()
    PvSkinPlates()
    PvSkinParty()
    PvLayout()
    pvNext = GetTime() + 0.3
    pvNextOther = pvNext + 0.2
end

local function PvOnHide()
    I.previewShown = false
    wipe(pvQueue)
    ClearPool(pvPool)
end

local function PvBuild()
    pv = CreateFrame("Frame")
    pv:Hide()
    pv:SetClipsChildren(true)
    local bg = pv:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.03, 0.04, 0.05, 0.6)
    pvStage = CreateFrame("Frame", nil, pv)
    pvStage:SetAllPoints(pv)
    for i = 1, #PV_FRIENDS do
        pvFriends[i] = PvBarFrame(pvStage)
    end
    for i = 1, #PV_MOBS do
        -- The frame spans the plate and its name, as a real plate's frame does
        local mob = CreateFrame("Frame", nil, pvStage)
        local plate = PvBarFrame(mob)
        plate:SetPoint("BOTTOM")
        plate.text:SetPoint("RIGHT", plate, "RIGHT", -3, 0)
        mob.plate = plate
        mob.name = mob:CreateFontString(nil, "OVERLAY")
        mob.glow = mob:CreateTexture(nil, "BACKGROUND")
        mob.glow:SetTexture(WHITE)
        mob.glow:SetPoint("TOPLEFT", plate, "TOPLEFT", -3, 3)
        mob.glow:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", 3, -3)
        mob.hl = plate.bar:CreateTexture(nil, "OVERLAY", nil, 6)
        mob.hl:SetAllPoints(plate.bar)
        pvMobs[i] = mob
    end
    pvPool = NewPool(pvStage)
    pv:SetScript("OnShow", PvOnShow)
    pv:SetScript("OnHide", PvOnHide)
    pv:SetScript("OnUpdate", function(self, elapsed) Guard(PvOnUpdate, self, elapsed) end)
    pvStage:SetScript("OnSizeChanged", PvLayout)
    -- A setting changed: the scene fits its host again
    I.changed = function()
        if pv:IsVisible() then PvLayout() end
    end
end

-- Draws the scene in `host`. One preview frame moves to each new host; the
-- options frame pool parks it with the page it was on.
function OCT.Preview(host)
    if not pv then PvBuild() end
    pv:Hide()
    pv:SetParent(host)
    pv:ClearAllPoints()
    pv:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -PV_INSET)
    pv:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, PV_INSET)
    pv:Show()
end

function OCT.PreviewHide(host)
    if pv and (host == nil or pv:GetParent() == host) then pv:Hide() end
end

-- The host's height for the current settings on `page` (a frame whose scale
-- the host shares): the scene at game size, at most 360 game units (a taller
-- one is drawn smaller to fit), plus the preview's insets. The looks are read
-- first, as the plate and frame sizes count.
function OCT.PreviewHeight(page)
    if not pv then PvBuild() end
    PvSkinPlates()
    PvSkinParty()
    local k = 1
    local pe = page and page:GetEffectiveScale()
    if pe and pe > 0 then k = UIParent:GetEffectiveScale() / pe end
    return math.ceil(math.min(PvGeometry(), 360) * k) + 2 * PV_INSET
end
