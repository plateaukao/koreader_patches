--[[
    Cover image optimization patch for color e-ink screens.

    Place this file in the koreader/patches/ directory on your device.
    (Create the patches/ folder if it does not exist.)

    Adds an "Optimize for color e-ink" percentage slider inside the
    Cover Image > Size, background and format menu.

    Applies a combined processing pipeline tuned for color e-ink panels
    (Kaleido, Gallery) without front light:

      1. Gamma lift          – brightens shadows and midtones
      2. Saturation boost    – compensates for washed-out e-ink colors
      3. S-curve contrast    – adds punch without blowing out highlights
      4. Floyd-Steinberg dithering – smoother gradients on limited palettes

      0 % = off (original image)
     30 % = subtle
     50 % = recommended for most color e-ink screens
     80 % = aggressive (very saturated, high contrast)

    Works independently of (or in addition to) the lighten patch.
--]]

local userpatch = require("userpatch")
local Blitbuffer = require("ffi/blitbuffer")
local logger     = require("logger")
local ffi        = require("ffi")
local math_floor = math.floor
local math_exp   = math.exp

--- Round and clamp a value to a uint8 (0-255).
local function clamp8(v)
    v = math_floor(v + 0.5)
    if v < 0 then return 0 elseif v > 255 then return 255 end
    return v
end

--- Build a 256-entry uint8 lookup table that applies gamma lift then S-curve.
--  gamma: > 1.0 lifts shadows (e.g. 1.4-2.0)
--  k:     S-curve steepness (e.g. 4-10, 0 = linear)
local function buildToneLUT(gamma, k)
    local lut = ffi.new("uint8_t[256]")
    -- Pre-compute S-curve endpoint normalization
    local sig_0, sig_range
    if k > 0.01 then
        sig_0     = 1 / (1 + math_exp(k * 0.5))
        sig_range = 1 / (1 + math_exp(-k * 0.5)) - sig_0
    end
    for i = 0, 255 do
        local v = (i / 255) ^ (1 / gamma)       -- gamma lift
        if k > 0.01 then                         -- S-curve contrast
            v = (1 / (1 + math_exp(-k * (v - 0.5))) - sig_0) / sig_range
        end
        lut[i] = clamp8(v * 255)
    end
    return lut
end

--- Apply tone curve (LUT) and saturation boost to an RGB buffer in-place.
--  bpp: bytes per pixel (3 for RGB24, 4 for RGB32)
local function applyToneAndSaturation(raw, stride, w, h, bpp, lut, sat)
    for y = 0, h - 1 do
        local row = raw + y * stride
        for x = 0, w - 1 do
            local p = row + x * bpp
            local r, g, b = lut[p[0]], lut[p[1]], lut[p[2]]
            if sat ~= 1 then
                local L = 0.299 * r + 0.587 * g + 0.114 * b
                r = clamp8(L + sat * (r - L))
                g = clamp8(L + sat * (g - L))
                b = clamp8(L + sat * (b - L))
            end
            p[0], p[1], p[2] = r, g, b
        end
    end
end

--- Floyd-Steinberg error-diffusion dithering in-place.
--  Quantises each channel to `levels` values (e.g. 16 for Kaleido).
local function applyDither(raw, stride, w, h, bpp, levels)
    local step = 255 / (levels - 1)
    -- Two-row error buffers per channel; index offset by 1 so x-1 is safe
    local sz = (w + 2)
    local ec_r = ffi.new("float[?]", sz)
    local ec_g = ffi.new("float[?]", sz)
    local ec_b = ffi.new("float[?]", sz)
    local en_r = ffi.new("float[?]", sz)
    local en_g = ffi.new("float[?]", sz)
    local en_b = ffi.new("float[?]", sz)
    local fill_bytes = sz * ffi.sizeof("float")

    for y = 0, h - 1 do
        ffi.fill(en_r, fill_bytes, 0)
        ffi.fill(en_g, fill_bytes, 0)
        ffi.fill(en_b, fill_bytes, 0)
        local row = raw + y * stride
        for x = 0, w - 1 do
            local p  = row + x * bpp
            local xi = x + 1            -- offset index into error buffers

            -- Original value + accumulated error
            local r = p[0] + ec_r[xi]
            local g = p[1] + ec_g[xi]
            local b = p[2] + ec_b[xi]

            -- Quantise to nearest level
            local qr = clamp8(math_floor(r / step + 0.5) * step)
            local qg = clamp8(math_floor(g / step + 0.5) * step)
            local qb = clamp8(math_floor(b / step + 0.5) * step)

            p[0], p[1], p[2] = qr, qg, qb

            -- Error to distribute
            local er, eg, eb = r - qr, g - qg, b - qb

            -- Right: 7/16
            ec_r[xi + 1] = ec_r[xi + 1] + er * 0.4375
            ec_g[xi + 1] = ec_g[xi + 1] + eg * 0.4375
            ec_b[xi + 1] = ec_b[xi + 1] + eb * 0.4375
            -- Below-left: 3/16
            en_r[xi - 1] = en_r[xi - 1] + er * 0.1875
            en_g[xi - 1] = en_g[xi - 1] + eg * 0.1875
            en_b[xi - 1] = en_b[xi - 1] + eb * 0.1875
            -- Below: 5/16
            en_r[xi] = en_r[xi] + er * 0.3125
            en_g[xi] = en_g[xi] + eg * 0.3125
            en_b[xi] = en_b[xi] + eb * 0.3125
            -- Below-right: 1/16
            en_r[xi + 1] = en_r[xi + 1] + er * 0.0625
            en_g[xi + 1] = en_g[xi + 1] + eg * 0.0625
            en_b[xi + 1] = en_b[xi + 1] + eb * 0.0625
        end
        -- Swap current / next error rows
        ec_r, en_r = en_r, ec_r
        ec_g, en_g = en_g, ec_g
        ec_b, en_b = en_b, ec_b
    end
end

--- Main processing pipeline.  Modifies bb in-place (or returns a converted copy).
local function optimizeForEink(bb, strength)
    if strength <= 0 then return bb end

    -- Determine bytes-per-pixel; convert non-RGB types to RGB32
    local bb_type = bb:getType()
    local bpp
    if bb_type == Blitbuffer.TYPE_BBRGB32 then
        bpp = 4
    elseif bb_type == Blitbuffer.TYPE_BBRGB24 then
        bpp = 3
    else
        local w, h = bb:getWidth(), bb:getHeight()
        local rgb32 = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
        rgb32:blitFrom(bb, 0, 0, 0, 0, w, h)
        bb:free()
        bb = rgb32
        bpp = 4
    end

    local w      = bb:getWidth()
    local h      = bb:getHeight()
    local raw    = ffi.cast("uint8_t*", bb.data)
    local stride = bb.stride

    -- Map strength (0-100) → per-effect parameters
    local t         = strength / 100
    local gamma     = 1.0 + t * 1.0      -- 1.0 → 2.0
    local sat       = 1.0 + t * 0.8      -- 1.0 → 1.8
    local s_curve_k = t * 8.0            -- 0   → 8
    local dither_levels = 16             -- ≈ Kaleido color depth

    -- 1-3: gamma + S-curve (via LUT) and saturation boost
    local lut = buildToneLUT(gamma, s_curve_k)
    applyToneAndSaturation(raw, stride, w, h, bpp, lut, sat)

    -- 4: Floyd-Steinberg dithering
    applyDither(raw, stride, w, h, bpp, dither_levels)

    logger.dbg(string.format(
        "eink-optimize: strength=%d%% gamma=%.2f sat=%.2f curve=%.1f dither=%d",
        strength, gamma, sat, s_curve_k, dither_levels))

    return bb
end

-- ---------------------------------------------------------------------------
-- Patch the coverimage plugin
-- ---------------------------------------------------------------------------
userpatch.registerPatchPluginFunc("coverimage", function(plugin)
    if plugin._eink_optimize_patched then return end
    plugin._eink_optimize_patched = true

    -- Wrap createCoverImage to post-process the saved screensaver file.
    local orig_createCoverImage = plugin.createCoverImage
    plugin.createCoverImage = function(self, doc_settings)
        orig_createCoverImage(self, doc_settings)

        local strength = G_reader_settings:readSetting("cover_image_eink_optimize", 0)
        if strength <= 0 then return end
        if not self:coverEnabled() then return end

        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(self.cover_image_path, "mode") ~= "file" then return end

        local RenderImage = require("ui/renderimage")
        local bb = RenderImage:renderImageFile(self.cover_image_path)
        if not bb then
            logger.warn("eink-optimize: could not load cover image")
            return
        end

        bb = optimizeForEink(bb, strength)

        local ext = self.cover_image_path:match("%.([^.]+)$") or "jpg"
        local fmt = self.cover_image_format ~= "auto" and self.cover_image_format or ext
        if not bb:writeToFile(self.cover_image_path, fmt,
                              self.cover_image_quality, self.cover_image_grayscale) then
            logger.warn("eink-optimize: error writing optimised image to", self.cover_image_path)
        end
        bb:free()
    end

    -- Inject menu entry into Cover Image > Size, background and format.
    local orig_menuEntrySBF = plugin.menuEntrySBF
    plugin.menuEntrySBF = function(self)
        local menu = orig_menuEntrySBF(self)
        local _ = require("gettext")
        local T = require("ffi/util").template
        -- Append at the end of the sub-menu
        table.insert(menu.sub_item_table, {
            text_func = function()
                local val = G_reader_settings:readSetting("cover_image_eink_optimize", 0)
                return T(_("Optimize for color e-ink: %1"),
                    val ~= 0 and (val .. " %") or _("off"))
            end,
            help_text = _(
                "Combined image processing for color e-ink screensavers:\n"
                .. "• Gamma lift (brightens dark areas)\n"
                .. "• Saturation boost (richer colors)\n"
                .. "• S-curve contrast (adds depth)\n"
                .. "• Floyd-Steinberg dithering (smoother gradients)\n\n"
                .. "0 = off, 30 = subtle, 50 = recommended, 80 = aggressive."),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager  = require("ui/uimanager")
                UIManager:show(SpinWidget:new{
                    value = G_reader_settings:readSetting("cover_image_eink_optimize", 0),
                    value_min = 0,
                    value_max = 100,
                    value_step = 5,
                    default_value = 0,
                    title_text = _("Optimize cover for color e-ink"),
                    ok_text = _("Set"),
                    unit = "%",
                    callback = function(spin)
                        G_reader_settings:saveSetting("cover_image_eink_optimize", spin.value)
                        if self:coverEnabled() then
                            self:createCoverImage(self.ui.doc_settings)
                        end
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        })
        return menu
    end

    logger.info("coverimage eink-optimize patch applied")
end)
