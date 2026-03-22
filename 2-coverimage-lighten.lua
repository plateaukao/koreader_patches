--[[
    Cover image lightening patch for color e-ink screens.

    Place this file in the koreader/patches/ directory on your device.
    (Create the patches/ folder if it does not exist.)

    Adds a "Lighten for color e-ink" percentage slider inside the
    Cover Image > Size, background and format menu.
    Blends the saved screensaver image with white so it looks better
    on color e-ink without front light.

    0 % = off (original colors)
    30 % = subtle lightening
    50 % = medium (recommended for most color e-ink screens)
    70 % = very light
--]]

local userpatch = require("userpatch")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")

--- Blend bb onto a white background at (100 - lighten_percent) opacity.
-- Frees the original bb and returns the lightened buffer.
local function lightenBlitBuffer(bb, lighten_percent)
    if lighten_percent <= 0 then return bb end
    local w, h = bb:getWidth(), bb:getHeight()
    local result = Blitbuffer.new(w, h, bb:getType())
    result:fill(Blitbuffer.COLOR_WHITE)
    -- alpha = opacity of the original image; lower = lighter result
    result:addblitFrom(bb, 0, 0, 0, 0, w, h, 1.0 - lighten_percent / 100.0)
    bb:free()
    return result
end

userpatch.registerPatchPluginFunc("coverimage", function(plugin)
    -- The plugin class object is reused across book opens; only patch it once.
    if plugin._lighten_patched then return end
    plugin._lighten_patched = true

    -- Patch createCoverImage: lighten the saved file after the original runs.
    -- Works for both cache-hit and cache-miss paths because we always run
    -- after orig_createCoverImage returns, and the file is already written.
    local orig_createCoverImage = plugin.createCoverImage
    plugin.createCoverImage = function(self, doc_settings)
        orig_createCoverImage(self, doc_settings)

        local lighten_percent = G_reader_settings:readSetting("cover_image_lighten", 0)
        if lighten_percent <= 0 then return end
        if not self:coverEnabled() then return end

        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(self.cover_image_path, "mode") ~= "file" then return end

        local RenderImage = require("ui/renderimage")
        local bb = RenderImage:renderImageFile(self.cover_image_path)
        if not bb then
            logger.warn("coverimage-lighten: could not load saved cover image")
            return
        end

        bb = lightenBlitBuffer(bb, lighten_percent)

        -- Determine actual format from the file extension when set to "auto"
        local ext = self.cover_image_path:match("%.([^.]+)$") or "jpg"
        local act_format = self.cover_image_format ~= "auto" and self.cover_image_format or ext

        if not bb:writeToFile(self.cover_image_path, act_format,
                              self.cover_image_quality, self.cover_image_grayscale) then
            logger.warn("coverimage-lighten: error writing lightened image to", self.cover_image_path)
        end
        bb:free()
        logger.dbg("coverimage-lighten: applied", lighten_percent, "% lightening to", self.cover_image_path)
    end

    -- Patch menuEntrySBF to inject a lighten percentage spinner.
    -- Inserted as the second entry (after "Aspect ratio stretch threshold").
    local orig_menuEntrySBF = plugin.menuEntrySBF
    plugin.menuEntrySBF = function(self)
        local menu = orig_menuEntrySBF(self)
        local _ = require("gettext")
        local T = require("ffi/util").template
        table.insert(menu.sub_item_table, 2, {
            text_func = function()
                local val = G_reader_settings:readSetting("cover_image_lighten", 0)
                return T(_("Lighten for color e-ink: %1"),
                    val ~= 0 and (val .. " %") or _("off"))
            end,
            help_text = _("Blend the cover with white before saving as screensaver. "
                .. "Useful for color e-ink screens without front light. "
                .. "0 = off, 30 = subtle, 50 = medium."),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager = require("ui/uimanager")
                UIManager:show(SpinWidget:new{
                    value = G_reader_settings:readSetting("cover_image_lighten", 0),
                    value_min = 0,
                    value_max = 70,
                    default_value = 0,
                    title_text = _("Lighten cover image"),
                    ok_text = _("Set"),
                    unit = "%",
                    callback = function(spin)
                        G_reader_settings:saveSetting("cover_image_lighten", spin.value)
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

    logger.info("coverimage-lighten patch applied")
end)
