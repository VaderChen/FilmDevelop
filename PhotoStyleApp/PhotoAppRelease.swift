import Foundation

/// Date-based release order, including same-day builds. Display preserves leading zeros.
struct PhotoAppVersion: Comparable, Equatable {
    let year: Int
    let monthDay: Int
    let build: Int

    init?(version: String, build: String) {
        let parts = version.split(separator: ".")
        guard parts.count == 3, parts[0] == "1", parts[1].count == 2, parts[2].count == 4,
              parts[1].allSatisfy(\.isNumber), parts[2].allSatisfy(\.isNumber),
              let year = Int(parts[1]), let day = Int(parts[2]),
              !build.isEmpty, build.count <= 4, build.allSatisfy(\.isNumber), let time = Int(build),
              time / 100 < 24, time % 100 < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: 2000 + year, month: day / 100, day: day % 100)
        guard let date = calendar.date(from: components),
              calendar.component(.month, from: date) == day / 100,
              calendar.component(.day, from: date) == day % 100 else { return nil }
        self.year = year; monthDay = day; self.build = time
    }

    init?(tag: String) {
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let pieces = value.components(separatedBy: "-build-")
        guard pieces.count == 2 else { return nil }
        self.init(version: pieces[0], build: pieces[1])
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.monthDay, lhs.build) < (rhs.year, rhs.monthDay, rhs.build)
    }
    var version: String { String(format: "1.%02d.%04d", year, monthDay) }
    var buildText: String { String(format: "%04d", build) }
    var display: String { "\(version) build \(buildText)" }
    var tag: String { "v\(version)-build-\(buildText)" }
    var assetName: String { "FilmYourPhoto-\(version)-build-\(buildText)-arm64.dmg" }

    static func installed(in bundle: Bundle = .main) -> Self? {
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "PhotoStyleBuildTime") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
        return Self(version: version, build: build)
    }
}

struct PhotoAppUpdateError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static func explanation(for error: Error, phase: PhotoAppUpdatePhase) -> String {
        if let error = error as? Self { return error.message }
        if error is DecodingError { return "GitHub 的版本資訊無法讀取，請稍後再試。" }
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain {
            switch failure.code {
            case NSURLErrorTimedOut: return "連線逾時，請稍後再試。"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "網路連線已中斷，請恢復連線後再試一次。"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot:
                return "無法安全連線至 GitHub，請確認系統日期與網路設定。"
            default: return "無法連線至 GitHub，請稍後再試。"
            }
        }
        if failure.domain == NSCocoaErrorDomain {
            switch failure.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "更新需要的檔案不存在，請重新下載或手動安裝。"
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return "無法讀取或寫入更新檔案，請將 App 移到可寫入的「應用程式」資料夾後再試。"
            case NSFileWriteOutOfSpaceError:
                return "磁碟空間不足，請釋放空間後再更新。"
            default: break
            }
        }
        return "\(phase.title)失敗（\(failure.domain)：\(failure.code)）。原本的 App 保持不變，請稍後再試。"
    }
}

enum PhotoAppUpdatePhase {
    case checking, downloading, preparing, installing
    var title: String {
        switch self {
        case .checking: return "檢查更新"
        case .downloading: return "下載更新"
        case .preparing: return "準備更新"
        case .installing: return "安裝更新"
        }
    }
}

struct PhotoAppRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let size: Int64
        let url: URL
        let digest: String?
        let state: String
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    func update(after current: PhotoAppVersion, repository: String) throws -> (PhotoAppVersion, Asset)? {
        guard !draft, !prerelease else { return nil }
        guard let version = PhotoAppVersion(tag: tag_name) else {
            throw PhotoAppUpdateError(message: "GitHub 最新版本的版本號格式不符，請使用 v1.YY.MMdd-build-HHmm。")
        }
        guard version > current else { return nil }
        guard let asset = assets.first(where: { $0.name == version.assetName && $0.state == "uploaded" }),
              asset.size > 0, asset.url.scheme == "https", asset.url.host == "api.github.com",
              asset.url.path.hasPrefix("/repos/\(repository)/releases/assets/"),
              let digest = asset.digest, digest.hasPrefix("sha256:"), digest.count == 71,
              digest.dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
            throw PhotoAppUpdateError(message: "新版尚未提供完整的 Apple Silicon 安裝檔，請稍後再試。")
        }
        return (version, asset)
    }
}

/// Redirects may go to GitHub's asset CDN; credentials never leave api.github.com.
final class PhotoUpdateTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var destination: URL?
    private var result: Result<URLResponse, Error>?
    private var cancelled = false
    private var createdDestination = false
    let progress: @Sendable (Int64, Int64) -> Void
    init(progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    // Session-level download callbacks deliver byte progress reliably; the async
    // URLSession convenience method only forwards task-level delegate events.
    func download(_ request: URLRequest, to destination: URL) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.destination = destination
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 1800
                configuration.httpShouldSetCookies = false
                configuration.urlCache = nil
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: request)
                downloadSession = session; downloadTask = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.downloadTask
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destination, let response = downloadTask.response else { return }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            createdDestination = true
            result = .success(response)
        } catch { result = .failure(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let outcome = cancelled ? Result<URLResponse, Error>.failure(CancellationError())
            : error.map { .failure($0) } ?? result ?? .failure(URLError(.badServerResponse))
        let downloadSession = self.downloadSession
        self.downloadSession = nil; downloadTask = nil
        lock.unlock()
        if case .failure = outcome, createdDestination, let destination {
            try? FileManager.default.removeItem(at: destination)
        }
        continuation?.resume(with: outcome)
        downloadSession?.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", let host = request.url?.host,
              ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host) else {
            completionHandler(nil); return
        }
        var next = request
        if host != "api.github.com" { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }
}
