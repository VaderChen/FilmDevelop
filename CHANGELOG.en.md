# Changelog

[繁體中文](CHANGELOG.md) · [English](CHANGELOG.en.md) · [日本語](CHANGELOG.ja.md) · [한국어](CHANGELOG.ko.md)

<!-- 由 scripts/release_notes.py 產生；請修改 history.json。 -->

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
