# PhotoStyleApp MLX runtime

This macOS 14+ Apple Silicon helper loads local multimodal MLX models and inspects
one image per subprocess. It is built with Swift and Metal, without Python,
network listening ports, or a runtime dependency on another application.

The model loading architecture follows Tanpopo's `MLXRuntime.swift`: use
`VLMModelFactory` for local vision checkpoints, prepare a structured system/user
conversation with an image, then generate with MLX. No Tanpopo implementation or
forked third-party source is copied. Dependencies are pinned to official upstream
releases: mlx-swift 0.31.6, mlx-swift-lm 3.31.4, swift-transformers 1.1.9; transitive
revisions are recorded in `Package.resolved`. Their licenses are included in the
packaged runtime's `Licenses` directory. The pinned packages require Swift 6.3+
and a complete Xcode installation with the Metal Toolchain.

Build from the repository root with `scripts/build-mlx-macos.sh`. The resulting
`Vendor/MLXRuntime` contents must be copied into
`PhotoStyleApp.app/Contents/Resources/MLXRuntime`. Keep the executable, sibling
resource bundles, and particularly `mlx-swift_Cmlx.bundle` together. Model weights
are external data; they are never copied into the app or compiled.

The process accepts one JSON request on stdin (closed after the request):
`modelDirectory`, `systemPrompt`, `userPrompt`, `imageBase64` (JPEG), `maxTokens`
(1–4096), and `contextLimit` (4096–16384). It emits one JSON object on stdout with
`text` or `error`; diagnostics go to stderr. Only local tokenizer/model loading
APIs are used. The app cancels its own process, escalates termination if needed,
limits output and elapsed time, and releases GPU memory when the worker exits.

MLX generation is **not grammar constrained**. The app shares its existing prompt
and complete-plan decoder with GGUF, rejects incomplete or invalid output, and
applies adjustments only after the decoder succeeds. It never substitutes a
fabricated plan for failed model output.
