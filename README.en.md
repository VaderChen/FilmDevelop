# FilmDevelop

Print/viewing exposure defaults to ±8 EV, or ±16 EV with Extended exposure enabled. Disabling it preserves existing out-of-range values.

[繁體中文](README.md) · [English](README.en.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

![FilmDevelop](demo.gif)

A film-inspired photo editor for Apple Silicon Mac. Open a photo folder, choose a film, adjust development, scanning and tones, then export. Photo editing and AI-assisted adjustments run locally.

Requires macOS 14 or later. AI features require a compatible local model, downloaded separately.


## Development updates (unreleased)

The source now includes material defaults for all 23 core film stocks, four print recipes below Print Illuminant, and a separate Silver Density section. Film Default preserves the original paper settings. Printing and scanning can be combined: print the film first, then scan the photo. These features are not yet included in the release listed below.

## Latest changes — 1.26.0925 build 1416

Six artistic scan styles are available: Neutral, Warm, Soft Portrait, Vivid, Cool Clean and Faded Vintage. They are not measured commercial-scanner profiles. GR digital camera simulations force scanning off and disable the entire panel, including for old recipes and exports. Film stocks and Original retain scanning support; with default controls, Neutral and Off look identical on Original.

All 74 workbench adjustment controls have help. Click an underlined label, or focus it and press Enter/Space; Escape closes it. “Show help automatically” only controls automatic hints: clicking still works when it is off. Help clicks and double-clicks do not change or reset values. Original is hidden from the film-library list, always available in the workbench, and selected on first launch.

Exposure adjusts linear luminance before film color processing: ±8 EV normally, ±16 EV with expansion. Highlight protection applies only when enabled and cannot recover clipped source detail. Portra 800 saturation ordering, Lomo Purple red preservation and fixed tungsten casts on white-balanced inputs have been refined; these remain qualitative approximations.

On first launch, `run.command` downloads missing llama.cpp/libwebp submodules; network access and full Xcode are required. Restart an already-open app after rebuilding to load the updated interface.

## Download and languages

Download the Apple Silicon DMG from [GitHub Releases](https://github.com/VaderChen/FilmDevelop/releases/latest), open it, and drag `照片沖洗.app` into Applications. Official installers are Developer ID signed and notarized by Apple.

The interface supports Traditional Chinese, English, Japanese and Korean. Choose a language in Settings or use automatic detection. Native menus, dialogs, film descriptions, tips and progress messages follow your selection. Filenames, custom film names and user prompts remain unchanged.

## Features

- **Film collection:** color negative, cinema negative, slide, monochrome, instant and special processes. All are selected by default; choose which appear in your workspace. The collapsible sidebar remembers its state.
- **Original:** the first collection item preserves the source exposure and tones without a film effect.
- **Development and scanning:** adjust grain, development, glow, halation, exposure and contrast. Choose neutral scanning or warm midtones with cool highlights.
- **Digital adjustments:** adjust the overall image, highlights, midtones and shadows separately.
- **Crop and rotation:** source ratio, free crop and common ratios; drag outside a corner to rotate.
- **Undo and redo:** use the buttons beside Choose Folder. A continuous slider drag counts as one step.
- **Per-photo memory:** film selection, manual adjustments and AI results stay with each photo. Reopening does not automatically rerun AI.
- **Frames and dates:** add borders and retro-camera date imprints in either adjustment mode.

## Getting started

1. Choose a folder and open a thumbnail, or drag in a photo.
2. Select a film in the sidebar, or Original to begin with the source appearance.
3. Choose Film or Digital on the right. Film contains Develop, Scan and Frame; Digital contains Overall, Highlights, Midtones, Shadows and Frame.
4. Run AI Assistance if desired, or adjust manually.
5. Export the result. Export is calculated from the original photo, not a preview thumbnail.

### Browsing and preview

Thumbnails come in three sizes and load only within the visible area, showing a spinner while loading. Arrow buttons scroll one thumbnail; the mouse wheel scrolls three without changing the active photo. The last folder, photo and thumbnail position are remembered.

Scroll over the preview to zoom; drag with the left mouse button to pan. The minimum zoom fits the window. Hold Space or the comparison button to see the original. Press the photo for 0.8 seconds to display the RGB histogram at the upper left; close it with ×. The histogram uses the current preview.

Hover over a sidebar film to preview it using a small image, including collapsed icons and custom films. Moving away or switching windows restores the current photo. Hover previews do not create edit steps, mark the photo as edited or affect exports; click to apply a film.

### Cropping

The menu offers Off, Source Ratio, Free Crop and common ratios. Source Ratio locks the original aspect ratio; fixed ratios adapt to portrait or landscape orientation.

Drag inside the crop to move it, handles to resize, or outside a corner to rotate. Done applies the crop. Cancel or Off discards the current unfinished changes while preserving previously completed crops.

Cropping uses a fast preview with the same fit-to-window behavior as normal editing. The completed result is calculated from the original; display previews have a maximum long edge of 2048 px.

### Repair brush

Use the eraser icon to the left of Crop, set the brush size in the top toolbar, and paint over an unwanted object. Releasing the mouse applies the repair automatically. Choose Done to return to the current film look. Repairs support undo/redo, are saved per photo, and are included in previews and full-resolution exports without changing the original file. Reset to defaults immediately removes applied repairs.

Clicking the eraser checks the local model before enabling the brush. On first use it downloads the approximately 217 MB LaMa model in a cancellable progress dialog showing percentage and downloaded bytes. Model preparation then continues automatically. Once cached, repairs work offline using Core ML on Apple Silicon; photos are not uploaded. Inspect large repairs for blurred or unnatural details.

### Skin and rendering controls

Skin warmth sits between lens blur and whitening: −100 is cooler, +100 warmer, and 0 neutral. It affects only the skin mask and supports per-photo saving, undo/redo, and reset. Smoothing now uses an edge-preserving guided filter without a separate model download. Noise reduction runs before film grain, and vignette compensation preserves black levels.

HDR can be adjusted without an AI tone curve. Lens blur respects crop and depth alignment and reduces subject-edge color bleeding. Print illuminant is available in scan and reversal modes through output color compensation; Original Reference preserves the existing color. Non-scanned negatives retain spectral printing. The export button now uses the accent color.

### Adjustments and AI

Film intensity defaults to 50. All built-in films, including Original, default to neutral scanning. Exposure and contrast remain available under Develop while scanning is enabled. Positive exposure brightens and negative darkens. Raising EV gently compresses highlights; lowering EV protects shadow detail. Zero EV leaves the appearance unchanged. Scan controls color density, layer separation, scanner flare and midtone/highlight warmth.

Opening a photo does not start AI. Select a compatible local model, then run AI Assistance. Analysis can be cancelled and its results adjusted manually. Judge the result by your photo.

Double-click a slider's adjustment area to reset that value to the current film's default without changing other controls. This can be undone.

Reset to Defaults restores the film's adjustments and clears undo/redo history and the thumbnail's red edit marker. Custom films return to their saved recipe. New edits clear the redo branch. History lasts only for the current photo-editing session; switching photos or restarting clears history, but saved photo adjustments remain.

### Settings and privacy

Feature tips are enabled by default. Hover over headings for help; you can disable automatic tips and still click headings to read them. Edit at Original Resolution increases editing resolution; turning it off improves responsiveness. Both modes export from the original.

Photos, models and adjustment records stay local. Model searches, downloads and update checks require internet access; analyzing with downloaded models does not upload photos. Advanced users can enable or disable the local external-control service. Its connection settings include an access token: do not share or commit them.

### App updates

Check for Updates appears on the same line as the Settings heading, aligned with the card's right edge. It checks the latest stable GitHub Release. Downloads show progress and file size and can be cancelled. The app verifies the installer, saves adjustments, installs the update and restarts.

The app also checks at launch and only notifies you when an update is available. Offline checks or missing releases do not interrupt editing. Install in a writable Applications folder to use updates. Versions use `1.YY.MMdd build HHmm`, for example `1.26.0924 build 0109`, in Taiwan time.

Updates come from [FilmDevelop Releases](https://github.com/VaderChen/FilmDevelop/releases). A public repository and stable release with an installer are required. Tags use `v1.YY.MMdd-build-HHmm`; assets use `FilmYourPhoto-1.YY.MMdd-build-HHmm-arm64.dmg`. The local packaging tool generates matching names from the build version.

If an early version reports “Update Incomplete” after downloading, download the installer from [GitHub Releases](https://github.com/VaderChen/FilmDevelop/releases/latest), quit the old app and reinstall once. Saved photo adjustments and custom films are preserved. Newer versions handle renamed apps more reliably and provide clearer explanations when an update fails.

## Build and run

```sh
git clone --recurse-submodules https://github.com/VaderChen/FilmDevelop.git
cd FilmDevelop
./run.command
```

Full Xcode is required; initial setup may download build dependencies. You can also double-click `run.command` in Finder. In-app updates restart automatically; quit the old app before running a new source build.

## Additional notes

Film and scanner appearances are simulations, not manufacturer-measured reproductions of individual films or scanners.

Tests, research documents (`doc/`, `docs/`) and build/temporary outputs stay on the developer's machine and are excluded from the public repository. Required third-party submodules remain recorded; scripts invoked by `run.command` generate build artifacts.

Right-click the preview for undo, redo, reset, histogram, source-ratio/free crop, export, Reveal in Finder and Move to Trash.

PNG defaults to 8-bit RGB without transparency. Transparent edges are filled with the same black background as the preview.

The development animation reuses the current photo’s completed preview cache (up to 2048 px on the long edge) and follows native processing progress. It does not process the original again or decode the exported file for the animation. The exported file still uses the original resolution.

During export, a central dialog reveals the photo gradually from black, like developing film. Timing follows photo size, format, previous export durations and actual processing/saving progress. The finished image appears only after saving. Fast exports still show roughly seven seconds of animation; saving does not wait for it.

A red dot marks edited thumbnails and disappears after resetting. Original also supports scanning, color density, flare and warmth adjustments. Once the preview is ready, use the eyedropper beside Crop to sample a gray or white area for white balance; Esc cancels sampling.

Use the save icon above intensity to name and save all current adjustments as a custom film. Delete on its card removes the recipe while preserving adjustments already applied to photos. Recipes remain on this Mac across launches; subsequent photo edits do not overwrite them. Switching custom films preserves built-in films' adjustments. The library separates custom and built-in films; the workspace lists Original first, then custom and built-in films. Collapsed sidebar icons remain clickable.

## Emulsion, development and print materials

New controls cover color-layer curves and inhibition, film width (8–120 mm), grain-size distribution, emulsion detail loss, virtual exposure time (0.0001–3600 s) and reciprocity loss, anti-halation absorption, additional silver density, developer temperature (10–40°C) and activity, and paper material, scatter, white and maximum density. They are artistic approximations, not measured manufacturer film, chemistry, paper or scanner profiles. Developer temperature is a relative model, not a processing-time recommendation; virtual exposure does not read or change EXIF.

All 23 core stocks, including five retained for legacy recipes, have conservative material defaults. Existing saved recipes are not overwritten. Missing fields retain the old neutral values: film width 36 mm, paper white 100, anti-halation 50, temperature 20°C and activity 100. CineStill 800T uses anti-halation 35 and halation 28 to keep red return energy near its previous baseline. Bleach Bypass retains its built-in silver effect; SX-70 keeps its original low print density under Film Default.

### Print recipes and photo scanning

In Development, Print Recipe appears immediately below Print Illuminant. It defaults to Film Default. Selecting a recipe preserves scan on/off, scan style, exposure and film settings, and selects Printed Photo as the scan source. Reversal film, Original and digital camera looks do not use print recipes.

| Recipe | Paper | Scatter | Paper white | Black-density offset |
| --- | --- | ---: | ---: | ---: |
| Film Default | reference | 0 | 100 | 0 |
| Glossy Print | glossy | 4 | 100 | 0 |
| Soft Matte | matte | 22 | 96 | 0 |
| Warm Fiber | warmFiber | 14 | 94 | 0 |

Fine-tuning the paper controls shows Custom Print when the values no longer match a recipe. Save the result as a custom film; actual values persist with photos and recipes and support undo/redo.

Scan Source selects direct Film scanning or **film → optical print → paper effects → photo scan**. Photo scanning retains paper white, density and scatter, then applies scan style, color and flare. It does not repeat exposure or invert negative dyes; layer-separation correction is disabled. With scanning off, the result is the print itself. Direct film scans and reversal film bypass paper controls. Old recipes default to direct film scanning. Photo scanning is an artistic positive-image model, not a measured reflective scanner.

### Silver density

The separate Silver Density section displays Film Default when additional silver is 0. The 0–100 slider adds neutral silver density and affects printing and both scan paths. Film Default clears only this extra adjustment, preserving the stock's own silver, including Bleach Bypass, and leaving paper, exposure and scanner settings intact.

MCP `update_adjustments` accepts `printRecipe` (`reference`, `glossy`, `matte`, `warmFiber`), `scannerSource` (`film`, `paper`) and `silverRetention` (0–100). Explicit adjustments in the same batch run after a recipe. Saved/AI JSON uses `scanner_source` and `silver_retention` within `film_effects`. The print recipe is stored as its paper values, not a separate recipe identifier.

## License

Copyright (C) 2026 VaderChen. The [source-available, no-commercial-sales license](LICENSE.en.md) permits free acquisition, use, study, modification and free sharing, including internal company/organization use. It prohibits selling the software, paid hosting/SaaS, paid services, paid-product integration, and charges for installation, customization, support or maintenance.

Arrangements prohibited by the license require separate written permission from the copyright holder; an inquiry alone grants no permission. See the [commercial-sales policy](COMMERCIAL-LICENSE.md). This is source-available software with commercial-sales restrictions, not an OSI-approved open-source license.

Full terms: [繁體中文](LICENSE.md) · [English](LICENSE.en.md) · [日本語](LICENSE.ja.md) · [한국어](LICENSE.ko.md). The Traditional Chinese text prevails if translations differ.

Third-party libraries and models retain their own licenses; see [Third-party notices](THIRD_PARTY_NOTICES.md). Using the app does not apply its software license to your photos or exported images. Terms are adapted from [YourDesk](https://github.com/VaderChen/YourDesk/blob/539f3f266cc31cce6958f08826bc27653c98282f/LICENSE.md), with the project name changed to FilmDevelop.
