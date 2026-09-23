import AppKit
import CryptoKit
import Security

struct PhotoAppPreparedUpdate {
    let work: URL
    let target: URL
    let staged: URL
    let backup: URL
    let version: PhotoAppVersion

    func discard() {
        try? FileManager.default.removeItem(at: staged)
        try? FileManager.default.removeItem(at: work)
    }
}

/// Runs off the main thread. Only a digest-checked DMG and a sealed matching app are accepted.
enum PhotoAppUpdateInstaller {
    static let workPrefix = "FilmYourPhoto-update-"

    static func validateDestination(_ target: URL) throws {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        let values = try target.resourceValues(forKeys: [.isSymbolicLinkKey, .volumeIsReadOnlyKey])
        guard target.pathExtension == "app", values.isSymbolicLink != true,
              values.volumeIsReadOnly != true, !target.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: target.path) else {
            throw PhotoAppUpdateError(message: "請先將 App 移到可寫入的「應用程式」資料夾，再從那裡開啟並更新。")
        }
    }

    static func verifyDigest(_ file: URL, expected: String, size: Int64) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data); count += Int64(data.count)
        }
        let actual = "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == size, actual == expected.lowercased() else {
            throw PhotoAppUpdateError(message: "安裝檔驗證失敗，請重新下載。")
        }
    }

    static func prepare(dmg: URL, asset: PhotoAppRelease.Asset, version: PhotoAppVersion,
                        target: URL, work: URL, helper: URL) throws -> PhotoAppPreparedUpdate {
        let fm = FileManager.default
        try validateDestination(target)
        try verifyDigest(dmg, expected: asset.digest ?? "", size: asset.size)
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        _ = try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path]) }
        // Accept the current display name and installers made before the rename.
        let renamedApp = mount.appendingPathComponent("照片沖洗.app")
        let candidate = fm.fileExists(atPath: renamedApp.path)
            ? renamedApp : mount.appendingPathComponent("FilmYourPhoto.app")
        let expectedID = try metadata(target)["CFBundleIdentifier"] as? String
        guard let expectedID, !expectedID.isEmpty else { throw PhotoAppUpdateError(message: "無法辨識目前 App。") }
        try validateBundle(candidate, identifier: expectedID, version: version)
        // A Developer ID signed installation may only be replaced by the same team.
        if let team = try signingTeam(target), try signingTeam(candidate) != team {
            throw PhotoAppUpdateError(message: "新版 App 的開發者簽章不符，已停止更新。")
        }
        let id = UUID().uuidString
        let parent = target.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".FilmYourPhoto-\(id).app")
        let backup = parent.appendingPathComponent(".FilmYourPhoto-\(id).bak")
        var prepared = false
        defer { if !prepared { try? fm.removeItem(at: staged) } }
        _ = try run("/usr/bin/ditto", ["--norsrc", candidate.path, staged.path])
        try validateBundle(staged, identifier: expectedID, version: version)
        try fm.copyItem(at: helper, to: work.appendingPathComponent("install.sh"))
        let receipt: [String: String] = ["target": target.path, "staged": staged.path,
                                       "backup": backup.path, "tag": version.tag, "identifier": expectedID]
        try JSONSerialization.data(withJSONObject: receipt).write(to: work.appendingPathComponent("receipt.json"), options: .atomic)
        prepared = true
        return PhotoAppPreparedUpdate(work: work, target: target, staged: staged, backup: backup, version: version)
    }

    static func validateBundle(_ app: URL, identifier: String, version: PhotoAppVersion) throws {
        let fm = FileManager.default
        guard (try app.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw PhotoAppUpdateError(message: "安裝檔的 App 格式不正確。")
        }
        let info = try metadata(app)
        guard info["CFBundleIdentifier"] as? String == identifier,
              let short = info["CFBundleShortVersionString"] as? String,
              let build = info["PhotoStyleBuildTime"] as? String ?? info["CFBundleVersion"] as? String,
              PhotoAppVersion(version: short, build: build) == version,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), executable != ".", executable != ".." else {
            throw PhotoAppUpdateError(message: "安裝檔的 App 或版本與 Release 不符。")
        }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            guard minimum.compare(current, options: .numeric) != .orderedDescending else {
                throw PhotoAppUpdateError(message: "此版本需要 macOS \(minimum) 或更新版本。")
            }
        }
        let binary = app.appendingPathComponent("Contents/MacOS/\(executable)")
        guard fm.isExecutableFile(atPath: binary.path),
              try run("/usr/bin/lipo", ["-archs", binary.path]).split(whereSeparator: \.isWhitespace).contains("arm64") else {
            throw PhotoAppUpdateError(message: "此安裝檔不支援 Apple Silicon。")
        }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    private static func signingTeam(_ app: URL) throws -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func metadata(_ app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw PhotoAppUpdateError(message: "無法讀取安裝檔資訊。")
        }
        return info
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PhotoAppUpdateError(message: "更新準備失敗，原本的 App 保持不變。請重新下載或手動安裝。")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The newly launched, validated app acknowledges installation before the backup is removed.
    static func finishInstallation(arguments: [String], bundle: Bundle = .main) {
        guard let index = arguments.firstIndex(of: "--finish-update"), index + 1 < arguments.count else { return }
        let fm = FileManager.default
        let work = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = fm.temporaryDirectory.resolvingSymlinksInPath()
        guard work.deletingLastPathComponent() == temporary,
              work.lastPathComponent.hasPrefix(workPrefix),
              let data = try? Data(contentsOf: work.appendingPathComponent("receipt.json")),
              let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              receipt["target"] == bundle.bundleURL.resolvingSymlinksInPath().path,
              receipt["tag"] == PhotoAppVersion.installed(in: bundle)?.tag,
              receipt["identifier"] == bundle.bundleIdentifier,
              let stagedPath = receipt["staged"], let backupPath = receipt["backup"] else { return }
        let staged = URL(fileURLWithPath: stagedPath)
        let backup = URL(fileURLWithPath: backupPath)
        let parent = bundle.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent()
        guard staged.deletingLastPathComponent() == parent, backup.deletingLastPathComponent() == parent,
              staged.lastPathComponent.hasPrefix(".FilmYourPhoto-"), staged.pathExtension == "app",
              backup == staged.deletingPathExtension().appendingPathExtension("bak"),
              !fm.fileExists(atPath: staged.path) else { return }
        // The installer waits for this acknowledgement; it owns cleanup and rollback.
        fm.createFile(atPath: work.appendingPathComponent("confirmed").path, contents: Data())
    }
}
