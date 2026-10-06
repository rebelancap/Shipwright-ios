# Installing Ship of Harkinian on Apple Vision Pro

This is an iOS and visionOS build of [Ship of Harkinian](https://github.com/HarbourMasters/Shipwright), Harbour Masters' native Ocarina of Time port, on [libultraship](https://github.com/HarbourMasters/libultraship), rendering natively on Metal. On Apple Vision Pro it plays three ways: a freely resizable 2D window, a stereoscopic 3D mode that puts the game on a world-locked panel in your room, and an immersive first-person VR mode.

## What you need

- Apple Vision Pro on visionOS 2 or later
- Your own Ocarina of Time ROM
- For the prebuilt app: SideStore on the headset, installed with the [visionOS fork of iloader](https://github.com/rebelancap/iloader/releases#release-visionos) on an Apple Silicon Mac
- To build from source: macOS with Xcode and `cmake` (`brew install cmake`)
- For VR mode: PS VR2 Sense controllers, which act as your hands
- Optional: a game controller (Backbone, DualSense, Xbox and others). The window also shows the on-screen touch layout.

## Your game files

Neither this repository nor the app contains any game content. You supply your own Ocarina of Time ROM.

1. Install the app and open it.
2. The app walks you through adding your ROM on first launch. Extraction runs inside the app on the headset; no PC tools or companion app are needed.

A texture pack is optional; the 4K OoT Reloaded pack is the one recommended for Vision Pro. Its `.o2r` goes in *On My Apple Vision Pro → Ship of Harkinian → mods* in the Files app. See [Texture packs](README.md#texture-packs-strongly-recommended) in the README for the download and steps.

## Install the prebuilt app

1. Install SideStore on the headset with the [visionOS fork of iloader](https://github.com/rebelancap/iloader/releases#release-visionos). It runs on an Apple Silicon Mac and pairs with the headset over Wi-Fi: no cable, no Dev Strap, no Xcode.
2. In SideStore, go to *Sources → +* and paste this source, then install Ship of Harkinian:

   ```
   https://raw.githubusercontent.com/rebelancap/harbourmasters-ports/main/apps-visionos.json
   ```

   The app updates from this source when new versions ship.

To install by hand instead, download `soh-*-visionOS.ipa` from the [latest release](https://github.com/rebelancap/Shipwright-ios/releases/latest) and install it through SideStore or AltStore.

## Build from source

From a checkout of this repo:

```sh
scripts/bootstrap.sh          # clone + pin upstream Shipwright (submodules recursive)
scripts/build-oracle.sh       # native macOS build: generates the asset archive
SOH_IOS_TEAM=YOUR_TEAM_ID scripts/build-visionos.sh   # signed Apple Vision Pro build
```

`scripts/build-visionos.sh` takes your Apple Developer team ID from `SOH_IOS_TEAM` and writes the app to `build-visionos/soh/Release-xros/soh.app`. No ROM is needed for the device build. `scripts/build-oracle.sh` configures CMake with the Ninja generator, so `ninja` needs to be installed as well.

Upstream Shipwright is vendored unmodified and pinned by commit. Every local change is a patch in `overlay/patches/`, applied by `scripts/apply-overlay.sh`; a patch that fails to apply fails the build. Simulator and iPhone builds are in [Building from source](README.md#building-from-source).

## Notes

- Switch between Window, 3D and VR at any time from the ornament under the game window; the game keeps running across the switch. The gear button next to them opens the settings for the current mode.
- Apps sideloaded with a free Apple account expire after 7 days (paid developer accounts last a year). SideStore refreshes them in the background; if the app stops launching, open SideStore and let it re-sign.
- If the app crashes, it writes `crash.txt` and a `logs/` folder to *On My Apple Vision Pro → Ship of Harkinian* in Files. Attach them to a [GitHub issue](https://github.com/rebelancap/Shipwright-ios/issues).
- THE LEGEND OF ZELDA: OCARINA OF TIME is © Nintendo. This project is not affiliated with or endorsed by Nintendo, and ships no Nintendo content.
