if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
-- EllesmereUIQoL_OutgoingCombatText.lua
-- WoW FOREVER ONLY: outgoing combat text. Your damage pops over the nameplate
-- of the mob it hit and your heals over the group frame of the player they
-- healed, each with the icon of the swing or spell that caused it.
--
-- UNIT_COMBAT is the hit source. It names the unit, the kind of hit, its
-- flags (CRITICAL) and its school, but not who caused it, and its amount is
-- secret: the amount only reaches C formatters and FontString setters, never a
-- compare or arithmetic. A hit is yours when it lands within CLAIM_WINDOW of
-- your own swing (PLAYER_SWING) or cast (UNIT_SPELLCAST_SUCCEEDED), in either
-- order. One cast's hits in one frame and school share its icon (an AoE).
-- Solo, every hit on a mob you can loot also counts (on a mob another player
-- tagged, only explained hits do, as in a group); a hit no swing or cast
-- explains takes an icon from game data (see Icon sources), else it shows
-- without one. In a group only matched hits on your target count. When a
-- mob's nameplate goes away its numbers end with it: a nameplate cannot be
-- measured. Others' Damage shows the hits that are not yours in their own
-- style. Messages move on an OnUpdate that runs only while one is live. Off,
-- nothing is created or registered.
--
-- Where Health Animations draws a unit's damage as Number Morph, that hit goes
-- to EllesmereUI.TrailNumbers instead of a message here.
--
-- Settings: the QoL profile's unitCombatText table (sparse; Get falls back to
-- DEFAULTS), read into a cache by Refresh. Login (EllesmereUIQoL.lua), profile
-- swaps (EllesmereUI._applyOutgoingCombatText) and option changes all route
-- through Refresh. The options preview lives in
-- EllesmereUIQoL_OutgoingCombatTextPreview.lua and shares this file's pool
-- through ns.OCT_I.
-------------------------------------------------------------------------------
local _, ns = ...
local EllesmereUI = _G.EllesmereUI
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end

local POOL_SIZE    = 24    -- messages a pool starts with; a burst grows it to 8 times this
local PENDING_MAX  = 64    -- hits that wait for a claim (in a group: every mob's)
local FADE_FRAC    = 0.3   -- a message fades over this part of Duration, where it stopped
local LINE_H       = 1.15  -- a message's line height per point of font size
local LINE_GAP     = 2     -- px kept between staggered messages
local CLAIM_WINDOW = 0.4   -- s between a swing or cast and the hit it caused
local HEAL_RISE    = 0.5   -- group frames are small: heals travel half as far
local CRIT_POP     = 1.5   -- a crit starts this much larger and shrinks in
local CRIT_POP_T   = 0.12  -- s the crit pop takes
local MERGE_POP    = 1.25  -- a merged line bumps to this size
local MERGE_POP_T  = 0.15  -- s the bump takes to settle
local SLIDE_RISE   = 0.25  -- Slide climbs this part of its distance
local SWING_SPELL  = 6603  -- Auto Attack, the icon of a swing
-- s a solo number drawn without an icon waits for its swing or cast event (they
-- can come a frame after the hit). Short: a DoT tick drawn just before a cast
-- would take that cast's icon from the cast's own hit.
local LATE_WINDOW  = 0.05
local GROUND_SLACK = 0.5   -- s a running spell's last tick may land after its duration
local ICON_GAP     = 2     -- px from the anchor to the icon and to the text
local ICON_LIFT    = 0.1   -- icon bottom above the text bottom, per point of font size
-- Crit shake: a side-to-side wobble of Shake Strength px that dies out
local SHAKE_T      = 0.25  -- s
local SHAKE_SPEED  = 80    -- radians per s (about 13 wobbles a second)

local DEFAULTS = {
    enabled = false,
    size = 30, critScale = 1.5, rise = 80, duration = 1.6,
    anim = "straight",     -- straight (up) | down | fountain | bounce | slide | static
    font = "__combat",     -- __combat (CombatTextFont), __global (the QoL font) or a font key
    critFont = "Fira Sans Bold", -- __same (the Font above) or a font key
    outline = "OUTLINE",   -- NONE | OUTLINE | THICKOUTLINE
    -- px from the frame's anchor (a plate's top, a group frame's centre) to
    -- where messages start, -300 to 300 (negative: below it). Every motion
    -- starts there; Down falls Travel Distance below it.
    offset = 40,
    critShake = true, shakeAmount = 12,
    mergeWindow = 0.85,    -- s between hits that share one line
    mergePop = true,
    icons = true, merge = true, schoolColor = true,
    damage = true, heal = true, avoid = true,
    -- Others' damage: hits on mobs that no swing or cast of yours explains.
    -- The game does not say who hit, so they get one color, not a class color.
    others = true,
    othersAnim = "down",   -- __same (the Animation above) or a motion
    othersOffset = -82, othersScale = 0.75,
    othersColor = { r = 1, g = 0, b = 0.989 },
    -- An icon on another player's hit: a party member's spell cast at that mob
    -- just before it, else its school's icon
    othersIcons = true,
    -- Another player's hit takes its school's color (physical and mixed keep
    -- othersColor)
    othersSchool = false,
    -- Your pet's hits and your DoT ticks (also ground effects and totems):
    -- their own color and size, so they do not look like your big hits or
    -- another player's.
    petLook = true, petScale = 0.8, petColor = { r = 0.9, g = 0.72, b = 0.5 },
    dotLook = true, dotScale = 0.7, dotColor = { r = 0.72, g = 0.86, b = 0.4 },
    -- A DoT tick takes its school's color, not dotColor (it keeps its size)
    dotSchool = true,
    damageColor = { r = 1,    g = 1,    b = 1    },
    healColor   = { r = 0.3,  g = 1,    b = 0.42 },
    critColor   = { r = 1,    g = 0.61, b = 0.18 },
    avoidColor  = { r = 0.79, g = 0.82, b = 0.85 },
}

-- Single-school colors by school mask; physical and mixed schools use the
-- damage color.
local SCHOOL = {
    [2]  = { r = 1,   g = 0.88, b = 0.4 },  -- holy
    [4]  = { r = 1,   g = 0.5,  b = 0   },  -- fire
    [8]  = { r = 0.3, g = 1,    b = 0.3 },  -- nature
    [16] = { r = 0.5, g = 1,    b = 1   },  -- frost
    [32] = { r = 0.6, g = 0.5,  b = 1   },  -- shadow
    [64] = { r = 1,   g = 0.5,  b = 1   },  -- arcane
}

-- UNIT_COMBAT avoid kinds, each with its COMBAT_TEXT_* string
local AVOID = { "MISS", "DODGE", "PARRY", "BLOCK", "RESIST", "IMMUNE", "EVADE", "DEFLECT", "REFLECT", "ABSORB" }
local avoidLabel = {}
for i = 1, #AVOID do
    local t = AVOID[i]
    avoidLabel[t] = _G["COMBAT_TEXT_" .. t] or _G[t] or t
end

-- Unit tokens read: enemy nameplates (solo), the target (group), group members (heals).
local ENEMY_PLATE, GROUP_UNIT, PARTY_UNIT = {}, { player = true }, {}
for i = 1, 40 do
    ENEMY_PLATE["nameplate" .. i] = true
    GROUP_UNIT["raid" .. i] = true
end
for i = 1, 4 do
    GROUP_UNIT["party" .. i] = true
    PARTY_UNIT["party" .. i] = true
end

-- Curved motions: control points as fractions of the scroll distance, x
-- toward the side (sides alternate) and y up, evenly spaced in time.
-- Fountain is a quarter circle; Bounce rises and falls back to the start.
local CURVE_POINTS = 4
local CURVES = {
    fountain = { { 0.076, 0.383 }, { 0.293, 0.707 }, { 0.617, 0.924 }, { 1, 1 } },
    bounce   = { { 0.25, 0.75 }, { 0.5, 1 }, { 0.75, 0.75 }, { 1, 0 } },
}

local MERGE_FMT = { ["%s"] = "%s x%d", ["+%s"] = "+%s x%d" }

local container, ev, fallback, db
-- Message pools, each { msgs, nextIdx, xDir }: main (the game world) and the
-- options preview's. Restyle updates every pool.
local main
local pools = {}
local enabled = false
-- Settings as the message path reads them, refilled by Refresh. fontVer tells
-- a pooled string its font is stale.
local S = { fontVer = 0 }
-- What the preview file shares (ns.OCT_I); previewShown: the preview is up
local I = { S = S, DEFAULTS = DEFAULTS, avoidLabel = avoidLabel, previewShown = false,
    LINE_H = LINE_H, LINE_GAP = LINE_GAP, CRIT_POP = CRIT_POP, HEAL_RISE = HEAL_RISE,
    SWING_SPELL = SWING_SPELL }
ns.OCT_I = I

-- Claims: your last swing and your last harmful and helpful casts. n is how
-- many hits each may still take (a swing can carry a seal proc). id: the
-- cast's spell; plate: your target's plate at a targeted cast; bt, bs: the
-- time and school of the last hit it took (more hits of that frame and school
-- share it: an AoE); took: it took a hit.
local swing = { t = -1, n = 0 }
local harm  = { t = -1, n = 0 }
local help  = { t = -1, n = 0 }
-- Icon sources for hits no claim took, late swings and flights, and the
-- fight check, in one table: the file is near Lua 5.1's limit of 200
-- file-scope locals.
--   learned: spellID -> school mask of the hits its claims took
--   text:    spellID -> { schools, dur, damage } read from its description
--   recent:  ring of your damaging casts { id, icon, t }, newest by t
--   buffs:   your helpful auras whose text says they deal damage (spell IDs)
--   incomingT: time of the last hit on you (a damage shield answers it)
--   buffDur: spell ID -> the buff's duration in s (0: no end), when plain
local src = { learned = {}, text = {}, recent = {}, recentIdx = 0, buffs = {}, buffDur = {},
    buffsDirty = true, incomingT = -1, names = {}, combat = false,
    -- PET_ICON stands for your pet's portrait as an icon (src.PetIcon draws
    -- it): your pet's hit with no spell (its swing) has no icon of its own.
    PET_ICON = "pet",
    -- s between the checks of a solo hit that waits for its fight check
    POLL_STEP = 0.02 }
-- Late hits (see src.SwingQ): s a swing's own hit may come after its event,
-- swing events kept, s a flying spell may take, flights kept
src.SWING_LATE, src.SWING_MAX, src.TRAVEL_MAX, src.FLIGHT_MAX = 1.1, 4, 2, 8
src.swq, src.swi, src.flights, src.fli = {}, 0, {}, 0
-- Your fight (src.Fight): s a solo hit nothing explains waits for your or
-- your pet's threat to show; s a matched hit keeps its mob your fight while
-- the game hides the threat list; [plate] = GetTime() of that hit
src.FIGHT_WAIT, src.FIGHT_WINDOW, src.fight = 0.2, 10, {}
-- Icons On Others' Hits: party members' harmful casts at a mob with a
-- nameplate (ring, src.PartyCast), and one well-known spell per school whose
-- icon stands for that damage type (src.OtherIcon)
src.pcasts, src.pci, src.PCAST_MAX = {}, 0, 8
src.SCHOOL_SPELL = { [1] = 6603, [2] = 585, [4] = 133, [8] = 403, [16] = 116, [32] = 589, [64] = 5143 }
-- How long a group hit no claim took waits before it counts as another's
src.GROUP_WAIT = 0.11
local band, bor = bit.band, bit.bor
-- Solo numbers drawn without an icon, for a swing or cast event that comes
-- just after them (ring): { m, gen, t, school, unit }. m: a line of this
-- module; unit (m nil): a hit Number Morph draws, which gets the late icon
-- through a "late" note.
local ORPHAN_MAX = 8
local orphans = {}
for i = 1, ORPHAN_MAX do orphans[i] = {} end
local orphanIdx = 0
-- Hits that arrived before the swing or cast they belong to (ring, reused).
local pending = {}
for i = 1, PENDING_MAX do pending[i] = {} end
local pendIdx = 0
-- Flush timers. queued: a next-frame Flush waits; lateQ: a group wait runs.
-- run and late: Flush and FlushLate through Guard (set below them).
local flush = { queued = false, lateQ = false }
local iconCache = {}

local issecret = issecretvalue or function() return false end

-- Events, timers and OnUpdate scripts of this module run through Guard. The
-- game may hide Lua errors, so the first error prints one chat line instead
-- of failing in silence.
local Guard
do
    local errShown = false
    function Guard(fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok and not errShown then
            errShown = true
            EllesmereUI.Print("Outgoing Combat Text error: " .. tostring(err))
        end
    end
end
I.Guard = Guard

-- The QoL profile (the shared EllesmereUIQoLDB; no defaults are merged in:
-- Get falls back to DEFAULTS).
local function Profile()
    if not db then db = EllesmereUI.Lite.NewDB("EllesmereUIQoLDB") end
    return db.profile
end

local function Get(k)
    local t = Profile().unitCombatText
    local v = t and t[k]
    if v == nil then return DEFAULTS[k] end
    return v
end
I.Get = Get

local function Settings()
    local p = Profile()
    local t = p.unitCombatText
    if not t then t = {}; p.unitCombatText = t end
    return t
end

local function Enabled()
    return Get("enabled") == true
end

local function FontPath(key)
    if key == "__global" then return EllesmereUI.GetFontPath("extras") end
    if key ~= "__combat" then return EllesmereUI.ResolveFontName(key) end
    local f = _G.CombatTextFont
    return f and f:GetFont() or STANDARD_TEXT_FONT
end

local function ReadSettings()
    S.font = FontPath(Get("font"))
    local critKey = Get("critFont")
    S.critFont = critKey == "__same" and S.font or FontPath(critKey)
    S.offset = Get("offset")
    S.critShake, S.shakeAmount = Get("critShake"), Get("shakeAmount")
    S.mergeWindow, S.mergePop = Get("mergeWindow"), Get("mergePop")
    S.others, S.othersColor = Get("others"), Get("othersColor")
    S.othersAnim, S.othersOffset, S.othersScale = Get("othersAnim"), Get("othersOffset"), Get("othersScale")
    S.petLook, S.petScale, S.petColor = Get("petLook"), Get("petScale"), Get("petColor")
    S.dotLook, S.dotScale, S.dotColor = Get("dotLook"), Get("dotScale"), Get("dotColor")
    S.dotSchool, S.othersIcons, S.othersSchool = Get("dotSchool"), Get("othersIcons"), Get("othersSchool")
    local outline = Get("outline")
    S.flags = (outline == "OUTLINE" and EllesmereUI.SlugFlag("OUTLINE, SLUG"))
        or (outline == "THICKOUTLINE" and EllesmereUI.SlugFlag("THICKOUTLINE, SLUG")) or ""
    S.size = Get("size")
    S.critSize = S.size * Get("critScale")
    S.fontVer = S.fontVer + 1
    S.anim, S.rise, S.duration = Get("anim"), Get("rise"), Get("duration")
    S.icons, S.merge, S.schoolColor = Get("icons"), Get("merge"), Get("schoolColor")
    S.damage, S.heal, S.avoid = Get("damage"), Get("heal"), Get("avoid")
    S.damageColor, S.healColor = Get("damageColor"), Get("healColor")
    S.critColor, S.avoidColor = Get("critColor"), Get("avoidColor")
end
I.ReadSettings = ReadSettings

-------------------------------------------------------------------------------
--  Message pool and motion
-------------------------------------------------------------------------------
-- Messages move by OnUpdate, as Blizzard's own combat text does: each frame
-- sets every live message's point, scale and alpha. Engine animations
-- (Translation, Path) move the icon but not a font string that holds a secret
-- amount; moving the anchor point moves both. A pool's OnUpdate runs only
-- while one of its messages is live.

-- Point j of a curve as fractions; 0 is the start
local function CurveAt(curve, j)
    if j <= 0 then return 0, 0 end
    local p = curve[j > CURVE_POINTS and CURVE_POINTS or j]
    return p[1], p[2]
end

-- A curve's point at fraction f of the travel: a Catmull-Rom spline from the
-- start through the curve's points, evenly spaced in time
local function CurvePoint(curve, f, side, dist)
    local seg = f * CURVE_POINTS
    local i = math.floor(seg)
    if i >= CURVE_POINTS then
        local x, y = CurveAt(curve, CURVE_POINTS)
        return side * x * dist, y * dist
    end
    local t = seg - i
    local t2 = t * t
    local t3 = t2 * t
    local x0, y0 = CurveAt(curve, i - 1)
    local x1, y1 = CurveAt(curve, i)
    local x2, y2 = CurveAt(curve, i + 1)
    local x3, y3 = CurveAt(curve, i + 2)
    local x = 0.5 * (2 * x1 + (x2 - x0) * t + (2 * x0 - 5 * x1 + 4 * x2 - x3) * t2
        + (3 * x1 - x0 - 3 * x2 + x3) * t3)
    local y = 0.5 * (2 * y1 + (y2 - y0) * t + (2 * y0 - 5 * y1 + 4 * y2 - y3) * t2
        + (3 * y1 - y0 - 3 * y2 + y3) * t3)
    return side * x * dist, y * dist
end

-- The highest and lowest height each motion reaches, as shares of its
-- distance (Down falls its whole distance; curves are sampled). The options
-- preview sizes its box with them.
local TOP_FRAC = { straight = 1, down = 0, slide = SLIDE_RISE, static = 0 }
local LOW_FRAC = { straight = 0, down = -1, slide = 0, static = 0 }
for mode, curve in pairs(CURVES) do
    local top, low = 0, 0
    for i = 1, 40 do
        local _, y = CurvePoint(curve, i / 40, 1, 1)
        if y > top then top = y end
        if y < low then low = y end
    end
    TOP_FRAC[mode], LOW_FRAC[mode] = top, low
end
I.TOP_FRAC, I.LOW_FRAC = TOP_FRAC, LOW_FRAC

-- A message's move at fraction f of its time, in its parent's units
local function Motion(m, f)
    local mode, dist = m.mode, m.dist
    if mode == "straight" then return 0, dist * f end
    if mode == "down" then return 0, -dist * f end
    if mode == "slide" then return dist * f, dist * SLIDE_RISE * f end
    local curve = CURVES[mode]
    if curve then return CurvePoint(curve, f, m.lane, dist) end
    return 0, 0
end

-- How far a message has moved along its travel direction at `now`
local function Travel(m, now)
    local f = (now - m.t0) / S.duration
    if f > 1 then f = 1 end
    local _, dy = Motion(m, f)
    return m.dir * dy
end

-- Sets one message for `now`; false once it has ended. It moves for
-- Duration, then holds at the end of its path (until its crit shake and a
-- merge's bump end too) and fades over FADE_FRAC of Duration: no message
-- fades while it still moves. y0 is the stagger, taken along the travel
-- direction (dir: 1 up, -1 down) from the start point (the anchor plus Text
-- Offset). The scale grows from the message's anchor, so its offsets are
-- divided by it.
local function Step(m, now)
    local el = now - m.t0
    local dur = S.duration
    local hold = m.bumpT and m.bumpT - m.t0 + MERGE_POP_T or 0
    if m.shake and hold < SHAKE_T then hold = SHAKE_T end
    if hold < dur then hold = dur end
    local fade = dur * FADE_FRAC
    if el >= hold + fade then
        m:Hide()
        m.live = nil
        return false
    end
    local f = el < dur and el / dur or 1
    local dx, dy = Motion(m, f)
    local s = 1
    if m.crit and el < CRIT_POP_T then
        s = CRIT_POP + (1 - CRIT_POP) * el / CRIT_POP_T
    end
    if m.bumpT then
        local b = now - m.bumpT
        if b < MERGE_POP_T then s = s * (MERGE_POP + (1 - MERGE_POP) * b / MERGE_POP_T) end
    end
    if m.shake and el < SHAKE_T then
        local w = m.shake * math.sin(el * SHAKE_SPEED) * (1 - el / SHAKE_T)
        dx, dy = dx + w, dy + w * 0.4
    end
    -- A world message ignores its parent's scale (a nameplate's changes with
    -- distance), so its own scale carries the UI scale.
    local sc = m.world and UIParent:GetEffectiveScale() * s or s
    if sc ~= m.s then
        m.s = sc
        m:SetScale(sc)
    end
    m:SetPoint("BOTTOM", m.host, m.point, (m.ox + dx) / s,
        (m.oy + m.dir * m.y0 + dy) / s)
    m:SetAlpha(el <= hold and 1 or 1 - (el - hold) / fade)
    return true
end

-- Nameplates the hit path has used as hosts (see Adopt).
-- Never measure a nameplate (GetCenter, GetTop, IsVisible and the like): it is
-- a restricted region and GetCenter raises "Can't measure restricted
-- regions". Only parent and anchor to it.
local knownPlate = setmetatable({}, { __mode = "k" })

local function Drive(P)
    local now = GetTime()
    local msgs = P.msgs
    local any = false
    for i = 1, #msgs do
        local m = msgs[i]
        if m.live then
            if Step(m, now) then any = true end
        end
    end
    if not any then
        P.running = false
        P.driver:SetScript("OnUpdate", nil)
    end
end

local function Run(P)
    if P.running then return end
    P.running = true
    P.driver:SetScript("OnUpdate", P.tick)
end

-- Ends every message of pool P at once
local function ClearPool(P)
    for i = 1, #P.msgs do
        local m = P.msgs[i]
        m:Hide()
        m.live = nil
    end
    P.running = false
    P.driver:SetScript("OnUpdate", nil)
end
I.ClearPool = ClearPool

-- Messages on `parent`, moved by a driver frame that shows with it. A pool
-- starts with POOL_SIZE and grows in a burst, up to P.max (see P.take). A world
-- pool's messages can become children of a nameplate (see Adopt).
local function NewPool(parent, world)
    local P = { msgs = {}, nextIdx = 0, xDir = 1, running = false, max = POOL_SIZE * 8 }
    P.driver = CreateFrame("Frame", nil, parent)
    P.tick = function() Guard(Drive, P) end
    local msgs = P.msgs
    local function Add()
        local m = CreateFrame("Frame", nil, parent)
        m:SetSize(1, 1)
        m:Hide()
        m.s = 1
        if world and m.SetIgnoreParentScale then
            m.world = true
            m:SetIgnoreParentScale(true)
            m:SetIgnoreParentAlpha(true)
        end
        -- P.level: the preview's frame level for its messages
        if P.level then m:SetFrameLevel(P.level) end
        m.fs = m:CreateFontString(nil, "OVERLAY")
        m.icon = m:CreateTexture(nil, "OVERLAY")
        m.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        msgs[#msgs + 1] = m
        return m
    end
    for _ = 1, POOL_SIZE do Add() end
    -- A message for a new line: the next free one, else a new one (up to
    -- P.max), else the oldest. So a burst never cuts a live message short
    -- until P.max messages show at once.
    P.take = function()
        local n = #msgs
        local i = P.nextIdx
        for _ = 1, n do
            i = i % n + 1
            if not msgs[i].live then
                P.nextIdx = i
                return msgs[i]
            end
        end
        if n < P.max then
            P.nextIdx = n + 1
            return Add()
        end
        local old = msgs[1]
        for j = 2, n do
            if msgs[j].t0 < old.t0 then old = msgs[j] end
        end
        return old
    end
    pools[#pools + 1] = P
    return P
end
I.NewPool = NewPool

local function Build()
    container = CreateFrame("Frame", nil, UIParent)
    container:SetAllPoints(UIParent)
    container:SetFrameStrata("HIGH")
    -- Where a hit goes when its unit has no nameplate or group frame
    fallback = CreateFrame("Frame", nil, container)
    fallback:SetSize(1, 1)
    fallback:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    main = NewPool(container, true)
    ev = CreateFrame("Frame")
end

-- A message on a known plate is that plate's child: text only anchored to a
-- plate (from another parent) stays put when the camera turns, while the
-- plate's own children move with it. A world message keeps its own scale,
-- alpha and strata.
local function Adopt(m, host)
    if not m.world then return end
    local parent = knownPlate[host] and host or container
    if m:GetParent() ~= parent then
        m:SetParent(parent)
        m:SetFrameStrata("HIGH")
    end
end

-- Before a message of line height h starts on `host`, push that host's live
-- messages of the same motion and lane (one side of a curve) further along
-- their way until the nearest one sits clear of it. They move together, so
-- the spacing holds.
local function ClearLane(P, host, mode, lane, h)
    local now, dur = GetTime(), S.duration
    local msgs = P.msgs
    local nearD
    for i = 1, #msgs do
        local m = msgs[i]
        if m.live and m.host == host and m.mode == mode and m.lane == lane and now - m.t0 < dur then
            local d = m.y0 + Travel(m, now)
            if not nearD or d < nearD then nearD = d end
        end
    end
    if not nearD then return end
    local need = h + LINE_GAP - nearD
    if need <= 0 then return end
    for i = 1, #msgs do
        local m = msgs[i]
        if m.live and m.host == host and m.mode == mode and m.lane == lane and now - m.t0 < dur then
            m.y0 = m.y0 + need
        end
    end
end

-- Plates whose unit went away, until NAME_PLATE_UNIT_ADDED gives them a new
-- one: no new number attaches to them.
local gonePlate = {}

-- A removed nameplate (its mob died or went out of range) hides its children.
-- Its numbers leave it for the container but stay anchored to it, so they
-- finish their rise and fade where the mob was.
local function EndPlate(plate)
    gonePlate[plate] = true
    for i = 1, #main.msgs do
        local m = main.msgs[i]
        if m.live and m.host == plate and m:GetParent() ~= container then
            m:SetParent(container)
            m:SetFrameStrata("HIGH")
        end
    end
end

-- The game gives a removed plate to a mob again (NAME_PLATE_UNIT_ADDED). The
-- numbers still anchored to it end at once, so they never jump to that mob.
local function ReusePlate(plate)
    gonePlate[plate] = nil
    src.fight[plate] = nil
    for i = 1, #main.msgs do
        local m = main.msgs[i]
        if m.live and m.host == plate then
            m:Hide()
            m.live = nil
        end
    end
end

-- Both formatters are C-side and accept secret numbers
local function FormatAmount(n)
    return BreakUpLargeNumbers(n)
end

local function FindMerge(P, host, key, now)
    for i = 1, #P.msgs do
        local m = P.msgs[i]
        if m.live and m.host == host and m.key == key
           and now - m.last <= S.mergeWindow and now - m.t0 < S.duration then
            return m
        end
    end
end

-- role: "heal", "avoid", "other" (others' damage), "pet" (your pet's hit),
-- "dot" (a DoT tick), or a damage school mask. A pet's or DoT's crit keeps
-- its look's color (it is larger). school: the hit's school, for its
-- school's color: a DoT tick's (DoT School Color; physical and mixed: the
-- damage color), another player's (Others' School Color; physical and
-- mixed: the others color).
local function ColorFor(role, crit, school)
    if role == "other" then
        if S.othersSchool then return SCHOOL[school] or S.othersColor end
        return S.othersColor
    end
    if role == "pet" then return S.petColor end
    if role == "dot" then
        if S.dotSchool then return SCHOOL[school] or S.damageColor end
        return S.dotColor
    end
    if crit then return S.critColor end
    if role == "heal" then return S.healColor end
    if role == "avoid" then return S.avoidColor end
    return S.schoolColor and SCHOOL[role] or S.damageColor
end

local function SizeFor(crit, other, role)
    local size = crit and S.critSize or S.size
    if role == "pet" then
        size = size * S.petScale
    elseif role == "dot" then
        size = size * S.dotScale
    end
    return other and size * S.othersScale or size
end

-- A message's font, size and color from the current settings. Also run on
-- live messages after a settings change.
local function StyleText(m)
    local other = m.role == "other"
    local size = SizeFor(m.crit, other, m.role)
    local kind = (m.crit and 2 or 1) + (other and 2 or 0)
        + (m.role == "pet" and 4 or m.role == "dot" and 8 or 0)
    local fs = m.fs
    if m.fontVer ~= S.fontVer or m.fontKind ~= kind then
        m.fontVer, m.fontKind = S.fontVer, kind
        EllesmereUI.PrimeFontShadow(fs, false)
        fs:SetFont(m.crit and S.critFont or S.font, size, S.flags)
        m.icon:SetSize(size, size)
        if m.icon:IsShown() then
            m.icon:ClearAllPoints()
            m.icon:SetPoint("BOTTOMRIGHT", m, "BOTTOM", -ICON_GAP, size * ICON_LIFT)
        end
    end
    local c = ColorFor(m.role, m.crit, m.school)
    fs:SetTextColor(c.r, c.g, c.b)
end

-- With an icon: icon left of the anchor, text right of it, so the layout
-- never needs the width of a secret text. Without: text centred.
local function PlaceIcon(m, icon, size)
    local fs = m.fs
    fs:ClearAllPoints()
    if icon then
        if icon == src.PET_ICON then src.PetIcon(m.icon) else m.icon:SetTexture(icon) end
        m.icon:ClearAllPoints()
        m.icon:SetPoint("BOTTOMRIGHT", m, "BOTTOM", -ICON_GAP, size * ICON_LIFT)
        m.icon:Show()
        fs:SetPoint("BOTTOMLEFT", m, "BOTTOM", ICON_GAP, 0)
    else
        m.icon:Hide()
        fs:SetPoint("BOTTOM", m, "BOTTOM", 0, 0)
    end
end

-- Shows a message from pool P. value is a secret amount when label is nil,
-- else a plain label. A new line takes a free message (see P.take). Returns
-- the message and true when it is a new line (false when the hit merged into
-- a line). school: the hit's school mask (a DoT tick's color), or nil.
local function Emit(P, host, point, k, fmt, value, label, role, crit, icon, key, school)
    local now = GetTime()
    if key and S.merge then
        local m = FindMerge(P, host, key, now)
        if m then
            m.count = m.count + 1
            m.last = now
            m.fs:SetFormattedText(MERGE_FMT[fmt], FormatAmount(value), m.count)
            if S.mergePop then m.bumpT = now end
            return m, false
        end
    end
    local m = P.take()
    m.live = nil
    m.gen = (m.gen or 0) + 1
    local dist = S.rise * k
    local other = role == "other"
    local mode = S.anim
    if other and S.othersAnim ~= "__same" then mode = S.othersAnim end
    -- Curves alternate sides; each side is a lane of its own
    local lane = 0
    if CURVES[mode] then
        P.xDir = -P.xDir
        lane = P.xDir
    end
    local dir = mode == "down" and -1 or 1
    local size = SizeFor(crit, other, role)
    local h = size * LINE_H
    ClearLane(P, host, mode, lane, h)
    -- A pooled string's font changes only with the settings or between a hit
    -- and a crit.
    local fs = m.fs
    m.crit, m.role, m.school = crit, role, school
    StyleText(m)
    if label then
        fs:SetText(label)
    else
        fs:SetFormattedText(fmt, FormatAmount(value))
    end
    PlaceIcon(m, S.icons and icon or nil, size)
    local off = other and S.othersOffset or S.offset
    m.host, m.point, m.ox, m.oy, m.k, m.off = host, point, 0, off, k, off
    m.mode, m.dist, m.dir = mode, dist, dir
    m.t0, m.last, m.y0, m.h, m.lane, m.key, m.count = now, now, 0, h, lane, key, 1
    m.bumpT = nil
    m.shake = crit and S.critShake and not other and S.shakeAmount or nil
    m.live = true
    Adopt(m, host)
    m:ClearAllPoints()
    Step(m, now)
    m:Show()
    Run(P)
    return m, true
end
I.Emit = Emit

-------------------------------------------------------------------------------
--  Hits
-------------------------------------------------------------------------------
-- EUI's group frame for a unit (read from the raid frames module), else the
-- player frame for yourself.
local function GroupFrameFor(unit)
    local rns = EllesmereUI._ModuleNS and EllesmereUI._ModuleNS["EllesmereUIRaidFrames"]
    local int = rns and rawget(rns, "_internals")
    local map = int and rawget(int, "unitToButton")
    local b = map and map[unit]
    -- IsVisible can be secret (12.x): a secret answer counts as shown
    local vis = b and b:IsVisible()
    if b and (issecret(vis) or vis) then return b end
    if unit == "player" then
        local pf = _G.EllesmereUIUnitFrames_Player
        vis = pf and pf:IsVisible()
        if pf and (issecret(vis) or vis) then return pf end
    end
end

-- A spell's icon file. A miss is not kept: the spell's data may load later.
local function IconFor(spellID)
    local t = iconCache[spellID]
    if t then return t end
    t = C_Spell.GetSpellTexture(spellID)
    if t and not issecret(t) then
        iconCache[spellID] = t
        return t
    end
end
I.IconFor = IconFor

-- The game's answer to f(...) and whether the game hid it. The client throws
-- an error for some calls while their data is secret; a thrown error counts as
-- hidden, like a secret value.
function src.Ask(f, ...)
    local ok, v = pcall(f, ...)
    if ok then
        if issecret(v) then return nil, true end
        return v, false
    end
    return nil, true
end

-- Your pet's portrait on icon texture tex (square: no round mask), for your
-- pet's hit with no spell (PET_ICON). No pet out, or the game refused it:
-- the swing's icon.
function src.PetIcon(tex)
    local has = UnitExists("pet")
    local ok = not issecret(has) and has and pcall(SetPortraitTexture, tex, "pet", true)
    if not ok then tex:SetTexture(IconFor(SWING_SPELL)) end
end

-------------------------------------------------------------------------------
--  Icon sources: for a hit no swing or cast claimed. The game gives addons
--  no spell ID per hit, so these read game data only; no spell list is kept.
--  - A spell's schools: from the hits its claims took (exact), and from its
--    description: a school name next to the word for damage ("Holy damage").
--  - Running spells: your damaging casts that keep hitting after the cast
--    (ground effects, DoTs, channels). One runs while a totem slot holds it,
--    while your aura of it is on the hit unit, or for the longest "N sec"
--    its description names.
--  - Damage buffs: your buffs whose description says they deal a school's
--    damage (damage shields such as Thorns, seals, weapon imbues).
-------------------------------------------------------------------------------
local SCHOOL_BITS = { 1, 2, 4, 8, 16, 32, 64 }
local NO_TEXT = { schools = 0 }

-- A school's name in lower case ("holy"), from the game
function src.Name(mask)
    local n = src.names[mask]
    if n == nil then
        n = C_Spell.GetSchoolString and C_Spell.GetSchoolString(mask)
        if (issecret(n) or type(n) ~= "string" or n == "") and GetSchoolString then
            n = GetSchoolString(mask)
        end
        if issecret(n) or type(n) ~= "string" or n == "" then
            local g = ({ [1] = "PHYSICAL", [2] = "HOLY", [4] = "FIRE", [8] = "NATURE",
                [16] = "FROST", [32] = "SHADOW", [64] = "ARCANE" })[mask]
            n = g and _G["STRING_SCHOOL_" .. g]
        end
        n = (not issecret(n) and type(n) == "string" and n ~= "") and n:lower() or false
        src.names[mask] = n
    end
    return n
end

-- What a spell's description says: the schools it deals damage of, the
-- longest "N sec" in it, and whether it mentions damage at all. A missing or
-- not yet loaded description is not kept.
function src.Text(id)
    local t = src.text[id]
    if t then return t end
    local desc = C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(id)
    if issecret(desc) or type(desc) ~= "string" or desc == "" then return NO_TEXT end
    desc = desc:lower()
    local dmg = (type(_G.DAMAGE) == "string" and _G.DAMAGE ~= "" and _G.DAMAGE or "damage"):lower()
    local schools = 0
    for i = 1, #SCHOOL_BITS do
        local n = src.Name(SCHOOL_BITS[i])
        if n and (desc:find(n .. " " .. dmg, 1, true) or desc:find(n .. dmg, 1, true)) then
            schools = schools + SCHOOL_BITS[i]
        end
    end
    local dur
    for n in desc:gmatch("(%d+%.?%d*) sec") do
        n = tonumber(n)
        if n and (not dur or n > dur) then dur = n end
    end
    t = { schools = schools, dur = dur, damage = desc:find(dmg, 1, true) ~= nil }
    src.text[id] = t
    return t
end

function src.Schools(id)
    return bor(src.learned[id] or 0, src.Text(id).schools)
end

-- A claim of spell `id` took a hit of `school`
function src.Learn(id, school)
    if id and school > 0 then src.learned[id] = bor(src.learned[id] or 0, school) end
end

-- A damaging cast of yours: newest in the ring (one entry per spell)
function src.Cast(id, icon, now)
    local r
    for i = 1, 8 do
        local x = src.recent[i]
        if x and x.id == id then r = x end
    end
    if not r then
        src.recentIdx = src.recentIdx % 8 + 1
        r = src.recent[src.recentIdx]
        if not r then
            r = {}
            src.recent[src.recentIdx] = r
        end
    end
    r.id, r.icon, r.t = id, icon, now
end

-- Whether cast r still runs at `now` for a hit on `unit`. Its text's
-- duration counts only when the text names a damage school: "judge an
-- enemy for 10 sec" (Judgement) and "Stuns the target for 3 sec" (Hammer
-- of Justice) deal no damage over that time.
function src.Running(r, now, unit)
    local tx = src.Text(r.id)
    local dur = tx.schools ~= 0 and tx.dur
    if dur and now <= r.t + dur + GROUND_SLACK then return true end
    if GetTotemInfo then
        for slot = 1, 4 do
            local have, _, start, length, _, _, sid = GetTotemInfo(slot)
            if not (issecret(have) or issecret(sid) or issecret(start) or issecret(length))
               and have and sid == r.id and start and length and now <= start + length + GROUND_SLACK then
                return true
            end
        end
    end
    local get = unit and C_UnitAuras and C_UnitAuras.GetUnitAuraBySpellID
    if get then
        local ok, a = pcall(get, unit, r.id)
        if ok and a then
            local who = a.sourceUnit
            if issecret(who) or who == "player" or who == "pet" then return true end
        end
    end
    return false
end

-- Your newest running cast whose schools include `school`
function src.Linger(school, now, unit)
    if school == 0 then return end
    local best
    for i = 1, 8 do
        local r = src.recent[i]
        if r and r.id and (not best or r.t > best.t) and band(src.Schools(r.id), school) ~= 0
           and src.Running(r, now, unit) then
            best = r
        end
    end
    return best
end

-- Your damage buffs in aura order, and whether a description was not loaded
-- yet; nil while aura data is secret.
local GetAuraAt = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
local AurasSecret = C_Secrets and C_Secrets.ShouldAurasBeSecret
local BUFF_RETRY = 1

local function ReadBuffs()
    local list, dur, unread = {}, {}, false
    for i = 1, 40 do
        local a = GetAuraAt("player", i, "HELPFUL")
        if not a then break end
        local id = a.spellId
        if issecret(id) then return nil end
        if id then
            local t = src.Text(id)
            if t == NO_TEXT then unread = true end
            if t.damage then
                list[#list + 1] = id
                local d = a.duration
                if not issecret(d) and type(d) == "number" then dur[id] = d end
            end
        end
    end
    return list, unread, dur
end

-- Reads your damage buffs again after UNIT_AURA. While aura data is secret
-- (in some fights, maybe every fight) the last readable list stays; the game
-- refuses an addon's aura read then with "Auras cannot be accessed when
-- secret", so the read is skipped (C_Secrets) and guarded. A read from a hit
-- tries again BUFF_RETRY seconds later; out of combat (a buff changed, combat
-- ended) it reads at once, so the list is ready before a fight where auras
-- are secret.
function src.ReadNow(force)
    if not (src.buffsDirty and GetAuraAt) then return end
    if not force and GetTime() < (src.buffsRetry or 0) then return end
    local secret = AurasSecret and AurasSecret()
    local ok, list, unread, dur = false, nil, false, nil
    if not (issecret(secret) or secret) then ok, list, unread, dur = pcall(ReadBuffs) end
    if ok and list then
        src.buffs, src.buffDur = list, dur
        -- A description not loaded yet: read again next time
        src.buffsDirty = unread
    else
        src.buffsRetry = GetTime() + BUFF_RETRY
    end
end

-- Your buff that deals `school` damage: its spell ID. want "shield" (a hit on
-- the mob that hit you: Retribution Aura, Thorns) takes the one that lasts
-- longest (no end is longest), "proc" (a hit on your swing: a seal) the one
-- that lasts shortest, "spell" the first in aura order that is not a damage
-- shield, else the first in aura order. A buff with no end or longer than
-- PROC_MAX is a damage shield, never a proc.
src.PROC_MAX = 120
function src.Buff(school, want)
    if school == 0 or school == 1 then return end
    src.ReadNow()
    local b, du = src.buffs, src.buffDur
    local best, bestD
    for i = 1, #b do
        local id = b[i]
        local d0 = du[id]
        if band(src.Schools(id), school) ~= 0
           and not ((want == "proc" or want == "spell") and d0 and (d0 == 0 or d0 > src.PROC_MAX)) then
            if not want or want == "spell" then return id end
            local d = du[id]
            if d == 0 then d = math.huge end
            if not best then
                best, bestD = id, d
            elseif d and (not bestD or (want == "shield" and d > bestD) or (want == "proc" and d < bestD)) then
                best, bestD = id, d
            end
        end
    end
    return best
end

-- One tick of your running spell per mob and frame: Consecration hits a mob
-- once a tick, so a second hit of it on that mob in that frame is another
-- player's (two paladins' Consecrations often tick in the same frame).
-- Returns true for the first one and keeps it.
function src.FirstTick(r, t, mob)
    local list = src.ticks
    if not list then
        list = {}
        src.ticks, src.tickIdx = list, 0
    end
    for i = 1, #list do
        local e = list[i]
        if e.t == t and e.mob == mob and e.id == r.id then return false end
    end
    src.tickIdx = src.tickIdx % 64 + 1
    local e = list[src.tickIdx]
    if not e then
        e = {}
        list[src.tickIdx] = e
    end
    e.t, e.mob, e.id = t, mob, r.id
    return true
end

-- The icon for a hit of `school` at time t on `unit` (mob: its host frame)
-- that no claim took, and its tag: "dot" when the icon is a running spell's
-- (a DoT, ground effect or totem tick). nil: no icon, or one more tick of
-- that spell in this frame (another player's).
function src.Find(school, t, unit, mob)
    if math.abs(t - src.incomingT) <= LATE_WINDOW then
        local id = src.Buff(school, "shield")
        if id then return IconFor(id) end
    end
    local r = src.Linger(school, t, unit)
    if r then
        if not src.FirstTick(r, t, mob or unit) then return nil end
        return r.icon, "dot"
    end
    local id = src.Buff(school)
    if id then return IconFor(id) end
end

-- The icon of claim c for a hit of `school`: a non-physical hit that takes
-- your swing's claim is a proc; your buff of that school names it (a seal).
function src.ClaimIcon(c, school)
    if c == swing and school ~= 1 and school ~= 0 then
        local id = src.Buff(school, "proc")
        if id then return IconFor(id) end
    end
    return c.icon
end

-- The nameplate of the target of `who` ("pet", "party1"-"party4"). The client
-- refuses a compound unit token ("pettarget") in
-- C_NamePlate.GetNamePlateForUnit: it throws an error. So the game is asked
-- which mob it is: your target first, then each enemy nameplate. nil: no
-- target, no nameplate, or the game hid the answer (a secret value or an
-- error, src.Ask).
src.TARGET_OF = { pet = "pettarget", party1 = "party1target", party2 = "party2target",
    party3 = "party3target", party4 = "party4target" }
function src.TargetPlate(who)
    local tt = src.TARGET_OF[who]
    if not tt then return nil end
    if not src.Ask(UnitExists, tt) then return nil end
    if src.Ask(UnitIsUnit, "target", tt) then
        return C_NamePlate.GetNamePlateForUnit("target")
    end
    for token in pairs(ENEMY_PLATE) do
        if src.Ask(UnitIsUnit, token, tt) then
            return C_NamePlate.GetNamePlateForUnit(token)
        end
    end
    return nil
end

-- A party member's cast (UNIT_SPELLCAST_SUCCEEDED for party1-4, Icons On
-- Others' Hits): a harmful one at a mob with a nameplate waits for that
-- player's hit there (src.OtherIcon). The game may hide the spell (a secret
-- value): the hit then gets its school's icon.
function src.PartyCast(unit, id)
    if not S.othersIcons then return end
    if issecret(id) or not id then return end
    local harmful = C_Spell.IsSpellHarmful(id)
    if not issecret(harmful) and not harmful then return end
    local plate = src.TargetPlate(unit)
    if not plate then return end
    src.pci = src.pci % src.PCAST_MAX + 1
    local e = src.pcasts[src.pci]
    if not e then
        e = {}
        src.pcasts[src.pci] = e
    end
    e.id, e.icon, e.t, e.plate, e.open, e.ht = id, IconFor(id), GetTime(), plate, true, nil
end

-- Icons On Others' Hits: the icon of another player's hit p. A party
-- member's harmful cast at p's mob (its plate) just before it gives its
-- spell's icon: the oldest open one, cast up to TRAVEL_MAX before the hit,
-- of the hit's school when the spell's text names one (Frostbolt: frost);
-- a spell with no school in its text takes only a hit up to CLAIM_WINDOW
-- after it. One hit per cast; hits in the frame of that hit share it (AoE).
-- Else the icon of a well-known spell of p's school (src.SCHOOL_SPELL);
-- none for a mixed or hidden school.
function src.OtherIcon(p)
    local school, plate, t = p.school, p.host, p.t
    local best
    if plate then
        for i = 1, src.PCAST_MAX do
            local e = src.pcasts[i]
            if e and e.plate == plate and (e.open or e.ht == t) then
                local d = t - e.t
                local s = src.Schools(e.id)
                if d >= -LATE_WINDOW and d <= src.TRAVEL_MAX
                   and ((s ~= 0 and band(s, school) ~= 0) or (s == 0 and d <= CLAIM_WINDOW))
                   and (not best or e.t < best.t) then
                    best = e
                end
            end
        end
    end
    local icon
    if best then
        best.open, best.ht = false, t
        icon = best.icon
    end
    if not icon then
        local id = src.SCHOOL_SPELL[school]
        icon = id and IconFor(id) or nil
    end
    return icon
end

-------------------------------------------------------------------------------
--  Showing a hit
-------------------------------------------------------------------------------
-- Shows hit p (a pending slot or the shared hit table). p.school is a plain
-- number (0 when the event's school was secret); p.amount is secret. Returns
-- the message and whether it is a new line; for a hit Number Morph draws,
-- nil, nil, true (a late swing can still give its icon, see Claim). Every hit
-- shown here is yours: Number Morph gets "mine" (another player's goes by
-- ShowOther). lone: solo, nothing of yours explains it (no icon).
local function Show(p, icon, lone)
    local kind = p.kind
    -- A hit of yours or your pet's that matched: its mob is your fight for a
    -- while (src.Fight reads it when the game hides the threat list)
    if not p.heal and not lone and p.host and p.host ~= fallback then src.fight[p.host] = p.t end
    -- Your pet's hit with no icon (its swing): your pet's portrait shows as its
    -- icon. Merges keep the real icon.
    local shown = icon or (p.tag == "pet" and not p.heal and src.PET_ICON or nil)
    if p.heal then
        return Emit(main, p.host, p.point, HEAL_RISE, "+%s", p.amount, nil, "heal",
            p.flag == "CRITICAL", icon, icon or 0)
    end
    local tn = EllesmereUI.TrailNumbers
    local label = avoidLabel[kind]
    if label then
        if not S.avoid then return end
        -- Number Morph draws this unit's numbers: the word (Miss, Parry)
        -- joins them there, in their stack and under them, so it never
        -- covers one. It gets the icon and whose hit.
        if p.unit and tn and tn.Avoid and tn.Wants(p.unit) then
            local c = S.avoidColor
            tn.Avoid(p.unit, p.t, label, shown, "mine", c.r, c.g, c.b)
            return nil, nil, true
        end
        return Emit(main, p.host, p.point, 1, "%s", nil, label, "avoid", false, shown, nil)
    end
    -- Number Morph draws this hit's number: it gets the icon, the role and
    -- the school, and nothing is drawn here.
    if p.unit and tn and tn.Wants(p.unit) then
        tn.Note(p.unit, p.t, icon, "mine", p.school, p.tag)
        return nil, nil, true
    end
    -- Claims stay open for Others' Damage while My Damage is off, so your own
    -- hits are not shown as someone else's.
    if not S.damage then return end
    -- Hits merge by icon and school: a swing and its seal proc stay apart.
    -- Your pet's hits and DoT ticks can have a look of their own.
    local look = p.school
    if (p.tag == "pet" and S.petLook) or (p.tag == "dot" and S.dotLook) then look = p.tag end
    return Emit(main, p.host, p.point, 1, "%s", p.amount, nil, look,
        p.flag == "CRITICAL", shown, (icon or 0) * 128 + p.school, p.school)
end

-- A hit no swing or cast of yours explains (WOUND only), when Others' Damage
-- is on. Number Morph takes it as another player's hit. Both get its icon
-- while Icons On Others' Hits is on (src.OtherIcon).
local function ShowOther(p)
    if p.kind ~= "WOUND" then return end
    local tn = EllesmereUI.TrailNumbers
    local trail = p.unit and tn and tn.Wants(p.unit)
    if not trail and not S.others then return end
    local icon = S.othersIcons and src.OtherIcon(p) or nil
    if trail then
        tn.Note(p.unit, p.t, icon, "other", p.school)
        return
    end
    Emit(main, p.host, p.point, 1, "%s", p.amount, nil, "other", p.flag == "CRITICAL", icon,
        icon and ("o" .. p.school .. "/" .. tostring(icon)) or ("o" .. p.school), p.school)
end

-- Late hits. Your swing's own physical hit (or its miss word) shows when the
-- swing's animation lands: after its event (PLAYER_SWING), 0.42 to 1 s later,
-- by weapon and animation. So each swing event waits up to SWING_LATE for one
-- physical hit of its own (src.swq, oldest first). A spell that flies
-- (Shadow Bolt) hits up to about 1.5 s after its cast event: each damage cast
-- of yours at a target with a nameplate, and each harmful cast of your pet,
-- waits up to TRAVEL_MAX for a hit of its school on that plate (src.flights).

-- A swing event: its own hit is still to come (or came a frame or two before)
function src.SwingQ(now)
    src.swi = src.swi % src.SWING_MAX + 1
    local e = src.swq[src.swi]
    if not e then
        e = {}
        src.swq[src.swi] = e
    end
    e.t, e.open, e.ht = now, true, nil
end

-- In a group your swing's own hit lands in its windows after its event:
-- 0.38-0.62 s or 0.90-1.06 s, here with a frame of slack. Another player's
-- melee outside them is not your swing's (it took your swing's claim, and
-- your own hit then showed as another's). Solo every hit can be yours: no
-- windows.
src.SWING_WIN = { 0.36, 0.64, 0.88, 1.08 }
function src.InSwingWin(d)
    local w = src.SWING_WIN
    return (d >= w[1] and d <= w[2]) or (d >= w[3] and d <= w[4])
end

-- A physical hit or miss word at t: the oldest open swing event it can be
-- (a frame or two before it up to SWING_LATE after; in a group only in the
-- swing's windows, src.inGroup). One hit per swing; a second physical hit
-- in the frame of a swing's hit shares it (AoE). Returns the swing claim
-- (its icon), or nil.
function src.TakeSwing(t)
    local best, same
    for i = 1, src.SWING_MAX do
        local e = src.swq[i]
        if e then
            local d = t - e.t
            if d >= -LATE_WINDOW * 2 and d <= src.SWING_LATE and (not src.inGroup or src.InSwingWin(d)) then
                if e.open then
                    if not best or e.t < best.t then best = e end
                elseif e.ht == t then
                    same = e
                end
            end
        end
    end
    if best then
        best.open, best.ht = false, t
        -- The swing claim keeps the frame of the last swing hit: your AoE's
        -- hits on other mobs share it (flush.share), a proc in it is the
        -- swing's (Take). Your newest swing's hit also uses up one of its hits.
        swing.bt, swing.bs = t, 1
        if best.t == swing.t then
            swing.n = swing.n > 0 and swing.n - 1 or 0
            swing.took = true
        end
        return swing
    end
    if same then return swing end
end

-- True when a swing of yours took a physical hit in frame t (your AoE)
function src.SwungAt(t)
    for i = 1, src.SWING_MAX do
        local e = src.swq[i]
        if e and not e.open and e.ht == t then return true end
    end
    return false
end

-- A damage cast of yours (pet: your pet's) at the mob of nameplate `plate`
function src.Flight(id, icon, now, plate, pet)
    if not plate then return end
    src.fli = src.fli % src.FLIGHT_MAX + 1
    local e = src.flights[src.fli]
    if not e then
        e = {}
        src.flights[src.fli] = e
    end
    e.id, e.icon, e.t, e.plate, e.pet, e.open = id, icon, now, plate, pet and true or false, true
end

-- Your cast's claim took its hit: that cast's flight is over
function src.Landed(t)
    for i = 1, src.FLIGHT_MAX do
        local e = src.flights[i]
        if e and e.open and not e.pet and e.t == t then e.open = false end
    end
end

-- A non-physical hit at t on plate: the oldest open flight to that plate whose
-- spell deals its school (a pet spell of unknown school: any), cast up to
-- TRAVEL_MAX before it. In a group (needLine) only your pet's flights count:
-- another player's hit can look like your spell's. Returns the flight (its
-- icon, id, t, pet) or nil.
function src.TakeFlight(t, school, plate, needLine)
    if school <= 1 or not plate then return end
    local ok = not needLine
    local best
    for i = 1, src.FLIGHT_MAX do
        local e = src.flights[i]
        if e and e.open and e.plate == plate and (e.pet or ok) then
            local d = t - e.t
            local s = e.id and src.Schools(e.id) or 0
            if d >= -LATE_WINDOW and d <= src.TRAVEL_MAX and ((s == 0 and e.pet) or band(s, school) ~= 0)
               and (not best or e.t < best.t) then
                best = e
            end
        end
    end
    if not best then return end
    best.open = false
    src.Learn(best.id, school)
    -- Your current cast's hit came this way: its claim is used
    if not best.pet and best.t == harm.t and harm.n > 0 then
        harm.n = 0
        harm.bt, harm.bs, harm.took = t, school, true
    end
    return best
end

-- Your pet's cast (UNIT_SPELLCAST_SUCCEEDED for "pet"): a harmful one goes at
-- your pet's target. Its hit is yours (src.TakeFlight); it never opens or
-- uses your own claims. The game may hide the spell or whether it is harmful
-- (secret values): the flight then goes anyway, with no spell and no icon
-- when the spell is hidden (a pet spell of unknown school takes any school).
function src.PetCast(id)
    local hidden = issecret(id)
    if not hidden then
        if not id then return end
        local harmful = C_Spell.IsSpellHarmful(id)
        if not issecret(harmful) and not harmful then return end
    end
    local now = GetTime()
    local plate = src.TargetPlate("pet")
    if hidden then id = nil end
    src.Flight(id, id and IconFor(id) or nil, now, plate, true)
end

-- True only when the game says this mob is your pet's target; solo, for a
-- hit nothing of yours explains (Flush): your pet's look. Not when the game
-- hides it (a secret value), your pet has no target now, your pet attacks
-- another mob, or you have no pet: the hit is still yours (the solo rule),
-- with no pet look.
function src.PetMob(unit)
    if not unit then return false end
    local has = UnitExists("pet")
    if issecret(has) or not has then
        local ui = HasPetUI and HasPetUI()
        if issecret(ui) or not ui then return false end
    end
    if src.Ask(UnitIsUnit, unit, "pettarget") then return true end
    -- A plate shows one mob: when your pet's target has the hit's plate, it
    -- is that mob (src.TargetPlate: no compound token).
    local pp = src.TargetPlate("pet")
    return pp ~= nil and pp == C_NamePlate.GetNamePlateForUnit(unit)
end

-- Solo: is the mob of a hit (unit, its plate host, the hit's time t) your
-- fight? Yes when you or your pet is on its threat list (the game's own
-- answer; the tag is not, the game can share a mob's tag). When the game
-- hides that list, or the mob is dead or gone (its list is empty then): yes
-- when a hit of yours or your pet's matched on its plate in the last
-- src.FIGHT_WINDOW s (src.fight, Show), or (not gone) it is your target
-- while you are in combat: your pet's first hits come before yours. Each
-- game call goes through src.Ask: the client can throw an error instead of
-- a secret value.
function src.Fight(unit, host, t)
    local unsure = false
    local ex, exHid = false, false
    if unit then ex, exHid = src.Ask(UnitExists, unit) end
    local gone = not unit or (not exHid and not ex)
    if gone then
        unsure = true
    else
        local s, sHid = src.Ask(UnitThreatSituation, "player", unit)
        if sHid then
            unsure = true
        elseif s ~= nil then
            return true
        end
        local ps, psHid = src.Ask(UnitThreatSituation, "pet", unit)
        if psHid then
            unsure = true
        elseif ps ~= nil then
            return true
        end
        if not unsure then
            local dead, deadHid = src.Ask(UnitIsDead, unit)
            if not (deadHid or dead) then return false end
        end
    end
    local ft = host and host ~= fallback and src.fight[host]
    if ft and t - ft <= src.FIGHT_WINDOW then return true end
    if not gone then
        local tp = C_NamePlate.GetNamePlateForUnit("target")
        if unit == "target" or (tp and host == tp) then
            if src.Ask(UnitAffectingCombat, "player") then return true end
        end
    end
    return false
end

-- Takes a hit at time t (a pending hit's is older than now) from claim c
-- while c is open. A hit of the same frame and school as the claim's last
-- one shares it without using it up: one cast's AoE hits all get its icon.
-- Returns c, or nil. A spell whose hits were seen takes only hits of those
-- schools (a Thorns hit is not your Judgement's).
local function Take(c, t, school)
    if c == swing and school == 1 then return src.TakeSwing(t) end
    local d = t - c.t
    if d > CLAIM_WINDOW or d < -CLAIM_WINDOW then return end
    -- A swing's own hit comes at most a frame or two before the swing event:
    -- an older hit is someone else's (a guard's).
    if c == swing and d < -LATE_WINDOW * 2 then return end
    if c.n > 0 then
        -- A spell takes only hits of the schools its hits had or its text
        -- names: another player's Arcane Missiles are not your Exorcism's.
        local seen = c.id and src.Schools(c.id)
        if seen and seen ~= 0 and school > 0 and band(seen, school) == 0 then return end
        -- A swing's second hit is its proc: in the frame of its first hit, or
        -- later of a school a buff of yours procs (a seal). A guard's swing or
        -- another player's spell just after your swing is not yours.
        if c == swing and c.took and t ~= c.bt and (school <= 1 or not src.Buff(school, "proc")) then
            return
        end
        -- In a group a non-physical hit is your swing's only as your proc
        -- buff's (a seal): another player's spell often lands just after
        -- your swing
        if c == swing and src.inGroup and school > 1 and not src.Buff(school, "proc") then return end
        c.n = c.n - 1
        c.bt, c.bs, c.took = t, school, true
        src.Learn(c.id, school)
        if c == harm then src.Landed(c.t) end
        return c
    end
    if c.bt == t and c.bs == school then return c end
end

-- Physical hits look to the swing first, others to the last harmful cast.
-- g: solo, your running spell of the hit's school (a ground effect, a DoT).
-- Then a hit on another mob than the one your targeted cast went at is a
-- tick, not that cast's hit, and a tick goes before a swing's proc.
local function ClaimHit(school, now, plate, g)
    if school == 1 then
        return Take(swing, now, school) or Take(harm, now, school)
    end
    if not (g and harm.plate and plate ~= harm.plate) then
        local c = Take(harm, now, school)
        if c then return c end
    end
    if g then return end
    return Take(swing, now, school)
end

-- A solo number drawn without an icon: a swing or cast event that comes
-- within LATE_WINDOW of its hit still gives it the icon (see Claim). m: this
-- module's line; or m nil and unit: a hit Number Morph draws (avoid: its
-- avoid word).
local function AddOrphan(m, t, school, unit, avoid)
    orphanIdx = orphanIdx % ORPHAN_MAX + 1
    local o = orphans[orphanIdx]
    o.m, o.gen, o.t, o.school, o.unit, o.avoid = m, m and m.gen, t, school, unit, avoid
end

local function Flush()
    flush.queued = false
    local now = GetTime()
    local again = false
    for i = 1, PENDING_MAX do
        local p = pending[i]
        if p.used then
            if p.solo and p.busy then
                -- Its decision threw an error last time (Guard reported it):
                -- drop it, so it does not block the hits after it
                p.used = false
            elseif p.solo then
                p.busy = true
                local icon
                local f = not p.heal and src.TakeFlight(p.t, p.school, p.host ~= fallback and p.host or nil)
                if f then
                    icon = f.icon
                    p.tag = f.pet and "pet" or nil
                else
                    local tag
                    icon, tag = src.Find(p.school, p.t, p.unit, p.host)
                    p.tag = icon and tag or nil
                end
                -- Solo, a hit nothing of yours explains on the mob the game
                -- says your pet attacks is your pet's (or a guardian's):
                -- yours, no icon, your pet's look
                local pet = not icon and not p.heal and src.PetMob(p.unit)
                local lone = not icon and not pet
                -- Solo, on a mob you can loot (another player did not tag
                -- it) that is your fight (src.Fight), a hit no swing, cast,
                -- running spell or damage buff of yours explains is yours
                -- (your pet's or a guardian's), here and in Number Morph,
                -- with no icon; a late swing or cast still gives it one
                -- (Claim). Not your fight: another player's (the game can
                -- share a mob's tag). Your or your pet's threat can show a
                -- moment after the hit: such a hit waits up to src.FIGHT_WAIT
                -- for it.
                local fight = true
                if lone and not p.heal then fight = src.Fight(p.unit, p.host, p.t) end
                if not fight and now - p.t < src.FIGHT_WAIT then
                    again = true
                else
                    p.used = false
                    if pet then p.tag = "pet" end
                    if not fight then
                        ShowOther(p)
                    else
                        local m, new, trail = Show(p, icon, lone)
                        if not icon then
                            if trail then
                                AddOrphan(nil, p.t, p.school, p.unit, avoidLabel[p.kind] ~= nil)
                            elseif new and (m.key or m.role == "avoid") then
                                AddOrphan(m, p.t, p.school)
                            end
                        end
                    end
                end
                -- No error: decided, or waits for its fight check
                p.busy = nil
            elseif now - p.t > CLAIM_WINDOW then
                p.used = false
                flush.other(p)
            end
            if not p.used then p.amount = nil end
        end
    end
    if again and not flush.queued then
        flush.queued = true
        C_Timer.After(src.POLL_STEP, flush.run)
    end
end

-- A waiting hit that no claim took: your pet's flight (a group hit counts
-- only then), else another player's.
flush.other = function(p)
    if p.heal then return end
    local f = src.TakeFlight(p.t, p.school, p.host ~= fallback and p.host or nil, true)
    if f then
        p.tag = f.pet and "pet" or nil
        Show(p, f.icon)
        return
    end
    ShowOther(p)
end

-- Group hits that no claim took within GROUP_WAIT are others'. One timer at a
-- time: it comes back for the hits that are not old enough yet.
local function FlushLate()
    flush.lateQ = false
    local now = GetTime()
    local wait
    for i = 1, PENDING_MAX do
        local p = pending[i]
        if p.used and not p.solo and not p.heal then
            local age = now - p.t
            if age >= src.GROUP_WAIT then
                p.used = false
                flush.other(p)
                p.amount = nil
            elseif not wait or src.GROUP_WAIT - age < wait then
                wait = src.GROUP_WAIT - age
            end
        end
    end
    if wait then
        flush.lateQ = true
        C_Timer.After(wait + 0.005, flush.late)
    end
end

flush.run = function()
    Guard(Flush)
    -- An error stopped Flush before its end: come back for the solo hits it
    -- left (the one that threw is dropped then, p.busy)
    if not flush.queued then
        for i = 1, PENDING_MAX do
            local p = pending[i]
            if p.used and p.solo then
                flush.queued = true
                C_Timer.After(src.POLL_STEP, flush.run)
                break
            end
        end
    end
end
flush.late = function() Guard(FlushLate) end

-- share: a group hit on a mob you do not target. A claim takes it only as a
-- part of your AoE (flush.share), and never uses a claim up for it: in a raid
-- others' hits on every mob would use up your swing's and your casts' claims.
local function Pend(now, host, point, kind, flag, amount, school, heal, solo, unit, share)
    pendIdx = pendIdx % PENDING_MAX + 1
    local p = pending[pendIdx]
    -- Full: the oldest waiting group hit is decided now, not lost
    if p.used and not p.solo and not p.heal then flush.other(p) end
    p.used, p.t, p.host, p.point, p.unit = true, now, host, point, unit
    p.kind, p.flag, p.amount, p.school, p.heal, p.solo = kind, flag, amount, school, heal, solo
    p.share, p.tag, p.busy = share, nil, nil
    -- Solo hits show next frame, with the icon of any swing or cast that
    -- arrives in the meantime, else of an icon source (src.Find). In a group,
    -- an unclaimed hit is another's: for Others' Damage, and for Number Morph
    -- (else its threat guess may call a guard's hit yours).
    if solo and not flush.queued then
        flush.queued = true
        C_Timer.After(0, flush.run)
    elseif not solo and not heal and not flush.lateQ then
        local tn = EllesmereUI.TrailNumbers
        if S.others or (unit and tn and tn.Wants(unit)) then
            flush.lateQ = true
            C_Timer.After(src.GROUP_WAIT + 0.005, flush.late)
        end
    end
end

-- A claim took a hit (c.bt, c.bs): the waiting group hits on other mobs of
-- that frame and school are the rest of your AoE.
flush.share = function(c)
    local bt, bs = c.bt, c.bs
    if not bt then return end
    for i = 1, PENDING_MAX do
        local p = pending[i]
        if p.used and p.share and p.t == bt and p.school == bs then
            p.used = false
            Show(p, (src.ClaimIcon(c, bs)))
            p.amount = nil
        end
    end
end

-- A new swing or cast: open its claim, then give it the hits it caused that
-- came first: pending hits, and solo numbers already drawn without an icon.
local function Claim(c, now, n, icon, heal, id, plate)
    c.t, c.n, c.icon, c.id, c.plate = now, n, icon, id, plate
    c.bt, c.bs, c.took = nil, nil, false
    for i = 1, PENDING_MAX do
        local p = pending[i]
        if p.used and p.heal == heal and not p.share then
            if Take(c, p.t, p.school) then
                p.used = false
                Show(p, (src.ClaimIcon(c, p.school)))
                p.amount = nil
            end
        end
    end
    if heal then return end
    flush.share(c)
    -- Oldest first: a swing and its proc in one frame take their hits in order
    for k = 1, ORPHAN_MAX do
        local o = orphans[(orphanIdx + k - 1) % ORPHAN_MAX + 1]
        local m = o.m
        if m and m.live and m.gen == o.gen and m.count == 1 and now - o.t <= LATE_WINDOW
           and Take(c, o.t, o.school) then
            o.m = nil
            local ic = src.ClaimIcon(c, o.school)
            -- An avoid word never merges, so it keeps no merge key
            if m.role ~= "avoid" then m.key = (ic or 0) * 128 + o.school end
            if ic and S.icons then PlaceIcon(m, ic, SizeFor(m.crit, false, m.role)) end
        elseif not m and o.unit and now - o.t <= LATE_WINDOW and Take(c, o.t, o.school) then
            -- Number Morph drew this hit: it becomes yours, with the icon
            local unit = o.unit
            o.unit = nil
            local ic = src.ClaimIcon(c, o.school)
            local tn = EllesmereUI.TrailNumbers
            if tn and o.avoid then
                if tn.Avoid then tn.Avoid(unit, o.t, nil, ic, "late") end
            elseif tn then
                tn.Note(unit, o.t, ic, "late", o.school)
            end
        end
    end
end

local function OnCast(spellID)
    if issecret(spellID) or not spellID then return end
    local icon = IconFor(spellID)
    local now = GetTime()
    local harmful, helpful = C_Spell.IsSpellHarmful(spellID), C_Spell.IsSpellHelpful(spellID)
    if issecret(harmful) then harmful = false end
    if issecret(helpful) then helpful = false end
    -- "Harmful" means "can be cast on a hostile target", so a spell cast at
    -- no target (Consecration, Divine Storm) is not. It counts as damage when
    -- its hits were seen or its description says it deals damage.
    local damage = harmful or (not helpful and (src.learned[spellID] or src.Text(spellID).damage))
    if damage then src.Cast(spellID, icon, now) end
    if (S.damage or S.avoid or S.others) and damage then
        -- A targeted cast goes at your target: its plate tells the cast's
        -- hit from a tick on another mob (ClaimHit)
        Claim(harm, now, 1, icon, false, spellID,
            harmful and C_NamePlate.GetNamePlateForUnit("target") or nil)
        src.Flight(spellID, icon, now, harm.plate, false)
    end
    if S.heal and helpful then Claim(help, now, 1, icon, true, spellID) end
end

-- Same-frame pairs: per plate and frame, a hit shows only when its token
-- (target or nameplate) has now sent more hits of that kind, flag and school
-- than the other token. Two real hits in one frame still show twice.
local freshT, freshSeen = -1, {}
local function Fresh(plate, isTarget, kind, flag, school)
    local now = GetTime()
    if now ~= freshT then
        freshT = now
        wipe(freshSeen)
    end
    local perPlate = freshSeen[plate]
    if not perPlate then
        perPlate = {}
        freshSeen[plate] = perPlate
    end
    local key = kind .. flag .. school
    local e = perPlate[key]
    if not e then
        e = { 0, 0 }
        perPlate[key] = e
    end
    local mine, other = isTarget and 1 or 2, isTarget and 2 or 1
    e[mine] = e[mine] + 1
    return e[mine] > e[other]
end

local hit = {}
-- unit token -> its nameplate, from the hits: NAME_PLATE_UNIT_REMOVED finds
-- the plate here when the game no longer gives it
local plateOf = {}
local function OnUnitCombat(unit, kind, flag, amount, school)
    if issecret(kind) or issecret(flag) then return end
    if issecret(school) or type(school) ~= "number" then school = 0 end
    local now = GetTime()
    -- A hit on you: a damage shield's hit on the attacker comes in the same frame
    if unit == "player" and (kind == "WOUND" or kind == "BLOCK") then src.incomingT = now end
    if kind == "HEAL" then
        if not S.heal or not GROUP_UNIT[unit] then return end
        -- In a raid, party tokens repeat the raid ones
        if PARTY_UNIT[unit] and IsInRaid() then return end
        hit.host, hit.point = GroupFrameFor(unit), "CENTER"
        if not hit.host then hit.host = fallback end
        hit.kind, hit.flag, hit.amount, hit.school, hit.heal = kind, flag, amount, school, true
        local c = Take(help, now, school)
        if c then
            Show(hit, c.icon)
        else
            Pend(now, hit.host, hit.point, kind, flag, amount, school, true, false)
        end
        hit.amount = nil
        return
    end
    local avoid = avoidLabel[kind]
    if kind ~= "WOUND" and not avoid then return end
    if avoid and not S.avoid then return end
    if not avoid and not S.damage and not S.others then return end
    local solo = not IsInGroup()
    src.inGroup = not solo
    -- A hit on your target can come as "target", as its nameplate token, or
    -- as both in the same frame; both are read and a same-frame pair counts
    -- once (Fresh). Every mob counts: in a group your AoE hits mobs you do
    -- not target too.
    local isTarget = unit == "target"
    if not isTarget and not ENEMY_PLATE[unit] then return end
    if not UnitCanAttack("player", unit) then return end
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if plate and gonePlate[plate] then plate = nil end
    local onTarget = isTarget or (plate ~= nil and plate == C_NamePlate.GetNamePlateForUnit("target"))
    -- A hit on your target after its plate went away (often the killing
    -- blow) shows at the fixed spot.
    local pairKey, host, point = plate, plate, "TOP"
    if plate then
        knownPlate[plate] = true
        if ENEMY_PLATE[unit] then plateOf[unit] = plate end
    else
        host, point = fallback, "CENTER"
    end
    if pairKey and not Fresh(pairKey, isTarget, kind, flag, school) then return end
    hit.host, hit.point = host, point
    hit.kind, hit.flag, hit.amount, hit.school, hit.heal = kind, flag, amount, school, false
    hit.unit, hit.t = unit, now  -- for Number Morph (Show, ShowOther)
    hit.tag = nil  -- "pet" or "dot": your pet's hit or a DoT tick (Show)
    -- Can this hit be yours? Solo: yes. In a group, on your target: when
    -- your swing, cast or damage shield explains it; on another mob: only as
    -- a part of your AoE (below). A mob another player tagged (tap denied)
    -- is solo too, but there most hits are not yours: a hit counts as yours
    -- only when your swing, cast, running spell or damage shield explains
    -- it, as on your target in a group; an unexplained one is another's
    -- (Pend, FlushLate). The tag never decides by itself, so your hits on
    -- such a mob stay yours.
    local tapped = false
    if solo then
        local td = UnitIsTapDenied(unit)
        tapped = not issecret(td) and td and true or false
    end
    -- A damage shield's hit (Retribution Aura, Thorns) lands on the mob that
    -- hit you, in the frame you were hit. It goes before the claims, so it
    -- does not take your swing's proc or your cast's hit. Not when your swing
    -- hit in this frame: then it is more likely your seal's proc.
    if school > 1 and now - src.incomingT <= LATE_WINDOW and swing.bt ~= now then
        local id = src.Buff(school, "shield")
        if id then
            Show(hit, IconFor(id))
            hit.amount = nil
            return
        end
    end
    -- In a group, a hit on a mob you do not target is yours only when it
    -- came in the frame and school of a hit a claim of yours took (your
    -- AoE). Else it waits: a claim that takes such a hit later shares it
    -- (flush.share), and FlushLate shows it as another's.
    if not (solo or onTarget) then
        local c = (swing.bt == now and swing.bs == school and swing)
            or (school == 1 and src.SwungAt(now) and swing)
            or (harm.bt == now and harm.bs == school and harm) or nil
        if c then
            Show(hit, (src.ClaimIcon(c, school)))
        else
            Pend(now, hit.host, hit.point, kind, flag, amount, school, false, false, unit, true)
        end
        hit.amount = nil
        return
    end
    local g
    if solo then g = src.Linger(school, now, unit) end
    local c = ClaimHit(school, now, plate, g)
    local f = not c and plate and src.TakeFlight(now, school, plate, not solo)
    if c then
        Show(hit, (src.ClaimIcon(c, school)))
        if not solo then flush.share(c) end
    elseif f then
        hit.tag = f.pet and "pet" or nil
        Show(hit, f.icon)
    elseif g and src.incomingT ~= now and src.FirstTick(g, now, host) then
        -- A tick of your running spell shows now: a cast in this frame does
        -- not take it; a second hit on this mob in this frame is not it.
        hit.tag = "dot"
        Show(hit, g.icon)
    else
        -- It shows next frame, with a late claim's icon or an icon source's
        -- (Flush; a hit on you in this frame may make it a damage shield's).
        -- On a tagged mob it waits for a late claim like a group hit.
        Pend(now, hit.host, hit.point, kind, flag, amount, school, false, solo and not tapped, unit)
    end
    hit.amount = nil
end

local function OnEvent(_, event, unit, a2, a3, a4, a5)
    if event == "UNIT_COMBAT" then
        OnUnitCombat(unit, a2, a3, a4, a5)
    elseif event == "PLAYER_SWING" then
        src.SwingQ(GetTime())
        Claim(swing, GetTime(), 2, IconFor(SWING_SPELL), false)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if unit == "pet" then src.PetCast(a3) else OnCast(a3) end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local plate = C_NamePlate.GetNamePlateForUnit(unit) or plateOf[unit]
        plateOf[unit] = nil
        if plate then EndPlate(plate) end
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        local plate = C_NamePlate.GetNamePlateForUnit(unit)
        if plate then ReusePlate(plate) end
    elseif event == "UNIT_AURA" then
        -- Your buffs changed: read the damage buffs again, at once out of
        -- combat (in combat aura data can be secret), else when next needed
        src.buffsDirty = true
        if not src.combat then src.ReadNow(true) end
    elseif event == "PLAYER_REGEN_DISABLED" then
        src.combat = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        src.combat = false
        src.ReadNow(true)
    end
end

-- Registers only the events the enabled categories need.
local function UpdateEvents()
    local hostile = S.damage or S.avoid or S.others
    if hostile or S.heal then
        ev:RegisterEvent("UNIT_COMBAT")
        ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "pet")
    else
        ev:UnregisterEvent("UNIT_COMBAT")
        ev:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    end
    if hostile then
        ev:RegisterEvent("PLAYER_SWING")
        ev:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        ev:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
        ev:RegisterUnitEvent("UNIT_AURA", "player")
        -- Combat state: UNIT_AURA reads buffs only out of combat, and the end
        -- of combat reads them once
        ev:RegisterEvent("PLAYER_REGEN_DISABLED")
        ev:RegisterEvent("PLAYER_REGEN_ENABLED")
        src.combat = UnitAffectingCombat("player") and true or false
        src.buffsDirty = true
        if not src.combat then src.ReadNow(true) end
    else
        ev:UnregisterEvent("PLAYER_SWING")
        ev:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
        ev:UnregisterEvent("NAME_PLATE_UNIT_REMOVED")
        ev:UnregisterEvent("UNIT_AURA")
        ev:UnregisterEvent("PLAYER_REGEN_DISABLED")
        ev:UnregisterEvent("PLAYER_REGEN_ENABLED")
        wipe(gonePlate)
        wipe(plateOf)
    end
    -- Party members' casts (Icons On Others' Hits): two frames of our own,
    -- as a unit event takes at most two units
    if hostile and S.othersIcons then
        if not src.pev then
            src.pev = { CreateFrame("Frame"), CreateFrame("Frame") }
            for i = 1, 2 do
                src.pev[i]:SetScript("OnEvent", function(_, _, u, _, id) Guard(src.PartyCast, u, id) end)
            end
        end
        src.pev[1]:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "party1", "party2")
        src.pev[2]:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "party3", "party4")
    elseif src.pev then
        src.pev[1]:UnregisterAllEvents()
        src.pev[2]:UnregisterAllEvents()
    end
end

-------------------------------------------------------------------------------
--  Settings, refresh and the public API
-------------------------------------------------------------------------------
-- Live messages take a new font, size or color at once; motion settings
-- apply from the next message.
local function Restyle()
    for p = 1, #pools do
        local msgs = pools[p].msgs
        for i = 1, #msgs do
            local m = msgs[i]
            if m.live then StyleText(m) end
        end
    end
end

local function Refresh()
    local want = Enabled()
    if want and not container then Build() end
    -- The options preview follows the settings while the feature is off too
    if want or I.previewShown then
        ReadSettings()
        Restyle()
    end
    if want == enabled then
        if want then UpdateEvents() end
        return
    end
    enabled = want
    if want then
        container:Show()
        ev:SetScript("OnEvent", function(...) Guard(OnEvent, ...) end)
        UpdateEvents()
    else
        ev:UnregisterAllEvents()
        ev:SetScript("OnEvent", nil)
        if src.pev then
            src.pev[1]:UnregisterAllEvents()
            src.pev[2]:UnregisterAllEvents()
        end
        ClearPool(main)
        for i = 1, PENDING_MAX do
            pending[i].used = false
            pending[i].amount = nil
        end
        wipe(gonePlate)
        wipe(plateOf)
        container:Hide()
    end
end

-- Outgoing Combat Text, for the options pages and Health Animations.
local OCT = { DEFAULTS = DEFAULTS, Refresh = Refresh }
EllesmereUI.OutgoingCombatText = OCT

function OCT.Get(k)
    return Get(k)
end

-- Unknown keys are ignored. The preview fits its scene again (I.changed).
function OCT.Set(k, v)
    if DEFAULTS[k] == nil then return end
    Settings()[k] = v
    Refresh()
    if I.changed then I.changed() end
end

-- Every setting back to its default (the saved table goes away).
function OCT.Reset()
    Profile().unitCombatText = nil
    Refresh()
    if I.changed then I.changed() end
end

-- True while this module sends words to Number Morph (its hit side and its
-- avoid words): Health Animations waits for them on a hit it cannot place.
function OCT.Notes()
    return enabled and (S.damage or S.others) and true or false
end

-- Draws your pet's portrait on icon texture tex (for Number Morph's pet hits).
function OCT.PetIcon(tex)
    src.PetIcon(tex)
end

ns.OCT_Refresh = Refresh
ns.OCT_Get = OCT.Get
ns.OCT_Set = OCT.Set
ns.OCT_Reset = OCT.Reset
EllesmereUI._applyOutgoingCombatText = Refresh  -- RefreshAllAddons (profile swaps)
