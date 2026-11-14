if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end -- Outgoing Combat Text is WoW Forever only
-------------------------------------------------------------------------------
--  EUI_QoL_CombatText_Options.lua
--  Quality of Life > Combat Text: the settings of Outgoing Combat Text (runtime:
--  EllesmereUIQoL_OutgoingCombatText.lua, every value through its Get/Set), under
--  a live preview in the content header. Sections: OUTGOING COMBAT TEXT, LOOK and
--  DAMAGE. While Number Morph draws the damage on nameplates, LOOK and DAMAGE
--  carry a tag that opens Health Animations.
-------------------------------------------------------------------------------
if not EllesmereUI._ModuleNS["EllesmereUIQoL"] then return end  -- module disabled: no options page

-- Page reuse: frames this file builds go through the options frame pool
-- (EllesmereUI_FramePool.lua), which hands a kept page its previous build's
-- frames back reset to new; on any other parent it is the plain CreateFrame.
local CreateFrame = EllesmereUI._Pool.CreateFrame

local FEATURE = "Outgoing Combat Text"
local GLOBAL_KEY = "_EUIGlobal"
local ANIM_PAGE = "Health Animations"
local TAG_TEXT = "Plate damage: Number Morph"
local TAG_TIP = "Health Animations > Nameplates"

local PV_PAD = 16       -- header room above and below the preview
local PV_BOX_H = 230    -- the preview's height when the runtime gives none

-- The frame the preview was last drawn in (the page's header builds a new one),
-- and the resize that follows the scene's height (set by the header builder).
local previewHost
local syncHeader

-------------------------------------------------------------------------------
--  Preview header
-------------------------------------------------------------------------------
-- The room the scene needs, in tens so a slider drag resizes the header only
-- now and then.
local function BoxHeight(hdr)
    local OCT = EllesmereUI.OutgoingCombatText
    local h = OCT and OCT.PreviewHeight and OCT.PreviewHeight(hdr)
    if type(h) ~= "number" then return PV_BOX_H end
    return math.ceil(h / 10) * 10
end

local function HeaderBuilder(hdr)
    local OCT = EllesmereUI.OutgoingCombatText
    local height = BoxHeight(hdr) + 2 * PV_PAD
    local box = CreateFrame("Frame", nil, hdr)
    box:SetFrameLevel(hdr:GetFrameLevel() + 2)
    box:SetPoint("TOPLEFT", hdr, "TOPLEFT", EllesmereUI.CONTENT_PAD, -PV_PAD)
    box:SetPoint("BOTTOMRIGHT", hdr, "BOTTOMRIGHT", -EllesmereUI.CONTENT_PAD, PV_PAD)
    previewHost = box
    if OCT and OCT.Preview then OCT.Preview(box) end
    syncHeader = function()
        if not (hdr:IsVisible() and previewHost == box) then return end
        local h = BoxHeight(hdr) + 2 * PV_PAD
        if h ~= height then
            height = h
            EllesmereUI:UpdateContentHeaderHeight(h)
        end
    end
    return height
end

function _G._EUI_CombatTextHeaderBuilder()
    return HeaderBuilder
end

-- A cached page came back: the preview plays again in its header.
function _G._EUI_CombatTextRefreshHeader()
    local OCT = EllesmereUI.OutgoingCombatText
    if previewHost and OCT and OCT.Preview then OCT.Preview(previewHost) end
    if syncHeader then syncHeader() end
end

-- Another page or module is shown: the preview stops.
function _G._EUI_CombatTextHidePreview()
    local OCT = EllesmereUI.OutgoingCombatText
    if previewHost and OCT and OCT.PreviewHide then OCT.PreviewHide(previewHost) end
end

-------------------------------------------------------------------------------
--  Number Morph tag on a section header
-------------------------------------------------------------------------------
local function NumberMorphOn()
    local HA = EllesmereUI.HealthAnimations
    return HA and HA.NumberMorphActive and HA.NumberMorphActive() and true or false
end

-- A badge after the header's title (the same badge as the tag on the Health
-- Animations page); it shows only while Number Morph is active, and a click
-- opens Health Animations on the Nameplates look.
local function AddNumberMorphTag(hdr)
    if EllesmereUI._prebuilding then return end
    local label = hdr and hdr._label
    if not label then return end
    local badge = EllesmereUI.BuildStatusBadge(hdr, TAG_TEXT, nil, {
        dot = false,
        tooltip = TAG_TIP,
        onClick = function()
            if EllesmereUI.HealthAnimationsEditLook then
                EllesmereUI.HealthAnimationsEditLook("enemy")
            else
                EllesmereUI:NavigateToElementSettings(GLOBAL_KEY, ANIM_PAGE)
            end
        end,
    })
    badge:SetFrameLevel(hdr:GetFrameLevel() + 3)
    EllesmereUI.PanelPP.Point(badge, "LEFT", label, "RIGHT", 12, 0)
    local function Sync() badge:SetShown(NumberMorphOn()) end
    Sync()
    EllesmereUI.RegisterWidgetRefresh(Sync)
end

-------------------------------------------------------------------------------
--  Page builder (dispatched from the Quality of Life module registration)
-------------------------------------------------------------------------------
local ANIM_VALUES = { straight = "Up", down = "Down", fountain = "Fountain",
    bounce = "Bounce", slide = "Slide", static = "Static" }
local ANIM_ORDER = { "straight", "down", "fountain", "bounce", "slide", "static" }

function _G._EUI_BuildCombatTextPage(pageName, parent, yOffset)
    local W = EllesmereUI.Widgets
    local OCT = EllesmereUI.OutgoingCombatText
    local y = yOffset
    local _, h, hdr
    if not OCT then return math.abs(y) end
    local Get = OCT.Get
    local function Set(key, v)
        OCT.Set(key, v)
        if syncHeader then syncHeader() end
    end

    EllesmereUI:SetContentHeader(HeaderBuilder)
    parent._showRowDivider = true

    local function off() return not Get("enabled") end
    local function Toggle(text, key, tip)
        return { type="toggle", text=text, tooltip=tip,
          disabled=off, disabledTooltip=FEATURE,
          getValue=function() return Get(key) end,
          setValue=function(v) Set(key, v); EllesmereUI:RefreshPage() end }
    end
    local function Dropdown(text, key, values, order)
        return { type="dropdown", text=text, values=values, order=order,
          disabled=off, disabledTooltip=FEATURE,
          getValue=function() return Get(key) end,
          setValue=function(v) Set(key, v) end }
    end
    -- A toggle's color, locked while the feature or that toggle is off
    local function Swatch(rgn, key, colorKey, label)
        EllesmereUI.BuildInlineSwatches(rgn, { {
            disabled = function() return off() or not Get(key) end,
            disabledTooltip = function() return off() and FEATURE or label end,
            getValue = function() local c = Get(colorKey) or {}; return c.r or 1, c.g or 1, c.b or 1 end,
            setValue = function(r, g, b) Set(colorKey, { r = r, g = g, b = b }) end,
        } })
    end
    -- A cog slider row
    local function CogSlider(label, key, lo, hi, step, tip)
        return { type="slider", label=label, min=lo, max=hi, step=step, tooltip=tip,
          get=function() return Get(key) end,
          set=function(v) Set(key, v) end }
    end

    ---------------------------------------------------------------------------
    --  OUTGOING COMBAT TEXT
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "OUTGOING COMBAT TEXT", y);  y = y - h

    local row1
    row1, h = W:DualRow(parent, y,
        { type="toggle", text=FEATURE,
          tooltip="Your damage on the mob you hit and your heals on the group frame. In a group, some of your hits may not show.",
          getValue=function() return not off() end,
          setValue=EllesmereUI.SectionToggleSetValue(function(v) Set("enabled", v) end) },
        Toggle("Show My Healing", "heal"));  y = y - h
    Swatch(row1._rightRegion, "heal", "healColor", "Show My Healing")

    -- Section gate: the rows below exist only while the feature is on (the
    -- toggle's SectionToggleSetValue rebuilds the page).
    if off() then return math.abs(y) end

    local row2
    row2, h = W:DualRow(parent, y,
        Toggle("Show Avoidance", "avoid", "Miss, dodge, parry and the like."),
        Toggle("Icons On Others' Hits", "othersIcons",
            "A spell icon on other players' hits. Needs Spell Icons."));  y = y - h
    Swatch(row2._leftRegion, "avoid", "avoidColor", "Show Avoidance")

    ---------------------------------------------------------------------------
    --  LOOK
    ---------------------------------------------------------------------------
    hdr, h = W:SectionHeader(parent, "LOOK", y);  y = y - h
    AddNumberMorphTag(hdr)

    local lookRow
    lookRow, h = W:DualRow(parent, y,
        { type="slider", text="Combat Text Size", min=10, max=100, step=1,
          disabled=off, disabledTooltip=FEATURE,
          getValue=function() return Get("size") end,
          setValue=function(v) Set("size", v) end },
        Dropdown("Animation", "anim", ANIM_VALUES, ANIM_ORDER));  y = y - h
    EllesmereUI.BuildInlineCog(lookRow._leftRegion, { disabled = off, disabledTooltip = FEATURE,
        title = "Combat Text Size",
        rows = {
            CogSlider("Travel Distance", "rise", 20, 600, 5),
            CogSlider("Duration", "duration", 0.5, 5, 0.1, "Seconds a number moves, then fades."),
            CogSlider("Text Offset", "offset", -300, 300, 1),
            CogSlider("Crit Scale", "critScale", 1, 4, 0.1),
        },
    })

    local fontValues, fontOrder = EllesmereUI.BuildFontDropdownData()
    fontValues["__combat"] = { text = "Combat Text Font" }
    table.insert(fontOrder, 1, "__combat")
    _, h = W:DualRow(parent, y,
        Dropdown("Font", "font", fontValues, fontOrder),
        Dropdown("Outline", "outline",
            { NONE = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick Outline" },
            { "NONE", "OUTLINE", "THICKOUTLINE" }));  y = y - h

    local critValues, critOrder = EllesmereUI.BuildFontDropdownData()
    critValues["__combat"] = { text = "Combat Text Font" }
    critValues["__same"] = { text = "Same as Font" }
    table.insert(critOrder, 1, "__combat")
    table.insert(critOrder, 1, "__same")
    _, h = W:DualRow(parent, y,
        Dropdown("Crit Font", "critFont", critValues, critOrder),
        { type="colorpicker", text="Crit Color", hasAlpha=false,
          disabled=off, disabledTooltip=FEATURE,
          getValue=function() local c = Get("critColor") or {}; return c.r or 1, c.g or 1, c.b or 1, 1 end,
          setValue=function(r, g, b) Set("critColor", { r = r, g = g, b = b }) end });  y = y - h

    local shakeRow
    shakeRow, h = W:DualRow(parent, y,
        Toggle("Spell Icons", "icons", "A spell icon beside each number."),
        Toggle("Shake Crits", "critShake", "Crits shake when they show."));  y = y - h
    EllesmereUI.BuildInlineCog(shakeRow._rightRegion, {
        disabled = function() return off() or not Get("critShake") end,
        disabledTooltip = function() return off() and FEATURE or "Shake Crits" end,
        title = "Shake Crits",
        rows = { CogSlider("Shake Strength", "shakeAmount", 1, 50, 1) },
    })

    local mergeRow
    mergeRow, h = W:DualRow(parent, y,
        Toggle("Merge Fast Hits", "merge",
            "Close hits from one spell share a line with a count. The line shows the last amount."),
        EllesmereUI.BlankRowCfg());  y = y - h
    EllesmereUI.BuildInlineCog(mergeRow._leftRegion, {
        disabled = function() return off() or not Get("merge") end,
        disabledTooltip = function() return off() and FEATURE or "Merge Fast Hits" end,
        title = "Merge Fast Hits",
        rows = {
            CogSlider("Merge Window", "mergeWindow", 0.1, 5, 0.05, "How close hits must land, in seconds."),
            { type="toggle", label="Pop On Merge",
              get=function() return Get("mergePop") end,
              set=function(v) Set("mergePop", v) end },
        },
    })

    ---------------------------------------------------------------------------
    --  DAMAGE
    ---------------------------------------------------------------------------
    hdr, h = W:SectionHeader(parent, "DAMAGE", y);  y = y - h
    AddNumberMorphTag(hdr)

    local dmgRow
    dmgRow, h = W:DualRow(parent, y,
        Toggle("Show My Damage", "damage"),
        Toggle("Color By Spell School", "schoolColor",
            "Non-physical hits take the color of their spell school."));  y = y - h
    Swatch(dmgRow._leftRegion, "damage", "damageColor", "Show My Damage")

    -- Other players' damage: its own color, size, height and motion
    local function othersOff() return off() or not Get("others") end
    local othersAnimValues = { __same = "Same as Animation" }
    for k, v in pairs(ANIM_VALUES) do othersAnimValues[k] = v end
    local othersAnimOrder = { "__same" }
    for i = 1, #ANIM_ORDER do othersAnimOrder[i + 1] = ANIM_ORDER[i] end
    local othersRow
    othersRow, h = W:DualRow(parent, y,
        Toggle("Show Others' Damage", "others",
            "Hits by other players and their pets on mobs near you."),
        { type="dropdown", text="Others' Animation", values=othersAnimValues, order=othersAnimOrder,
          disabled=othersOff,
          disabledTooltip=function() return off() and FEATURE or "Show Others' Damage" end,
          getValue=function() return Get("othersAnim") end,
          setValue=function(v) Set("othersAnim", v) end });  y = y - h
    EllesmereUI.BuildInlineCog(othersRow._leftRegion, {
        disabled = othersOff,
        disabledTooltip = function() return off() and FEATURE or "Show Others' Damage" end,
        title = "Others' Damage",
        rows = {
            CogSlider("Text Offset", "othersOffset", -300, 300, 1),
            CogSlider("Size", "othersScale", 0.5, 3, 0.05),
        },
    })
    Swatch(othersRow._leftRegion, "others", "othersColor", "Show Others' Damage")

    -- Your pet's hits and your DoT ticks: their own color and size
    local lookRow2
    lookRow2, h = W:DualRow(parent, y,
        Toggle("Pet Damage Look", "petLook",
            "Your pet's hits in their own color and size."),
        Toggle("DoT Tick Look", "dotLook",
            "Your DoT ticks in their own color and size."));  y = y - h
    EllesmereUI.BuildInlineCog(lookRow2._leftRegion, {
        disabled = function() return off() or not Get("petLook") end,
        disabledTooltip = function() return off() and FEATURE or "Pet Damage Look" end,
        title = "Pet Damage Look",
        rows = { CogSlider("Size", "petScale", 0.3, 2, 0.05) },
    })
    Swatch(lookRow2._leftRegion, "petLook", "petColor", "Pet Damage Look")
    EllesmereUI.BuildInlineCog(lookRow2._rightRegion, {
        disabled = function() return off() or not Get("dotLook") end,
        disabledTooltip = function() return off() and FEATURE or "DoT Tick Look" end,
        title = "DoT Tick Look",
        rows = { CogSlider("Size", "dotScale", 0.3, 2, 0.05) },
    })
    -- The DoT color: locked while DoT School Color is on
    EllesmereUI.BuildInlineSwatches(lookRow2._rightRegion, { {
        disabled = function() return off() or not Get("dotLook") or Get("dotSchool") end,
        disabledTooltip = function()
            if off() then return FEATURE end
            return Get("dotLook") and "DoT School Color" or "DoT Tick Look"
        end,
        requireState = function()
            return (not off() and Get("dotLook") and Get("dotSchool")) and "disabled" or "enabled"
        end,
        getValue = function() local c = Get("dotColor") or {}; return c.r or 1, c.g or 1, c.b or 1 end,
        setValue = function(r, g, b) Set("dotColor", { r = r, g = g, b = b }) end,
    } })

    -- School colors, as a pair: your DoT ticks and other players' hits
    _, h = W:DualRow(parent, y,
        { type="toggle", text="DoT School Color",
          tooltip="DoT ticks take the color of their spell school. They keep their size.",
          disabled=function() return off() or not Get("dotLook") end,
          disabledTooltip=function() return off() and FEATURE or "DoT Tick Look" end,
          getValue=function() return Get("dotSchool") end,
          setValue=function(v) Set("dotSchool", v); EllesmereUI:RefreshPage() end },
        { type="toggle", text="Others' School Color",
          tooltip="Other players' hits take the color of their spell school.",
          disabled=othersOff,
          disabledTooltip=function() return off() and FEATURE or "Show Others' Damage" end,
          getValue=function() return Get("othersSchool") end,
          setValue=function(v) Set("othersSchool", v); EllesmereUI:RefreshPage() end });  y = y - h

    -- Framework contract: return the positive total content height.
    return math.abs(y)
end
