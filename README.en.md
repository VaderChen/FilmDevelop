# FilmDevelop

Give your photos a film look you love. Pick a film, adjust exposure, color and grain, then export your work.

[繁體中文](README.md) · [English](README.en.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

![FilmDevelop](demo.gif)

## Get the app

[Download for Mac and Windows](https://github.com/VaderChen/FilmDevelop/releases/latest). Version **1.26.1003 build 1109**; Windows is labeled **Beta**.

Mac requires Apple Silicon and macOS 14+. Open the DMG and drag FilmDevelop into Applications. This release’s DMG and included app are Developer ID signed, Apple notarized and stapled. Windows requires Windows 10/11 x64 and WebView2. Fully extract the x64 portable ZIP and run FilmDevelop.exe. The VC++ x64 Runtime is included; the app is not Authenticode signed.

For the first move from an older Windows setup version, manually download and extract the ZIP into a new folder. Existing settings and edits remain available; later updates can run inside the portable app. ZIP packaging does not guarantee that Windows trust prompts disappear.

The old Swift Mac app can upgrade through Check for Updates. The FilmYourPhoto bridge converts the existing installation to the standard FilmDevelop identity on first launch, without a second download. Subsequent updates use FilmDevelop. The bridge remains available during the transition for old Swift and previous compatibility installations. Recognized edits, ratings, categories and custom films migrate without overwriting newer data. Database export/import supports relocation to another computer; original photos are not included. The interface supports Traditional Chinese, English, Japanese and Korean.

<!-- release-summary:start -->
## What changed

Compared with: **1.26.1003 build 1026**。

- **Fixed**：Fixed duplicate Cancel and Cancel download buttons in update downloads, and duplicate Cancel and Close actions in information dialogs. Shared dialogs no longer add a fallback Cancel when a dismiss action is already provided.
- **Fixed**：Completed four-language titles, descriptions, buttons, and progress messages for shared dialogs. Closing a window is distinguished from the Off setting; filenames, model names, and user input remain unchanged.
- **Fixed**：Blank names cannot be submitted by the confirmation button or Enter. Dialog key events no longer reach background crop, repair, and original-comparison controls, and focus returns to the original control when it remains available.
- **Improved**：Prompt editing now uses a native modal dialog to keep focus out of the background. UI state refreshes preserve the draft, and cancelling returns focus to the original edit control.

[Full changelog](CHANGELOG.en.md)
<!-- release-summary:end -->

## What makes it different

- **Explore the whole film process:** simulate color layers, emulsion grain, developer chemistry, print paper and scanning, with control throughout the process.
- **Start with a classic, make it your own:** Portra, Ektar, VISION3, Velvia, monochrome and special films, plus GR III/GR IV simulations. Save your favorite settings as custom films.
- **Each photo keeps its own edits:** adjustments, crops and repairs stay with the photo. Compare with the original anytime; exports use the source image without overwriting it.
- **Local editing, optional AI:** photos and edits stay on your computer. Download models for offline analysis and repairs, or adjust everything yourself.

## Features at a glance

| Feature | What you can do |
| --- | --- |
| Film collection and custom looks | Pick favorites, reorder them and adjust strength; rename, duplicate, import and export custom films. |
| Development and texture | Adjust time, temperature, agitation, contrast, grain, glow and halation; explore color layers, emulsion, reciprocity and retained silver. |
| Scanning and printing | Choose scanner simulations, film or paper scanning, glossy, matte or warm fiber paper, and adjust print lighting and warmth. |
| RAW, exposure and color | Keep Original exposure and white balance, with lens correction for supported RAW files; use the white-balance eyedropper, zone exposure, contrast, vibrance, saturation and HDR. |
| Portraits and detail | Skin smoothing, whitening and warmth, background and lens blur, noise reduction and vignette compensation. |
| Live preview | Hover over films to try them, zoom into details, compare with the original and view the RGB histogram. |
| Composition and repairs | Free or fixed-ratio crops, rotation, an AI repair brush, borders and date stamps, with undo and redo. |
| Photo organization | Select multiple thumbnails, add ratings and categories, sort and filter, inspect EXIF and reopen recent folders. |
| Copies and batch editing | Duplicate a photo with its edits, copy adjustments to several photos, reset selections to Original and export in batches. |
| Export options | JPEG, PNG, WebP and TIFF; 8/16-bit PNG and TIFF, size and quality settings, plus sRGB, Adobe RGB and Display P3. |
| AI and external tools | Start AI-assisted analysis and adjustments when you want. Enable the local MCP server to connect compatible external tools. |

## Start in four steps

1. Choose a folder and select a photo.
2. Pick a film, or start with Original.
3. Adjust while watching the preview. Undo changes or compare with the original whenever you like.
4. Choose Export Photo. You can export several photos together, each with its own adjustments.

Photos and edits stay on your computer. AI models need an initial download; once ready, they work offline.

## A couple of tips

RAW and compute acceleration default to **System**, persist across launches and are checked against available hardware. Mac uses Apple acceleration. Windows prefers a tested Vulkan GPU and falls back to CPU. Built-in LibRaw provides fallback RAW decoding.

Sources that need an additional decoder, including Nikon HE/HE* NEF and GoPro GPR, can create lossless RAW caches automatically using the separately installed, free [Adobe DNG Converter](https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/adobe-dng-converter.html). If it is missing, a confirmation dialog appears first; confirming opens Adobe’s official download page in the default browser. After cancelling, the photo footer can reopen the dialog or check again after installation. Adobe software is not bundled with FilmDevelop; original photos and capture EXIF are preserved.

This release validates 47 RAW files on Mac, 20 on Windows, and 14 Windows System-mode samples, including the NEF/GPR gaps. Successful decoding does not imply support for every RAW format, full HDR range or pixel-identical platform output. JPEG XL/Enhanced DNG remains unverified. See the [supplemental RAW decoding record](engine/verification/raw/supplemental-decoder.md) for scope, deployment requirements and differences.

Film and camera looks are simulations, not manufacturer presets or LUTs. Click a feature title in the app for help.

<details>
<summary>Want to build from source?</summary>

You need full Xcode, CMake, glslang, Vulkan headers/loader and MoltenVK. See the [build notes](Vendor/PhotoCompute/README.md#建置與部署) for dependencies.

Go 1.25+ / Python 3.9+. [Go / Swift / C++](desktop/README.md).

```sh
git clone --recurse-submodules https://github.com/VaderChen/FilmDevelop.git
cd FilmDevelop
./run.command
```

</details>

## License

Copyright © 2026 VaderChen. Free use, modification and sharing are allowed under the [license](LICENSE.en.md). Commercial sales and paid services using this software are prohibited; see the [commercial-sales policy](COMMERCIAL-LICENSE.md). The software license does not apply to your photos or exports. Third-party components retain [their own licenses](THIRD_PARTY_NOTICES.md).
