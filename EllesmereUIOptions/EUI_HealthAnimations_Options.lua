if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_HealthAnimations_Options.lua -- Global Settings > Health Animations.
--  The look of the damage and heal animations (EllesmereUI_HealthAnimations.lua):
--  one look for nameplates and one for raid and party frames, picked in the
--  page header above a preview bar, plus the places each animation shows on.
--  Every value lives in the active profile's healthAnimations table; this page
--  only writes it through EllesmereUI.HealthAnimations. On WoW Forever the
--  Damage Animation also has the Number Morph style, with its own rows.
-------------------------------------------------------------------------------
local HTr = EllesmereUI.HealthAnimations
local HB = EllesmereUI.HealthBars
if not (HTr and HB) then return end
local IS_FOREVER = EllesmereUI.IS_FOREVER == true

-- Options page pool (EllesmereUI_FramePool.lua): frames made here on a pool
-- host are reset and dressed again by the next build instead of made anew;
-- elsewhere this is CreateFrame.
local CreateFrame = EllesmereUI._Pool.CreateFrame

local PAGE_NAME = "Health Animations"
local GLOBAL_KEY = "_EUIGlobal"

-- Which look the page edits: "plates" or "frames". Session only, never saved.
local selectedSet = "plates"
local SET_ORDER = { "plates", "frames" }
local SET_LABELS = { plates = "Nameplates", frames = "Raid & Party" }

-------------------------------------------------------------------------------
--  Settings access (the look being edited)
-------------------------------------------------------------------------------
-- Resizes the header to the room the look's motion needs; set by the header
-- builder.
local syncHeader

local function Get(key)
    return HTr.GetLook(selectedSet, key)
end

local function Set(key, v)
    HTr.SetLook(selectedSet, key, v)
    if syncHeader then syncHeader() end
end

-- A toggle or dropdown can gate other rows: they follow.
local function SetAndRefresh(key, v)
    Set(key, v)
    EllesmereUI:RefreshPage()
end

local function ColorGet(key)
    return function()
        local c = Get(key)
        if type(c) ~= "table" then return 0, 0, 0, 1 end
        return c.r or 0, c.g or 0, c.b or 0, 1
    end
end

local function ColorSet(key)
    return function(r, g, b) Set(key, { r = r, g = g, b = b }) end
end

-- Row config makers (a DualRow config is never shared between rows).
local function Slider(text, key, lo, hi, step, tip, disabled, disabledTip)
    return { type = "slider", text = text, tooltip = tip, min = lo, max = hi, step = step,
        disabled = disabled, disabledTooltip = disabledTip,
        getValue = function() return tonumber(Get(key)) or lo end,
        setValue = function(v) Set(key, v) end }
end

local function Toggle(text, key, tip, disabled, disabledTip)
    return { type = "toggle", text = text, tooltip = tip,
        disabled = disabled, disabledTooltip = disabledTip,
        getValue = function() return Get(key) == true end,
        setValue = function(v) SetAndRefresh(key, v and true or false) end }
end

local function Drop(text, key, values, order, tip, disabled, disabledTip)
    return { type = "dropdown", text = text, tooltip = tip, values = values, order = order,
        disabled = disabled, disabledTooltip = disabledTip,
        getValue = function() return Get(key) end,
        setValue = function(v) SetAndRefresh(key, v) end }
end

local function Color(text, key, tip)
    return { type = "colorpicker", text = text, tooltip = tip,
        getValue = ColorGet(key), setValue = ColorSet(key) }
end

-------------------------------------------------------------------------------
--  Presets and styles
-------------------------------------------------------------------------------
local STYLE_VALUES = { shrink = "Shrink", slide = "Slide", fall = "Fall Off", fade = "Fade",
    chip = "Chip Off", crumble = "Crumble" }
local STYLE_ORDER = { "shrink", "slide", "fall", "fade", "chip", "crumble" }
if IS_FOREVER then
    STYLE_VALUES.number = "Number Morph"
    STYLE_ORDER[#STYLE_ORDER + 1] = "number"
end
local HEAL_STYLE_VALUES = { slide = "Slide", fade = "Fade" }
local HEAL_STYLE_ORDER = { "slide", "fade" }
local EASE_VALUES = { NONE = "Linear", IN = "Ease In", OUT = "Ease Out", IN_OUT = "In-Out" }
local EASE_ORDER = { "NONE", "IN", "OUT", "IN_OUT" }

-- Presets write these keys; the dropdown shows Custom when no preset matches.
local DAMAGE_PRESET_ORDER = { "classic", "snappy", "fall", "slide", "chip", "crumble" }
local DAMAGE_PRESET_VALUES = { classic = "Classic", snappy = "Snappy", fall = "Fall Off",
    slide = "Steady Slide", chip = "Chip Off", crumble = "Crumble", custom = "Custom" }
local DAMAGE_PRESETS = {
    classic = { healthTrailStyle = "shrink", healthTrailEase = "OUT", healthTrailWait = 400,
        healthTrailMove = 450, healthTrailFlash = 0 },
    snappy = { healthTrailStyle = "shrink", healthTrailEase = "OUT", healthTrailWait = 120,
        healthTrailMove = 220, healthTrailFlash = 60 },
    fall = { healthTrailStyle = "fall", healthTrailEase = "IN", healthTrailWait = 150,
        healthTrailMove = 550, healthTrailFall = 16, healthTrailFlash = 100 },
    slide = { healthTrailStyle = "slide", healthTrailEase = "NONE", healthTrailWait = 300,
        healthTrailMove = 1200, healthTrailFlash = 0 },
    chip = { healthTrailStyle = "chip", healthTrailWait = 150, healthTrailMove = 700,
        healthTrailFall = 22, healthTrailFlash = 80, healthTrailPop = 10, healthTrailTilt = 35,
        healthTrailDrift = 12, healthTrailVary = true },
    crumble = { healthTrailStyle = "crumble", healthTrailEase = "IN", healthTrailWait = 150,
        healthTrailMove = 650, healthTrailFall = 22, healthTrailFlash = 80, healthTrailChipSize = 6,
        healthTrailChipCols = 16, healthTrailSpread = 8, healthTrailSpin = 120, healthTrailStagger = 160 },
}
if IS_FOREVER then
    DAMAGE_PRESET_ORDER[#DAMAGE_PRESET_ORDER + 1] = "number"
    DAMAGE_PRESET_VALUES.number = "Number Morph"
    -- The color keys are tables, so a preset leaves them (MatchPreset compares values).
    DAMAGE_PRESETS.number = { healthTrailStyle = "number", healthTrailWait = 150, healthTrailFlash = 80,
        healthTrailNumFlight = 450, healthTrailNumArc = 6, healthTrailNumDrift = 0,
        healthTrailNumMorph = 25, healthTrailNumOffset = 6, healthTrailNumSize = 18,
        healthTrailNumRise = 26, healthTrailNumTime = 900, healthTrailNumIcon = true,
        healthTrailNumIconSide = "LEFT", healthTrailNumColor = "white", healthTrailNumSchool = true,
        healthTrailNumCritRise = 100, healthTrailNumCritShake = false, healthTrailNumShake = 4,
        healthTrailNumOverlap = "stack", healthTrailNumGap = 4, healthTrailNumMerge = 300,
        healthTrailNumOthersSize = 75, healthTrailNumOthersOffset = false }
end
local HEAL_PRESET_ORDER = { "gentle", "quick", "glow" }
local HEAL_PRESET_VALUES = { gentle = "Gentle", quick = "Quick", glow = "Glow", custom = "Custom" }
local HEAL_PRESETS = {
    gentle = { healthTrailHealStyle = "slide", healthTrailHealEase = "OUT", healthTrailHealWait = 150,
        healthTrailHealMove = 500 },
    quick = { healthTrailHealStyle = "slide", healthTrailHealEase = "OUT", healthTrailHealWait = 50,
        healthTrailHealMove = 250 },
    glow = { healthTrailHealStyle = "fade", healthTrailHealEase = "OUT", healthTrailHealWait = 100,
        healthTrailHealMove = 700 },
}

-- The preset whose keys all match the look, or "custom".
local function MatchPreset(presets, order)
    for i = 1, #order do
        local name = order[i]
        local ok = true
        for k, v in pairs(presets[name]) do
            if Get(k) ~= v then
                ok = false
                break
            end
        end
        if ok then return name end
    end
    return "custom"
end

-- Each style's own keys: the timing all styles use plus the keys of that
-- style's own rows. A switch to another style keeps them in the look's
-- healthTrailKept[style] and brings back the new style's, so no switch loses a
-- setting.
local STYLE_KEYS = {
    shrink = {}, slide = {}, fade = {},
    fall = { "healthTrailFall" },
    chip = { "healthTrailFall", "healthTrailPop", "healthTrailTilt", "healthTrailDrift", "healthTrailVary" },
    crumble = { "healthTrailFall", "healthTrailChipSize", "healthTrailChipCols", "healthTrailSpread",
        "healthTrailSpin", "healthTrailStagger" },
}
if IS_FOREVER then
    local own = {}
    for _, k in ipairs(HTr.KEYS) do
        if k:find("^healthTrailNum") then own[#own + 1] = k end
    end
    STYLE_KEYS.number = own
end
for _, list in pairs(STYLE_KEYS) do
    list[#list + 1] = "healthTrailEase"
    list[#list + 1] = "healthTrailWait"
    list[#list + 1] = "healthTrailMove"
    list[#list + 1] = "healthTrailFlash"
end

-- A copy of a saved value (a color is a table).
local function KeepCopy(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = KeepCopy(x) end
    return c
end

-- A switch from the look's style to style `to`: the writes, as a table for
-- SetLookMany. They keep the leaving style's own keys in healthTrailKept[from]
-- and bring back what was kept for `to`. Second return: true when `to` had
-- kept values.
local function StyleSwitch(to)
    local from = Get("healthTrailStyle")
    local old = Get("healthTrailKept")
    local kept = {}
    if type(old) == "table" then
        for s, t in pairs(old) do kept[s] = KeepCopy(t) end
    end
    local keys = STYLE_KEYS[from]
    if keys and from ~= to then
        local k = {}
        for i = 1, #keys do k[keys[i]] = KeepCopy(Get(keys[i])) end
        kept[from] = k
    end
    local w = { healthTrailStyle = to, healthTrailKept = kept }
    local back = kept[to]
    if type(back) ~= "table" or from == to then return w, false end
    for k, v in pairs(back) do w[k] = KeepCopy(v) end
    return w, true
end

local function Style()
    return Get("healthTrailStyle")
end

-- A style that is not Number Morph shows no Number Morph rows.
local function NumberStyle()
    return IS_FOREVER and Style() == "number"
end

-- The page is built again when the style change brings Number Morph's rows or
-- takes them away.
local function SetMany(tbl)
    local was = NumberStyle()
    HTr.SetLookMany(selectedSet, tbl)
    if syncHeader then syncHeader() end
    EllesmereUI:RefreshPage(NumberStyle() ~= was)
end

local function MovesBelow()
    local s = Style()
    return s == "fall" or s == "chip" or s == "crumble"
end

-------------------------------------------------------------------------------
--  Preview: one plain bar in the page header. Replay plays hits and a heal on
--  it through HTr, as a real bar would get them. Nothing is saved.
-------------------------------------------------------------------------------
local PV_MAX = 6000
local PV_BAR = { plates = { 150, 17 }, frames = { 125, 40 } }
-- Frame levels over the bar and for the part below it (the nameplate values).
local PV_LVL, PV_BELOW = 2, 8
local PV_GAP = 1      -- seconds between the steps of a replay
local PV_TOP_PAD = 16 -- above the segmented control
local PV_SEG_GAP = 14 -- under the segmented control
local PV_BOTTOM_PAD = 14
local PV_ROOM_MAX = 120 -- most room above or below the bar; more is clipped
-- Number Morph: the replay's hits take these schools in turn, with this icon.
local PV_SCHOOLS = { 1, 4, 16, 8, 32, 2, 64 }
local PV_ICON = "Interface\\Icons\\INV_Sword_04"
local PV_NUM_ROOM_MAX = 150 -- most room the numbers get above or below the bar
-- The lengths that shrink when the numbers would not fit that room.
local FIT_KEYS = { "healthTrailNumOffset", "healthTrailNumRise", "healthTrailNumSize", "healthTrailNumGap",
    "healthTrailNumShake", "healthTrailNumArc", "healthTrailNumDrift", "healthTrailNumOthersOffset" }

-- Made once, on the first header build (a plain frame: the options pool does
-- not take it, so the page keeps one preview and puts it in each new header).
local pv

local function PvColor()
    if selectedSet == "plates" then return 0.78, 0.16, 0.13 end
    local _, class = UnitClass("player")
    local c = class and EllesmereUI.GetClassColor(class)
    if c then return c.r, c.g, c.b end
    return 0.2, 0.75, 0.25
end

local function PvBuild()
    local f = CreateFrame("Frame")
    local bar = CreateFrame("StatusBar", nil, f)
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    bar:SetMinMaxValues(0, PV_MAX)
    bar:SetValue(PV_MAX)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    bg:SetColorTexture(0.06, 0.06, 0.06, 0.9)
    -- The look's switches and values for MakeStyle: both animations on and no
    -- absorb overlays to draw under; My Damage follows the look on a replay.
    local view = { healthTrail = true, healthTrailHeal = true, healthTrailMine = false,
        healthTrailUnderAbsorbs = false }
    setmetatable(view, { __index = function(_, key) return Get(key) end })
    pv = { frame = f, bar = bar, view = view, token = 0, value = PV_MAX }
end

-- Header units per 1080p pixel of the look (HealthAnimations draws in physical
-- pixels; the header has its own scale).
local function PvPx()
    local PP = EllesmereUI.PP
    local tall = PP and PP.physicalHeight or 1080
    local mul = math.max(1, math.floor(tall / 1080 + 0.5))
    local hs = pv.frame:GetEffectiveScale()
    if not hs or hs <= 0 then hs = UIParent:GetEffectiveScale() end
    return mul * (PP and PP.perfect or 1) / hs
end

-- Number Morph: how far its numbers reach above and below the bar (another
-- player's numbers sink below it on nameplates), in header units, and the
-- margin each side. A crit's number goes Crit Distance far.
local function NumReach()
    local px = PvPx()
    local th = (tonumber(Get("healthTrailNumSize")) or 0) * 0.72
    if Get("healthTrailNumChunk") == true then
        th = th * math.max(1, (tonumber(Get("healthTrailNumChunkMin")) or 0) / 100,
            (tonumber(Get("healthTrailNumChunkMax")) or 0) / 100)
    end
    local rise = math.max(0, tonumber(Get("healthTrailNumRise")) or 0)
        * math.max(1, (tonumber(Get("healthTrailNumCritRise")) or 0) / 100)
    local off = tonumber(Get("healthTrailNumOffset")) or 0
    local top = (off + rise + th * 1.2 + 4) * px
    local bottom = 0
    if selectedSet == "plates" then
        local oReach = (tonumber(Get("healthTrailNumOthersOffset")) or off) + rise
        local o = (tonumber(Get("healthTrailNumOthersSize")) or 0) / 100
        bottom = (oReach + th * o * 1.2 + 4) * px
    end
    return top, bottom, 4 * px
end

-- Numbers that would reach past the room draw smaller (their timing stays):
-- the view the look is read through carries the scaled lengths.
local function PvFit()
    if not IS_FOREVER then return end
    local fit = 1
    if NumberStyle() then
        local top, bottom, margin = NumReach()
        local cap = PV_NUM_ROOM_MAX
        if top > cap then fit = (cap - margin) / (top - margin) end
        if bottom > cap then fit = math.min(fit, (cap - margin) / (bottom - margin)) end
        if fit < 0.05 then fit = 0.05 end
    end
    local defaults = selectedSet == "plates" and HTr.DEFAULTS_PLATES or HTr.DEFAULTS_FRAMES
    for i = 1, #FIT_KEYS do
        local key = FIT_KEYS[i]
        local v = tonumber(Get(key)) or tonumber(defaults[key])
        pv.view[key] = (fit < 1 and v) and v * fit or nil
    end
end

-- The room the look's motion needs above and below the bar, in tens, so a
-- slider drag resizes the header only now and then.
local function PvRoom()
    local px = PvPx()
    local above, below = 10, 10
    local cap = PV_ROOM_MAX
    local s = Style()
    local fall = tonumber(Get("healthTrailFall")) or 0
    if s == "chip" then
        above = (tonumber(Get("healthTrailPop")) or 0) * 1.4 * px + 6
        below = fall * px + 8
    elseif s == "fall" then
        below = fall * px + 8
    elseif s == "crumble" then
        below = fall * 1.4 * px + 24
    end
    if NumberStyle() then
        local top, bottom = NumReach()
        above, below = math.max(above, top), math.max(below, bottom)
        cap = PV_NUM_ROOM_MAX
    end
    local function Round(v)
        return math.min(cap, math.ceil(v / 10) * 10)
    end
    return Round(above), Round(below)
end

-- Places the bar in the header and returns the header height.
local function PvLayout()
    local PP = EllesmereUI.PanelPP
    local f, bar = pv.frame, pv.bar
    local w, h = PV_BAR[selectedSet][1], PV_BAR[selectedSet][2]
    local above, below = PvRoom()
    bar:ClearAllPoints()
    PP.Size(bar, w, h)
    PP.Point(bar, "TOP", f, "TOP", 0, -(pv.top + above))
    bar:SetStatusBarColor(PvColor())
    return pv.top + above + h + below + PV_BOTTOM_PAD
end

local function PvSmooth()
    return selectedSet == "frames" and HTr.ViewSmooth(false, false)
end

-- One step: the health moves by delta (a share of the max); a hit may be a
-- crit and/or the player's own, which the look colors when those are on. With
-- Number Morph a hit also makes its number: another player's (other) or your
-- pet's or a DoT tick's (tag), on the nameplate look.
local function PvStep(delta, crit, mine, other, tag)
    local bar, style = pv.bar, pv.style
    local last = pv.value
    local v = math.floor(last + PV_MAX * delta + 0.5)
    if v < 0 then v = 0 elseif v > PV_MAX then v = PV_MAX end
    pv.value = v
    local smooth = PvSmooth()
    local interp = Enum and Enum.StatusBarInterpolation
    local ease = interp and interp.ExponentialEaseOut
    if smooth and ease then bar:SetValue(v, ease) else bar:SetValue(v) end
    HTr.Change(bar, v, style, smooth, PV_LVL, PV_BELOW, PV_MAX)
    if crit or mine then HTr.Hit(bar, style, crit and true or false, mine and true or false) end
    if style.numOn and v < last then
        pv.hits = pv.hits + 1
        HTr.NumHit(bar, style, last - v, PV_SCHOOLS[pv.hits % #PV_SCHOOLS + 1], crit and true or false,
            other and "other" or "mine", selectedSet == "plates", PV_ICON, tag)
    end
end

local function PvRun(steps, i, token)
    if token ~= pv.token or not pv.frame:IsVisible() then return end
    local s = steps[i]
    if not s then return end
    PvStep(s[1], s[2], s[3], s[4], s[5])
    if steps[i + 1] then
        C_Timer.After(PV_GAP, function() PvRun(steps, i + 1, token) end)
    end
end

local function PvReplay()
    if not (pv and pv.frame:IsVisible()) then return end
    pv.token = pv.token + 1
    local token = pv.token
    local mine = selectedSet == "plates" and Get("healthTrailMine") == true
    pv.view.healthTrailMine = mine
    PvFit()
    local style = HTr.MakeStyle(pv.view, pv.style,
        selectedSet == "plates" and HTr.DEFAULTS_PLATES or HTr.DEFAULTS_FRAMES)
    pv.style = style
    pv.value = PV_MAX
    pv.hits = 0
    pv.bar:SetMinMaxValues(0, PV_MAX)
    pv.bar:SetValue(PV_MAX)
    HTr.Reset(pv.bar, PV_MAX, PV_MAX)
    -- A hit, a crit and the player's own hits where those colors are on, a heal.
    local steps = { { -0.28 } }
    local crit = Get("healthTrailCrit") == true
    if crit then steps[#steps + 1] = { -0.14, true } end
    if mine then
        steps[#steps + 1] = { -0.14, false, true }
        if crit then steps[#steps + 1] = { -0.1, true, true } end
    end
    if NumberStyle() and selectedSet == "plates" then
        steps[#steps + 1] = { -0.08, false, false, true }
        steps[#steps + 1] = { -0.06, false, false, false, "pet" }
        steps[#steps + 1] = { -0.05, false, false, false, "dot" }
    end
    steps[#steps + 1] = { 0.4 }
    C_Timer.After(0.3, function() PvRun(steps, 1, token) end)
end

-------------------------------------------------------------------------------
--  Header: the look switch, the preview bar and Replay
-------------------------------------------------------------------------------
local function HeaderBuilder(hdr)
    local PP = EllesmereUI.PanelPP
    if not pv then PvBuild() end

    local seg, segH = EllesmereUI.BuildSegmentedControl({
        parent     = hdr,
        keys       = SET_ORDER,
        labels     = SET_LABELS,
        autoWidth  = true,
        square     = true,
        getChecked = function(key) return key == selectedSet end,
        onToggle   = function(key)
            if key == selectedSet then return end
            selectedSet = key
            -- The rows differ (My Damage Colors is for nameplates): the page and
            -- its header are built again.
            EllesmereUI:RefreshPage(true)
        end,
    })
    seg:SetFrameLevel(hdr:GetFrameLevel() + 5)
    PP.Point(seg, "TOP", hdr, "TOP", 0, -PV_TOP_PAD)

    local replay = CreateFrame("Button", nil, hdr)
    PP.Size(replay, 90, 26)
    PP.Point(replay, "TOPRIGHT", hdr, "TOPRIGHT", -20, -PV_TOP_PAD - math.floor((segH - 26) / 2))
    replay:SetFrameLevel(hdr:GetFrameLevel() + 5)
    EllesmereUI.MakeStyledButton(replay, "Replay", 12, EllesmereUI.WB_COLOURS, PvReplay)

    local f = pv.frame
    f:SetParent(hdr)
    f:ClearAllPoints()
    f:SetAllPoints(hdr)
    f:SetFrameLevel(hdr:GetFrameLevel() + 2)
    f:Show()
    pv.top = PV_TOP_PAD + segH + PV_SEG_GAP
    pv.style = nil
    local height = PvLayout()
    pv.height = height

    syncHeader = function()
        if not (pv and pv.frame:GetParent()) then return end
        local h = PvLayout()
        if h ~= pv.height then
            pv.height = h
            EllesmereUI:UpdateContentHeaderHeight(h)
        end
    end
    C_Timer.After(0.1, PvReplay)
    return height
end

function _G._EUI_HealthAnimationsHeaderBuilder()
    return HeaderBuilder
end

-- A cached page came back: the preview plays again.
function _G._EUI_HealthAnimationsRefreshHeader()
    if not pv then return end
    if syncHeader then syncHeader() end
    C_Timer.After(0.1, PvReplay)
end

-------------------------------------------------------------------------------
--  Place switches (the page's own and the cfgs module pages use)
-------------------------------------------------------------------------------
local KIND_TIPS = {
    dmg = "The lost piece of health stays on the bar, then goes away.",
    heal = "The gained piece of health shows in the heal color, then the bar color takes over.",
}

local function PlaceToggle(place, kind, text)
    return { type = "toggle", text = text, tooltip = KIND_TIPS[kind],
        getValue = function() return HTr.PlaceOn(place, kind) end,
        setValue = function(v) HTr.SetPlace(place, kind, v and true or false) end }
end

-- Opens this page on the look that place uses.
local function EditLook(place)
    EllesmereUI:NavigateToElementSettings(GLOBAL_KEY, PAGE_NAME, nil, function()
        selectedSet = HTr.SetOf(place)
    end)
end
EllesmereUI.HealthAnimationsEditLook = EditLook

-- EllesmereUI.HealthAnimationsPlaceCfg(place) -> { damage, heal, AddEditLook }:
-- the two toggle configs ("Damage Animation", "Heal Animation") for a module
-- page's DualRow slots, and AddEditLook(region), which puts an Edit Look cog on
-- a slot built from one of them.
function EllesmereUI.HealthAnimationsPlaceCfg(place)
    return {
        damage = PlaceToggle(place, "dmg", "Damage Animation"),
        heal = PlaceToggle(place, "heal", "Heal Animation"),
        AddEditLook = function(rgn)
            EllesmereUI.BuildInlineCog(rgn, {
                title = "Health Animations",
                rows = { { type = "button", label = "Edit Look", action = function() EditLook(place) end } },
            })
        end,
    }
end

-------------------------------------------------------------------------------
--  Overrides Combat Text: shown beside the Style row while Number Morph draws
--  the nameplates' damage numbers; a click opens the Combat Text tab.
-------------------------------------------------------------------------------
local function CombatTextTag(rgn)
    if EllesmereUI._prebuilding or not (NumberStyle() and selectedSet == "plates") then return end
    local reg = EllesmereUI._ModuleNS
    if not (reg and reg.EllesmereUIQoL) then return end
    local badge = EllesmereUI.BuildStatusBadge(rgn, "Overrides Combat Text", nil, {
        dot = false,
        tooltip = "Combat Text tab",
        onClick = function() EllesmereUI:NavigateToElementSettings("EllesmereUIQoL", "Combat Text") end,
    })
    EllesmereUI.PanelPP.Point(badge, "RIGHT", rgn._lastInline or rgn._control or rgn, "LEFT", -8, 0)
    badge:SetFrameLevel(rgn:GetFrameLevel() + 5)
    badge:Show()
end

-------------------------------------------------------------------------------
--  Style settings cog (the rows of the Fall Off, Chip Off and Crumble styles)
-------------------------------------------------------------------------------
local function StyleRow(label, key, lo, hi, step, tip, styles)
    return { type = "slider", label = label, min = lo, max = hi, step = step, tooltip = tip,
        hidden = function() return not styles[Style()] end,
        get = function() return tonumber(Get(key)) or lo end,
        set = function(v) Set(key, v) end }
end

local function StyleCog(rgn)
    local below = { fall = true, chip = true, crumble = true }
    local chip, crumble = { chip = true }, { crumble = true }
    EllesmereUI.BuildInlineCog(rgn, {
        title = "Style Settings",
        disabled = function() return not MovesBelow() end,
        disabledTooltip = "This option needs the Fall Off, Chip Off or Crumble style.",
        rows = {
            StyleRow("Fall Distance", "healthTrailFall", 4, 250, 1, "How far below the bar the piece falls.", below),
            StyleRow("Jump Height", "healthTrailPop", 0, 200, 1, "How far the piece jumps up before it falls.", chip),
            StyleRow("Tilt", "healthTrailTilt", 0, 720, 5, "How far the piece turns in flight, in degrees.", chip),
            StyleRow("Sideways", "healthTrailDrift", 0, 250, 1, "How far the piece moves to the right.", chip),
            { type = "toggle", label = "Vary Each Piece",
              tooltip = "Each piece jumps, tilts and moves a little differently.",
              hidden = function() return Style() ~= "chip" end,
              get = function() return Get("healthTrailVary") == true end,
              set = function(v) Set("healthTrailVary", v and true or false) end },
            StyleRow("Chip Size", "healthTrailChipSize", 3, 50, 1, "The side of one square chip.", crumble),
            StyleRow("Chips Across", "healthTrailChipCols", 6, 32, 1, "The most chips in a row; more chips cost more.", crumble),
            StyleRow("Spread", "healthTrailSpread", 0, 100, 1, "How far a chip can move sideways.", crumble),
            StyleRow("Spin", "healthTrailSpin", 0, 720, 10, "How far a chip can turn, in degrees.", crumble),
            StyleRow("Stagger (ms)", "healthTrailStagger", 0, 3000, 10,
                "The latest a chip starts to fall after the wait.", crumble),
        },
    })
end

-------------------------------------------------------------------------------
--  Number Morph rows (the Damage Animation's style on WoW Forever): the lost
--  piece flies up and turns into the hit's number. Another player's, your
--  pet's and DoT numbers show on enemy nameplates only.
-------------------------------------------------------------------------------
-- Cog rows (BuildInlineCog rows take label / get / set).
local function CogSlider(label, key, lo, hi, step, tip, disabled, disabledTip)
    return { type = "slider", label = label, min = lo, max = hi, step = step, tooltip = tip,
        disabled = disabled, disabledTooltip = disabledTip,
        get = function() return tonumber(Get(key)) or lo end,
        set = function(v) Set(key, v) end }
end

local function CogToggle(label, key, tip, disabled, disabledTip)
    return { type = "toggle", label = label, tooltip = tip,
        disabled = disabled, disabledTooltip = disabledTip,
        get = function() return Get(key) == true end,
        set = function(v) Set(key, v and true or false) end }
end

local function CogDrop(label, key, values, order, tip, disabled, disabledTip)
    return { type = "dropdown", label = label, values = values, order = order, tooltip = tip,
        disabled = disabled, disabledTooltip = disabledTip,
        get = function() return Get(key) end,
        set = function(v) Set(key, v) end }
end

local function IsOff(key)
    return function() return Get(key) ~= true end
end

-- Another player's number: not set (false) it follows Text Offset, which is
-- also what the slider shows then. Set to Text Offset's value it follows again.
local function OthersOffsetCfg()
    local function OwnOff()
        return tonumber(Get("healthTrailNumOffset")) or 0
    end
    return { type = "slider", text = "Others Text Offset", min = 0, max = 200, step = 1,
        tooltip = "Space between the bar and another player's number, below the bar. Follows Text Offset until changed.",
        getValue = function()
            local v = tonumber(Get("healthTrailNumOthersOffset"))
            if v == nil then v = OwnOff() end
            return v
        end,
        setValue = function(v)
            local n = tonumber(v)
            if n and math.abs(n - OwnOff()) < 0.001 then v = false end
            Set("healthTrailNumOthersOffset", v)
        end }
end

-- Builds the NUMBER MORPH section (and, on nameplates, the one for other
-- players', pet and DoT numbers) at y; returns the new y.
local function BuildNumberMorphRows(parent, y, plates)
    local W = EllesmereUI.Widgets
    local _, h
    local row
    local chunkOff = IsOff("healthTrailNumChunk")

    _, h = W:SectionHeader(parent, "NUMBER MORPH", y);  y = y - h

    _, h = W:DualRow(parent, y,
        Slider("Flight (ms)", "healthTrailNumFlight", 150, 3000, 25,
            "The piece's whole trip, from lift-off to its number."),
        Slider("Text Offset", "healthTrailNumOffset", 0, 200, 1,
            "Space between the bar and the number."));  y = y - h

    row, h = W:DualRow(parent, y,
        Slider("Number Size", "healthTrailNumSize", 10, 100, 1),
        Slider("Number Rise", "healthTrailNumRise", 0, 250, 1,
            "How far the number rises. Another player's number sinks."));  y = y - h
    EllesmereUI.BuildInlineCog(row._leftRegion, {
        title = "Number Size",
        rows = {
            CogToggle("Size by Chunk", "healthTrailNumChunk",
                "A bigger hit gets a bigger number, by its part of the unit's max health."),
            CogSlider("Smallest Chunk (%)", "healthTrailNumChunkMin", 30, 200, 5,
                "The number of a hit under 2% of max health, as a part of Number Size.", chunkOff, "Size by Chunk"),
            CogSlider("Largest Chunk (%)", "healthTrailNumChunkMax", 50, 300, 5,
                "The number of a hit of 20% of max health or more, as a part of Number Size.", chunkOff, "Size by Chunk"),
        },
    })

    _, h = W:DualRow(parent, y,
        Slider("Number Time (ms)", "healthTrailNumTime", 300, 5000, 50,
            "How long the number rises, then fades where it stopped."),
        Slider("Morph Starts (%)", "healthTrailNumMorph", 0, 90, 5,
            "How far into the flight the piece starts to shrink and take the number's color."));  y = y - h

    _, h = W:DualRow(parent, y,
        Slider("Arc", "healthTrailNumArc", 0, 100, 1, "How far the path bows to one side."),
        Slider("Drift", "healthTrailNumDrift", 0, 200, 1, "How far to the side the number lands."));  y = y - h

    row, h = W:DualRow(parent, y,
        Slider("Crit Distance (%)", "healthTrailNumCritRise", 0, 400, 10,
            "How far a crit's number rises, as a part of Number Rise."),
        Toggle("Crit Shake", "healthTrailNumCritShake",
            "A crit's number shakes for a moment. A bigger hit shakes more."));  y = y - h
    EllesmereUI.BuildInlineCog(row._rightRegion, {
        title = "Crit Shake",
        disabled = IsOff("healthTrailNumCritShake"),
        disabledTooltip = "Crit Shake",
        rows = {
            CogSlider("Shake Strength", "healthTrailNumShake", 1, 50, 1,
                "The most a crit's number shakes to each side."),
        },
    })

    row, h = W:DualRow(parent, y,
        Toggle("School Colors", "healthTrailNumSchool",
            "A spell's number takes its school's color. Physical hits keep Number Color."),
        Drop("Number Color", "healthTrailNumColor", { white = "White", custom = "Custom" },
            { "white", "custom" }, "The color of physical hits, and of every hit with School Colors off."));  y = y - h
    EllesmereUI.BuildInlineSwatches(row._rightRegion, {
        { tooltip = "Custom Color",
          getValue = ColorGet("healthTrailNumCustom"), setValue = ColorSet("healthTrailNumCustom"),
          disabled = function() return Get("healthTrailNumColor") ~= "custom" end,
          disabledTooltip = "Number Color Custom" },
    }, { size = 20 })

    row, h = W:DualRow(parent, y,
        Toggle("Spell Icon", "healthTrailNumIcon",
            "The spell's icon beside the number. Outgoing Combat Text finds it, so it needs that on."),
        Drop("Overlap", "healthTrailNumOverlap", { stack = "Stack", merge = "Merge", off = "Off" },
            { "stack", "merge", "off" },
            "Stack: a new number moves the young ones up. Merge: a hit joins the young number (x2, x3). Off: numbers can overlap."));  y = y - h
    EllesmereUI.BuildInlineCog(row._leftRegion, {
        title = "Spell Icon",
        disabled = IsOff("healthTrailNumIcon"),
        disabledTooltip = "Spell Icon",
        rows = {
            CogDrop("Icon Side", "healthTrailNumIconSide", { LEFT = "Left", RIGHT = "Right" }, { "LEFT", "RIGHT" }),
        },
    })
    EllesmereUI.BuildInlineCog(row._rightRegion, {
        title = "Overlap",
        rows = {
            CogSlider("Gap", "healthTrailNumGap", 0, 50, 1, "Space between stacked numbers.",
                function() return Get("healthTrailNumOverlap") ~= "stack" end, "Overlap Stack"),
            CogSlider("Merge Window (ms)", "healthTrailNumMerge", 100, 3000, 50, nil,
                function() return Get("healthTrailNumOverlap") ~= "merge" end, "Overlap Merge"),
        },
    })

    if not plates then return y end

    _, h = W:SectionHeader(parent, "OTHERS, PET AND DOT", y);  y = y - h

    _, h = W:DualRow(parent, y,
        Color("Others Color", "healthTrailNumOthersColor",
            "Another player's hit flies down and sinks in this color."),
        Slider("Others Size (%)", "healthTrailNumOthersSize", 50, 300, 5,
            "Another player's number, as a part of Number Size."));  y = y - h

    _, h = W:DualRow(parent, y,
        OthersOffsetCfg(),
        Toggle("Others Use School Color", "healthTrailNumOthersSchool",
            "Another player's hit takes its spell school's color. Physical and mixed hits keep Others Color."));  y = y - h

    local petOff = IsOff("healthTrailNumPet")
    local dotOff = IsOff("healthTrailNumDot")
    local function DotSchool() return Get("healthTrailNumDotSchool") == true end
    row, h = W:DualRow(parent, y,
        Toggle("Pet Numbers", "healthTrailNumPet",
            "Your pet's hits in their own color and size. Outgoing Combat Text tells which hits are your pet's, so it needs that on."),
        Toggle("DoT Tick Numbers", "healthTrailNumDot",
            "Ticks of your damage over time spells, ground effects and totems in their own color and size. Outgoing Combat Text tells which hits are ticks, so it needs that on."));  y = y - h
    EllesmereUI.BuildInlineSwatches(row._leftRegion, {
        { tooltip = "Pet Color",
          getValue = ColorGet("healthTrailNumPetColor"), setValue = ColorSet("healthTrailNumPetColor"),
          disabled = petOff, disabledTooltip = "Pet Numbers" },
    }, { size = 20 })
    EllesmereUI.BuildInlineCog(row._leftRegion, {
        title = "Pet Numbers",
        disabled = petOff,
        disabledTooltip = "Pet Numbers",
        rows = {
            CogSlider("Pet Size (%)", "healthTrailNumPetSize", 30, 200, 5,
                "Your pet's number, as a part of Number Size."),
        },
    })
    EllesmereUI.BuildInlineSwatches(row._rightRegion, {
        { tooltip = "DoT Tick Color",
          getValue = ColorGet("healthTrailNumDotColor"), setValue = ColorSet("healthTrailNumDotColor"),
          disabled = function() return dotOff() or DotSchool() end,
          disabledTooltip = "DoT Tick Numbers on and DoT Use School Color off" },
    }, { size = 20 })
    EllesmereUI.BuildInlineCog(row._rightRegion, {
        title = "DoT Tick Numbers",
        disabled = dotOff,
        disabledTooltip = "DoT Tick Numbers",
        rows = {
            CogToggle("DoT Use School Color", "healthTrailNumDotSchool",
                "A tick takes its spell school's color, not DoT Tick Color. Physical ticks keep Number Color."),
            CogSlider("DoT Tick Size (%)", "healthTrailNumDotSize", 30, 200, 5,
                "A tick's number, as a part of Number Size."),
            CogDrop("DoT Tick Style", "healthTrailNumDotGroup",
                { grow = "One Growing Number", each = "Each Tick" }, { "grow", "each" },
                "One Growing Number: the ticks of each DoT fly into one number that grows. Each Tick: every tick has its own number."),
        },
    })
    return y
end

-------------------------------------------------------------------------------
--  Page builder (dispatched from the Global Settings module registration)
-------------------------------------------------------------------------------
local function ConfirmReset()
    local set = selectedSet
    EllesmereUI:ShowConfirmPopup({
        title       = "Reset Look",
        message     = "Reset the " .. SET_LABELS[set] .. " look to its defaults?",
        confirmText = "Reset",
        cancelText  = "Cancel",
        onConfirm   = function()
            HTr.ResetLook(set)
            EllesmereUI:RefreshPage(true)
        end,
    })
end

function _G._EUI_BuildHealthAnimationsPage(pageName, parent, yOffset)
    local W = EllesmereUI.Widgets
    local BLANK = EllesmereUI.BlankRowCfg
    local y = yOffset
    local _, h
    local row
    local plates = selectedSet == "plates"

    EllesmereUI:SetContentHeader(HeaderBuilder)
    parent._showRowDivider = true

    ---------------------------------------------------------------------------
    --  SHOW ANIMATIONS ON: both animations, every place
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "SHOW ANIMATIONS ON", y);  y = y - h
    for _, def in ipairs(HB.PLACES) do
        if def.anim then
            _, h = W:DualRow(parent, y,
                PlaceToggle(def.id, "dmg", def.label .. ": Damage Animation"),
                PlaceToggle(def.id, "heal", def.label .. ": Heal Animation"));  y = y - h
        end
    end

    ---------------------------------------------------------------------------
    --  DAMAGE ANIMATION
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "DAMAGE ANIMATION", y);  y = y - h

    row, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Preset",
          tooltip = "Sets the style and timing in one step.",
          values = DAMAGE_PRESET_VALUES, order = DAMAGE_PRESET_ORDER,
          getValue = function() return MatchPreset(DAMAGE_PRESETS, DAMAGE_PRESET_ORDER) end,
          setValue = function(v)
              local pr = DAMAGE_PRESETS[v]
              if not pr then return end
              -- A preset of another style switches to it: the settings you had
              -- for that style come back, else the preset's. A preset of the
              -- style you have writes its values.
              local to = pr.healthTrailStyle
              if to and to ~= Style() then
                  local w, had = StyleSwitch(to)
                  if not had then
                      for k, x in pairs(pr) do w[k] = x end
                  end
                  SetMany(w)
              else
                  SetMany(pr)
              end
          end },
        { type = "dropdown", text = "Style",
          tooltip = "How the lost piece of health goes away.",
          values = STYLE_VALUES, order = STYLE_ORDER,
          getValue = Style,
          setValue = function(v)
              if v == Style() then return end
              SetMany((StyleSwitch(v)))
          end });  y = y - h
    StyleCog(row._rightRegion)
    CombatTextTag(row._rightRegion)

    _, h = W:DualRow(parent, y,
        Drop("Easing", "healthTrailEase", EASE_VALUES, EASE_ORDER,
            "How the motion speeds up or slows down.",
            function() return Style() == "chip" or NumberStyle() end,
            "This option does not apply to Chip Off and Number Morph, which move on their own curves."),
        Slider("Wait (ms)", "healthTrailWait", 0, 3000, 25,
            "How long the lost piece stays before it moves."));  y = y - h

    _, h = W:DualRow(parent, y,
        Slider("Move Time (ms)", "healthTrailMove", 100, 3000, 25, "How long the motion takes.",
            NumberStyle, "This option does not apply to Number Morph: see Flight and Number Time."),
        Slider("Hit Flash (ms)", "healthTrailFlash", 0, 1000, 10,
            "How long a white flash shows on the lost piece; 0 is off."));  y = y - h

    _, h = W:DualRow(parent, y,
        Color("Damage Color", "healthTrailColor", "The color of the lost piece of health."),
        Slider("Opacity", "healthTrailAlpha", 20, 100, 5, "How solid the lost piece is."));  y = y - h

    _, h = W:DualRow(parent, y,
        Toggle("Group Pieces", "healthTrailGroup",
            "A new hit makes waiting pieces start over, so a burst moves together."),
        Toggle("Draw Under Absorbs", "healthTrailUnderAbsorbs",
            "Draws below the shield, heal absorb and heal prediction overlays."));  y = y - h

    -- Crit Color and My Damage Colors: the toggle with its swatches inline.
    row, h = W:DualRow(parent, y,
        Toggle("Crit Color", "healthTrailCrit", "Crit hits, from anyone, leave a piece in the crit color."),
        plates and Toggle("My Damage Colors", "healthTrailMine",
            "Your own hits get their own colors, guessed from your threat.") or BLANK());  y = y - h
    EllesmereUI.BuildInlineSwatches(row._leftRegion, {
        { tooltip = "Crit Color",
          getValue = ColorGet("healthTrailCritColor"), setValue = ColorSet("healthTrailCritColor"),
          disabled = function() return Get("healthTrailCrit") ~= true end,
          disabledTooltip = "Crit Color" },
    }, { size = 20 })
    if plates then
        EllesmereUI.BuildInlineSwatches(row._rightRegion, {
            { tooltip = "My Hit",
              getValue = ColorGet("healthTrailMineColor"), setValue = ColorSet("healthTrailMineColor"),
              disabled = function() return Get("healthTrailMine") ~= true end,
              disabledTooltip = "My Damage Colors" },
            { tooltip = "My Crit",
              getValue = ColorGet("healthTrailMineCritColor"), setValue = ColorSet("healthTrailMineCritColor"),
              disabled = function() return not (Get("healthTrailMine") == true and Get("healthTrailCrit") == true) end,
              disabledTooltip = "My Damage Colors and Crit Color" },
        }, { size = 20 })
    end

    if NumberStyle() then
        y = BuildNumberMorphRows(parent, y, plates)
    end

    ---------------------------------------------------------------------------
    --  HEAL ANIMATION
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "HEAL ANIMATION", y);  y = y - h

    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Preset",
          tooltip = "Sets the style and timing in one step.",
          values = HEAL_PRESET_VALUES, order = HEAL_PRESET_ORDER,
          getValue = function() return MatchPreset(HEAL_PRESETS, HEAL_PRESET_ORDER) end,
          setValue = function(v)
              if HEAL_PRESETS[v] then SetMany(HEAL_PRESETS[v]) end
          end },
        Drop("Style", "healthTrailHealStyle", HEAL_STYLE_VALUES, HEAL_STYLE_ORDER,
            "How the heal color gives way to the bar color."));  y = y - h

    _, h = W:DualRow(parent, y,
        Color("Heal Color", "healthTrailHealColor", "The healed part of the bar, before the bar color takes over."),
        Slider("Heal Opacity", "healthTrailHealAlpha", 20, 100, 5, "How solid the heal color is."));  y = y - h

    _, h = W:DualRow(parent, y,
        Drop("Easing", "healthTrailHealEase", EASE_VALUES, EASE_ORDER,
            "How the motion speeds up or slows down."),
        Slider("Wait (ms)", "healthTrailHealWait", 0, 3000, 25,
            "How long the healed part stays before it changes."));  y = y - h

    _, h = W:DualRow(parent, y,
        Slider("Move Time (ms)", "healthTrailHealMove", 100, 3000, 25, "How long the change takes."),
        BLANK());  y = y - h

    ---------------------------------------------------------------------------
    --  RESET
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "RESET", y);  y = y - h
    _, h = W:DualRow(parent, y,
        { type = "button", text = "Reset " .. SET_LABELS[selectedSet] .. " Look", width = 240,
          onClick = ConfirmReset },
        BLANK());  y = y - h

    -- Framework contract: return the positive total content height.
    return math.abs(y)
end
