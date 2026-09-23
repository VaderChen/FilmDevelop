import Foundation

/// Shared by discovery and inference; MLX remains isolated in its worker process.
enum AIModelRuntimeSupport {
    static var executableURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["PHOTOSTYLE_MLX_WORKER"].map { URL(fileURLWithPath: $0) },
            Bundle.main.resourceURL?.appendingPathComponent("MLXRuntime/photostyle-mlx"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Vendor/MLXRuntime/photostyle-mlx")
        ].compactMap { $0 }
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path) &&
                FileManager.default.isReadableFile(atPath: $0.deletingLastPathComponent()
                    .appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib").path)
        }
    }

    static var isAvailable: Bool { executableURL != nil }
    static var availabilityMessage: String {
        return isAvailable ? "MLX 已就緒" : "尚未建置 MLX 執行環境；請以 run.command 啟動專案完成安裝。"
    }
}
