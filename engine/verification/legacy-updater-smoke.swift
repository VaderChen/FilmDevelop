import Foundation

// 與舊版的 PhotoAppRelease／PhotoAppUpdateInstaller 原始碼一起編譯，
// 用相同選包、雜湊、身分、Team、掛載及暫存流程驗證相容安裝包。
@main struct LegacyUpdaterSmoke {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { fatalError("用法：select release.json 或 prepare release.json target.app update.dmg work") }
        let release = try JSONDecoder().decode(PhotoAppRelease.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let current = PhotoAppVersion(version: "1.26.0930", build: "1745")!
        guard let (version, asset) = try release.update(after: current, repository: "VaderChen/FilmDevelop") else {
            fatalError("舊 Swift 更新器未選出新版")
        }
        var result: [String: String] = ["version": version.display, "asset": asset.name]
        if args[1] == "prepare" {
            guard args.count == 6 else { fatalError("缺少 prepare 引數") }
            let target = URL(fileURLWithPath: args[3])
            let prepared = try PhotoAppUpdateInstaller.prepare(
                dmg: URL(fileURLWithPath: args[4]), asset: asset, version: version,
                target: target, work: URL(fileURLWithPath: args[5]),
                helper: target.appendingPathComponent("Contents/Resources/Updater/install.sh"))
            result["target"] = prepared.target.path
            result["staged"] = prepared.staged.path
            result["backup"] = prepared.backup.path
            result["work"] = prepared.work.path
        } else {
            guard args[1] == "select" else { fatalError("不支援的操作") }
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
