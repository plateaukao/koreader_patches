# KOReader User Patches

A collection of [KOReader](https://github.com/koreader/koreader) user patches for e-ink devices.

## Installation

1. Connect your e-ink device (or access its filesystem).
2. Navigate to the `koreader/` directory.
3. Create a `patches/` folder if it doesn't already exist.
4. Copy the desired `.lua` patch files into `koreader/patches/`.
5. Restart KOReader.

## Patches

### 2-coverimage-lighten.lua

Adds a **"Lighten for color e-ink"** slider to the Cover Image plugin's *Size, background and format* menu. Blends the saved screensaver cover image with white so it looks better on color e-ink screens without a front light.

| Setting | Effect |
|---------|--------|
| 0 % | Off (original colors) |
| 30 % | Subtle lightening |
| 50 % | Medium (recommended for most color e-ink screens) |
| 70 % | Very light |

## Writing Your Own Patches

KOReader's user patch system loads `.lua` files from the `patches/` directory at startup. Patches use `userpatch.registerPatchPluginFunc(plugin_name, callback)` to monkey-patch existing plugin methods. See the existing patches for the pattern.

File names are prefixed with a number (e.g., `2-`) to control load order.

## License

These patches interact with KOReader, which is licensed under the [AGPL-3.0](https://github.com/koreader/koreader/blob/master/COPYING).
