# libwebp for PhotoStyleApp

The app statically links the existing libwebp 1.6.0 sources at
`aiTest/ThirdParty/stable-diffusion.cpp/thirdparty/libwebp`.

Run `scripts/build-webp-macos.sh` to reproduce the Apple Silicon (arm64) macOS 14+ archive.
It requires only the Xcode command-line tools and their Python 3. No Homebrew
library, dynamic library, network download, or external runtime encoder is used.
Source/header/toolchain fingerprints avoid unnecessary rebuilds.

`macos/WebPLicenses` contains the upstream copyright license, patent grant, and
author list and is also copied into the application bundle. The build script
does not modify upstream sources. WebP export is lossy RGB with lossless alpha,
8 bits per channel; 16-bit WebP is not advertised.
