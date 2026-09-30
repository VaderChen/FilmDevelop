# FilmDevelop

Give your photos a film look you love. Pick a film, adjust exposure, color and grain, then export your work.

[繁體中文](README.md) · [English](README.en.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

![FilmDevelop](demo.gif)

## Get the app

[Download for Mac](https://github.com/VaderChen/FilmDevelop/releases/latest), open the DMG and drag the app into Applications.

Requires **Apple Silicon and macOS 14 or later**. The app supports Traditional Chinese, English, Japanese and Korean. The installer is notarized by Apple.

## What can you do?

- **Find your look:** choose color, black-and-white or cinema film styles and GR camera simulations, or save your own adjustments.
- **Fine-tune the feel:** adjust exposure, white balance, contrast, grain, development and scanning.
- **Organize and edit in batches:** use star ratings and categories, then copy adjustments to several photos at once.
- **Clean up the frame:** crop, rotate, repair unwanted objects, and add borders or dates.
- **Get help from AI:** download a model for local photo analysis and adjustment suggestions. Your photos are not uploaded.
- **Export your work:** save JPEG, PNG, WebP or TIFF with your choice of size and color space, keeping the originals untouched.

## Start in four steps

1. Choose a folder and select a photo.
2. Pick a film, or start with Original.
3. Adjust while watching the preview. Undo changes or compare with the original whenever you like.
4. Choose Export Photo. You can export several photos together, each with its own adjustments.

Photos and edits stay on your Mac. AI models need an initial download; once ready, they work offline.

## A couple of tips

Use **System native decoding** and **System native acceleration**. Built-in software decoding and Vulkan are testing modes in preparation for Windows. There is no Windows installer yet.

Film and camera looks are simulations, not manufacturer presets or LUTs. Click a feature title in the app for help.

<details>
<summary>Want to build from source?</summary>

You need full Xcode, CMake, glslang, Vulkan headers/loader and MoltenVK. See the [build notes](Vendor/PhotoCompute/README.md#建置與部署) for dependencies.

```sh
git clone --recurse-submodules https://github.com/VaderChen/FilmDevelop.git
cd FilmDevelop
./run.command
```

</details>

## License

Copyright © 2026 VaderChen. Free use, modification and sharing are allowed under the [license](LICENSE.en.md). Commercial sales and paid services using this software are prohibited; see the [commercial-sales policy](COMMERCIAL-LICENSE.md). The software license does not apply to your photos or exports. Third-party components retain [their own licenses](THIRD_PARTY_NOTICES.md).
