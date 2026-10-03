# Changelog

[繁體中文](CHANGELOG.md) · [English](CHANGELOG.en.md) · [日本語](CHANGELOG.ja.md) · [한국어](CHANGELOG.ko.md)

<!-- 由 scripts/release_notes.py 產生；請修改 history.json。 -->

## 1.26.1004 build 0036

Compared with: **1.26.1003 build 1503**。

- **Improved**：Skin smoothing now uses multiple luminance scales to reduce local unevenness while retaining fine texture, undertones and facial shading. Mid-to-high slider settings are stronger, and the blend strength no longer reaches its cap early.
- **Improved**：Skin brightening now uses a lightness curve that preserves individual undertones instead of uniformly reducing saturation and contrast. Stronger slider response retains protection for highlights, black, HDR and alpha.
- **Fixed**：Improve underexposed skin detection and remove residual skin effects outside the person mask and in fully transparent areas. Protect strongly red details and reapply confidence exclusions after mask refinement.
- **Fixed**：Align edge-preserving channel-wise denoising across platforms, fixing weak midrange response and color contamination from transparent pixels. Effect blending preserves source coverage so semi-transparent images do not become more opaque.
- **Fixed**：Use a shared monotonic luminance curve for tonal-zone fade, preventing adjacent tones from reversing under strong shadow fade while retaining existing zone controls and workflow.
- **Fixed**：HDR log-luminance reconstruction preserves black and near-black gradations, avoiding lifted blacks or clipped shadows from numerical stabilization. Custom black-level controls and floating-point highlights remain available.
- **Improved**：Align guided-filter sampling coordinates and upsampling to reduce differences between previews, exports and tiled rendering. Keep small coefficient images on the GPU within existing cache limits to avoid CPU readback and re-upload.
- **Improved**：Make the photo export reveal smoother with display-synchronized frames, a shorter minimum reveal of 6.2 seconds instead of 7, continuous motion between sparse progress reports, and a gradual finish. Preserve the existing dialog, workflow and preview memory limit.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1503...v1.26.1004-build-0036) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1004-build-0036/desktop/RESTORATION.md)

## 1.26.1003 build 1503

Compared with: **1.26.1003 build 1300**。

- **Improved**：Optimize recipe editing, validation and custom-film defaults by reducing repeated JSON decoding, copying and allocations, preserving features, layout and workflow.
- **Improved**：Validate mask assets and compare existing imports with a streaming buffer capped at 64 KiB, retaining full content, dimensions and SHA-256 checks.
- **Improved**：Score each model-pairing candidate once and build natural-sort keys once per photo, retaining pairing decisions, tie handling, ordering and thumbnail identities.
- **Improved**：Optimize CPU Gaussian sampling while preserving floating-point precision, weights and accumulation order. All 114 bit-exact cases pass on both macOS and Windows; 10 exports per Windows CPU/Vulkan backend match build 1300 byte for byte.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1300...v1.26.1003-build-1503) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1503/desktop/RESTORATION.md)

## 1.26.1003 build 1300

Compared with: **1.26.1003 build 1109**。

- **Fixed**：Fix external-volume JPEG export failures and restore single-image and MCP development dialogs, batch counts and stage progress while protecting source photos.
- **Fixed**：Fix 12 additional Swift migration gaps in preset reselection, reset history, preview retry, repair cancellation, portrait crop labels, prompt language, the 8-bit PNG default, custom-film save/copy/delete/export, and RAW-switch rollback.
- **Fixed**：Retain the previous 13 fixes, including seven-stage AI progress and cancellation, mask validity, MCP export settings, multi-photo reset, duplicate selection and native drag-and-drop.
- **Fixed · Windows**：Hide MLX from Windows download and local-model selectors and default to GGUF. Reject unsupported MLX downloads; retain existing files with a compatibility explanation. Match named mmproj files in shared directories and reject ambiguous pairs.
- **Improved**：Reduce allocations in state snapshots and edit history by sharing immutable image and repair data and releasing evicted references, preserving image processing and interface layout.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1109...v1.26.1003-build-1300) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1300/desktop/RESTORATION.md)

## 1.26.1003 build 1109

Compared with: **1.26.1003 build 1026**。

- **Fixed**：Fixed the silent wait when migrating from FilmYourPhoto. A startup dialog shows settings, legacy records, folder scanning and photo-adjustment stages, with actual item counts and a progress bar when totals are known. It closes automatically when ready, preserving original photos and legacy data.
- **Fixed**：Fixed duplicate Cancel and Cancel download buttons in update downloads, and duplicate Cancel and Close actions in information dialogs. Shared dialogs no longer add a fallback Cancel when a dismiss action is already provided.
- **Fixed**：Completed four-language titles, descriptions, buttons, and progress messages for shared dialogs. Closing a window is distinguished from the Off setting; filenames, model names, and user input remain unchanged.
- **Fixed**：Blank names cannot be submitted by the confirmation button or Enter. Dialog key events no longer reach background crop, repair, and original-comparison controls, and focus returns to the original control when it remains available.
- **Improved**：Prompt editing now uses a native modal dialog to keep focus out of the background. UI state refreshes preserve the draft, and cancelling returns focus to the original edit control.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-1026...v1.26.1003-build-1109) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1109/desktop/RESTORATION.md)

## 1.26.1003 build 1026

Compared with: **1.26.1003 build 0924**。

- **Added**：When the current photo requires a separately installed Adobe DNG Converter, a confirmation dialog now appears automatically. Confirming opens Adobe’s official download page in the system default browser, replacing the previous footer-only prompt.
- **Improved**：Cancelling preserves the current view and does not repeatedly prompt when retrying the same photo. The footer can reopen the dialog. Prompts wait for other dialogs, ignore stale photos and unrelated errors, and include all four interface languages.
- **Fixed**：The update download dialog now includes a progress bar synchronized with percentage and size from 0%, staying full during package verification. Cancellation clears temporary files, and stale download events cannot affect a newer dialog.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0924...v1.26.1003-build-1026) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-1026/desktop/RESTORATION.md)

## 1.26.1003 build 0924

Compared with: **1.26.1003 build 0018**。

- **Fixed**：Added a shared decoding fallback for Nikon HE/HE* NEF and GoPro GPR on Mac and Windows. When the system or LibRaw lacks a decoder, an installed Adobe DNG Converter creates a lossless RAW cache.
- **Added**：When the additional decoder is missing, the photo footer offers Adobe’s official download page and a check-again action. Users complete Adobe’s installation themselves. FilmDevelop does not bundle the converter or automatically open an installation dialog during preview.
- **Fixed**：GPR is now recognized by photo import and both RAW engines. Files without a usable embedded thumbnail can use the supplemental decoder, and checking again after installation restores failed list thumbnails.
- **Improved**：Supplemental decoding preserves original photos, edit identities and capture EXIF. The cache validates content, has a size limit, supports cancellation and is removed on exit. Shared LibRaw still develops the full sensor data; camera JPEGs are not used as editing sources.
- **Improved**：Validated 141 preview/export operations across 47 RAW files on Mac, 60 operations across 20 files on Windows, and 42 Windows System-mode operations. EXIF, dimensions and pixel differences are documented; unknown formats, JPEG XL/Enhanced DNG and pixel identity remain limited.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1003-build-0018...v1.26.1003-build-0924) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0924/desktop/RESTORATION.md)

## 1.26.1003 build 0018

Compared with: **1.26.1002 build 2330**。

- **Fixed**：The update-complete dialog now lists actual additions, fixes and improvements, with a comparison version, in the selected interface language.
- **Fixed**：When skipping versions, changes are grouped by release. If another dialog is open, the update summary is delivered again after it closes.
- **Improved · Windows**：The Windows portable ZIP omits C++ debug data while retaining the existing image algorithms, lookup tables, models and Microsoft runtime.
- **Added**：Added a version-by-version changelog. README summaries, in-app notes and GitHub releases share one four-language source, including the changes from build 1323 to build 2330.
- **Improved**：The full release workflow clears the project dist directory once before building Mac and Windows in sequence, and validates release notes and the artifact list.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1002-build-2330...v1.26.1003-build-0018) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1003-build-0018/desktop/RESTORATION.md)

## 1.26.1002 build 2330

Compared with: **1.26.1002 build 1323**。

- **Fixed**：Aligned framing across list thumbnails, editing thumbnails and full previews to prevent a sudden zoom during photo transitions.
- **Improved**：Reused bounded caches and C++ worker threads. Mac software RAW editing previews use half-size decoding, while full-resolution previews and exports retain full decoding.
- **Improved**：Shared emulsion-crystal calculations with boundary recalculation, retaining four samples, three layers and FP32. The measured emulsion stage is about 30–35% faster; this is not an end-to-end preview speedup.
- **Added · Windows**：Windows now ships as a portable ZIP: extract all files and run. It includes 12 original Microsoft VC++ x64 runtime DLLs; WebView2 is still required.
- **Added · Windows**：The Windows portable app can update in place, verifying ZIP and per-file SHA-256, preserving additional files and rolling back on startup failure. Existing setup users must manually download the ZIP for the first transition.
- **Fixed**：Fixed Swift Sendable warnings and build-system compatibility, and extended Windows CPU/Vulkan image and update validation.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.1002-build-1323...v1.26.1002-build-2330) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1002-build-2330/desktop/RESTORATION.md)

## 1.26.1002 build 1323

Compared with: **1.26.0930 build 1745**。

- **Added**：Introduced a shared Go/Wails desktop and Windows x64 Beta; Mac retains the Swift/C++ image engine.
- **Fixed · macOS**：Restored direct updates from the Swift Mac app. The FilmYourPhoto bridge migrates the installation identity on first launch; subsequent updates use the standard FilmDevelop package.
- **Added**：Migrated Swift photo edits, ratings, categories and custom films, with migration records and database export/import/relocation while preserving existing newer data.
- **Added**：Added crop reset and Write EXIF enabled by default, matching Swift export names, with conventional context menus, colored dialog actions, compact lists and custom-film selection fixes.
- **Improved**：RAW and compute acceleration default to System and persist preferences; Windows probes Vulkan GPUs with CPU fallback. Reduced duplicate package resources and audited private paths.

[Source comparison](https://github.com/VaderChen/FilmDevelop/compare/v1.26.0930-build-1745...v1.26.1002-build-1323) · [Validation record](https://github.com/VaderChen/FilmDevelop/blob/v1.26.1002-build-1323/desktop/RESTORATION.md)

[Swift · Changelog (繁體中文)](CHANGELOG.swift.md)
