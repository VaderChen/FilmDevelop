// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PhotoStyleMLXRuntime",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "photostyle-mlx", targets: ["PhotoStyleMLXWorker"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.1.9")
    ],
    targets: [
        .executableTarget(name: "PhotoStyleMLXWorker", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXVLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "Hub", package: "swift-transformers")
        ])
    ]
)
