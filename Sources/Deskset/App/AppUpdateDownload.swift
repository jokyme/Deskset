import CryptoKit
import DesksetCore
import Foundation

/// The caller owns this private directory after a successful download and removes it after installing or cancelling.
struct AppPreparedUpdate {
    let directory: URL
    let appURL: URL
}

protocol AppUpdateDownloading {
    /// Main-thread callbacks. A nil progress means verifying the downloaded file; cancellation suppresses completion.
    @discardableResult
    func download(_ release: AppRelease, progress: @escaping (Double?) -> Void,
                  completion: @escaping (Result<AppPreparedUpdate, Error>) -> Void) -> () -> Void
}

enum AppUpdateDownloadError: LocalizedError, Equatable {
    case missingAsset, invalidResponse, httpStatus(Int), unsafeRedirect, wrongSize, checksum, invalidApp, architecture
    case systemVersion(String)

    var errorDescription: String? {
        switch self {
        case .missingAsset: return "This release has no verified download for this Mac. You can download it from GitHub instead."
        case .invalidResponse: return "The download server returned an invalid response."
        case .httpStatus(let code): return "The download server returned HTTP \(code). Please try again."
        case .unsafeRedirect: return "The download redirected outside the expected GitHub servers."
        case .wrongSize: return "The downloaded file does not match the release size. Please try again."
        case .checksum: return "The downloaded file failed its SHA-256 check. Please try again."
        case .invalidApp: return "The downloaded application does not match this Deskset release."
        case .architecture: return "The downloaded application does not support this Mac’s processor."
        case .systemVersion(let version): return "This update requires macOS \(version) or later. Your installed version of Deskset has been kept."
        }
    }
}

final class AppUpdateDownloader: AppUpdateDownloading {
    private let configuration: URLSessionConfiguration
    private let temporaryDirectory: URL
    private let architecture: String

    init(configuration: URLSessionConfiguration = .ephemeral,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory,
         architecture: String = AppUpdateAsset.currentArchitecture) {
        self.configuration = configuration
        self.temporaryDirectory = temporaryDirectory
        self.architecture = architecture
    }

    @discardableResult
    func download(_ release: AppRelease, progress: @escaping (Double?) -> Void,
                  completion: @escaping (Result<AppPreparedUpdate, Error>) -> Void) -> () -> Void {
        do {
            let name = AppUpdateAsset.name(version: release.version, architecture: architecture)
            let assets = release.assets.filter { $0.name == name && $0.isValid(version: release.version, releaseURL: release.url) }
            guard assets.count == 1, let asset = assets.first else { throw AppUpdateDownloadError.missingAsset }
            let operation = try Download(release: release, asset: asset, architecture: architecture, configuration: configuration,
                                         temporaryDirectory: temporaryDirectory, progress: progress, completion: completion)
            operation.start()
            return { operation.cancel() }
        } catch {
            let pending = Guarded(true)
            DispatchQueue.main.async {
                if pending.access({ active in defer { active = false }; return active }) { completion(.failure(error)) }
            }
            return { pending.access { $0 = false } }
        }
    }

    /// GitHub uses signed URLs on these hosts for release assets. Query parameters are allowed only on these hosts.
    static func permitsDownloadURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let host = parts.host?.lowercased() else { return false }
        return ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com",
                "github-releases.githubusercontent.com"].contains(host)
    }

    /// Read the thin or universal Mach-O CPU headers without requiring Xcode's lipo tool on the user's Mac.
    static func hasCompatibleArchitecture(_ executable: URL, architecture: String = AppUpdateAsset.currentArchitecture) throws -> Bool {
        let file = try FileHandle(forReadingFrom: executable)
        defer { try? file.close() }
        let bytes = [UInt8](try file.read(upToCount: 4096) ?? Data())
        func word(_ offset: Int, littleEndian: Bool = false) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let positions = littleEndian ? Array((offset..<(offset + 4)).reversed()) : Array(offset..<(offset + 4))
            return positions.reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[$1]) }
        }
        let expected: UInt32
        switch architecture {
        case "arm64": expected = 0x0100000c // CPU_TYPE_ARM64, including arm64e.
        case "x86_64": expected = 0x01000007 // CPU_TYPE_X86_64.
        default: return false
        }
        guard let magic = word(0) else { return false }
        switch magic {
        case 0xfeedfacf, 0xcffaedfe:
            return word(4, littleEndian: magic == 0xcffaedfe) == expected
        case 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca:
            let littleEndian = magic == 0xbebafeca || magic == 0xbfbafeca
            let width = magic == 0xcafebabf || magic == 0xbfbafeca ? 32 : 20
            guard let count = word(4, littleEndian: littleEndian), count > 0, count <= 32,
                  8 + Int(count) * width <= bytes.count else { return false }
            return (0..<Int(count)).contains { word(8 + $0 * width, littleEndian: littleEndian) == expected }
        default:
            return false
        }
    }

    private struct SystemRequirement: Decodable {
        let LSMinimumSystemVersion: String?
    }

    private static func verifySystemRequirement(_ app: URL) throws {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let requirement = try? PropertyListDecoder().decode(SystemRequirement.self, from: data) else {
            throw AppUpdateDownloadError.invalidApp
        }
        guard let text = requirement.LSMinimumSystemVersion else { return }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
            throw AppUpdateDownloadError.invalidApp
        }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { throw AppUpdateDownloadError.invalidApp }
        let minimum = OperatingSystemVersion(majorVersion: values[0], minorVersion: values[1],
                                             patchVersion: values.count == 3 ? values[2] : 0)
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(minimum) else {
            throw AppUpdateDownloadError.systemVersion(text)
        }
    }

    private final class Download: NSObject, URLSessionDownloadDelegate {
        private struct State {
            var active = true
            var resultQueued = false
            var task: URLSessionDownloadTask?
        }
        private let state = Guarded(State())
        private let work = DispatchQueue(label: "app.deskset.update-download", qos: .userInitiated)
        private let release: AppRelease
        private let asset: AppUpdateAsset
        private let architecture: String
        private let directory: URL
        private let progress: (Double?) -> Void
        private let completion: (Result<AppPreparedUpdate, Error>) -> Void
        private var session: URLSession!

        init(release: AppRelease, asset: AppUpdateAsset, architecture: String, configuration: URLSessionConfiguration,
             temporaryDirectory: URL, progress: @escaping (Double?) -> Void,
             completion: @escaping (Result<AppPreparedUpdate, Error>) -> Void) throws {
            self.release = release
            self.asset = asset
            self.architecture = architecture
            self.progress = progress
            self.completion = completion
            directory = temporaryDirectory.appendingPathComponent("Deskset-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            super.init()
            let settings = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
            settings.urlCache = nil
            settings.requestCachePolicy = .reloadIgnoringLocalCacheData
            settings.timeoutIntervalForRequest = 30
            settings.timeoutIntervalForResource = 10 * 60
            settings.waitsForConnectivity = false
            settings.httpShouldSetCookies = false
            settings.httpCookieAcceptPolicy = .never
            session = URLSession(configuration: settings, delegate: self, delegateQueue: nil)
        }

        func start() {
            var request = URLRequest(url: asset.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpShouldHandleCookies = false
            request.setValue("Deskset/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: request)
            state.access { $0.task = task }
            reportProgress(0)
            task.resume()
        }

        func cancel() {
            let cancelled = state.access { value -> Bool in
                guard value.active else { return false }
                value.active = false
                value.task?.cancel()
                return true
            }
            guard cancelled else { return }
            session.invalidateAndCancel()
            // Extraction, if already underway, is bounded and serializes its cleanup before any later delivery.
            work.async { try? FileManager.default.removeItem(at: self.directory) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, AppUpdateDownloader.permitsDownloadURL(url) else {
                completionHandler(nil)
                task.cancel()
                finish(.failure(AppUpdateDownloadError.unsafeRedirect))
                return
            }
            completionHandler(state.current.active ? request : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesWritten <= asset.size, totalBytesExpectedToWrite <= asset.size else {
                downloadTask.cancel()
                finish(.failure(AppUpdateDownloadError.wrongSize))
                return
            }
            reportProgress(min(1, Double(totalBytesWritten) / Double(asset.size)))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                guard let response = downloadTask.response as? HTTPURLResponse,
                      let url = response.url, AppUpdateDownloader.permitsDownloadURL(url) else {
                    throw AppUpdateDownloadError.invalidResponse
                }
                guard response.statusCode == 200 else { throw AppUpdateDownloadError.httpStatus(response.statusCode) }
                let archive = directory.appendingPathComponent("update.zip")
                try state.access { value in
                    guard value.active, !value.resultQueued else { throw URLError(.cancelled) }
                    // URLSession removes location after this callback; move it before scheduling background verification.
                    try FileManager.default.moveItem(at: location, to: archive)
                    work.async { self.prepare(archive) }
                }
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)) }
        }

        private func prepare(_ archive: URL) {
            guard state.current.active else { return }
            reportProgress(nil)
            let result = Result<AppPreparedUpdate, Error> {
                let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
                guard (attributes[.size] as? NSNumber)?.int64Value == asset.size else { throw AppUpdateDownloadError.wrongSize }
                let file = try FileHandle(forReadingFrom: archive)
                defer { try? file.close() }
                var hasher = SHA256()
                while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                    guard state.current.active else { throw URLError(.cancelled) }
                    hasher.update(data: bytes)
                }
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == asset.sha256 else { throw AppUpdateDownloadError.checksum }
                guard state.current.active else { throw URLError(.cancelled) }
                let extracted = directory.appendingPathComponent("extracted", isDirectory: true)
                _ = try RmskinPackage.extract(archive, into: extracted)
                guard state.current.active else { throw URLError(.cancelled) }
                let app = extracted.appendingPathComponent("Deskset.app", isDirectory: true)
                guard try ReleaseVersion(AppInstallation.info(at: app).version) == release.version else {
                    throw AppUpdateDownloadError.invalidApp
                }
                try AppInstallation.verifySignature(app)
                guard try AppUpdateDownloader.hasCompatibleArchitecture(app.appendingPathComponent("Contents/MacOS/Deskset"),
                                                                        architecture: architecture) else {
                    throw AppUpdateDownloadError.architecture
                }
                try AppUpdateDownloader.verifySystemRequirement(app)
                try FileManager.default.removeItem(at: archive)
                return AppPreparedUpdate(directory: directory, appURL: app)
            }
            finish(result)
        }

        private func reportProgress(_ value: Double?) {
            DispatchQueue.main.async {
                let current = self.state.current
                if current.active, !current.resultQueued { self.progress(value) }
            }
        }

        private func finish(_ result: Result<AppPreparedUpdate, Error>) {
            let deliver = state.access { value -> Bool in
                guard value.active, !value.resultQueued else { return false }
                value.resultQueued = true
                return true
            }
            guard deliver else { return }
            session.finishTasksAndInvalidate()
            work.async {
                if case .failure = result { try? FileManager.default.removeItem(at: self.directory) }
                DispatchQueue.main.async {
                    let deliver = self.state.access { value -> Bool in
                        guard value.active else { return false }
                        value.active = false
                        return true
                    }
                    if deliver { self.completion(result) }
                }
            }
        }
    }
}
