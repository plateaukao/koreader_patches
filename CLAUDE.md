# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A collection of KOReader user patches — standalone Lua scripts that users drop into the `koreader/patches/` directory on their e-ink devices. Each file is a self-contained patch; there is no build system, test framework, or dependency manager.

## Conventions

- **File naming**: Patches are numbered with a prefix (e.g., `2-coverimage-lighten.lua`). The number controls load order within KOReader's patch system.
- **Language**: Lua, targeting KOReader's LuaJIT runtime.
- **Patch mechanism**: Patches use `userpatch.registerPatchPluginFunc(plugin_name, callback)` to monkey-patch existing KOReader plugin methods at runtime. The pattern is to capture the original method, replace it with a wrapper that calls the original, then extends behavior.
- **Settings**: Persistent settings use `G_reader_settings:readSetting(key, default)` / `G_reader_settings:saveSetting(key, value)`.
- **UI**: Menu entries and widgets come from KOReader's `ui/widget/` modules (e.g., `SpinWidget`, `UIManager`). Localization uses `require("gettext")`.
- **Image processing**: Uses KOReader's `ffi/blitbuffer` for pixel-level image manipulation.

## Adding a New Patch

Create a new numbered `.lua` file at the repo root. Include a header comment block explaining what the patch does, where to install it, and how to configure it. Follow the existing pattern: `userpatch.registerPatchPluginFunc` wrapping original plugin methods.
