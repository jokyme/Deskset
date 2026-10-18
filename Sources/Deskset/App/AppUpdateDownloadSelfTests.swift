import CryptoKit
import Foundation

/// Every request is intercepted. Bundles, archives and download staging stay in the test's temporary directories.
enum AppUpdateDownloadSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: app update download: verifies and extracts a signed bundle off the main thread") {
            let root = t.temporaryDirectory("download-success")
            let bytes = try archive(root: root)
            let folder = try staging(root)
            var progress: [Double?] = []
            let result = download(t, bytes: bytes, folder: folder, progress: {
                t.check(Thread.isMainThread)
                progress.append($0)
            })
            guard case .success(let prepared) = result else { return t.check(false, "signed update is prepared") }
            defer { try? FileManager.default.removeItem(at: prepared.directory) }
            t.equal(prepared.directory.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
            t.equal(try AppInstallation.info(at: prepared.appURL).version, "0.3.0")
            try AppInstallation.verifySignature(prepared.appURL)
            let permissions = try FileManager.default.attributesOfItem(atPath: prepared.directory.path)[.posixPermissions] as? NSNumber
            t.equal(permissions?.intValue, 0o700)
            t.check(!FileManager.default.fileExists(atPath: prepared.directory.appendingPathComponent("update.zip").path))
            // Fast verification can finish before main repaints; queued progress is then correctly discarded.
            t.check(progress.compactMap { $0 }.allSatisfy { (0...1).contains($0) })
            t.equal(StubURLProtocol.requests.current.first?.url, release(bytes: bytes).assets.first?.url)
            t.equal(StubURLProtocol.requests.current.first?.timeoutInterval, 30)
        }

        t.suite("App: app update download: response, size, checksum and archive failures clean up") {
            let root = t.temporaryDirectory("download-failures")
            let bytes = try archive(root: root)
            let folder = try staging(root)
            for code in [404, 503] {
                let result = download(t, bytes: bytes, folder: folder, status: code)
                t.equal(failure(result) as? AppUpdateDownloadError, .httpStatus(code))
                t.equal(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
            }
            let wrongSize = release(bytes: bytes, size: Int64(bytes.count + 1))
            t.equal(failure(download(t, bytes: bytes, folder: folder, offered: wrongSize)) as? AppUpdateDownloadError, .wrongSize)
            t.equal(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
            let wrongHash = release(bytes: bytes, digest: String(repeating: "0", count: 64))
            t.equal(failure(download(t, bytes: bytes, folder: folder, offered: wrongHash)) as? AppUpdateDownloadError, .checksum)
            t.equal(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
            let invalidZip = Data("not an archive".utf8)
            t.check(failure(download(t, bytes: invalidZip, folder: folder)) != nil)
            t.equal(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        }

        t.suite("App: app update download: the bundle must match the release and retain a valid signature") {
            let root = t.temporaryDirectory("download-bundle-checks")
            let folder = try staging(root)
            let wrongVersion = try archive(root: root.appendingPathComponent("wrong-version"), version: "0.4.0")
            t.equal(failure(download(t, bytes: wrongVersion, folder: folder)) as? AppUpdateDownloadError, .invalidApp)
            let tampered = try archive(root: root.appendingPathComponent("tampered"), tamper: true)
            t.equal(failure(download(t, bytes: tampered, folder: folder)) as? AppInstallation.Failure, .signature)
            let linked = try archive(root: root.appendingPathComponent("linked"), link: true)
            t.check(failure(download(t, bytes: linked, folder: folder)) != nil, "symlinks are refused before installation")
            let wrongArchitecture = AppUpdateAsset.currentArchitecture == "arm64" ? "x86_64" : "arm64e"
            let incompatible = try archive(root: root.appendingPathComponent("architecture"), architecture: wrongArchitecture)
            t.equal(failure(download(t, bytes: incompatible, folder: folder)) as? AppUpdateDownloadError, .architecture)
            t.equal(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        }

        t.suite("App: app update download: missing or ambiguous assets never start a request") {
            let root = t.temporaryDirectory("download-missing")
            let folder = try staging(root)
            let bytes = Data("unused".utf8)
            let valid = release(bytes: bytes)
            let missing = AppRelease(version: valid.version, url: valid.url)
            let duplicate = AppRelease(version: valid.version, url: valid.url, assets: valid.assets + valid.assets)
            for offered in [missing, duplicate] {
                t.equal(failure(download(t, bytes: bytes, folder: folder, offered: offered)) as? AppUpdateDownloadError, .missingAsset)
                t.equal(StubURLProtocol.requests.current.count, 0)
                t.equal(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
            }
        }

        t.suite("App: app update download: native architecture selects the matching asset and Mach-O slice") {
            let root = t.temporaryDirectory("download-native-architecture")
            let folder = try staging(root)
            for architecture in ["arm64", "x86_64"] {
                let other = architecture == "arm64" ? "x86_64" : "arm64"
                let bytes = try archive(root: root.appendingPathComponent(architecture),
                                        architecture: architecture == "arm64" ? "arm64e" : "x86_64")
                let matching = release(bytes: bytes, architecture: architecture)
                let otherNamed = release(bytes: bytes, architecture: other)
                let both = AppRelease(version: matching.version, url: matching.url, assets: otherNamed.assets + matching.assets)
                guard case .success(let prepared) = download(t, bytes: bytes, folder: folder, offered: both, architecture: architecture) else {
                    t.check(false, "the \(architecture) package is selected and verified")
                    continue
                }
                t.equal(StubURLProtocol.requests.current.first?.url, matching.assets.first?.url)
                let executable = prepared.appURL.appendingPathComponent("Contents/MacOS/Deskset")
                t.check(try AppUpdateDownloader.hasCompatibleArchitecture(executable, architecture: architecture))
                t.check(try !AppUpdateDownloader.hasCompatibleArchitecture(executable, architecture: other))
                try FileManager.default.removeItem(at: prepared.directory)

                t.equal(failure(download(t, bytes: bytes, folder: folder, offered: matching, architecture: other)) as? AppUpdateDownloadError,
                        .missingAsset, "a missing native package never falls back to the other architecture")
                t.equal(StubURLProtocol.requests.current.count, 0)
                t.equal(failure(download(t, bytes: bytes, folder: folder, offered: otherNamed, architecture: other)) as? AppUpdateDownloadError,
                        .architecture, "the filename alone is not proof of a native executable")
                t.equal(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
            }
        }

        t.suite("App: app update download: unsupported or malformed macOS requirements are rejected before installing") {
            let root = t.temporaryDirectory("download-system-version")
            let folder = try staging(root)
            let future = try archive(root: root.appendingPathComponent("future"), minimumSystemVersion: "99.0.0")
            t.equal(failure(download(t, bytes: future, folder: folder)) as? AppUpdateDownloadError, .systemVersion("99.0.0"))
            for requirement in ["13.0-beta", "13..0", "999999999999999999999999.0"] {
                let malformed = try archive(root: root.appendingPathComponent(UUID().uuidString), minimumSystemVersion: requirement)
                t.equal(failure(download(t, bytes: malformed, folder: folder)) as? AppUpdateDownloadError, .invalidApp)
            }
            t.equal(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
            // Other successful fixtures declare the supported 13.0 minimum. The optional key may also be absent.
            let unspecified = try archive(root: root.appendingPathComponent("unspecified"), minimumSystemVersion: nil)
            guard case .success(let prepared) = download(t, bytes: unspecified, folder: folder) else {
                return t.check(false, "an optional absent minimum system version is accepted")
            }
            try FileManager.default.removeItem(at: prepared.directory)
        }

        t.suite("App: app update download: cancellation suppresses callbacks and removes staging") {
            let root = t.temporaryDirectory("download-cancel")
            let folder = try staging(root)
            let config = configuration(.hold)
            let downloader = AppUpdateDownloader(configuration: config, temporaryDirectory: folder)
            var completions = 0
            let cancel = downloader.download(release(bytes: Data("unused".utf8)), progress: { _ in }) { _ in completions += 1 }
            t.check(AppSelfTest.spin(timeout: 3) { !StubURLProtocol.requests.current.isEmpty })
            cancel()
            cancel()
            t.check(AppSelfTest.spin(timeout: 3) { StubURLProtocol.stopped.current > 0 })
            t.check(AppSelfTest.spin(timeout: 3) {
                (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true
            })
            t.equal(completions, 0)

            let noAsset = AppRelease(version: ReleaseVersion("0.3.0")!, url: URL(string: "https://github.com/jokyme/Deskset/releases/tag/v0.3.0")!)
            let cancelQueued = downloader.download(noAsset, progress: { _ in }) { _ in completions += 1 }
            cancelQueued()
            RenderCommand.wait(milliseconds: 30)
            t.equal(completions, 0, "cancellation suppresses an already queued failure too")
        }

        t.suite("App: app update download: cancelling a prepared result awaiting the main thread cleans up") {
            let root = t.temporaryDirectory("download-cancel-prepared")
            let bytes = try archive(root: root)
            let folder = try staging(root)
            let downloader = AppUpdateDownloader(configuration: configuration(.http(200, bytes)), temporaryDirectory: folder)
            var completions = 0
            let cancel = downloader.download(release(bytes: bytes), progress: { _ in }) { _ in completions += 1 }
            let end = Date().addingTimeInterval(5)
            var prepared = false
            // Do not drain main: preparation finishes on its worker while completion remains queued for delivery.
            while !prepared, Date() < end {
                let jobs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                prepared = jobs.contains {
                    FileManager.default.fileExists(atPath: $0.appendingPathComponent("extracted/Deskset.app/Contents/Info.plist").path)
                        && !FileManager.default.fileExists(atPath: $0.appendingPathComponent("update.zip").path)
                }
                if !prepared { Thread.sleep(forTimeInterval: 0.005) }
            }
            t.check(prepared, "verification finished without needing the main thread")
            cancel()
            t.check(AppSelfTest.spin(timeout: 3) {
                (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true
            })
            RenderCommand.wait(milliseconds: 30)
            t.equal(completions, 0, "a cancelled prepared result is not installed")
        }

        t.suite("App: app update download: redirects remain on the expected HTTPS release servers") {
            for text in ["https://github.com/jokyme/Deskset/releases/download/v0.3.0/Deskset.zip",
                         "https://release-assets.githubusercontent.com/github-production-release-asset/1/test?token=signed",
                         "https://objects.githubusercontent.com/test", "https://github-releases.githubusercontent.com/test"] {
                t.check(AppUpdateDownloader.permitsDownloadURL(URL(string: text)!))
            }
            for text in ["http://github.com/test", "https://github.com.example.org/test", "https://example.org/test",
                         "https://user@github.com/test", "https://github.com:8443/test", "https://github.com/test#fragment",
                         "file:///tmp/test", "https://raw.githubusercontent.com/test"] {
                t.check(!AppUpdateDownloader.permitsDownloadURL(URL(string: text)!))
            }
        }

        t.suite("App: app update download: an untrusted redirect is refused before requesting it") {
            let root = t.temporaryDirectory("download-redirect")
            let folder = try staging(root)
            let downloader = AppUpdateDownloader(configuration: configuration(.redirect(URL(string: "https://example.org/update.zip")!)),
                                                  temporaryDirectory: folder)
            var result: Result<AppPreparedUpdate, Error>?
            let cancel = downloader.download(release(bytes: Data("unused".utf8)), progress: { _ in }) { result = $0 }
            defer { cancel() }
            t.check(AppSelfTest.spin(timeout: 3) { result != nil })
            t.equal(failure(result) as? AppUpdateDownloadError, .unsafeRedirect)
            t.equal(StubURLProtocol.requests.current.count, 1, "the redirected host is never requested")
            t.equal(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        }
    }

    private static func staging(_ root: URL) throws -> URL {
        let folder = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func archive(root: URL, version: String = "0.3.0", tamper: Bool = false, link: Bool = false,
                                architecture: String? = nil, minimumSystemVersion: String? = "13.0") throws -> Data {
        let fm = FileManager.default
        let app = root.appendingPathComponent("Deskset.app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/Deskset")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let architecture {
            try run("/usr/bin/lipo", ["/usr/bin/true", "-thin", architecture, "-output", executable.path])
        } else {
            try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        }
        var plist = ["CFBundleIdentifier": AppInstallation.bundleID, "CFBundleExecutable": "Deskset",
                     "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        plist["LSMinimumSystemVersion"] = minimumSystemVersion
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let resource = app.appendingPathComponent("Contents/Resources/fixture.txt")
        try fm.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: resource)
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        if tamper { try Data("changed".utf8).write(to: resource) }
        if link { try fm.createSymbolicLink(at: resource.appendingPathExtension("link"), withDestinationURL: resource) }
        let zip = root.appendingPathComponent("fixture.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", app.path, zip.path])
        return try Data(contentsOf: zip)
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "AppUpdateDownloadSelfTests", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Fixture command failed: \(executable)"])
        }
    }

    private static func release(bytes: Data, size: Int64? = nil, digest: String? = nil,
                                architecture: String = AppUpdateAsset.currentArchitecture) -> AppRelease {
        let version = ReleaseVersion("0.3.0")!
        let name = AppUpdateAsset.name(version: version, architecture: architecture)
        let asset = AppUpdateAsset(name: name,
            url: URL(string: "https://github.com/jokyme/Deskset/releases/download/v0.3.0/\(name)")!,
            sha256: digest ?? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            size: size ?? Int64(bytes.count))
        return AppRelease(version: version, url: URL(string: "https://github.com/jokyme/Deskset/releases/tag/v0.3.0")!, assets: [asset])
    }

    private static func failure(_ result: Result<AppPreparedUpdate, Error>?) -> Error? {
        if case .failure(let error) = result { return error }
        return nil
    }

    private enum Response { case http(Int, Data), redirect(URL), hold }

    private static func configuration(_ response: Response) -> URLSessionConfiguration {
        StubURLProtocol.response.access { $0 = response }
        StubURLProtocol.requests.access { $0 = [] }
        StubURLProtocol.stopped.access { $0 = 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    private static func download(_ t: AppTestRunner, bytes: Data, folder: URL, offered: AppRelease? = nil,
                                 status: Int = 200, architecture: String = AppUpdateAsset.currentArchitecture,
                                 progress: @escaping (Double?) -> Void = { _ in }) -> Result<AppPreparedUpdate, Error>? {
        let downloader = AppUpdateDownloader(configuration: configuration(.http(status, bytes)), temporaryDirectory: folder,
                                              architecture: architecture)
        var result: Result<AppPreparedUpdate, Error>?
        let cancel = downloader.download(offered ?? release(bytes: bytes), progress: progress) {
            t.check(Thread.isMainThread)
            result = $0
        }
        defer { cancel() }
        t.check(AppSelfTest.spin(timeout: 10) { result != nil }, "the download completes")
        return result
    }

    private final class StubURLProtocol: URLProtocol {
        static let response = Guarded<Response>(.hold)
        static let requests = Guarded<[URLRequest]>([])
        static let stopped = Guarded(0)
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests.access { $0.append(request) }
            guard let url = request.url else { return }
            switch Self.response.current {
            case .http(let status, let body):
                guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": String(body.count), "Content-Type": "application/zip"]) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            case .redirect(let destination):
                guard let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": destination.absoluteString]) else { return }
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            case .hold:
                return
            }
        }
        override func stopLoading() { Self.stopped.access { $0 += 1 } }
    }
}
