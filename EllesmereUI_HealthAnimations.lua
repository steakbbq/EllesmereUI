if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
--------------------------------------------------------------------------------
--  EllesmereUI_HealthAnimations.lua
--  Health Animations: a damage animation (the lost piece of health stays, then
--  shrinks, slides, falls, fades, is thrown off or breaks into chips) and a heal
--  animation (the gained piece shows in the heal color, then the bar color
--  slides over it or the heal color fades) on nameplate and raid or party
--  health bars. A feature of EllesmereUI.HealthBars: nothing is registered or
--  built for a place until its Damage Animation or Heal Animation is on.
--
--  Health and max health are secret values: no Lua math or compare touches
--  them, they only reach SetMinMaxValues / SetValue. A hit cannot be told from
--  a heal, so every change makes one "piece" that carries both looks, and clip
--  frames leave only the one that fits (the lost part sits between the live fill
--  edge and the "before" edge, the gained part between the "before" edge and the
--  live edge). Each piece owns two hidden StatusBars (after = new health, before
--  = old health) whose fill edges are the anchors. Motion runs on
--  AnimationGroups. The per-bar state lives in weak tables, never on a bar.
--
--  Drawing API: Reset(bar, cur, maxHP, keep) on a new unit or max health;
--  Change(bar, cur, style, smooth, overLvl, belowLvl, maxHP) on a real health
--  change; Sync(bar, cur) on any other paint; Hide(bar); MakeStyle(src, old,
--  defaults); Hit(bar, style, crit, mine) and Crit(bar, style) for a hit that
--  was a critical strike and/or the player's own (its piece takes the crit and
--  My Damage colors).
--  Number Morph (damage style "number", WoW Forever only): the lost piece flies
--  up and turns into the hit's number (see the Number Morph section). NumHit,
--  NumNote, NumAvoid and NumMine feed it; EllesmereUI.TrailNumbers is the
--  contract with Outgoing Combat Text, which sends each hit's icon and whose
--  hit it was. The numbers move on one OnUpdate that runs only while a number,
--  a flying piece or a waiting hit exists.
--  Settings: the active profile's healthAnimations table (see GetLook, PlaceOn).
--------------------------------------------------------------------------------
local EllesmereUI = EllesmereUI
local HB = EllesmereUI.HealthBars

local HTr = {}
EllesmereUI.HealthAnimations = HTr

local PP = EllesmereUI.PP
local random = math.random
local pairs, ipairs, type, tonumber, next = pairs, ipairs, type, tonumber, next
local UnitHealth, UnitHealthMax = UnitHealth, UnitHealthMax
local issecretvalue = issecretvalue or function() return false end
local IS_FOREVER = EllesmereUI.IS_FOREVER == true

-- Per-bar state, keyed by the bar (weak: a bar is never collected anyway).
local STATE = setmetatable({}, { __mode = "k" })

local WHITE = "Interface\\Buttons\\WHITE8x8"
local POOL = 12          -- pieces per bar in turn; when full the next one is recycled
local PIECE_MAX = 48     -- Number Morph: most pieces per bar while every one is busy
local SMOOTH_LIFE = 0.9  -- seconds a smooth-fill heal piece waits for the fill to arrive
local SCALE_END = 0.001  -- a Scale animation cannot end at exactly 0
local CRIT_WINDOW = 0.15 -- seconds a crit event and its health paint may be apart

-- Every frame below the base draws at the base's own level (a new child is
-- otherwise one level above its parent), so the whole animation sits at one
-- known level against the absorb overlays and the Health Ticks marks.
local function Flat(f)
    if f.SetUsingParentLevel then f:SetUsingParentLevel(true) end
    return f
end

-------------------------------------------------------------------------------
--  Settings: the active profile's healthAnimations table, sparse (a missing key
--  means the default). { plates = { [lookKey] = v }, frames = { [lookKey] = v },
--  places = { [placeId] = { dmg = true, heal = true } } }. "plates" is the look
--  of enemy and friendly nameplates, "frames" of raid and party frames.
-------------------------------------------------------------------------------
local function ActiveProfile()
    local db = EllesmereUIDB
    local profiles = db and db.profiles
    return profiles and profiles[db.activeProfile or "Default"]
end

-- The saved table; nil until the active profile exists. A read never writes
-- (create = true is for writers).
function EllesmereUI.GetHealthAnimationsDB(create)
    local active = ActiveProfile()
    if not active then return nil end
    if create and not active.healthAnimations then active.healthAnimations = {} end
    return active.healthAnimations
end
local GetDB = EllesmereUI.GetHealthAnimationsDB

-- Look keys and defaults. Sizes and distances are 1080p pixels.
local DEFAULTS_FRAMES = {
    healthTrailStyle = "shrink",   -- shrink, slide, fall, fade, chip, crumble
    healthTrailEase = "OUT",       -- NONE, IN, OUT, IN_OUT (chip: not used)
    healthTrailWait = 400,         -- ms
    healthTrailMove = 450,         -- ms
    healthTrailFall = 16,          -- pixels below the bar (fall, chip, crumble)
    healthTrailPop = 10,           -- chip: jump height
    healthTrailTilt = 35,          -- chip: degrees over the flight
    healthTrailDrift = 12,         -- chip: sideways
    healthTrailVary = true,        -- chip: each piece jumps, tilts and drifts 0.7 to 1.3 times as far
    healthTrailChipSize = 6,       -- crumble: chip side (1 to 4 rows)
    healthTrailChipCols = 16,      -- crumble: most chips across
    healthTrailSpread = 8,         -- crumble: sideways spread
    healthTrailSpin = 120,         -- crumble: most degrees a chip turns
    healthTrailStagger = 160,      -- crumble: ms, the latest a chip starts after the wait
    healthTrailColor = { r = 0.949, g = 0.757, b = 0.306 },
    healthTrailCrit = false,       -- a crit hit leaves a piece in the crit color
    healthTrailCritColor = { r = 1, g = 0.32, b = 0.18 },
    healthTrailMine = false,       -- enemy nameplates only: the player's own hits use their own colors
    healthTrailMineColor = { r = 0.35, g = 0.8, b = 1 },
    healthTrailMineCritColor = { r = 0.8, g = 0.45, b = 1 },
    healthTrailAlpha = 100,        -- percent
    healthTrailFlash = 0,          -- ms, 0 = off
    healthTrailGroup = true,
    healthTrailUnderAbsorbs = true, -- draw below the absorb, heal absorb and prediction overlays
    healthTrailHealStyle = "slide", -- slide, fade
    healthTrailHealEase = "OUT",
    healthTrailHealWait = 150,     -- ms
    healthTrailHealMove = 500,     -- ms
    healthTrailHealColor = { r = 0.3, g = 0.85, b = 0.35 },
    healthTrailHealAlpha = 100,    -- percent
}
-- Number Morph (style "number", Forever only). Sizes and distances are 1080p
-- pixels.
if IS_FOREVER then
    for k, v in pairs({
        healthTrailNumFlight = 450,    -- ms, the piece's whole flight
        healthTrailNumArc = 6,         -- the path bows this far to one side
        healthTrailNumDrift = 0,       -- the number lands this far to the side
        healthTrailNumMorph = 25,      -- percent of the flight before the piece starts to change
        healthTrailNumOffset = 6,      -- between the bar and the number
        healthTrailNumSize = 18,       -- font size
        -- Size by Chunk: a hit's number takes one of 5 sizes by its part of the
        -- unit's max health, Smallest to Largest (percent of Number Size)
        healthTrailNumChunk = false,
        healthTrailNumChunkMin = 70,
        healthTrailNumChunkMax = 150,
        healthTrailNumRise = 26,       -- how far the number rises (another player's: sinks)
        healthTrailNumTime = 900,      -- ms the number shows
        healthTrailNumIcon = true,     -- the spell icon (Outgoing Combat Text finds it)
        healthTrailNumIconSide = "LEFT", -- LEFT, RIGHT
        healthTrailNumColor = "white", -- white, custom (the color of physical hits)
        healthTrailNumCustom = { r = 1, g = 1, b = 1 },
        healthTrailNumSchool = true,   -- a spell's number takes its school's color
        healthTrailNumCritRise = 100,  -- percent of Number Rise a crit's number travels
        healthTrailNumCritShake = false,
        healthTrailNumShake = 4,       -- crit shake strength: the most (a crit of 20% of max health or more)
        healthTrailNumOverlap = "stack", -- stack, merge, off
        healthTrailNumGap = 4,         -- between stacked numbers
        healthTrailNumMerge = 300,     -- ms
        healthTrailNumOthersColor = { r = 0.698, g = 0.4, b = 1 },
        healthTrailNumOthersSchool = false, -- their hit takes its school's color, not the Others color
        healthTrailNumOthersSize = 75, -- percent
        -- Outgoing Combat Text's word: your pet's hit, or a tick of a DoT (ground
        -- effect, totem): its own color and size (enemy nameplates only)
        healthTrailNumPet = true,
        healthTrailNumPetColor = { r = 0.9, g = 0.72, b = 0.5 },
        healthTrailNumPetSize = 80,    -- percent
        healthTrailNumDot = true,
        healthTrailNumDotColor = { r = 0.72, g = 0.86, b = 0.4 },
        healthTrailNumDotSchool = true, -- a tick takes its school's color, not the DoT color
        healthTrailNumDotSize = 70,    -- percent
        -- DoT Tick Style: "grow" each DoT's ticks fly into one number that grows;
        -- "each" every tick has its own number
        healthTrailNumDotGroup = "grow",
        -- between the bar and another player's number; false: Text Offset's
        healthTrailNumOthersOffset = false,
    }) do
        DEFAULTS_FRAMES[k] = v
    end
end
local DEFAULTS_PLATES = CopyTable(DEFAULTS_FRAMES)
do
    local d = DEFAULTS_PLATES
    d.healthTrailStyle = "chip"
    d.healthTrailEase = "NONE"
    d.healthTrailWait = 150
    d.healthTrailMove = 700
    d.healthTrailFall = 149
    d.healthTrailPop = 23
    d.healthTrailFlash = 80
    d.healthTrailCrit = true
    d.healthTrailMine = true
    if IS_FOREVER then
        d.healthTrailStyle = "number"
        d.healthTrailNumChunkMin = 30
        d.healthTrailNumChunkMax = 200
        d.healthTrailNumCritShake = true
        d.healthTrailNumDotGroup = "each"
        d.healthTrailNumMorph = 0
        d.healthTrailNumOffset = 71
        d.healthTrailNumOthersOffset = 18
        d.healthTrailNumOthersSchool = true
        d.healthTrailNumRise = 56
        d.healthTrailNumShake = 50
        d.healthTrailNumSize = 25
    end
end
HTr.DEFAULTS_FRAMES, HTr.DEFAULTS_PLATES = DEFAULTS_FRAMES, DEFAULTS_PLATES
local DEFAULTS = { frames = DEFAULTS_FRAMES, plates = DEFAULTS_PLATES }

local KEYS = {}
for k in pairs(DEFAULTS_FRAMES) do KEYS[#KEYS + 1] = k end
table.sort(KEYS)
HTr.KEYS = KEYS

-- healthTrailKept: the options page keeps each style's own values there when
-- the style changes. It has no default.
local function ValidKey(key)
    return DEFAULTS_FRAMES[key] ~= nil or key == "healthTrailKept"
end

local function CopyValue(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = CopyValue(x) end
    return c
end

-- The look a place uses: "plates" for nameplates, "frames" for raid and party.
function HTr.SetOf(place)
    local def = HB.PLACE[place]
    return (def and def.group == "plates") and "plates" or "frames"
end

-- The saved value of a look key, else its default. Never write to a color it
-- returns: it can be the default table.
function HTr.GetLook(set, key)
    local db = GetDB()
    local saved = db and db[set]
    local v
    if type(saved) == "table" then v = saved[key] end
    if v == nil then
        local d = DEFAULTS[set]
        v = d and d[key]
    end
    return v
end

local function WriteLook(db, set, key, value)
    local t = db[set]
    if not t then
        t = {}
        db[set] = t
    end
    t[key] = CopyValue(value)
end

function HTr.SetLook(set, key, value)
    if not DEFAULTS[set] or not ValidKey(key) then return end
    local db = GetDB(true)
    if not db then return end
    WriteLook(db, set, key, value)
    HB.QueueRefresh()
end

-- tbl: { [lookKey] = value }, written together (one refresh).
function HTr.SetLookMany(set, tbl)
    if not DEFAULTS[set] or type(tbl) ~= "table" then return end
    local db = GetDB(true)
    if not db then return end
    for k, v in pairs(tbl) do
        if ValidKey(k) then WriteLook(db, set, k, v) end
    end
    HB.QueueRefresh()
end

-- Every key of the look back to its default.
function HTr.ResetLook(set)
    if not DEFAULTS[set] then return end
    local db = GetDB()
    if db and db[set] then db[set] = nil end
    HB.QueueRefresh()
end

-- kind: "dmg" (Damage Animation) or "heal" (Heal Animation). Default off.
function HTr.PlaceOn(place, kind)
    local db = GetDB()
    local places = db and db.places
    local p = type(places) == "table" and places[place] or nil
    return type(p) == "table" and p[kind] == true
end

function HTr.SetPlace(place, kind, on)
    local def = HB.PLACE[place]
    if not (def and def.anim) or (kind ~= "dmg" and kind ~= "heal") then return end
    local db = GetDB(true)
    if not db then return end
    local places = db.places
    if not places then
        places = {}
        db.places = places
    end
    local p = places[place]
    if on then
        if not p then
            p = {}
            places[place] = p
        end
        p[kind] = true
    elseif p then
        p[kind] = nil
        if next(p) == nil then places[place] = nil end
    end
    HB.QueueRefresh()
end

local D_STYLES = { shrink = true, slide = true, fall = true, fade = true, chip = true, crumble = true,
    number = IS_FOREVER or nil }
local H_STYLES = { slide = true, fade = true }
local EASES = { NONE = true, IN = true, OUT = true, IN_OUT = true }
local N_COLORS = { white = true, custom = true }
local N_OVERLAP = { stack = true, merge = true, off = true }

local function Num(v, d)
    return tonumber(v) or d
end

-- The Number Morph part of a style, added to n (Forever only: D holds the
-- healthTrailNum keys).
local function NumStyle(src, D, dStyle, n)
    local nc = src.healthTrailNumCustom or D.healthTrailNumCustom
    local oc = src.healthTrailNumOthersColor or D.healthTrailNumOthersColor
    local pc = src.healthTrailNumPetColor or D.healthTrailNumPetColor
    local kc = src.healthTrailNumDotColor or D.healthTrailNumDotColor
    local nColor = src.healthTrailNumColor
    if not N_COLORS[nColor] then nColor = D.healthTrailNumColor end
    local dGroup = src.healthTrailNumDotGroup
    if dGroup ~= "grow" and dGroup ~= "each" then dGroup = D.healthTrailNumDotGroup end
    local nOver = src.healthTrailNumOverlap
    if not N_OVERLAP[nOver] then nOver = D.healthTrailNumOverlap end
    local nMorph = Num(src.healthTrailNumMorph, D.healthTrailNumMorph) / 100
    if nMorph < 0 then nMorph = 0 elseif nMorph > 0.95 then nMorph = 0.95 end
    local nOff = Num(src.healthTrailNumOffset, D.healthTrailNumOffset)
    n.numOn = (src.healthTrail and dStyle == "number") and true or false
    n.nFlight = math.max(50, Num(src.healthTrailNumFlight, D.healthTrailNumFlight)) / 1000
    n.nArc = Num(src.healthTrailNumArc, D.healthTrailNumArc)
    n.nDrift = Num(src.healthTrailNumDrift, D.healthTrailNumDrift)
    n.nMorph = nMorph
    n.nOff = nOff
    -- Others Text Offset: not set (false) follows Text Offset
    n.oOff = Num(src.healthTrailNumOthersOffset, nOff)
    n.nSize = math.max(4, Num(src.healthTrailNumSize, D.healthTrailNumSize))
    n.nChunk = src.healthTrailNumChunk == true
    n.ncMin = math.max(0.2, Num(src.healthTrailNumChunkMin, D.healthTrailNumChunkMin) / 100)
    n.ncMax = math.max(0.2, Num(src.healthTrailNumChunkMax, D.healthTrailNumChunkMax) / 100)
    n.nRise = Num(src.healthTrailNumRise, D.healthTrailNumRise)
    n.nTime = math.max(100, Num(src.healthTrailNumTime, D.healthTrailNumTime)) / 1000
    n.nIcon = src.healthTrailNumIcon ~= false
    n.nIconRight = src.healthTrailNumIconSide == "RIGHT"
    n.nColor = nColor
    n.nSchool = src.healthTrailNumSchool ~= false
    n.ncr, n.ncg, n.ncb = nc.r or 1, nc.g or 1, nc.b or 1
    n.nCritRise = math.max(0, Num(src.healthTrailNumCritRise, D.healthTrailNumCritRise)) / 100
    n.nShake = src.healthTrailNumCritShake
        and math.max(0, Num(src.healthTrailNumShake, D.healthTrailNumShake)) or 0
    n.nOverlap = nOver
    n.nGap = math.max(0, Num(src.healthTrailNumGap, D.healthTrailNumGap))
    n.nMerge = math.max(0, Num(src.healthTrailNumMerge, D.healthTrailNumMerge)) / 1000
    n.ocr = oc.r or D.healthTrailNumOthersColor.r
    n.ocg = oc.g or D.healthTrailNumOthersColor.g
    n.ocb = oc.b or D.healthTrailNumOthersColor.b
    n.oSize = math.max(0.2, Num(src.healthTrailNumOthersSize, D.healthTrailNumOthersSize) / 100)
    n.oSchool = src.healthTrailNumOthersSchool == true
    n.ptOn = src.healthTrailNumPet ~= false
    n.ptr = pc.r or D.healthTrailNumPetColor.r
    n.ptg = pc.g or D.healthTrailNumPetColor.g
    n.ptb = pc.b or D.healthTrailNumPetColor.b
    n.ptSize = math.max(0.2, Num(src.healthTrailNumPetSize, D.healthTrailNumPetSize) / 100)
    n.tkOn = src.healthTrailNumDot ~= false
    n.tkr = kc.r or D.healthTrailNumDotColor.r
    n.tkg = kc.g or D.healthTrailNumDotColor.g
    n.tkb = kc.b or D.healthTrailNumDotColor.b
    n.tkSchool = src.healthTrailNumDotSchool ~= false
    n.tkSize = math.max(0.2, Num(src.healthTrailNumDotSize, D.healthTrailNumDotSize) / 100)
    n.tkGroup = src.healthTrailNumDot ~= false and dGroup == "grow"
end

-- Reads the healthTrail* keys of a look (src: a table or a view with the place's
-- healthTrail and healthTrailHeal switches). Returns old when nothing changed,
-- so a caller restyles and resets only on a real change. defaults: the look's
-- default table, for a value that is missing or invalid.
function HTr.MakeStyle(src, old, defaults)
    local D = defaults or DEFAULTS_FRAMES
    local c = src.healthTrailColor or D.healthTrailColor
    local cc = src.healthTrailCritColor or D.healthTrailCritColor
    local mc = src.healthTrailMineColor or D.healthTrailMineColor
    local mcc = src.healthTrailMineCritColor or D.healthTrailMineCritColor
    local hc = src.healthTrailHealColor or D.healthTrailHealColor
    local dStyle = src.healthTrailStyle
    if not D_STYLES[dStyle] then dStyle = D.healthTrailStyle end
    local dEase = src.healthTrailEase
    if not EASES[dEase] then dEase = D.healthTrailEase end
    local hStyle = src.healthTrailHealStyle
    if not H_STYLES[hStyle] then hStyle = D.healthTrailHealStyle end
    local hEase = src.healthTrailHealEase
    if not EASES[hEase] then hEase = D.healthTrailHealEase end
    local n = {
        dmgOn = src.healthTrail and true or false,
        healOn = src.healthTrailHeal and true or false,
        dStyle = dStyle,
        dEase = dEase,
        dWait = math.max(0, Num(src.healthTrailWait, D.healthTrailWait)) / 1000,
        dMove = math.max(50, Num(src.healthTrailMove, D.healthTrailMove)) / 1000,
        fall = math.max(0, Num(src.healthTrailFall, D.healthTrailFall)),
        pop = math.max(0, Num(src.healthTrailPop, D.healthTrailPop)),
        tilt = Num(src.healthTrailTilt, D.healthTrailTilt),
        drift = Num(src.healthTrailDrift, D.healthTrailDrift),
        vary = src.healthTrailVary ~= false,
        chipSize = math.max(1, Num(src.healthTrailChipSize, D.healthTrailChipSize)),
        chipCols = math.max(1, math.floor(Num(src.healthTrailChipCols, D.healthTrailChipCols))),
        spread = math.max(0, Num(src.healthTrailSpread, D.healthTrailSpread)),
        spin = Num(src.healthTrailSpin, D.healthTrailSpin),
        stagger = math.max(0, Num(src.healthTrailStagger, D.healthTrailStagger)) / 1000,
        r = c.r or D.healthTrailColor.r,
        g = c.g or D.healthTrailColor.g,
        b = c.b or D.healthTrailColor.b,
        critOn = (src.healthTrail and src.healthTrailCrit) and true or false,
        cr = cc.r or D.healthTrailCritColor.r,
        cg = cc.g or D.healthTrailCritColor.g,
        cb = cc.b or D.healthTrailCritColor.b,
        mineOn = (src.healthTrail and src.healthTrailMine) and true or false,
        mr = mc.r or D.healthTrailMineColor.r,
        mg = mc.g or D.healthTrailMineColor.g,
        mb = mc.b or D.healthTrailMineColor.b,
        mcr = mcc.r or D.healthTrailMineCritColor.r,
        mcg = mcc.g or D.healthTrailMineCritColor.g,
        mcb = mcc.b or D.healthTrailMineCritColor.b,
        alpha = Num(src.healthTrailAlpha, D.healthTrailAlpha) / 100,
        flash = math.max(0, Num(src.healthTrailFlash, D.healthTrailFlash)) / 1000,
        group = src.healthTrailGroup ~= false,
        under = src.healthTrailUnderAbsorbs ~= false,
        hStyle = hStyle,
        hEase = hEase,
        hWait = math.max(0, Num(src.healthTrailHealWait, D.healthTrailHealWait)) / 1000,
        hMove = math.max(50, Num(src.healthTrailHealMove, D.healthTrailHealMove)) / 1000,
        hr = hc.r or D.healthTrailHealColor.r,
        hg = hc.g or D.healthTrailHealColor.g,
        hb = hc.b or D.healthTrailHealColor.b,
        ha = Num(src.healthTrailHealAlpha, D.healthTrailHealAlpha) / 100,
    }
    if IS_FOREVER then NumStyle(src, D, dStyle, n) end
    if old then
        local same = true
        for k, v in pairs(n) do
            if old[k] ~= v then same = false; break end
        end
        if same then return old end
    end
    return n
end

-------------------------------------------------------------------------------
--  Frames
-------------------------------------------------------------------------------
-- An invisible StatusBar over the health bar: its fill edge is the anchor.
local function HiddenBar(parent, bar)
    local sb = Flat(CreateFrame("StatusBar", nil, parent))
    sb:SetAllPoints(bar)
    sb:SetStatusBarTexture(WHITE)
    sb:SetStatusBarColor(0, 0, 0, 0)
    return sb
end

local function ClipFrame(parent)
    local f = Flat(CreateFrame("Frame", nil, parent))
    f:SetClipsChildren(true)
    return f
end

-- A finished group reverts its region to the start state, so the owner (a clip
-- frame, a frame or a texture) is hidden when the group ends. A recycled piece
-- carries a new gen, which mutes a late finish of its old run. g._chain(p), when
-- set, starts the next stage (Chip Off and Crumble: the piece leaves its place
-- at the end of the wait).
local function GroupDone(g)
    local p = g._p
    if p.gen ~= g._gen then return end
    g._hide:Hide()
    local nx = g._chain
    if nx then nx(p) end
end

local function NewGroup(owner, p, hide, kind)
    local g = owner:CreateAnimationGroup()
    local a = g:CreateAnimation(kind)
    g._p, g._hide = p, hide
    g:SetScript("OnFinished", GroupDone)
    return g, a
end

local function Run(g)
    g._gen = g._p.gen
    g:Play()
end

local function Timing(a, wait, move, ease)
    a:SetStartDelay(wait)
    a:SetDuration(move)
    a:SetSmoothing(ease)
end

-- A damage look: a clip (bar left .. before edge, inside a shared clip), the
-- piece frame with its color texture and white flash, and one group per motion.
-- A piece has one look inside the bar (p.dIn, in the shared live-edge clip
-- under the base) and, for a style that moves the piece below the bar, a twin
-- below it (p.dOut, in the shared below-the-bar clip under t.out). The twin
-- runs the same motions at the same time, so the two read as one piece; it
-- draws on OVERLAY 6 (flash OVERLAY 7) at the caller's below level, in front of
-- the bar's border art, which a flattened plate (SetFlattensRenderLayers) orders
-- by draw layer and a raid button by frame level.
local function NewDamageLook(holder, p, layer, sub, flashSub)
    local clip = ClipFrame(holder)
    local f = Flat(CreateFrame("Frame", nil, clip))
    local tex = f:CreateTexture(nil, layer, nil, sub)
    tex:SetAllPoints(f)
    local flash = f:CreateTexture(nil, "OVERLAY", nil, flashSub)
    flash:SetAllPoints(f)
    flash:SetColorTexture(1, 1, 1, 1)
    flash:Hide()
    local L = { clip = clip, f = f, tex = tex, flash = flash }
    local a
    L.scaleG, a = NewGroup(f, p, clip, "Scale")
    a:SetOrigin("LEFT", 0, 0)
    a:SetScaleFrom(1, 1)
    a:SetScaleTo(SCALE_END, 1)
    L.scale = a
    L.moveG, a = NewGroup(f, p, clip, "Translation")
    L.move = a
    L.alphaG, a = NewGroup(f, p, clip, "Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(0)
    L.alpha = a
    L.flashG, a = NewGroup(flash, p, flash, "Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(0)
    a:SetSmoothing("NONE")
    L.flashA = a
    clip:Hide()
    return L
end

local LOOK_GROUPS = { "scaleG", "moveG", "alphaG", "flashG" }

local function StopLook(L)
    for i = 1, #LOOK_GROUPS do L[LOOK_GROUPS[i]]:Stop() end
    L.clip:Hide()
    L.flash:Hide()
    L.g1, L.g2 = nil, nil
end

-- A look's motion groups start over (the Group Pieces option).
local function RestartLook(L)
    L.g1:Stop()
    L.g1:Play()
    if L.g2 then
        L.g2:Stop()
        L.g2:Play()
    end
end

-- Chip Off and Crumble: during the wait the piece sits in its place as the
-- look inside the bar (under the border, as the other styles); at the end of
-- the wait that look goes and the piece leaves its place in front of the
-- border art (under t.out). A Rotation needs a texture, so these groups run on
-- the textures.

-- Chip Off: the whole piece (after edge .. before edge, not clipped, so the jump
-- above the bar shows) jumps up, falls below the bar, tilts and moves sideways.
local function NewFly(t, p)
    local f = Flat(CreateFrame("Frame", nil, t.out))
    local tex = f:CreateTexture(nil, "OVERLAY", nil, 6)
    tex:SetPoint("TOPLEFT", p.afterTex, "TOPRIGHT")
    tex:SetPoint("BOTTOMRIGHT", p.beforeTex, "BOTTOMRIGHT")
    local F = { f = f, tex = tex }
    F.g, F.up = NewGroup(tex, p, f, "Translation")
    F.up:SetSmoothing("OUT")
    local g = F.g
    F.down = g:CreateAnimation("Translation")
    F.down:SetSmoothing("IN")
    F.side = g:CreateAnimation("Translation")
    F.side:SetSmoothing("NONE")
    F.spin = g:CreateAnimation("Rotation")
    F.spin:SetOrigin("CENTER", 0, 0)
    F.spin:SetSmoothing("NONE")
    F.fade = g:CreateAnimation("Alpha")
    F.fade:SetFromAlpha(1)
    F.fade:SetToAlpha(0)
    F.fade:SetSmoothing("NONE")
    f:Hide()
    return F
end

-- Crumble: one square chip with its own drop, drift, spin and fade.
local function NewChip(C, p)
    local tex = C.f:CreateTexture(nil, "OVERLAY", nil, 6)
    local ch = { tex = tex }
    ch.g, ch.move = NewGroup(tex, p, tex, "Translation")
    ch.spin = ch.g:CreateAnimation("Rotation")
    ch.spin:SetOrigin("CENTER", 0, 0)
    ch.fade = ch.g:CreateAnimation("Alpha")
    ch.fade:SetFromAlpha(1)
    ch.fade:SetToAlpha(0)
    ch.fade:SetSmoothing("IN")
    tex:Hide()
    return ch
end

-- Crumble: a clip (after edge .. before edge, down below the bar) inside the
-- shared below-the-bar clip, the chips (made when first needed), and the chunk:
-- the whole piece in a clip that ends where the chip grid starts, so a piece
-- wider than the grid drops its left part in one.
local CHUNK_LEFT = 20000  -- the chunk clip's left end: far left of any bar

local function NewCrumble(t, p)
    local clip = ClipFrame(t.oClip)
    local f = Flat(CreateFrame("Frame", nil, clip))
    local cclip = ClipFrame(clip)
    local cf = Flat(CreateFrame("Frame", nil, cclip))
    local chunk = cf:CreateTexture(nil, "OVERLAY", nil, 6)
    chunk:SetPoint("TOPLEFT", p.afterTex, "TOPRIGHT")
    chunk:SetPoint("BOTTOMRIGHT", p.beforeTex, "BOTTOMRIGHT")
    local C = { clip = clip, f = f, cclip = cclip, chunk = chunk, chips = {}, n = 0 }
    C.chunkG, C.chunkMove = NewGroup(chunk, p, chunk, "Translation")
    C.chunkFade = C.chunkG:CreateAnimation("Alpha")
    C.chunkFade:SetFromAlpha(1)
    C.chunkFade:SetToAlpha(0)
    clip:Hide()
    return C
end

local function StopCrumble(C)
    C.chunkG:Stop()
    local chips = C.chips
    for i = 1, C.n do chips[i].g:Stop() end
    C.clip:Hide()
end

-- Heal look (no smooth fill): clip (before edge .. bar right, inside the
-- shared bar left .. live edge clip) around a texture in the heal color.
local function EnsureHeal(t, p)
    if p.hClip then return end
    local clip = ClipFrame(t.hClip)
    local f = Flat(CreateFrame("Frame", nil, clip))
    -- Above the bar's own fill, which this covers.
    local tex = f:CreateTexture(nil, "OVERLAY", nil, 6)
    tex:SetAllPoints(f)
    p.hClip, p.hF, p.hTex = clip, f, tex
    local a
    p.hScaleG, a = NewGroup(f, p, clip, "Scale")
    a:SetOrigin("RIGHT", 0, 0)
    a:SetScaleFrom(1, 1)
    a:SetScaleTo(SCALE_END, 1)
    p.hScale = a
    p.hAlphaG, a = NewGroup(f, p, clip, "Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(0)
    p.hAlpha = a
    clip:Hide()
end

-- Heal look with smooth fill: the part right of the live edge up to the new
-- value, drawn as a StatusBar in the bar's own texture and the heal color.
-- No motion of its own (the fill slides over it); an alpha group retires it.
local function EnsureSmooth(t, p, bar)
    if p.sClip then return end
    local clip = ClipFrame(t.dClip)
    local sb = Flat(CreateFrame("StatusBar", nil, clip))
    sb:SetAllPoints(bar)
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(1)
    p.sClip, p.sBar = clip, sb
    local a
    p.sG, a = NewGroup(clip, p, clip, "Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(1)
    a:SetDuration(SMOOTH_LIFE)
    clip:Hide()
end

-- Number Morph: the numbers move by OnUpdate (the driver below): an engine
-- Translation did not move a font string that holds a secret amount. The
-- flying piece is a plain texture, so it runs on AnimationGroups like Chip
-- Off. The driver runs only while a piece is in flight, a hit waits for its
-- piece or a number shows.
local liveNums = {}   -- [number] = true
local arrivals = {}   -- [piece] = true: in flight; its numbers show at p.nArrT
local waitBars = {}   -- [state] = true: the bar has hits that wait for their health change
-- [piece] = true: its lift-off waits: for Outgoing Combat Text's word (NM.hold), for
-- a late hit (LATE) or for an older piece of its bar (ORDER)
local holds = {}

-- Number n's stack gap bars (SG, below) go back to their bar's pool.
local function SGFree(n)
    local bars = n.sgBars
    if bars and #bars > 0 then
        local t = n.sgT
        local pool = t and t.sgPool
        if t and not pool then
            pool = {}
            t.sgPool = pool
        end
        for i = #bars, 1, -1 do
            local b = bars[i]
            b:Hide()
            b:ClearAllPoints()
            if pool then pool[#pool + 1] = b end
            bars[i] = nil
        end
    end
    n.sgTop, n.sgPt = nil, nil
end

local function EndNum(n)
    n.h:Hide()
    SGFree(n)
    n.live = nil
    n.group, n.slot, n.gs = nil, nil, nil
    liveNums[n] = nil
end

-- Runs fn(...); an error is shown once (the error handler), never raised.
-- Returns true when fn ran to its end.
local guardShown = false
local function Guard(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok and not guardShown then
        guardShown = true
        geterrorhandler()(err)
    end
    return ok
end

-- True when the game forbids measuring this region now (GetPoint, GetWidth
-- and the like), as for a region anchored to a protected nameplate.
-- Tried, not asked: IsAnchoringRestricted's answer can be secret, and EUI's
-- plate bars measure fine while it says so. So: true when measuring r now
-- raises an error (anchored to a restricted region) or gives a secret value
-- (a secret layout).
local function Restricted(r)
    if not r then return true end
    local ok1, s = pcall(r.GetEffectiveScale, r)
    local ok2, w = pcall(r.GetWidth, r)
    local ok3, h = pcall(r.GetHeight, r)
    if not (ok1 and ok2 and ok3) then return true end
    if issecretvalue(s) or issecretvalue(w) or issecretvalue(h) then return true end
    return false
end

local GROUPS = { "hScaleG", "hAlphaG", "sG" }

-- Stops every look of a piece, but not its Number Morph flight and numbers.
local function StopLooks(p)
    if p.dIn then StopLook(p.dIn) end
    if p.dOut then StopLook(p.dOut) end
    if p.dFly then
        p.dFly.g:Stop()
        p.dFly.f:Hide()
    end
    if p.dCrumb then StopCrumble(p.dCrumb) end
    for i = 1, #GROUPS do
        local g = p[GROUPS[i]]
        if g then g:Stop() end
    end
    if p.hClip then p.hClip:Hide() end
    if p.sClip then p.sClip:Hide() end
    p.hG, p.dOutOn, p.dFlyOn, p.dCrumbOn = nil, nil, nil, nil
end

local function StopPiece(p)
    StopLooks(p)
    if p.nFly then
        p.nFly.g:Stop()
        p.nFly.cg:Stop()
        p.nFly.f:Hide()
    end
    if p.nOn then
        -- Its numbers are anchored to it: they end with it.
        arrivals[p] = nil
        local nl = p.numList
        for i = #nl, 1, -1 do
            local n = nl[i]
            if n.live and n.piece == p then EndNum(n) end
            nl[i] = nil
        end
        local hs = p.hits
        for i = #hs, 1, -1 do
            hs[i].amount = nil
            hs[i] = nil
        end
        p.nOn, p.arrived = nil, nil
    end
end

local function StopAll(t)
    local ps = t.pieces
    for i = 1, #ps do StopPiece(ps[i]) end
end

-- Number Morph: a piece that waits to lift off, flies, or holds a live number.
-- Its numbers are anchored to it, so recycling it ends them.
local function PieceBusy(p, now)
    if not p.nOn or p.nGen ~= p.gen then return false end
    if arrivals[p] or holds[p] then return true end
    if not p.arrived then
        local st = p.nSt
        return st ~= nil and now - (p.dT0 or 0) < st.dWait + 0.5
    end
    local nl = p.numList
    for i = 1, #nl do
        local n = nl[i]
        if n.live and n.piece == p then return true end
    end
    return false
end

-- The next piece in turn, past any busy one (see PieceBusy); when all POOL
-- pieces are used the oldest is recycled. When all POOL pieces are busy the bar
-- gets another, up to PIECE_MAX; only past that does a busy piece's number end
-- early.
local function TakePiece(t, bar)
    local ps = t.pieces
    local n = #ps
    local i = t.cursor
    if i > n and n >= POOL then i = 1 end
    if i <= n then
        local now = GetTime()
        local k, found = i, nil
        for _ = 1, n do
            if not PieceBusy(ps[k], now) then
                found = k
                break
            end
            k = k % n + 1
        end
        if found then
            i = found
        elseif n < PIECE_MAX then
            i = n + 1
        end
    end
    t.cursor = i + 1
    local p = ps[i]
    if p then
        StopPiece(p)
    else
        p = { after = HiddenBar(t.base, bar), before = HiddenBar(t.base, bar), gen = 0 }
        p.afterTex = p.after:GetStatusBarTexture()
        p.beforeTex = p.before:GetStatusBarTexture()
        ps[i] = p
    end
    p.gen = p.gen + 1
    return p
end

-------------------------------------------------------------------------------
--  Arming a piece (anchors, colors and timings are set per change, so a settings
--  edit needs no restyle pass)
-------------------------------------------------------------------------------
-- Color and draw layer of a damage piece from p.mine / p.crit (the crit color only
-- while Crit Color is on, the mine colors only while My Damage is on). Inside the
-- bar a special piece sits on the lowest overlay sublevel and a normal one on
-- ARTWORK 7; the white flash (OVERLAY 0) stays above both. The below-the-bar twin
-- keeps its own layer (OVERLAY 6) and takes the same color. Set on every arm and
-- recolor, because pieces are pooled.
local function PaintDamage(p, st)
    local crit, mine = p.crit and st.critOn, p.mine and st.mineOn
    local r, g, b
    if mine and crit then
        r, g, b = st.mcr, st.mcg, st.mcb
    elseif mine then
        r, g, b = st.mr, st.mg, st.mb
    elseif crit then
        r, g, b = st.cr, st.cg, st.cb
    else
        r, g, b = st.r, st.g, st.b
    end
    local tex = p.dIn.tex
    if mine or crit then
        tex:SetDrawLayer("OVERLAY", -8)
    else
        tex:SetDrawLayer("ARTWORK", 7)
    end
    local a = st.alpha
    tex:SetColorTexture(r, g, b, a)
    if p.dOut then p.dOut.tex:SetColorTexture(r, g, b, a) end
    if p.dFlyOn then p.dFly.tex:SetColorTexture(r, g, b, a) end
    if p.nOn then p.nFly.tex:SetColorTexture(r, g, b, a) end
    if p.dCrumbOn then
        local C = p.dCrumb
        C.chunk:SetColorTexture(r, g, b, a)
        local chips = C.chips
        for i = 1, C.n do chips[i].tex:SetColorTexture(r, g, b, a) end
    end
end

-- Crumble's chip grid: rows = the bar height / Chip Size, rounded, 1 to 4;
-- side = the bar height / rows (base units, plain numbers).
local function CrumbleGrid(t, st)
    local h = t.barH
    local rows = math.floor(h / (st.chipSize * t.mul) + 0.5)
    if rows < 1 then rows = 1 elseif rows > 4 then rows = 4 end
    return h / rows, rows
end

-- How far below the bar a damage style draws (0: it stays inside). Chip Off
-- draws with no clip, so it has no distance here.
local function BelowPx(t, st)
    local s = st.dStyle
    if s == "fall" then return st.fall * t.mul end
    if s == "crumble" then
        local side = CrumbleGrid(t, st)
        return st.fall * t.mul * 1.3 + side + 2 * t.mul
    end
    return 0
end

local CUT = 0.01  -- seconds: how fast the inside look goes at the end of the wait

-- Starts a look's motion for the damage style (and its flash). belowPx: the
-- style's distance below the bar. chain(p): Chip Off and Crumble, the stage that
-- starts when this look goes at the end of the wait.
local function Motion(t, L, st, belowPx, chain)
    local wait, move, ease = st.dWait, st.dMove, st.dEase
    local s = st.dStyle
    L.alphaG._chain = nil
    if chain then
        Timing(L.alpha, wait, CUT, "NONE")
        L.alphaG._chain = chain
        L.g1, L.g2 = L.alphaG, nil
    elseif s == "shrink" then
        Timing(L.scale, wait, move, ease)
        L.g1, L.g2 = L.scaleG, nil
    elseif s == "slide" then
        L.move:SetOffset(-t.barPx, 0)
        Timing(L.move, wait, move, ease)
        L.g1, L.g2 = L.moveG, nil
    elseif s == "fall" then
        L.move:SetOffset(0, -belowPx)
        Timing(L.move, wait, move, ease)
        Timing(L.alpha, wait, move, ease)
        L.g1, L.g2 = L.moveG, L.alphaG
    else
        Timing(L.alpha, wait, move, ease)
        L.g1, L.g2 = L.alphaG, nil
    end
    L.clip:Show()
    Run(L.g1)
    if L.g2 then Run(L.g2) end
    if st.flash > 0 then
        L.flashA:SetDuration(st.flash)
        L.flash:Show()
        Run(L.flashG)
    end
end

-- Places a look: its clip spans top .. the before edge (down to belowPx under the
-- bar's bottom), the piece spans left .. the before edge over the bar's height.
local function PlaceLook(L, top, topPoint, left, before, belowPx)
    L.clip:ClearAllPoints()
    L.clip:SetPoint("TOPLEFT", top, topPoint)
    L.clip:SetPoint("BOTTOMRIGHT", before, "BOTTOMRIGHT", 0, -belowPx)
    L.f:ClearAllPoints()
    L.f:SetPoint("TOPLEFT", left, "TOPRIGHT")
    L.f:SetPoint("BOTTOMRIGHT", before, "BOTTOMRIGHT")
end

-- Chip Off: the throw, as an arc. With u = time / move, the height is
-- y(u) = s^2 u^2 - 2 sqrt(pop) s u (down is +), s = sqrt(pop) + sqrt(pop + fall):
-- it peaks (-pop) at u0 = sqrt(pop) / s and ends at +fall. So the rise is an up
-- Translation for u0 * move (OUT: it slows to the peak) and the fall a down one
-- for the rest (IN: it speeds up). Tilt and sideways run over the whole move,
-- the fade over its last 40%. Vary scales pop, tilt and sideways by 0.7 to 1.3.
local MIN_DUR = 0.001

local function ArmFly(t, p, st)
    local F = p.dFly
    if not F then
        F = NewFly(t, p)
        p.dFly = F
    end
    local k1, k2, k3 = 1, 1, 1
    if st.vary then
        k1, k2, k3 = 0.7 + 0.6 * random(), 0.7 + 0.6 * random(), 0.7 + 0.6 * random()
    end
    local mul, move = t.mul, st.dMove
    local pop, fall = st.pop * k1 * mul, st.fall * mul
    local rp = math.sqrt(pop)
    local s = rp + math.sqrt(pop + fall)
    local rise = (s > 0) and (rp / s) * move or 0
    F.up:SetOffset(0, pop)
    F.up:SetStartDelay(0)
    F.up:SetDuration(math.max(rise, MIN_DUR))
    F.down:SetOffset(0, -(pop + fall))
    F.down:SetStartDelay(rise)
    F.down:SetDuration(math.max(move - rise, MIN_DUR))
    F.side:SetOffset(st.drift * k3 * mul, 0)
    F.side:SetDuration(move)
    -- A positive Rotation turns left; the tuner's tilt turns right.
    F.spin:SetDegrees(-st.tilt * k2)
    F.spin:SetDuration(move)
    F.fade:SetStartDelay(move * 0.6)
    F.fade:SetDuration(move * 0.4)
    F.f:Hide()
    p.dFlyOn = true
end

local function StartFly(p)
    local F = p.dFly
    F.f:Show()
    Run(F.g)
end

-- Crumble: chips in a fixed grid from the before edge leftward (plain offsets:
-- the piece's width is secret), each with its own random start (up to Stagger
-- after the wait), drop (0.7 to 1.3 times Fall Distance), drift and spin. The
-- chunk (the part left of the grid) starts after the full Stagger.
local function ArmCrumble(t, bar, p, st, belowPx)
    local C = p.dCrumb
    if not C then
        C = NewCrumble(t, p)
        p.dCrumb = C
    end
    local side, rows = CrumbleGrid(t, st)
    local cols = st.chipCols
    local n = cols * rows
    local mul, move, ease = t.mul, st.dMove, st.dEase
    local fall, spread, spin, stagger = st.fall * mul, st.spread * mul, st.spin, st.stagger
    C.clip:ClearAllPoints()
    C.clip:SetPoint("TOPLEFT", p.afterTex, "TOPRIGHT")
    C.clip:SetPoint("BOTTOMRIGHT", p.beforeTex, "BOTTOMRIGHT", 0, -belowPx)
    C.clip:Hide()
    C.cclip:ClearAllPoints()
    C.cclip:SetPoint("TOPLEFT", bar, "TOPLEFT", -CHUNK_LEFT, 0)
    C.cclip:SetPoint("BOTTOMRIGHT", p.beforeTex, "BOTTOMRIGHT", -cols * side, -belowPx)
    C.chunkMove:SetOffset(0, -fall)
    Timing(C.chunkMove, stagger, move, ease)
    Timing(C.chunkFade, stagger, move, ease)
    C.chunk:Show()
    local chips = C.chips
    for i = 1, n do
        local ch = chips[i]
        if not ch then
            ch = NewChip(C, p)
            chips[i] = ch
        end
        if ch.side ~= side or ch.rows ~= rows then
            local c, r = math.floor((i - 1) / rows), (i - 1) % rows
            local tex = ch.tex
            tex:ClearAllPoints()
            tex:SetSize(side, side)
            tex:SetPoint("TOPRIGHT", p.beforeTex, "TOPRIGHT", -c * side, -r * side)
            ch.side, ch.rows = side, rows
        end
        local d = random() * stagger
        ch.move:SetOffset((random() * 2 - 1) * spread, -fall * (0.7 + 0.6 * random()))
        Timing(ch.move, d, move, ease)
        ch.spin:SetDegrees((random() * 2 - 1) * spin)
        Timing(ch.spin, d, move, ease)
        ch.fade:SetStartDelay(d)
        ch.fade:SetDuration(move)
        ch.tex:Show()
    end
    for i = n + 1, C.n do chips[i].tex:Hide() end
    C.n = n
    p.dCrumbOn = true
end

local function StartCrumble(p)
    local C = p.dCrumb
    C.clip:Show()
    local chips = C.chips
    for i = 1, C.n do Run(chips[i].g) end
    Run(C.chunkG)
end

-------------------------------------------------------------------------------
--  Number Morph (damage style "number", Forever only)
--  The lost piece waits in place (the look inside the bar), lifts off in front
--  of the border and flies on an arc to its number's spot (Text Offset above
--  the middle of the piece; another player's hit: below it). From Morph Starts
--  on it shrinks and turns the number's color; on arrival it fades while the
--  number pops in, rises (sinks) and fades. The piece's x and width are secret:
--  the number is anchored to the piece, never measured. A hit pairs with the
--  health change of the same bar inside CRIT_WINDOW, or later with a piece
--  that has no hit yet (FlushWait); a hit with no change shows at the bar's
--  fill edge. A piece with no hit fades where it is.
-------------------------------------------------------------------------------
-- Number Morph constants (one table: the file is near the 200-local limit).
-- pop: s, the number's pop (the piece fades over it). hold: s a hit with no
-- side yet may wait for Outgoing Combat Text's word; in a group that word
-- comes when its claim window ends, about 0.45 s after the hit.
local NM = {
    pop = 0.16,
    hold = 0.6,
    popNorm = 1.25,        -- a number's pop (a crit's is the same)
    fade = 0.45,           -- after its rise a number fades over this part of Number Time
    young = 0.7,           -- part of its fade after which (alpha under 30%) it is not pushed
    th = 0.72,             -- a number's height per point of font size
    pool = 40,             -- most numbers per bar; past it a new one ends the oldest
    pieceHits = 4,         -- hits one piece takes; more show at the fill edge
    petIcon = "pet",       -- your pet's portrait as an icon
    waitMax = 6,           -- hits per bar that wait for their health change
    recent = 8,            -- hits per bar a note can still find
    noteWindow = 1,        -- s a note that came before its hit waits for it
    morphX = 0.35,         -- the piece's width at the end of the flight (its own is secret)
    critR = 1, critG = 0.824, critB = 0.235,
    shakeT = 0.25,         -- s a crit's number shakes
    shakeW = 80,           -- radians per s (about 13 wobbles a second)
}
-- A piece with no hit at the end of its wait holds up to LATE.hold s after its
-- health change for a late hit (a swing's hit event comes after its health
-- change). A piece that lifts off after such a hold flies in LATE.flight of
-- Flight Time. fade: a piece whose late hit did not come fades over this many s.
local LATE = { hold = 1, flight = 0.5, fade = 0.12 }
-- Lift-off order: a piece lifts off only after the older pieces of its bar
-- (earlier health changes) have. One that holds for a late hit or for the word
-- keeps the newer ones in their place; then they lift off in the same frame,
-- the oldest first. max: the longest a piece waits so. quick: a shorter wait
-- keeps the normal flight. list: DriveHolds' work list.
local ORDER = { max = LATE.hold + NM.hold, quick = 0.05, list = {} }
-- DoT Tick Style "One Growing Number": the ticks of one DoT on a mob fly into
-- one number beside the fill edge (left of it, so your other numbers rise
-- clear of it). Amounts are secret and cannot be added: it shows the newest
-- tick and a count ("x5"), and grows by `step` a tick up to `max`. It stays
-- `linger` s after the last tick, then fades. slots: DoTs a bar shows this way
-- at once, stacked up; a DoT past them shows each tick on its own. dx: its
-- center left of the fill edge, in points of its font size.
local DG = { linger = 3.6, step = 0.08, max = 1.5, slots = 3, dx = 2.2 }

-- The key of tick h's DoT: its icon (Outgoing Combat Text finds the spell)
function DG.Key(h)
    return h.icon or "dot"
end

-- The live grouped number of DoT key on bar t, else nil
function DG.Find(t, key)
    local nums = t.nums
    if not nums then return nil end
    for i = 1, #nums do
        local m = nums[i]
        if m.live and m.group == key then return m end
    end
    return nil
end

-- The slot (0 up) of DoT key on bar t: its live number's, else the lowest
-- free one; nil when every slot is taken.
function DG.Slot(t, key)
    local m = DG.Find(t, key)
    if m then return m.slot end
    local nums = t.nums or {}
    for s = 0, DG.slots - 1 do
        local free = true
        for i = 1, #nums do
            local n = nums[i]
            if n.live and n.group and n.slot == s then
                free = false
                break
            end
        end
        if free then return s end
    end
    return nil
end

-- Slot s's center above the bar's top; size: the number's font size (no crit)
function DG.Y(st, mul, size, s)
    local th = size * NM.th
    return st.nOff * mul + th / 2 + s * (th * DG.max + st.nGap * mul)
end

-- Single-school colors by school mask. Physical and mixed schools keep Number
-- Color.
local SCHOOL_RGB = {
    [2]  = { 1, 0.88, 0.4 },   -- holy
    [4]  = { 1, 0.5, 0 },      -- fire
    [8]  = { 0.3, 1, 0.3 },    -- nature
    [16] = { 0.5, 1, 1 },      -- frost
    [32] = { 0.6, 0.5, 1 },    -- shadow
    [64] = { 1, 0.5, 1 },      -- arcane
}

-- An amount is secret or plain; only a plain one is compared (with nil).
local function HasValue(v)
    if issecretvalue(v) then return true end
    return v ~= nil
end

-- School Colors: a spell's school color (a crit: half school, half gold).
-- Else Number Color: white, or the custom color; a crit goes gold unless
-- Custom. Another player's: the Others color (its school's with Others Use
-- School Color; a physical or mixed hit keeps the Others color). tag: "pet"
-- your pet's hit, "dot" a DoT tick: that look's color while it is on (a tick
-- with DoT Use School Color takes its school's color).
local function NumColor(st, crit, school, other, tag)
    if other then
        local s = st.oSchool and SCHOOL_RGB[school]
        if s then return s[1], s[2], s[3] end
        return st.ocr, st.ocg, st.ocb
    end
    if tag == "pet" and st.ptOn then return st.ptr, st.ptg, st.ptb end
    if tag == "dot" and st.tkOn then
        if not st.tkSchool then return st.tkr, st.tkg, st.tkb end
        local s = SCHOOL_RGB[school]
        if s then return s[1], s[2], s[3] end
    end
    local s = st.nSchool and SCHOOL_RGB[school]
    if s then
        if crit then return (s[1] + NM.critR) / 2, (s[2] + NM.critG) / 2, (s[3] + NM.critB) / 2 end
        return s[1], s[2], s[3]
    end
    if st.nColor == "custom" then return st.ncr, st.ncg, st.ncb end
    if crit then return NM.critR, NM.critG, NM.critB end
    return 1, 1, 1
end

-- A number's size. A crit's is the same (a crit shakes instead).
local function NumSize(st, mul, other, tag)
    local s = st.nSize * mul
    if other then
        s = s * st.oSize
    elseif tag == "pet" and st.ptOn then
        s = s * st.ptSize
    elseif tag == "dot" and st.tkOn then
        s = s * st.tkSize
    end
    s = math.floor(s + 0.5)
    if s < 4 then s = 4 end
    return s
end

local function NumFont()
    local f = EllesmereUI.GetFontPath and EllesmereUI.GetFontPath("nameplates")
    return f or STANDARD_TEXT_FONT
end

local function NumFlags()
    if EllesmereUI.SlugFlag then return EllesmereUI.SlugFlag("OUTLINE, SLUG") end
    return "OUTLINE"
end

-- Your pet's portrait on icon texture tex (square: no round mask); the auto
-- attack icon when there is no pet or the game refuses it.
local function PetIcon(tex)
    local ok = UnitExists("pet") and pcall(SetPortraitTexture, tex, "pet", true)
    if not ok then tex:SetTexture(C_Spell.GetSpellTexture(6603)) end
end

-- Size by Chunk (CH): a hit's number takes one of CH.n sizes by its part of
-- the unit's max health: under 2%, 2-5%, 5-10%, 10-20%, 20% or more. The
-- amount and the health are secret: no Lua code reads, compares or scales
-- them, so the engine picks the size. A hidden status bar inside the number
-- (min 0, max: the bar's max health, value: the amount, which the bar
-- clamps) puts its fill edge frac x W right of the number's point (frac: the
-- amount's part of max health). Each size is a clip frame whose window rides
-- on that edge, from (frac - hi) x W to (frac - lo) x W, so it holds the
-- number's point only while lo < frac < hi. Each draws the same text at its
-- own size; only the one whose window holds the point shows. Y: each window's
-- half height. off: set after an error (then Number Size). A crit shakes by
-- its chunk the same way: each size shakes by its own part of Shake Strength,
-- from shLo (under 2%) to shHi (20% or more). shMid: a crit's shake when its
-- chunk is not known (no max health, a DoT's growing number).
local CH = { cuts = { 0.0203, 0.0503, 0.1003, 0.2003 }, n = 5, W = 1e7, Y = 1e4, lo = -0.5, hi = 1.5,
    shLo = 0.3, shHi = 1, shMid = 0.65 }

-- True when hit h's number on bar t has its sizes (one draws, by its chunk):
-- Size by Chunk on, or a crit that shakes; an amount (not an avoid word) and
-- the bar's max health known.
function CH.On(st, h, t)
    return ((st.nChunk or (h.crit and (st.nShake or 0) > 0)) and not CH.off and not h.label
        and HasValue(h.amount) and HasValue(t.max)) and true or false
end

-- Size k's part of Shake Strength (CH.shLo to CH.shHi in even steps)
function CH.Part(k)
    return CH.shLo + (CH.shHi - CH.shLo) * (k - 1) / (CH.n - 1)
end

-- The sizes of number n: built the first time it shows by its chunk.
function CH.Parts(n)
    local c = n.ch
    if c then return c end
    local h = n.h
    local sb = Flat(CreateFrame("StatusBar", nil, h))
    sb:SetStatusBarTexture(WHITE)
    sb:SetStatusBarColor(0, 0, 0, 0)
    sb:SetPoint("LEFT", h, "CENTER", 0, 0)
    sb:SetSize(CH.W, 2)
    local fill = sb:GetStatusBarTexture()
    c = { sb = sb, steps = {} }
    for k = 1, CH.n do
        local lo = CH.cuts[k - 1] or CH.lo
        local hi = CH.cuts[k] or CH.hi
        local clip = ClipFrame(h)
        clip:SetPoint("TOPLEFT", fill, "RIGHT", -hi * CH.W, CH.Y)
        clip:SetPoint("BOTTOMRIGHT", fill, "RIGHT", -lo * CH.W, -CH.Y)
        local icon = clip:CreateTexture(nil, "OVERLAY")
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:Hide()
        c.steps[k] = { clip = clip, fs = clip:CreateFontString(nil, "OVERLAY"), icon = icon }
    end
    n.ch = c
    return c
end

-- Number n by its chunk (n.chOn) or at Number Size: its sizes show or hide.
-- On: the amount and t.max reach only the status bar.
function CH.Set(n, t, amount)
    if n.chOn then CH.Parts(n) end
    local c = n.ch
    if not c then return end
    if n.chOn then
        c.sb:SetMinMaxValues(0, t.max)
        c.sb:SetValue(amount)
    end
    local s = c.steps
    for k = 1, #s do s[k].clip:SetShown(n.chOn) end
end

-- Font, size and color of each of number n's sizes: by Size by Chunk,
-- Smallest to Largest of its size in even steps; else (a crit's shake only)
-- all at its size.
function CH.Style(n, st, size, font, r, g, b)
    local steps = n.ch.steps
    for k = 1, #steps do
        local s = steps[k]
        local f = st.nChunk and (st.ncMin + (st.ncMax - st.ncMin) * (k - 1) / (CH.n - 1)) or 1
        local sz = math.floor(size * f + 0.5)
        if sz < 4 then sz = 4 end
        if s.size ~= sz or s.font ~= font then
            s.size, s.font = sz, font
            if EllesmereUI.PrimeFontShadow then EllesmereUI.PrimeFontShadow(s.fs, false) end
            s.fs:SetFont(font, sz, NumFlags())
            s.ic = math.floor(sz * 0.85 + 0.5)
            s.icon:SetSize(s.ic, s.ic)
        end
        s.fs:SetTextColor(r, g, b)
    end
end

-- One text: an avoid word (label), an amount (s: from BreakUpLargeNumbers,
-- may be secret: it only reaches SetFormattedText) with a count when hits
-- merged, or none.
local function SetNumText(fs, label, has, s, count)
    if label then
        fs:SetText(label)
    elseif not has then
        fs:SetText("")
    elseif count then
        fs:SetFormattedText("%s x%d", s, count)
    else
        fs:SetFormattedText("%s", s)
    end
end

-- Number n's text. By its chunk each size gets it and its own stays empty.
local function NumText(n, label, has, amount, count)
    local s
    if has and not label then s = BreakUpLargeNumbers(amount) end
    if not n.chOn then
        SetNumText(n.fs, label, has, s, count)
        return
    end
    n.fs:SetText("")
    local steps = n.ch.steps
    for k = 1, #steps do SetNumText(steps[k].fs, label, has, s, count) end
end

-- Another player's hit (enemy nameplates only): the note, else the threat
-- guess. Unknown counts as the player's own.
local function IsOther(h)
    if not h.others then return false end
    return (h.role or h.guess) == "other"
end

-- True when hit h has no side yet (no word, threat guess "unknown") and
-- Outgoing Combat Text sends its word on enemy hits. Without it an unknown
-- hit counts as the player's.
local function Undecided(h)
    if not h.others or h.role or h.guess ~= "unknown" then return false end
    local oct = EllesmereUI.OutgoingCombatText
    return (oct and oct.Notes and oct.Notes()) and true or false
end

-- Hit h takes a side without the word: in a group another player's (the word
-- calls your own hits yours within its claim window), solo yours.
local function Settle(h)
    h.guess = (IsInGroup and IsInGroup()) and "other" or "mine"
end

-- True while hit h waits for the word, at most NM.hold s after it came; then it
-- takes a side (Settle).
local function Holding(h, now)
    if not Undecided(h) then return false end
    if now - h.t < NM.hold then return true end
    Settle(h)
    return false
end

-- The side hit h shows on: the first hit of a piece keeps the side its piece
-- flew to; a hit with no side yet takes one now.
local function PopSide(h, p)
    if p and p.hits[1] == h and p.nOther ~= nil then return p.nOther end
    if Undecided(h) then Settle(h) end
    return IsOther(h)
end

local function NewNum(t)
    local h = CreateFrame("Frame", nil, t.out)
    h:SetSize(1, 1)
    h:Hide()
    local fs = h:CreateFontString(nil, "OVERLAY")
    local icon = h:CreateTexture(nil, "OVERLAY")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:Hide()
    return { h = h, fs = fs, icon = icon, s = 1 }
end

-- The next free number of the bar, else a new one (up to NM.pool), else
-- the oldest ends early for it.
local function TakeNum(t)
    local nums = t.nums
    if not nums then
        nums = {}
        t.nums = nums
    end
    local c = #nums
    local i = t.nIdx or 0
    for _ = 1, c do
        i = i % c + 1
        if not nums[i].live then
            t.nIdx = i
            return nums[i]
        end
    end
    if c < NM.pool then
        local n = NewNum(t)
        nums[c + 1] = n
        t.nIdx = c + 1
        return n
    end
    local old = nums[1]
    for j = 2, c do
        if nums[j].t0 < old.t0 then old = nums[j] end
    end
    EndNum(old)
    return old
end

-- Font, size and color from the number's style, crit and side.
local function StyleNum(n, mul)
    local st = n.st
    local size = NumSize(st, mul, n.other, n.tag)
    local font = NumFont()
    if n.size ~= size or n.font ~= font then
        n.size, n.font = size, font
        if EllesmereUI.PrimeFontShadow then EllesmereUI.PrimeFontShadow(n.fs, false) end
        n.fs:SetFont(font, size, NumFlags())
        n.ic = math.floor(size * 0.85 + 0.5)
        n.icon:SetSize(n.ic, n.ic)
    end
    -- An avoid word (n.label) has Outgoing Combat Text's avoid color, unless
    -- it is another player's (the Others color)
    local r, g, b
    if n.label and n.lr and not n.other then
        r, g, b = n.lr, n.lg, n.lb
    else
        r, g, b = NumColor(st, n.crit, n.school, n.other, n.tag)
    end
    n.fs:SetTextColor(r, g, b)
    if n.chOn then CH.Style(n, st, size, font, r, g, b) end
end

-- The text fs centered on point h, the icon ic (side isz) beside the text
-- (anchored to it, so the text's secret width is never read); the pair is
-- centered. keep: an icon that comes after the number showed; the text
-- stays put. y: the text's height on h (a size's base line). Returns the
-- text's x on h (nil: kept).
local function PlaceIcon(h, fs, ic, isz, size, icon, keep, right, y)
    y = y or 0
    ic:ClearAllPoints()
    if not icon then
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", h, "CENTER", 0, y)
        ic:Hide()
        return 0
    end
    local gap = math.max(2, math.floor(size * 0.12 + 0.5))
    local x
    if not keep then
        local shift = (isz + gap) / 2
        x = right and -shift or shift
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", h, "CENTER", x, y)
    end
    if icon ~= NM.petIcon then
        ic:SetTexture(icon)
    else
        PetIcon(ic)
    end
    if right then
        ic:SetPoint("LEFT", fs, "RIGHT", gap, 0)
    else
        ic:SetPoint("RIGHT", fs, "LEFT", -gap, 0)
    end
    ic:SetAlpha(1)
    ic:Show()
    return x
end

-- The number's icon beside its text; by its chunk beside each size's text
-- (its own text is empty then, with no icon). Each size keeps its text's x
-- (fx) for the crit shake (ShakeSteps).
local function PlaceNumIcon(n, icon, keep)
    local right = n.st.nIconRight
    local ch = n.chOn
    PlaceIcon(n.h, n.fs, n.icon, n.ic, n.size, (not ch) and icon or nil, keep, right)
    if ch then
        local steps = n.ch.steps
        for k = 1, #steps do
            local s = steps[k]
            local x = PlaceIcon(n.h, s.fs, s.icon, s.ic, s.size, icon, keep, right, s.fy)
            if x then s.fx = x end
        end
    end
    -- The pet's portrait gives way to a real icon that comes later
    n.hasIcon = (icon and icon ~= NM.petIcon) and true or false
end

-- The crit shake by its chunk: each size's text moves d (in n.h's scale)
-- times its part of Shake Strength (CH.Part); d 0 puts them back.
local function ShakeSteps(n, d)
    local steps = n.ch.steps
    for k = 1, #steps do
        local s = steps[k]
        s.fs:SetPoint("CENTER", n.h, "CENTER", (s.fx or 0) + d * CH.Part(k), s.fy or 0)
    end
end

-- The alpha of the number's icon (of each size's by its chunk)
local function NumIconAlpha(n, a)
    n.icon:SetAlpha(a)
    if not n.chOn then return end
    local steps = n.ch.steps
    for k = 1, #steps do steps[k].icon:SetAlpha(a) end
end

-- An icon that comes after number n showed fades in beside its text.
local function LateIcon(n, icon, now)
    PlaceNumIcon(n, icon, true)
    NumIconAlpha(n, 0)
    n.iconT = now
end

-- Sets one number for `now`; false once it ended. It rises (sinks) for
-- n.dur. It holds where it stopped until n.hold (a merge's bump and shake end
-- first), then fades over n.fade: no number fades while it still moves. Pop:
-- from 0.6 to the peak over 60% of NM.pop, then back to 1; a merge bumps it
-- from full size. Alpha: in over 40% of NM.pop. The scale grows from the
-- number's point, so its offsets are divided by it.
local function StepNum(n, now)
    local el = now - n.t0
    local dur, hold = n.dur, n.hold
    if el >= hold + n.fade then
        EndNum(n)
        return false
    end
    local v = el < dur and el / dur or 1
    local peak = n.peak
    local s = 1
    local k = el / NM.pop
    if k < 0.6 then
        s = 0.6 + (peak - 0.6) * (k / 0.6)
    elseif k < 1 then
        s = peak - (peak - 1) * ((k - 0.6) / 0.4)
    end
    local bt = n.bumpT
    if bt then
        local k2 = (now - bt) / NM.pop
        if k2 < 0.4 then
            s = 1 + (peak - 1) * (k2 / 0.4)
        elseif k2 < 1 then
            s = peak - (peak - 1) * ((k2 - 0.4) / 0.6)
        else
            n.bumpT = nil
        end
    end
    -- A DoT's grouped number: its growth (DG)
    local gs = n.gs
    if gs then s = s * gs end
    local a = k * 2.5
    if a > 1 then a = 1 end
    if el > hold then a = a * (1 - (el - hold) / n.fade) end
    local e = 1 - (1 - v) * (1 - v)
    local y = n.dir * (n.by + n.dy + n.rise * e)
    if s ~= n.s then
        n.s = s
        n.h:SetScale(s)
    end
    -- Crit Shake: a side-to-side wobble that dies out over NM.shakeT. With
    -- its sizes each size's text shakes by its own part (ShakeSteps: a bigger
    -- chunk shakes more); else the whole number shakes.
    local x = n.dx
    local sk = n.shakeT
    if sk then
        local se = now - sk
        local d = 0
        if se < NM.shakeT then
            d = n.shakeA * (1 - se / NM.shakeT) * math.sin(se * NM.shakeW)
        else
            n.shakeT = nil
        end
        if n.chOn then
            ShakeSteps(n, d / s)
        else
            x = x + d
        end
    end
    -- Moved by numbers with sizes (SG): its point is the top of its chain,
    -- whose root follows its anchor
    local top, pt = n.anchor, n.apoint
    if n.sgTop then
        if n.sgA ~= top or n.sgP ~= pt then
            local r = n.sgRoot
            r:ClearAllPoints()
            r:SetPoint("CENTER", top, pt, 0, 0)
            n.sgA, n.sgP = top, pt
        end
        top, pt = n.sgTop, n.sgPt
    end
    n.h:SetPoint("CENTER", top, pt, x / s, y / s)
    n.h:SetAlpha(a)
    local it = n.iconT
    if it then
        local ia = (now - it) / NM.pop
        if ia >= 1 then
            ia = 1
            n.iconT = nil
        end
        NumIconAlpha(n, ia)
    end
    return true
end

-- Stack gaps by size (SG): with Size by Chunk a new number moves the young
-- ones by its own size, not by its largest. The amount is secret, so the
-- engine picks the size; it also adds the push: on each older number's chain
-- one hidden vertical bar per cut (SG.Link), min the cut's part of the bar's
-- max health, max a hair (tol) above it, value the amount. A bar is full (the
-- next size's extra height) only when the hit is past its cut, else empty.
-- Needs a plain max health (secret on every NPC: then Number Size's room, so a
-- big chunk may overlap its neighbor). Each size's text sits on the number's
-- base line (fy), so a small number sits close to the bar. cap: bars on one
-- number's chain; past it a push takes the largest size.
local SG = { cap = 48, tol = 1e-6 }

-- The bar's max health when plain, else nil (SG)
function SG.Max(t)
    local m = t.max
    if issecretvalue(m) then return nil end
    if type(m) ~= "number" or m <= 0 then return nil end
    return m
end

-- Number n with its sizes (Pop): each size's text on the base line (fy, on
-- its side), and for its pushes n.sgD (each size's extra height over the one
-- below it, with the pop) and n.sgM (the max health). Returns the smallest
-- size's height, or nil (the max health secret: the old room, no fy).
function SG.Steps(n, t, side)
    local steps = n.ch.steps
    local M = n.st.nChunk and SG.Max(t) or nil
    local base = steps[1].size * NM.th
    local d = n.sgD
    if not d then
        d = {}
        n.sgD = d
    end
    for k = 1, #steps do
        local th = steps[k].size * NM.th
        steps[k].fy = M and side * (th - base) / 2 or 0
        if k > 1 then d[k - 1] = M and (th - steps[k - 1].size * NM.th) * NM.popNorm or 0 end
    end
    n.sgM = M
    return M and base or nil
end

-- A hidden vertical bar of bar t's pool
function SG.Bar(t)
    local pool = t.sgPool
    local b = pool and pool[#pool]
    if b then
        pool[#pool] = nil
        return b
    end
    b = Flat(CreateFrame("StatusBar", nil, t.out))
    b:SetStatusBarTexture(WHITE)
    b:SetStatusBarColor(0, 0, 0, 0)
    b:SetOrientation("VERTICAL")
    b:SetWidth(1)
    return b
end

-- Older number m moves by new number n's extra size (SG): one bar per cut on
-- m's chain (from m's point, along its side), full only when n's hit is past
-- that cut. amt (secret) reaches only SetValue. False when m's chain is full
-- (then the largest size, in m.dy).
function SG.Link(m, t, n, amt)
    local d, M = n.sgD, n.sgM
    local bars = m.sgBars
    if not bars then
        bars = {}
        m.sgBars = bars
    end
    local c = 0
    for k = 1, #d do
        if d[k] > 0 then c = c + 1 end
    end
    if c == 0 then return true end
    if #bars + c > SG.cap then
        for k = 1, #d do m.dy = m.dy + d[k] end
        return false
    end
    local top, pt = m.sgTop, m.sgPt
    if not top then
        local r = m.sgRoot
        if not r then
            r = Flat(CreateFrame("Frame", nil, t.out))
            r:SetSize(1, 1)
            m.sgRoot = r
        end
        r:ClearAllPoints()
        r:SetPoint("CENTER", m.anchor, m.apoint, 0, 0)
        m.sgA, m.sgP = m.anchor, m.apoint
        top, pt = r, "CENTER"
    end
    local up = m.dir > 0
    local tol = M * SG.tol
    for k = 1, #d do
        if d[k] > 0 then
            local b = SG.Bar(t)
            local cut = CH.cuts[k] * M
            b:ClearAllPoints()
            b:SetReverseFill(not up)
            b:SetHeight(d[k])
            b:SetMinMaxValues(cut, cut + tol)
            b:SetValue(amt)
            b:SetPoint(up and "BOTTOM" or "TOP", top, pt, 0, 0)
            b:Show()
            bars[#bars + 1] = b
            top, pt = b:GetStatusBarTexture(), up and "TOP" or "BOTTOM"
        end
    end
    m.sgTop, m.sgPt, m.sgT = top, pt, t
    return true
end

-- Stack: the young numbers on this side of the bar move on (up, or down for
-- another player's) by the new one's height and the gap. None ends early: a
-- fast burst stacks higher. With its sizes (SG) the height is its smallest
-- size's, plus (SG.Link) its own size's extra. amt: its amount (secret) when it
-- has sizes.
local function Push(t, n, now, amt)
    local need = n.ht + n.st.nGap * t.mul
    local sg = n.sgM and HasValue(amt)
    local nums = t.nums
    for i = 1, #nums do
        local m = nums[i]
        if m ~= n and m.live and not m.group and m.side == n.side and now - m.t0 < m.hold + m.fade * NM.young then
            m.dy = m.dy + need
            if sg then SG.Link(m, t, n, amt) end
        end
    end
end

-- Merge: the youngest number on this side whose last hit is inside the merge
-- window and that still rises (has not started to fade). Never an avoid word.
local function MergeTarget(t, side, now, st, tag)
    local nums = t.nums
    if not nums then return nil end
    local best
    for i = 1, #nums do
        local m = nums[i]
        if m.live and not m.label and not m.group and m.side == side and m.tag == tag and now - m.last <= st.nMerge
           and now - m.t0 < m.dur and (not best or m.t0 > best.t0) then
            best = m
        end
    end
    return best
end

local StartDrive  -- below
local DriveHolds  -- below

-- DoT Tick Style "One Growing Number": tick h (your side) joins its DoT's
-- number on bar t, or starts one in a free slot, anchored to the fill edge
-- (it follows the health). has: h has an amount. False when every slot is
-- taken (the tick then shows on its own). The secret amount only reaches
-- BreakUpLargeNumbers and SetFormattedText: the newest tick and a count.
function DG.Pop(t, h, has, now)
    local st, key, mul = h.st, DG.Key(h), t.mul
    local m = DG.Find(t, key)
    if m then
        m.count = m.count + 1
        m.last = now
        if has then m.fs:SetFormattedText("%s x%d", BreakUpLargeNumbers(h.amount), m.count) end
        h.amount = nil
        local g = 1 + DG.step * (m.count - 1)
        m.gs = g > DG.max and DG.max or g
        -- A crit: its color; it shakes, its chunk not known
        if h.crit and not m.crit then
            m.crit = true
            StyleNum(m, mul)
        end
        if h.crit and st.nShake > 0 then m.shakeT, m.shakeA = now, st.nShake * mul * CH.shMid end
        m.bumpT = now
        local til = now - m.t0 + DG.linger
        if til > m.hold then m.hold = til end
        h.num = m
        if h.icon and st.nIcon and not m.hasIcon then LateIcon(m, h.icon, now) end
        return true
    end
    local slot = DG.Slot(t, key)
    if not slot then return false end
    local n = TakeNum(t)
    n.st, n.crit, n.other, n.side, n.school = st, h.crit, false, 1, h.school
    n.tag = "dot"
    n.label, n.lr, n.lg, n.lb = nil, nil, nil, nil
    n.h:SetFrameLevel(t.out:GetFrameLevel() + 3)
    -- One growing number keeps Number Size (no Size by Chunk)
    n.chOn = false
    CH.Set(n, t)
    StyleNum(n, mul)
    if has then
        n.fs:SetFormattedText("%s", BreakUpLargeNumbers(h.amount))
    else
        n.fs:SetText("")
    end
    h.amount = nil
    n.iconT = nil
    PlaceNumIcon(n, st.nIcon and h.icon or nil)
    local size = NumSize(st, mul, false, "dot")
    n.anchor, n.apoint = t.live, "TOPRIGHT"
    n.dx = -DG.dx * size
    n.dir = 1
    n.by = DG.Y(st, mul, size, slot)
    n.rise = 0
    if h.crit and st.nShake > 0 then
        n.shakeT, n.shakeA = now, st.nShake * mul * CH.shMid
    else
        n.shakeT = nil
    end
    n.dy = 0
    n.t0, n.last, n.count = now, now, 1
    n.dur = NM.pop
    n.hold = DG.linger
    n.fade = st.nTime * NM.fade
    n.peak = NM.popNorm
    n.ht = size * NM.th * n.peak
    n.bumpT = nil
    n.hit, n.piece = h, nil
    n.group, n.slot, n.gs = key, slot, 1
    h.num = n
    n.h:ClearAllPoints()
    n.live = true
    liveNums[n] = true
    StepNum(n, now)
    n.h:Show()
    StartDrive()
    return true
end

-- Shows hit h as a number on `anchor`: a piece's flight frame (point TOP, or
-- BOTTOM for another player's), or for a hit with no piece the live fill
-- texture (TOPRIGHT, BOTTOMRIGHT). p: the piece or nil. The secret amount
-- only reaches BreakUpLargeNumbers and SetFormattedText. Merge cannot add
-- secret amounts: the merged number shows the newest amount and a count.
-- h.label: an avoid word (see NumAvoid) instead of an amount; it never merges.
local function Pop(t, h, anchor, p, now)
    if not t.out or not anchor then
        h.amount = nil
        return
    end
    local st = h.st
    local other = PopSide(h, p)
    -- A later hit of the other side than its piece flew shows at the fill
    -- edge, so its number goes its own way from the bar, not from the piece.
    if p and p.nOther ~= nil and other ~= p.nOther and t.live then
        anchor, p = t.live, nil
    end
    local side = other and -1 or 1
    local has = HasValue(h.amount)
    -- A DoT tick on your side: its DoT's one growing number (DoT Tick Style)
    if not other and h.tag == "dot" and st.tkGroup and not h.label and DG.Pop(t, h, has, now) then return end
    if st.nOverlap == "merge" and not h.label then
        local m = MergeTarget(t, side, now, st, not other and h.tag or nil)
        if m then
            m.count = m.count + 1
            m.last = now
            if has then
                NumText(m, nil, true, h.amount, m.count)
                -- By its chunk: the newest hit's size
                if m.chOn then Guard(CH.Set, m, t, h.amount) end
            end
            h.amount = nil
            -- A crit: its color
            if h.crit and not m.crit then
                m.crit = true
                StyleNum(m, t.mul)
            end
            local til = now - m.t0 + NM.pop
            -- It shakes: with its sizes by the newest hit's chunk, else
            -- (chunk not known) at CH.shMid of Shake Strength
            if h.crit and st.nShake > 0 then
                m.shakeT, m.shakeA = now, st.nShake * t.mul * (m.chOn and 1 or CH.shMid)
                til = now - m.t0 + math.max(NM.pop, NM.shakeT)
            end
            m.bumpT = now
            if til > m.hold then m.hold = til end
            h.num = m
            -- A number without an icon takes the icon of a hit merged into it
            if h.icon and st.nIcon and not m.hasIcon then LateIcon(m, h.icon, now) end
            return
        end
    end
    local n = TakeNum(t)
    local mul = t.mul
    n.st, n.crit, n.other, n.side, n.school = st, h.crit, other, side, h.school
    n.tag = not other and h.tag or nil
    n.label, n.lr, n.lg, n.lb = h.label, h.r, h.g, h.b
    -- Damage numbers draw over avoid words (both are children of t.out)
    n.h:SetFrameLevel(t.out:GetFrameLevel() + (h.label and 1 or 3))
    -- Its sizes (CH: Size by Chunk, a crit's shake); an error turns them off
    -- for the session
    n.chOn = CH.On(st, h, t)
    if (n.chOn or n.ch) and not Guard(CH.Set, n, t, h.amount) then
        CH.off, n.chOn = true, false
        Guard(CH.Set, n, t)
    end
    StyleNum(n, mul)
    -- Size by Chunk: each size its own room when the max health is plain
    -- (SG: base, its smallest size's height), else Number Size's
    n.sgM = nil
    local base = n.chOn and SG.Steps(n, t, side) or nil
    NumText(n, h.label, has, h.amount)
    -- Its amount (secret) for its pushes (SG.Link: only SetValue)
    local amt
    if base and st.nOverlap == "stack" then amt = h.amount end
    h.amount = nil
    n.iconT = nil
    -- Your pet's hit with no icon (its swing): your pet's portrait
    PlaceNumIcon(n, st.nIcon and (h.icon or (n.tag == "pet" and NM.petIcon)) or nil)
    local th = base or n.size * NM.th
    n.anchor = anchor
    if p then
        n.apoint = other and "BOTTOM" or "TOP"
        n.dx = st.nDrift * mul * (p.nSide or 1)
    else
        n.apoint = other and "BOTTOMRIGHT" or "TOPRIGHT"
        n.dx = 0
    end
    n.dir = side
    n.by = (other and st.oOff or st.nOff) * mul + th / 2
    -- Crit Distance: a crit's number rises (or sinks) farther or shorter
    n.rise = st.nRise * mul * (h.crit and st.nCritRise or 1)
    -- Crit Shake: with its sizes each shakes by its chunk (StepNum); else
    -- (chunk not known) at CH.shMid of Shake Strength
    if h.crit and st.nShake > 0 then
        n.shakeT, n.shakeA = now, st.nShake * mul * (n.chOn and 1 or CH.shMid)
    else
        n.shakeT = nil
    end
    n.dy = 0
    n.t0, n.last, n.count = now, now, 1
    -- The rise, then the fade; a crit's pop and shake end inside the rise
    n.dur = st.nTime
    n.hold = math.max(n.dur, NM.pop, n.shakeT and NM.shakeT or 0)
    n.fade = n.dur * NM.fade
    n.peak = NM.popNorm
    n.ht = th * n.peak
    n.bumpT = nil
    n.hit, n.piece = h, p
    h.num = n
    if p then p.numList[#p.numList + 1] = n end
    if st.nOverlap == "stack" then Push(t, n, now, amt) end
    amt = nil
    n.h:ClearAllPoints()
    n.live = true
    liveNums[n] = true
    StepNum(n, now)
    n.h:Show()
    StartDrive()
end

-- A hit with no piece shows at the fill edge. One with no side yet first
-- waits in t.lone for the word (FlushWait shows it).
local function PopLone(t, h, now)
    if Holding(h, now) then
        local l = t.lone
        if not l then
            l = {}
            t.lone = l
        end
        if #l >= NM.waitMax * 2 then Pop(t, table.remove(l, 1), t.live, nil, now) end
        l[#l + 1] = h
        waitBars[t] = true
        StartDrive()
        return
    end
    Pop(t, h, t.live, nil, now)
end

-- A hit joins its piece; once the piece has arrived it shows at once.
local function Attach(t, p, h, now)
    local hs = p.hits
    if #hs >= NM.pieceHits then
        PopLone(t, h, now)
        return
    end
    hs[#hs + 1] = h
    if p.arrived then Pop(t, h, p.nFly.f, p, now) end
end

-- Outgoing Combat Text's note: the icon, and whose hit (it only changes a
-- number that has not shown yet; a late icon fades in beside the text). role
-- "late": a swing or cast event that came after the hit made it the player's.
local function ApplyNote(h, icon, role, now, tag)
    h.noted = true
    if role == "late" then role = "mine" end
    -- Your pet's hit or a DoT tick (tag): its own look
    if tag and role == "mine" then h.tag = tag end
    if role == "mine" or role == "other" then h.role = role end
    if icon and not h.icon then
        h.icon = icon
        local n = h.num
        if n and n.live and n.st.nIcon and not n.hasIcon then LateIcon(n, icon, now) end
    end
end

-- A note that came before its hit waits in t.notes; the hit takes it here.
-- A note belongs to the hit of its own frame (its time is the GetTime() of
-- the same UNIT_COMBAT event), of the same school when the note has one.
local function TakeNote(t, h)
    local notes = t.notes
    if not notes then return end
    local i = 1
    while notes[i] do
        local nt = notes[i]
        if h.t - nt.t > NM.noteWindow then
            table.remove(notes, i)
        elseif nt.t == h.t and (not nt.school or nt.school == h.school) then
            table.remove(notes, i)
            ApplyNote(h, nt.icon, nt.role, h.t, nt.tag)
            return
        else
            i = i + 1
        end
    end
end

-- A hit with no health change of its own inside CRIT_WINDOW (FlushWait,
-- TakeWaiting). A hit whose change came first, more than CRIT_WINDOW before it,
-- joins the oldest piece of the bar from before the hit that has no hit and
-- has not lifted off (it holds up to LATE.hold s after its change for one;
-- StartNumFly). Else it shows at the fill edge.
local function LateOrEdge(t, h, now)
    local q
    local ps = not h.label and t.pieces
    for j = 1, ps and #ps or 0 do
        local c = ps[j]
        if c.nOn and c.nGen == c.gen and c.hits and not c.hits[1] and not c.arrived and not arrivals[c]
            and c.nT0 <= h.t and now - c.nT0 <= LATE.hold and (not q or c.nT0 < q.nT0) then
            q = c
        end
    end
    if q then
        Attach(t, q, h, now)
        return
    end
    PopLone(t, h, now)
end

-- Hits still waiting CRIT_WINDOW after they came have no new health change:
-- a late hit's piece, or the fill edge (LateOrEdge). True while some still
-- wait.
local function FlushWait(t, now)
    local w = t.wait
    local i = 1
    while w and w[i] do
        local h = w[i]
        if now - h.t > CRIT_WINDOW then
            table.remove(w, i)
            LateOrEdge(t, h, now)
        else
            i = i + 1
        end
    end
    -- Hits with no piece that wait for the word
    local l = t.lone
    i = 1
    while l and l[i] do
        local h = l[i]
        if Holding(h, now) then
            i = i + 1
        else
            table.remove(l, i)
            Pop(t, h, t.live, nil, now)
        end
    end
    return (w and w[1] ~= nil) or (l and l[1] ~= nil) or false
end

-- A new piece takes the hits that came just before it. An avoid word has no
-- health change: it keeps waiting (a late note can still change it), then
-- shows at the fill edge (FlushWait).
local function TakeWaiting(t, p, now)
    local w = t.wait
    if not w or not w[1] then return end
    local keep = 0
    for i = 1, #w do
        local h = w[i]
        w[i] = nil
        if h.label then
            keep = keep + 1
            w[keep] = h
        elseif p.nOn and now - h.t <= CRIT_WINDOW then
            Attach(t, p, h, now)
        else
            LateOrEdge(t, h, now)
        end
    end
    if keep == 0 then waitBars[t] = nil end
end

-- Every number, waiting hit and note of one bar ends (Reset, Hide).
local function EndBarNums(t)
    local nums = t.nums
    if nums then
        for i = 1, #nums do
            if nums[i].live then EndNum(nums[i]) end
        end
    end
    local w = t.wait
    if w then
        for i = #w, 1, -1 do
            w[i].amount = nil
            w[i] = nil
        end
    end
    local l = t.lone
    if l then
        for i = #l, 1, -1 do
            l[i].amount = nil
            l[i] = nil
        end
    end
    waitBars[t] = nil
    if t.notes then wipe(t.notes) end
    if t.recent then wipe(t.recent) end
    if t.avoids then wipe(t.avoids) end
end

-- The driver: pieces that arrive, hits that waited too long, number motion.
-- Its OnUpdate runs only while something is live (StartDrive).
local drv = CreateFrame("Frame")
local driving = false

local function Arrive(p, now)
    p.arrived = true
    local t, hs = p.nT, p.hits
    for i = 1, #hs do Pop(t, hs[i], p.nFly.f, p, now) end
end

local function Drive()
    local now = GetTime()
    for p in pairs(arrivals) do
        if now >= p.nArrT then
            arrivals[p] = nil
            Arrive(p, now)
        end
    end
    for t in pairs(waitBars) do
        if not FlushWait(t, now) then waitBars[t] = nil end
    end
    DriveHolds(now)
    for n in pairs(liveNums) do StepNum(n, now) end
    if not (next(liveNums) or next(arrivals) or next(waitBars) or next(holds)) then
        drv:SetScript("OnUpdate", nil)
        driving = false
    end
end

-- A failing driver stops; what it held ends (the first error shown once).
local function Tick()
    if Guard(Drive) then return end
    for n in pairs(liveNums) do EndNum(n) end
    wipe(arrivals)
    for t in pairs(waitBars) do
        local w = t.wait or {}
        for i = #w, 1, -1 do
            w[i].amount = nil
            w[i] = nil
        end
        local l = t.lone or {}
        for i = #l, 1, -1 do
            l[i].amount = nil
            l[i] = nil
        end
    end
    wipe(waitBars)
    for p in pairs(holds) do
        if p.nFly then p.nFly.f:Hide() end
    end
    wipe(holds)
    drv:SetScript("OnUpdate", nil)
    driving = false
end

function StartDrive()
    if driving then return end
    driving = true
    drv:SetScript("OnUpdate", Tick)
end

-- The flight frame: the piece (after edge .. before edge) in front of the
-- border, its damage color texture over one in the number's color. One group
-- moves it (up or down, plus Drift), bows it sideways (out, then back), shrinks
-- it from Morph Starts and fades it on arrival; a second fades the damage
-- color.
local function NewNumFly(t, p)
    local f = Flat(CreateFrame("Frame", nil, t.out))
    f:SetPoint("TOPLEFT", p.afterTex, "TOPRIGHT")
    f:SetPoint("BOTTOMRIGHT", p.beforeTex, "BOTTOMRIGHT")
    local back = f:CreateTexture(nil, "OVERLAY", nil, 6)
    back:SetAllPoints(f)
    local tex = f:CreateTexture(nil, "OVERLAY", nil, 7)
    tex:SetAllPoints(f)
    local F = { f = f, back = back, tex = tex }
    F.g, F.move = NewGroup(f, p, f, "Translation")
    local g = F.g
    F.bowOut = g:CreateAnimation("Translation")
    F.bowOut:SetSmoothing("OUT")
    F.bowBack = g:CreateAnimation("Translation")
    F.bowBack:SetSmoothing("IN")
    F.shrink = g:CreateAnimation("Scale")
    F.shrink:SetOrigin("CENTER", 0, 0)
    F.shrink:SetScaleFrom(1, 1)
    F.shrink:SetSmoothing("IN_OUT")
    F.fade = g:CreateAnimation("Alpha")
    F.fade:SetFromAlpha(1)
    F.fade:SetToAlpha(0)
    F.fade:SetSmoothing("NONE")
    F.cg, F.color = NewGroup(tex, p, tex, "Alpha")
    F.color:SetFromAlpha(1)
    F.color:SetToAlpha(0)
    F.color:SetSmoothing("IN_OUT")
    f:Hide()
    return F
end

-- The flight's timings for a flight of fl s (ArmNum; StartNumFly after a hold
-- for a late hit, LATE.flight). The side, the end of the move and the number
-- color are set at lift-off, when the piece's first hit is known.
local function NumTimes(F, st, fl)
    local half = fl / 2
    F.bowOut:SetStartDelay(0)
    F.bowOut:SetDuration(half)
    F.bowBack:SetStartDelay(half)
    F.bowBack:SetDuration(half)
    F.move:SetStartDelay(0)
    F.move:SetDuration(fl)
    local ms = st.nMorph
    local mt = math.max(fl * (1 - ms), MIN_DUR)
    F.shrink:SetStartDelay(fl * ms)
    F.shrink:SetDuration(mt)
    F.color:SetStartDelay(fl * ms)
    F.color:SetDuration(mt)
    F.fade:SetStartDelay(fl)
end

local function ArmNum(t, p, st, now)
    local F = p.nFly
    if not F then
        F = NewNumFly(t, p)
        p.nFly = F
        p.hits, p.numList = {}, {}
    end
    local bow = st.nArc * t.mul * (random() < 0.5 and -1 or 1)
    F.bowOut:SetOffset(bow, 0)
    F.bowBack:SetOffset(-bow, 0)
    F.move:SetSmoothing("IN_OUT")
    NumTimes(F, st, st.nFlight)
    F.fade:SetDuration(NM.pop)
    F.f:Hide()
    p.nSide = random() < 0.5 and -1 or 1
    p.nT, p.nSt, p.nT0, p.nGen = t, st, now, p.gen
    p.nOther, p.arrived, p.nLate = nil, nil, nil
    p.nBehind = nil
    p.nOn = true
end

-- Lift-off order (ORDER): the oldest piece of p's bar from before p (an
-- earlier health change) that has not lifted off, while p is younger than
-- ORDER.max; else nil.
local function OlderPiece(p, now)
    if now - p.nT0 >= ORDER.max then return nil end
    local ps = p.nT.pieces
    local q
    for j = 1, ps and #ps or 0 do
        local c = ps[j]
        if c ~= p and c.nOn and c.nGen == c.gen and c.nT0 < p.nT0 and not c.arrived and not arrivals[c]
            and (not q or c.nT0 < q.nT0) then
            q = c
        end
    end
    return q
end

-- The latest landing of an older piece of p's bar still in flight, or nil
-- (ORDER: a newer piece never lands first).
local function LandAfter(p, now)
    local ps = p.nT.pieces
    local land
    for j = 1, ps and #ps or 0 do
        local c = ps[j]
        if c ~= p and arrivals[c] and c.nGen == c.gen and c.nT0 < p.nT0 and c.nArrT and c.nArrT > now
            and (not land or c.nArrT > land) then
            land = c.nArrT
        end
    end
    return land
end

-- Piece p lifts off: its wait for an older piece ends. Returns that wait in
-- s, or nil.
local function OrderDone(p, now)
    local b = p.nBehind
    if not b then return nil end
    p.nBehind = nil
    return now - b
end

-- The end of the wait: the piece lifts off. Its first hit decides the side
-- (another player's flies down) and the color it turns into. A first hit
-- with no side yet holds the piece in its place (the flight frame, still)
-- until the word or NM.hold s (DriveHolds). A piece with no hit, on a bar that
-- gets hits, holds until LATE.hold s after its change for a late hit
-- (LateOrEdge), then flies faster (LATE.flight); with none it fades where it
-- is: no number, no side, so it does not fly. A piece also holds while an older
-- piece of its bar has not lifted off (ORDER). force: the plate leaves (or a
-- hold for a late hit ended), lift off now.
local function StartNumFly(p, force)
    if not p.nOn or p.nGen ~= p.gen then return end
    local t, st, F = p.nT, p.nSt, p.nFly
    local h = p.hits[1]
    local now = GetTime()
    local hold
    if h and Undecided(h) then
        if force then
            Settle(h)
        else
            hold = Holding(h, now)
        end
    elseif not h and not force and t.hSeq and now - p.nT0 < LATE.hold then
        hold = true
        p.nLate = true
    end
    -- An older piece of the bar has not lifted off (ORDER)
    if not hold and not force then
        if OlderPiece(p, now) then
            hold = true
            if not p.nBehind then p.nBehind = now end
        end
    end
    if hold then
        if not holds[p] then
            holds[p] = true
            F.back:SetColorTexture(0, 0, 0, 0)
            F.tex:Show()
            F.f:Show()
            StartDrive()
        end
        return
    end
    holds[p] = nil
    local waited = OrderDone(p, now)
    if not h then
        p.nOther = nil
        F.move:SetOffset(0, 0)
        F.bowOut:SetOffset(0, 0)
        F.bowBack:SetOffset(0, 0)
        F.shrink:SetScaleTo(1, 1)
        F.back:SetColorTexture(0, 0, 0, 0)
        -- Its late hit did not come: a fast fade, as the newer pieces it held
        -- back lift off now
        local fl = st.nFlight
        if p.nLate then
            fl = LATE.fade
            NumTimes(F, st, fl)
            F.fade:SetDuration(fl)
        end
        F.tex:Show()
        F.f:Show()
        Run(F.g)
        Run(F.cg)
        p.nArrT = now + fl
        arrivals[p] = true
        StartDrive()
        return
    end
    local other = IsOther(h)
    p.nOther = other
    local mul = t.mul
    local tag = not other and h and h.tag or nil
    -- By its chunk the piece flies to its middle size when each size has its
    -- own room (SG, the max health plain), else to Number Size (Pop)
    local f = 1
    if st.nChunk and CH.On(st, h, t) and SG.Max(t) then
        f = (st.ncMin + st.ncMax) / 2
    end
    local th = NumSize(st, mul, other, tag) * NM.th * f
    local up = t.barH / 2 + (other and st.oOff or st.nOff) * mul + th / 2
    local dx = st.nDrift * mul * p.nSide
    -- A DoT tick (DoT Tick Style "One Growing Number"): the piece flies into
    -- its DoT's number (DG.Pop), up and left of the fill edge
    local slot = tag == "dot" and st.tkGroup and DG.Slot(t, DG.Key(h))
    if slot then
        local size = NumSize(st, mul, false, "dot")
        th = size * NM.th
        up = t.barH / 2 + DG.Y(st, mul, size, slot)
        dx = -DG.dx * size
    end
    F.move:SetOffset(dx, other and -up or up)
    local sy = th / math.max(1, t.barH)
    if sy < 0.2 then sy = 0.2 elseif sy > 4 then sy = 4 end
    F.shrink:SetScaleTo(NM.morphX, sy)
    local r, g, b = NumColor(st, h and h.crit, h and h.school, other, tag)
    F.back:SetColorTexture(r, g, b, st.alpha)
    -- It held for a late hit, or waited for an older piece: a shorter flight.
    -- It never lands before an older piece of its bar still in flight (a short
    -- flight beside a full one): then it flies longer.
    local fl = st.nFlight
    if p.nLate or (waited and waited >= ORDER.quick) then fl = fl * LATE.flight end
    local land = LandAfter(p, now)
    if land and now + fl < land then fl = land - now end
    if fl ~= st.nFlight then NumTimes(F, st, fl) end
    F.tex:Show()
    F.f:Show()
    Run(F.g)
    Run(F.cg)
    p.nArrT = now + fl
    arrivals[p] = true
    StartDrive()
end

local function StartNumFlyG(p)
    Guard(StartNumFly, p)
end

-- Held pieces lift off once their first hit has its word or waited NM.hold s.
-- A piece with no hit: once a late hit joined it, or LATE.hold s after its
-- change (then it fades where it is). And only once no older piece of its
-- bar is left in its place (ORDER): the oldest change goes first, so the
-- newer pieces it held back lift off in the same frame after it.
local function ByChange(a, b) return a.nT0 < b.nT0 end
function DriveHolds(now)
    local list = ORDER.list
    wipe(list)
    local n = 0
    for p in pairs(holds) do
        n = n + 1
        list[n] = p
    end
    if n > 1 then table.sort(list, ByChange) end
    for i = 1, n do
        local p = list[i]
        list[i] = nil
        local h = p.hits and p.hits[1]
        if not p.nOn or p.nGen ~= p.gen or not p.hits then
            holds[p] = nil
        elseif h and Holding(h, now) then
            -- its first hit waits for the word
        elseif not h and p.nLate and now - p.nT0 < LATE.hold then
            -- no hit yet: it waits for a late hit
        elseif OlderPiece(p, now) then
            if not p.nBehind then p.nBehind = now end
        else
            holds[p] = nil
            Guard(StartNumFly, p, not h)
        end
    end
end

-- belowPx: from BelowPx. twin: the fall twin draws the part below the bar
-- (Change set up t.out and t.oClip). inBelow: how far the look inside the bar
-- reaches down itself (Fall Off without a twin: under the border art).
-- Chip Off, Crumble and Number Morph also need t.out (and Crumble t.oClip).
local function ArmDamage(t, bar, p, st, now, crit, mine, belowPx, twin, inBelow)
    if not p.dIn then p.dIn = NewDamageLook(t.dClip, p, "ARTWORK", 7, 0) end
    if twin and not p.dOut then p.dOut = NewDamageLook(t.oClip, p, "OVERLAY", 6, 7) end
    local s = st.dStyle
    local left = s == "shrink" and t.live or p.afterTex
    PlaceLook(p.dIn, bar, "TOPLEFT", left, p.beforeTex, inBelow)
    if twin then PlaceLook(p.dOut, bar, "BOTTOMLEFT", left, p.beforeTex, belowPx) end
    p.crit, p.mine, p.dOutOn = crit, mine, twin
    local chain
    if s == "chip" then
        ArmFly(t, p, st)
        chain = StartFly
    elseif s == "crumble" then
        ArmCrumble(t, bar, p, st, belowPx)
        chain = StartCrumble
    elseif s == "number" then
        if Guard(ArmNum, t, p, st, now) then chain = StartNumFlyG end
    end
    PaintDamage(p, st)
    p.dT0 = now
    Motion(t, p.dIn, st, belowPx, chain)
    if twin then Motion(t, p.dOut, st, belowPx) end
end

local function ArmHeal(t, bar, p, st, now)
    EnsureHeal(t, p)
    local clip, f = p.hClip, p.hF
    clip:ClearAllPoints()
    clip:SetPoint("TOPLEFT", p.beforeTex, "TOPRIGHT")
    clip:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT")
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", p.beforeTex, "TOPRIGHT")
    f:SetPoint("BOTTOMRIGHT", st.hStyle == "slide" and t.live or p.afterTex, "BOTTOMRIGHT")
    p.hTex:SetColorTexture(st.hr, st.hg, st.hb, st.ha)
    clip:Show()
    p.hT0 = now
    if st.hStyle == "slide" then
        Timing(p.hScale, st.hWait, st.hMove, st.hEase)
        p.hG = p.hScaleG
        Run(p.hScaleG)
    else
        Timing(p.hAlpha, st.hWait, st.hMove, st.hEase)
        p.hG = p.hAlphaG
        Run(p.hAlphaG)
    end
end

local function ArmSmooth(t, bar, p, st)
    EnsureSmooth(t, p, bar)
    local clip, sb = p.sClip, p.sBar
    clip:ClearAllPoints()
    clip:SetPoint("TOPLEFT", bar, "TOPLEFT")
    clip:SetPoint("BOTTOMRIGHT", p.afterTex, "BOTTOMRIGHT")
    local live = t.live
    local file = live:GetTexture()
    if p.sFile ~= file then
        p.sFile = file
        sb:SetStatusBarTexture(file or WHITE)
        sb:GetStatusBarTexture():SetDrawLayer("ARTWORK", 7)
    end
    -- The heal color; the bar's own alpha goes straight through (it may be secret).
    sb:SetStatusBarColor(st.hr, st.hg, st.hb, st.ha)
    sb:GetStatusBarTexture():SetAlpha(live:GetAlpha())
    clip:Show()
    Run(p.sG)
end

-- Group Pieces option: a piece still in its start delay starts over, so the
-- pieces of a burst move together. Flashes are left alone.
local function Regroup(t, st, now)
    local ps = t.pieces
    for i = 1, #ps do
        local p = ps[i]
        local L = p.dIn
        if L and L.g1 and now - p.dT0 < st.dWait then
            p.dT0 = now
            RestartLook(L)
            if p.dOutOn and p.dOut.g1 then RestartLook(p.dOut) end
        end
        if p.hG and now - p.hT0 < st.hWait then
            p.hT0 = now
            p.hG:Stop()
            p.hG:Play()
        end
    end
end

-------------------------------------------------------------------------------
--  A bar that goes away (its plate was removed: the mob died or left range)
-------------------------------------------------------------------------------
-- Number Morph work in progress: a live number, a piece that waits or flies,
-- or a hit that waits for its health change.
local function NumsBusy(t)
    if t.wait and t.wait[1] then return true end
    if t.lone and t.lone[1] then return true end
    local nums = t.nums
    if nums then
        for i = 1, #nums do
            if nums[i].live then return true end
        end
    end
    local ps = t.pieces
    for i = 1, #ps do
        local p = ps[i]
        if p.nOn and p.nGen == p.gen and not p.arrived then return true end
    end
    return false
end

-- The parent of released holders: shown while the plate is hidden.
local keeper

-- Pinned states (see Pin): [state] = the game's nameplate its stand-in hangs
-- on. PIN: on while a place has Number Morph on; hooked: the plate hook is in
-- (it cannot be removed, so it does nothing while PIN.on is false); added[unit]:
-- when the game last gave that token a plate (NAME_PLATE_UNIT_ADDED).
local pins = {}
local PIN = { on = false, hooked = false, added = {} }
local PIN_AGE = 30  -- s: how old a place from an earlier health change may be

-- The bar hides with a dead mob's plate, and its numbers would go at once:
-- t.out leaves the bar for `keeper` and keeps its anchors (a hidden plate
-- keeps its place until the game gives it to another unit), so the numbers
-- finish. A piece in its wait lifts off now, so the killing blow still
-- flies; every other look stops. The bar's next Reset ends what is left.
-- Returns false when nothing is in progress (then Hide ends all at once).
local function Release(t)
    local out = t.out
    if not out or not NumsBusy(t) then return false end
    local ps = t.pieces
    for i = 1, #ps do
        local p = ps[i]
        if p.nOn and p.nGen == p.gen then
            StopLooks(p)
            if not p.arrived and not arrivals[p] then Guard(StartNumFly, p, true) end
        else
            StopPiece(p)
        end
    end
    if not keeper then keeper = CreateFrame("Frame", nil, UIParent) end
    local strata, lvl = out:GetFrameStrata(), out:GetFrameLevel()
    out:SetParent(keeper)
    out:SetFrameStrata(strata)
    out:SetFrameLevel(lvl)
    t.gone, t.oStrata = true, strata
    return true
end

-- True when one of the values is secret (then none of them is used).
local function AnySecret(...)
    for i = 1, select("#", ...) do
        if issecretvalue((select(i, ...))) then return true end
    end
    return false
end

-- A removed plate's bar has no place on screen: EUI's pool clears its plate's
-- anchors on NAME_PLATE_UNIT_REMOVED. The game's driver removes the plate
-- before any addon sees that event, and Pin runs right after it (a post-hook),
-- while EUI's anchors still hold. The bar's place, relative to the game's
-- nameplate: EUI's own anchors (the bar's centre on its plate's, the plate's
-- on the nameplate's) times the scales. No screen position is read. Returns
-- the nameplate, the offset and the size in screen units, or nil.
local function PinPlace(bar)
    local plate = bar:GetParent()
    if not plate then return nil end
    -- A restricted bar or plate cannot be measured: its numbers end now.
    if Restricted(bar) or Restricted(plate) then return nil end
    if bar:GetNumPoints() ~= 1 or plate:GetNumPoints() ~= 1 then return nil end
    local okB, p1, r1, q1, x1, y1 = pcall(bar.GetPoint, bar, 1)
    local okP, p2, nb, q2, x2, y2 = pcall(plate.GetPoint, plate, 1)
    if not (okB and okP) then return nil end
    local eb, ep = bar:GetEffectiveScale(), plate:GetEffectiveScale()
    local w, h = bar:GetWidth(), bar:GetHeight()
    if AnySecret(p1, q1, p2, q2, x1, y1, x2, y2, eb, ep, w, h) then return nil end
    if r1 ~= plate or not nb or nb ~= plate:GetParent() then return nil end
    if p1 ~= "CENTER" or q1 ~= "CENTER" or p2 ~= "CENTER" or q2 ~= "CENTER" then return nil end
    if not (x1 and y1 and x2 and y2 and eb and ep and w and h) or eb <= 0 or ep <= 0 then
        return nil
    end
    return nb, x2 * ep + x1 * eb, y2 * ep + y1 * eb, w * eb, h * eb
end

-- The pin's place from the last health change of a plate bar with numbers on,
-- while EUI's anchors surely held: EUI can let go of a plate (clear its
-- anchors) before the game removes it, and then the live place is gone.
local function NotePlace(t, bar)
    local e = HB.BARS[bar]
    if not (e and e.kind == "plate") then return end
    local nb, x, y, w, h = PinPlace(bar)
    if nb then t.pinNb, t.pinX, t.pinY, t.pinW, t.pinH, t.pinT = nb, x, y, w, h, GetTime() end
end

-- The plate is being removed (see PinPlace) while numbers show: Release, then
-- the holders hang on a stand-in frame of ours at the bar's place, anchored to
-- the game's nameplate (it keeps its place until the game gives it to another
-- unit). The flights and numbers hang on their pieces' edges, so those hidden
-- bars move to the stand-in too; a number with no piece (and a waiting hit)
-- hangs on a hidden bar of ours at the last health, not on EUI's fill. The
-- place: the live one, else the one from the last health change (NotePlace).
local function Pin(t, bar)
    if t.gone or not t.out or not NumsBusy(t) then return end
    local nb, x, y, w, h = PinPlace(bar)
    if not nb then
        if not (t.pinNb and GetTime() - t.pinT <= PIN_AGE) then return end
        nb, x, y, w, h = t.pinNb, t.pinX, t.pinY, t.pinW, t.pinH
    end
    if not Release(t) then return end
    local g = t.stand
    if not g then
        g = CreateFrame("Frame", nil, keeper)
        t.stand = g
    end
    local eg = g:GetEffectiveScale()
    g:ClearAllPoints()
    g:SetPoint("CENTER", nb, "CENTER", x / eg, y / eg)
    g:SetSize(w / eg, h / eg)
    local out = t.out
    out:ClearAllPoints()
    out:SetAllPoints(g)
    local ps = t.pieces
    for i = 1, #ps do
        local p = ps[i]
        if p.nOn and p.nGen == p.gen then
            p.after:SetParent(g)
            p.after:ClearAllPoints()
            p.after:SetAllPoints(g)
            p.before:SetParent(g)
            p.before:ClearAllPoints()
            p.before:SetAllPoints(g)
            p.pinned = true
        end
    end
    local e = t.edge
    if not e then
        e = HiddenBar(g, g)
        t.edge = e
    end
    if HasValue(t.max) then e:SetMinMaxValues(0, t.max) end
    if HasValue(t.last) then e:SetValue(t.last) end
    local et = e:GetStatusBarTexture()
    local nums = t.nums
    if nums then
        for i = 1, #nums do
            local n = nums[i]
            if n.live and n.anchor == t.live then n.anchor = et end
        end
    end
    t.live = et
    pins[t] = nb
end

-- Hide lets a plate bar go before the game removed its plate: EUI let go of
-- it first (its numbers would hide with it). Not when the game gave that token
-- a new mob in this frame (its old numbers end then).
local function PinLeft(t, bar)
    local e = HB.BARS[bar]
    if not (e and e.kind == "plate") then return end
    local unit = e.unit
    if unit and PIN.added[unit] == GetTime() then return end
    Guard(Pin, t, bar)
end

-- The pinned holders go back on the bar.
local function Unpin(t, bar)
    if not pins[t] then return end
    pins[t] = nil
    local base = t.base
    local ps = t.pieces
    for i = 1, #ps do
        local p = ps[i]
        if p.pinned then
            p.pinned = nil
            p.after:SetParent(base)
            p.after:ClearAllPoints()
            p.after:SetAllPoints(bar)
            p.before:SetParent(base)
            p.before:ClearAllPoints()
            p.before:SetAllPoints(bar)
        end
    end
    t.out:ClearAllPoints()
    t.out:SetAllPoints(bar)
    t.stand:ClearAllPoints()
end

-- t.out goes back to its bar (hidden; the next Change shows it).
local function Restore(t, bar)
    if not t.gone then return end
    t.gone = nil
    Unpin(t, bar)
    local out = t.out
    out:SetParent(bar)
    out:SetFrameStrata(t.oStrata)
    out:Hide()
    t.oLvl = nil
end

-------------------------------------------------------------------------------
--  API
-------------------------------------------------------------------------------
-- A new unit, or a new max health: forget the old health, drop every piece.
-- cur and maxHP may be secret; they are only stored. keep: the same unit
-- stays on the bar (a new max health): only the health is new, and what
-- shows now finishes.
function HTr.Reset(bar, cur, maxHP, keep)
    local t = STATE[bar]
    if not t then
        local tall = PP and PP.physicalHeight or 1080
        t = { pieces = {}, cursor = 1, mul = math.max(1, math.floor(tall / 1080 + 0.5)) }
        STATE[bar] = t
    end
    t.last, t.max, t.seeded = cur, maxHP, true
    if keep and not t.gone then return end
    t.newest, t.critT, t.mineT = nil, nil, nil
    t.pinNb, t.pinT = nil, nil
    StopAll(t)
    EndBarNums(t)
    Restore(t, bar)
end

-- Any paint that is not a real health change (a full repaint, a max change on a
-- percent bar): the next piece starts from this value. cur may be secret.
function HTr.Sync(bar, cur)
    local t = STATE[bar]
    if t and t.seeded then t.last = cur end
end

function HTr.Hide(bar)
    local t = STATE[bar]
    if not t then return end
    -- A plate bar that leaves before the game removed its plate (EUI let go of
    -- a dying mob's plate first): its numbers pin now
    if not pins[t] and not t.gone then PinLeft(t, bar) end
    if pins[t] then
        -- Pinned as the plate went: the numbers go on at the stand-in
    elseif t.gone or not Release(t) then
        StopAll(t)
        EndBarNums(t)
        Restore(t, bar)
        if t.out then t.out:Hide() end
    end
    if t.base then t.base:Hide() end
    t.seeded = false
    t.newest, t.critT, t.mineT = nil, nil, nil
end

-- The game's driver removed the plate of `unit` (a post-hook; EUI has not yet
-- cleared its plate): every plate bar of that unit pins its numbers.
local function OnPlateRemoved(_, unit)
    if not PIN.on then return end
    local set = unit and HB.byUnit[unit]
    if not set then return end
    for bar, e in pairs(set) do
        local t = e.kind == "plate" and STATE[bar]
        if t then Guard(Pin, t, bar) end
    end
end

-- The game gives a nameplate to a unit again: the numbers pinned to it end at
-- once, so they never jump to that unit.
local pinEv = CreateFrame("Frame")
pinEv:SetScript("OnEvent", function(_, _, unit)
    if unit then PIN.added[unit] = GetTime() end
    if not next(pins) then return end
    local nb = C_NamePlate.GetNamePlateForUnit(unit)
    if not nb then return end
    for t, b in pairs(pins) do
        if b == nb and NumsBusy(t) then
            StopAll(t)
            EndBarNums(t)
        end
    end
end)

-- Number Morph on somewhere: the plate hook is in (the first time; a hook
-- cannot be removed, so it does nothing while this is off) and the plate event
-- is registered.
local function PinSync(on)
    if PIN.on == on then return end
    PIN.on = on
    if on then
        if not PIN.hooked then
            PIN.hooked = true
            if NamePlateDriverFrame and NamePlateDriverFrame.OnNamePlateRemoved then
                hooksecurefunc(NamePlateDriverFrame, "OnNamePlateRemoved", OnPlateRemoved)
            end
        end
        pinEv:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    else
        pinEv:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
    end
end

-- A hit on this bar's unit that was a crit (UNIT_COMBAT, event WOUND, flagText
-- CRITICAL; the amount is secret and never read) and/or the player's own (nameplates:
-- the player's threat rose). A flag only counts while its setting is on (critOn,
-- mineOn). The event and the health paint arrive in either order: when the newest
-- piece was armed just now, it gains the flag and is repainted; otherwise the flag's
-- time is remembered and the next Change consumes it.
function HTr.Hit(bar, style, crit, mine)
    local t = STATE[bar]
    if not t or not t.seeded or not style then return end
    crit = crit and style.critOn and true or false
    mine = mine and style.mineOn and true or false
    if not (crit or mine) then return end
    local now = GetTime()
    local p = t.newest
    if p and p.dIn and p.dT0 and now - p.dT0 <= CRIT_WINDOW
        and ((crit and not p.crit) or (mine and not p.mine)) then
        p.crit = (p.crit or crit) and true or false
        p.mine = (p.mine or mine) and true or false
        PaintDamage(p, style)
        return
    end
    if crit then t.critT = now end
    if mine then t.mineT = now end
end

function HTr.Crit(bar, style)
    HTr.Hit(bar, style, true, false)
end

local function EnsureBase(t, bar)
    if t.base then return end
    local base = CreateFrame("Frame", nil, bar)
    base:SetAllPoints(bar)
    -- One base unit = one physical pixel.
    base:SetIgnoreParentScale(true)
    t.base = base
end

-- The holder of the below-the-bar twins (built on the first piece that leaves
-- the bar): the same size and scale as the base, its own frame level.
local function EnsureOut(t, bar)
    if t.out then return end
    local out = CreateFrame("Frame", nil, bar)
    out:SetAllPoints(bar)
    out:SetIgnoreParentScale(true)
    t.out = out
    t.oClip = ClipFrame(out)
end

-- The bar's width and height in base units (physical pixels).
local function MeasureBar(t, bar, base)
    local bscale = bar:GetEffectiveScale() / base:GetEffectiveScale()
    t.barPx = bar:GetWidth() * bscale
    t.barH = bar:GetHeight() * bscale
end

-- A real health change: cur is the new health. style: from MakeStyle. smooth:
-- the bar's fill eases by itself (raid frames), so the heal look is the part
-- between the live edge and the new value. overLvl: frame levels above the bar
-- for the "over the absorbs" setting (above the caller's absorb overlays, below
-- its Health Ticks marks); "under" draws at the bar's own level (SetUsingParentLevel),
-- below every absorb overlay frame (children at bar level + 1 or more) and above
-- the bar's own fill texture. Without that API, under falls back to the bar level.
-- belowLvl: frame levels above the bar for the part of a piece that leaves the
-- bar (Fall Off, Chip Off, Crumble), above the caller's border art. nil: Fall
-- Off keeps that part in the look inside the bar, under the border; Chip Off
-- and Crumble use overLvl + 1.
-- An optional 7th argument is the bar's max for this paint (may be secret, so it is
-- only counted with select, never tested), so the pieces always share the bar's scale.
function HTr.Change(bar, cur, style, smooth, overLvl, belowLvl, ...)
    local t = STATE[bar]
    if not t or not t.seeded then return end
    if select("#", ...) > 0 then t.max = (...) end
    local last = t.last
    t.last = cur
    if not style then return end
    local dmg, heal = style.dmgOn, style.healOn
    if not (dmg or heal) then return end
    local live = bar:GetStatusBarTexture()
    if not live then return end
    -- A restricted bar cannot be measured: no new piece on it. t.last is kept,
    -- so the next change on a free bar starts from this health.
    if Restricted(bar) then return end
    EnsureBase(t, bar)
    local base = t.base
    local scale = PP and PP.perfect or 1
    if t.scale ~= scale then
        base:SetScale(scale)
        t.scale = scale
    end
    local flat = (style.under and base.SetUsingParentLevel) and true or false
    if t.flat ~= flat then
        t.flat, t.lvl = flat, nil
        if base.SetUsingParentLevel then base:SetUsingParentLevel(flat) end
    end
    if not flat then
        local lvl = bar:GetFrameLevel() + (style.under and 0 or (overLvl or 2))
        if t.lvl ~= lvl then
            base:SetFrameLevel(lvl)
            t.lvl = lvl
        end
    end
    base:Show()
    t.live = live
    if not Guard(MeasureBar, t, bar, base) then return end
    local useHeal = heal and not smooth
    local useSmooth = heal and smooth
    local s = dmg and style.dStyle or nil
    local belowPx = dmg and BelowPx(t, style) or 0
    -- In front of the border art (t.out): the Fall Off twin (only with a below
    -- level; without one Fall Off stays under the border), a Chip Off flight,
    -- Crumble's chips and Number Morph's flight and numbers.
    local twin = (s == "fall" and belowPx > 0 and belowLvl) and true or false
    local useOut = twin or s == "chip" or s == "crumble" or s == "number"
    local inBelow = (s == "fall" and not twin) and belowPx or 0
    -- Shared clips: the damage look (and the smooth heal look) show right of the
    -- live edge, the heal look left of it. The twins below the bar and the
    -- chips also stay right of the live edge, so every part of a piece has the
    -- same width.
    if dmg or useSmooth then
        if not t.dClip then t.dClip = ClipFrame(base) end
        t.dClip:ClearAllPoints()
        t.dClip:SetPoint("TOPLEFT", live, "TOPRIGHT")
        t.dClip:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, -inBelow)
        t.dClip:Show()
    end
    if useOut then
        EnsureOut(t, bar)
        local out = t.out
        if t.oScale ~= scale then
            out:SetScale(scale)
            t.oScale = scale
        end
        local lvl = bar:GetFrameLevel() + (belowLvl or ((overLvl or 2) + 1))
        if t.oLvl ~= lvl then
            out:SetFrameLevel(lvl)
            t.oLvl = lvl
        end
        out:Show()
        local oc = t.oClip
        oc:ClearAllPoints()
        oc:SetPoint("TOPLEFT", live, "TOPRIGHT")
        oc:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, -belowPx)
    end
    if useHeal then
        if not t.hClip then t.hClip = ClipFrame(base) end
        t.hClip:ClearAllPoints()
        t.hClip:SetPoint("TOPLEFT", bar, "TOPLEFT")
        t.hClip:SetPoint("BOTTOMRIGHT", live, "BOTTOMRIGHT")
        t.hClip:Show()
    end
    local now = GetTime()
    if style.group then Regroup(t, style, now) end
    local p = TakePiece(t, bar)
    t.newest = p
    local crit, mine = false, false
    local ct, mt = t.critT, t.mineT
    if ct then
        t.critT = nil
        crit = (dmg and style.critOn and now - ct <= CRIT_WINDOW) and true or false
    end
    if mt then
        t.mineT = nil
        mine = (dmg and style.mineOn and now - mt <= CRIT_WINDOW) and true or false
    end
    local mx = t.max
    p.after:SetMinMaxValues(0, mx)
    p.after:SetValue(cur)
    p.before:SetMinMaxValues(0, mx)
    p.before:SetValue(last)
    if dmg then ArmDamage(t, bar, p, style, now, crit, mine, belowPx, twin, inBelow) end
    if s == "number" then
        Guard(TakeWaiting, t, p, now)
        Guard(NotePlace, t, bar)
    end
    if useHeal then
        ArmHeal(t, bar, p, style, now)
    elseif useSmooth then
        ArmSmooth(t, bar, p, style)
    end
end

-- A WOUND on this bar's unit, for Number Morph. amount may be secret (only
-- stored and formatted). school: a plain mask or 0. guess: "mine", "other" or
-- "unknown" (the threat guess; the note wins). others: another player's hit
-- may show (enemy nameplates). icon: a texture or nil. tag: "pet", "dot" or
-- nil. The event and the health paint come in either order inside
-- CRIT_WINDOW.
local function NumHit(t, st, amount, school, crit, guess, others, icon, tag)
    local now = GetTime()
    local seq = (t.hSeq or 0) + 1
    t.hSeq = seq
    local h = { t = now, seq = seq, st = st, amount = amount, school = school,
        crit = crit and true or false, guess = guess, others = others and true or false, icon = icon,
        tag = tag }
    TakeNote(t, h)
    local rec = t.recent
    if not rec then
        rec = {}
        t.recent = rec
    end
    local ri = (t.rIdx or 0) % NM.recent + 1
    t.rIdx = ri
    rec[ri] = h
    local p = t.newest
    if p and p.nOn and p.nGen == p.gen and now - p.nT0 <= CRIT_WINDOW then
        Attach(t, p, h, now)
        return
    end
    local w = t.wait
    if not w then
        w = {}
        t.wait = w
    end
    if #w >= NM.waitMax then
        w[1].amount = nil
        table.remove(w, 1)
    end
    w[#w + 1] = h
    waitBars[t] = true
    StartDrive()
end

function HTr.NumHit(bar, style, amount, school, crit, guess, others, icon, tag)
    local t = STATE[bar]
    if not t or not t.seeded or not style or not style.numOn then return end
    Guard(NumHit, t, style, amount, school, crit, guess, others, icon, tag)
end

-- The first hit (by seq) of frame `when` that the note fits: not noted yet,
-- or for a late note noted without an icon; of `school` when it is given.
local function NoteHit(rec, when, school, late)
    local best
    for i = 1, NM.recent do
        local h = rec[i]
        if h and h.t == when and (h.noted and true or false) == late and not (late and h.icon)
           and (not school or h.school == school) and (not best or h.seq < best.seq) then
            best = h
        end
    end
    return best
end

-- Outgoing Combat Text's note of its hit at time `when`, the GetTime() of the
-- same UNIT_COMBAT event, so the hit's own h.t. It pairs with the first hit of
-- that frame with no note yet (of the same school, when the note has one), else
-- it waits for that hit. Notes come out of order (a hit that waits for its
-- swing event is noted later), so a note never takes another frame's hit. Nor
-- another school's: your hit's note could go to another player's hit of the
-- same frame that came first, and the "other" note later to yours.
-- role: "mine", "other", or "late": the icon of a swing or cast event that
-- came a few frames after its hit, for the hit of that frame noted without
-- an icon. school: a plain mask, or nil.
local function NumNote(t, when, icon, role, school, tag)
    local late = role == "late"
    if type(school) ~= "number" or school <= 0 then school = nil end
    local rec = t.recent
    if rec then
        local h = NoteHit(rec, when, school, late)
        if h then
            ApplyNote(h, icon, role, GetTime(), tag)
            return
        end
    end
    -- A late icon whose hit is gone has nothing to change.
    if late then return end
    local notes = t.notes
    if not notes then
        notes = {}
        t.notes = notes
    end
    if #notes >= 4 then table.remove(notes, 1) end
    notes[#notes + 1] = { t = when, icon = icon, role = role, school = school, tag = tag }
end

function HTr.NumNote(bar, when, icon, role, school, tag)
    local t = STATE[bar]
    if not t or not t.seeded then return end
    Guard(NumNote, t, when, icon, role, school, tag)
end

-- Outgoing Combat Text's avoid word (Miss, Parry; a plain string) for its hit
-- at GetTime() `when`, in color r, g, b. It waits as a hit with no health
-- change does, then shows at the fill edge with the numbers: it stacks with
-- them and draws under them (Pop). role: "mine" or "other" (with others: an
-- enemy plate). role "late": only the icon, for the word of frame `when`
-- (from a swing or cast event after it); it also makes the word the player's.
local function NumAvoid(t, st, when, label, icon, role, others, r, g, b)
    local av = t.avoids
    if not av then
        av = {}
        t.avoids = av
    end
    if role == "late" then
        for i = 1, NM.recent do
            local h = av[i]
            if h and h.t == when and not h.icon then
                ApplyNote(h, icon, role, GetTime())
                return
            end
        end
        return
    end
    if type(label) ~= "string" then return end
    local h = { t = when, st = st, label = label, r = r, g = g, b = b, crit = false,
        guess = "mine", role = role == "other" and "other" or "mine",
        others = others and true or false, icon = icon, noted = true }
    local ai = (t.aIdx or 0) % NM.recent + 1
    t.aIdx = ai
    av[ai] = h
    local w = t.wait
    if not w then
        w = {}
        t.wait = w
    end
    if #w >= NM.waitMax then
        w[1].amount = nil
        table.remove(w, 1)
    end
    w[#w + 1] = h
    waitBars[t] = true
    StartDrive()
end

function HTr.NumAvoid(bar, style, when, label, icon, role, others, r, g, b)
    local t = STATE[bar]
    if not t or not t.seeded or not style or not style.numOn then return end
    Guard(NumAvoid, t, style, when, label, icon, role, others, r, g, b)
end

-- The player's threat on this bar's unit rose: the hits just before count as
-- the player's own (the guess; a note from Outgoing Combat Text still wins).
function HTr.NumMine(bar)
    local t = STATE[bar]
    local rec = t and t.recent
    if not rec then return end
    local now = GetTime()
    for i = 1, NM.recent do
        local h = rec[i]
        if h and h.guess == "other" and now - h.t <= CRIT_WINDOW then
            h.guess = "mine"
        end
    end
end

-------------------------------------------------------------------------------
--  The bar feature (EllesmereUI.HealthBars): which places draw, their styles,
--  and the crit, My Damage and Number Morph hit events. Nothing is registered
--  while no place has a Damage Animation or Heal Animation on.
-------------------------------------------------------------------------------
-- Frame levels above the bar: the part of a piece over the bar, and the part
-- that leaves it (Fall Off, Chip Off, Crumble), in front of the border art.
-- Plates draw by layer first (SetFlattensRenderLayers): the style art is OVERLAY
-- 5 at most and the twin OVERLAY 6; its frames sit at health + 6 and + 7, so + 8
-- also wins by level. Raid and party: health at button + 2, border at button + 8
-- / + 9, raised to + 10 / + 11 on hover, target or aggro, so health + 10.
local LVL = { enemy = 2, friendly = 2, raid = 4, party = 4 }
local BELOW = { enemy = 8, friendly = 8, raid = 10, party = 10 }

local CFG = {}                                   -- CFG[place] = { on, lvl, below, style, view }
local ST = setmetatable({}, { __mode = "k" })    -- ST[bar] = { style, unit, guid, thr, enemy, nthr, nRiseT }
local critOn, mineOn = false, false
local numOn, numEnemy = false, false             -- Number Morph somewhere / on enemy plates

local function RF()
    local reg = EllesmereUI._ModuleNS
    return type(reg) == "table" and reg.EllesmereUIRaidFrames or nil
end

-- A raid view's fill is smooth while its settings (party, extra frames or the
-- raid view) have Smooth Bars on: the heal look follows it.
function HTr.ViewSmooth(party, extra)
    local rf = RF()
    if not rf then return false end
    local s
    if party then
        s = rf._scaledPartyProxy
    elseif extra then
        s = rf._scaledExtraProxy
    else
        s = rf._scaledProfile
    end
    if not s then
        s = rf.db and rf.db.profile
    end
    return (s and s.smoothBars) and true or false
end

local function RaidSmooth(e)
    local d = e.ffd
    if not d then return false end
    return HTr.ViewSmooth(d._isParty, d._isExtra)
end

-- The player's threat on a unit; nil while it is secret or missing.
local function ReadThreat(unit)
    local _, _, _, _, v = UnitDetailedThreatSituation("player", unit)
    if v == nil or issecretvalue(v) then return nil end
    return v
end

local ev = CreateFrame("Frame")
local H = {}

local function SyncEvents()
    if critOn or mineOn or numOn then
        ev:RegisterEvent("UNIT_COMBAT")
    else
        ev:UnregisterEvent("UNIT_COMBAT")
    end
    if mineOn or numEnemy then
        ev:RegisterEvent("UNIT_THREAT_LIST_UPDATE")
    else
        ev:UnregisterEvent("UNIT_THREAT_LIST_UPDATE")
    end
    PinSync(numOn)
end

-- MakeStyle reads a place's switches and its look through one view: the look's
-- values (saved, else default) behind the place's own switches.
local function LookIndex(set)
    return function(_, key) return HTr.GetLook(set, key) end
end
local INDEX = { plates = LookIndex("plates"), frames = LookIndex("frames") }

local feature = {}

function feature.Resolve()
    critOn, mineOn = false, false
    numOn, numEnemy = false, false
    for _, def in ipairs(HB.PLACES) do
        if def.anim then
            local id = def.id
            local c = CFG[id]
            if not c then
                c = { view = {} }
                CFG[id] = c
            end
            local dmg, heal = HTr.PlaceOn(id, "dmg"), HTr.PlaceOn(id, "heal")
            c.on = (dmg or heal) and true or false
            if c.on then
                local set = HTr.SetOf(id)
                c.lvl = LVL[id] or 4
                c.below = BELOW[id]
                local view = c.view
                view.healthTrail = dmg
                view.healthTrailHeal = heal
                -- My Damage Colors works on enemy nameplates only.
                view.healthTrailMine = (def.mine and HTr.GetLook(set, "healthTrailMine") == true) or false
                if not getmetatable(view) then setmetatable(view, { __index = INDEX[set] }) end
                c.style = HTr.MakeStyle(view, c.style, DEFAULTS[set])
                if c.style.critOn then critOn = true end
                if c.style.mineOn then mineOn = true end
                if c.style.numOn then
                    numOn = true
                    if id == "enemy" then numEnemy = true end
                end
            end
        end
    end
    SyncEvents()
end

function feature.Wants(place)
    local c = CFG[place]
    return c and c.on or false
end

function feature.Apply(bar, e, force)
    local c = CFG[e.place]
    local st = ST[bar]
    if not st then
        st = {}
        ST[bar] = st
    end
    st.enemy = e.place == "enemy"
    if force or st.style ~= c.style then
        local unit = e.unit
        -- The same unit again (a new max health, a forced rescan): what shows
        -- finishes. A plate token keeps its unit until the plate is removed
        -- (Clear drops st); another token counts as the same by its GUID (a
        -- secret GUID never does).
        local g = UnitGUID(unit)
        if issecretvalue(g) then g = nil end
        local keep = st.style == c.style and st.unit == unit
            and (e.kind == "plate" or (g ~= nil and st.guid == g))
        HTr.Reset(bar, UnitHealth(unit), UnitHealthMax(unit), keep)
        st.unit, st.guid = unit, g
        st.style = c.style
        if c.style.mineOn then st.thr = ReadThreat(unit) else st.thr = nil end
        if c.style.numOn and st.enemy then st.nthr = ReadThreat(unit) else st.nthr = nil end
        st.nRiseT = nil
    end
end

function feature.Clear(bar)
    if ST[bar] then
        HTr.Hide(bar)
        ST[bar] = nil
    end
end

function feature.Health(unit, set)
    local cur, mx
    for bar, e in pairs(set) do
        local st = ST[bar]
        if st then
            if not cur then cur, mx = UnitHealth(unit), UnitHealthMax(unit) end
            local smooth = (e.kind == "raid") and RaidSmooth(e) or false
            local c = CFG[e.place]
            HTr.Change(bar, cur, st.style, smooth, c.lvl, c.below, mx)
        end
    end
end

HB.AddFeature(feature)

-- Number Morph hits. A "target" hit belongs to the target's nameplate.
-- The nameplate unit of the player's target (a hit on the target can come as
-- "target", as that plate's unit, or as both). nil: no plate of ours.
local function TargetPlateUnit()
    for u, set in pairs(HB.byUnit) do
        if next(set) and u:find("^nameplate") then
            local same = UnitIsUnit(u, "target")
            if not issecretvalue(same) and same then return u end
        end
    end
end

-- The bars of a hit's unit, and that unit ("target" becomes its plate's unit).
local function NumBars(unit)
    if unit == "target" then
        unit = TargetPlateUnit()
        if not unit then return nil end
    end
    return HB.byUnit[unit], unit
end

-- Same-frame pairs on a nameplate: a hit shows only when its token (target or
-- the plate's unit) has now sent more hits this frame than the other token. Two
-- real hits in one frame still count twice.
local FRESH = { t = -1, seen = {} }
local function Fresh(bar, isTarget)
    local now = GetTime()
    if now ~= FRESH.t then
        FRESH.t = now
        wipe(FRESH.seen)
    end
    local e = FRESH.seen[bar]
    if not e then
        e = { 0, 0 }
        FRESH.seen[bar] = e
    end
    local a, b = isTarget and 1 or 2, isTarget and 2 or 1
    e[a] = e[a] + 1
    return e[a] > e[b]
end

-- Whose hit, a guess from threat (enemy plates): the player's threat rose (now
-- or just before) is the player's hit. A secret threat is "unknown" (the game
-- makes it secret once the player has threat on the mob, as in a dungeon):
-- Number Morph then waits for Outgoing Combat Text's word, else counts it as
-- the player's. A unit with no threat for the player is another player's,
-- except an enemy player (no threat in PvP). Solo, while Outgoing Combat Text
-- sends its word, "another player's" is "unknown" too: your pet's hits never
-- raise your threat. Solo without that word, on your fight (you or your pet is
-- on its threat list) and a mob you can loot (another player did not tag it),
-- it is yours.
local function NumGuess(st, unit, now)
    local _, _, _, _, v = UnitDetailedThreatSituation("player", unit)
    if issecretvalue(v) then return "unknown" end
    if v == nil then
        local pl = UnitIsPlayer(unit)
        if not issecretvalue(pl) and pl then return "mine" end
    else
        local rose = v > (st.nthr or 0)
        st.nthr = v
        if rose or (st.nRiseT and now - st.nRiseT <= CRIT_WINDOW) then return "mine" end
    end
    if IsInGroup and IsInGroup() then return "other" end
    local oct = EllesmereUI.OutgoingCombatText
    if oct and oct.Notes and oct.Notes() then return "unknown" end
    -- No threat of yours on it: your fight only when your pet is on its list
    if v == nil then
        local ps = UnitThreatSituation("pet", unit)
        if issecretvalue(ps) or ps == nil then return "other" end
    end
    local td = UnitIsTapDenied(unit)
    if issecretvalue(td) or not td then return "mine" end
    return "other"
end

-- Each WOUND goes to the Number Morph bars of its unit. amount may be secret:
-- it is only handed to HTr.NumHit.
local function NumHits(unit, amount, school, crit)
    local isTarget = unit == "target"
    local set, u = NumBars(unit)
    if not set then return end
    if issecretvalue(school) or type(school) ~= "number" then school = 0 end
    local now = GetTime()
    for bar, e in pairs(set) do
        local st = ST[bar]
        local s = st and st.style
        if s and s.numOn and (e.kind ~= "plate" or Fresh(bar, isTarget)) then
            local guess = "mine"
            if st.enemy then guess = NumGuess(st, u, now) end
            HTr.NumHit(bar, s, amount, school, crit, guess, st.enemy, nil)
        end
    end
end

-- The amount is secret and is never read: a crit is the WOUND action with the
-- CRITICAL flag text. A hit is "mine" when the player's threat on this unit
-- rose (enemy plates only; a guess: heals add threat too). A secret or missing
-- threat value means unknown, so not mine.
function H.UNIT_COMBAT(unit, action, flagText, amount, school)
    if issecretvalue(action) or issecretvalue(flagText) then return end
    if action ~= "WOUND" then return end
    local crit = (flagText == "CRITICAL")
    if numOn then NumHits(unit, amount, school, crit) end
    if not (critOn or mineOn) then return end
    local set = HB.byUnit[unit]
    if not set then return end
    for bar in pairs(set) do
        local st = ST[bar]
        local s = st and st.style
        if s and (s.critOn or s.mineOn) then
            local mine = false
            if s.mineOn then
                local v = ReadThreat(unit)
                if v then
                    mine = v > (st.thr or 0)
                    st.thr = v
                end
            end
            if crit or mine then HTr.Hit(bar, s, crit, mine) end
        end
    end
end

-- A rise in the player's threat is the player's own action, so a hit just
-- painted (or one about to be) counts as mine; a fall is only stored.
function H.UNIT_THREAT_LIST_UPDATE(unit)
    local set = HB.byUnit[unit]
    if not set then return end
    for bar in pairs(set) do
        local st = ST[bar]
        local s = st and st.style
        if s and s.mineOn then
            local v = ReadThreat(unit)
            if v then
                local last = st.thr or 0
                st.thr = v
                if v > last then HTr.Hit(bar, s, false, true) end
            end
        end
        if s and s.numOn and st.enemy then
            local v = ReadThreat(unit)
            if v then
                local last = st.nthr or 0
                st.nthr = v
                if v > last then
                    st.nRiseT = GetTime()
                    HTr.NumMine(bar)
                end
            end
        end
    end
end

ev:SetScript("OnEvent", function(_, event, a1, a2, a3, a4, a5)
    local h = H[event]
    if h then h(a1, a2, a3, a4, a5) end
end)

-- The contract with Outgoing Combat Text (it only calls these). Wants(unit): a
-- bar of that unit draws Number Morph, so Outgoing Combat Text leaves that
-- hit's damage number (and avoid word, see Avoid) to it. Note(unit, t, icon,
-- role, school, tag): the icon it found (texture or nil) and whose hit ("mine"
-- or "other") for its hit at GetTime() t of school `school` (a plain mask; 0 or
-- nil: any); it pairs with the bar's own hit of that unit, frame and school
-- (HTr.NumNote), so in a frame with your hit and another player's the two notes
-- do not swap. "target" means the target's nameplate, so a hit that came as
-- both tokens is one hit. tag: "pet" (your pet's hit), "dot" (a DoT tick) or
-- nil. Avoid(unit, t, label, icon, role, r, g, b): its avoid word (Miss, Parry;
-- a plain string) for its hit at GetTime() t, drawn with this unit's numbers
-- so it never covers them, in color r, g, b. role "mine" or "other". role
-- "late" (label nil): only the icon, for the word of frame t, from a swing or
-- cast event that came after it.
if IS_FOREVER then
    EllesmereUI.TrailNumbers = {
        Wants = function(unit)
            if not numOn then return false end
            local set = NumBars(unit)
            if not set then return false end
            for bar in pairs(set) do
                local st = ST[bar]
                if st and st.style and st.style.numOn then return true end
            end
            return false
        end,
        Note = function(unit, t, icon, role, school, tag)
            if not numOn then return end
            local set = NumBars(unit)
            if not set then return end
            for bar in pairs(set) do
                local st = ST[bar]
                if st and st.style and st.style.numOn then HTr.NumNote(bar, t, icon, role, school, tag) end
            end
        end,
        Avoid = function(unit, t, label, icon, role, r, g, b)
            if not numOn then return end
            local set = NumBars(unit)
            if not set then return end
            for bar in pairs(set) do
                local st = ST[bar]
                local s = st and st.style
                if s and s.numOn then HTr.NumAvoid(bar, s, t, label, icon, role, st.enemy, r, g, b) end
            end
        end,
    }
end

-- True while a nameplate place (enemy or friendly) has its Damage Animation on
-- and its look's style is Number Morph. Read from the settings, so it is right
-- before the next refresh pass.
function HTr.NumberMorphActive()
    if not IS_FOREVER then return false end
    if HTr.GetLook("plates", "healthTrailStyle") ~= "number" then return false end
    return (HTr.PlaceOn("enemy", "dmg") or HTr.PlaceOn("friendly", "dmg")) and true or false
end
