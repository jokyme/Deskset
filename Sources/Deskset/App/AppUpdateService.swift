import DesksetCore
import Foundation

enum AppVersion {
    static var current: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else { return DesksetCore.version }
        return version
    }
}

/// SemVer precedence, without an integer-size limit or build metadata affecting equality.
struct ReleaseVersion: Comparable, CustomStringConvertible {
    private let core: [String]
    private let prerelease: [String]

    var description: String {
        core.joined(separator: ".") + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    init?(_ raw: String) {
        let value = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let buildParts = value.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2,
              buildParts.count == 1 || Self.validIdentifiers(String(buildParts[1]), prerelease: false) else { return nil }
        let versionParts = buildParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = versionParts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard numbers.count == 3, numbers.allSatisfy(Self.validNumber) else { return nil }
        if versionParts.count == 2 {
            let suffix = String(versionParts[1])
            guard Self.validIdentifiers(suffix, prerelease: true) else { return nil }
            prerelease = suffix.split(separator: ".").map(String.init)
        } else {
            prerelease = []
        }
        core = numbers
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(lhs.core, rhs.core) where left != right {
            return numericLess(left, right)
        }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = isDigits(left), rightNumeric = isDigits(right)
            if leftNumeric && rightNumeric { return numericLess(left, right) }
            if leftNumeric != rightNumeric { return leftNumeric }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func isDigits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func validNumber(_ value: String) -> Bool {
        isDigits(value) && (value.count == 1 || !value.hasPrefix("0"))
    }

    private static func numericLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
    }

    private static func validIdentifiers(_ value: String, prerelease: Bool) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            guard !part.isEmpty, part.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            }) else { return false }
            return !prerelease || !isDigits(String(part)) || validNumber(String(part))
        }
    }
}

struct AppRelease: Equatable {
    let version: ReleaseVersion
    let url: URL
}

protocol AppUpdateFetching {
    /// Completes on the main thread. Cancellation suppresses a completion that has not been delivered yet.
    @discardableResult
    func fetch(completion: @escaping (Result<AppRelease?, Error>) -> Void) -> () -> Void
}

enum AppUpdateError: LocalizedError, Equatable {
    case invalidResponse
    case rateLimited
    case httpStatus(Int)
    case invalidRelease

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The update server returned an invalid response. Please try again later."
        case .rateLimited: return "GitHub is limiting update checks. Please try again later."
        case .httpStatus(let status): return "The update server returned HTTP \(status). Please try again later."
        case .invalidRelease: return "The update server returned invalid release information. Please try again later."
        }
    }
}

final class GitHubAppUpdateService: AppUpdateFetching {
    private static let endpoint = URL(string: "https://api.github.com/repos/jokyme/Deskset/releases/latest")!
    private let session: URLSession
    private let ownsSession: Bool

    init(session: URLSession? = nil) {
        ownsSession = session == nil
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.waitsForConnectivity = false
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: configuration)
        }
    }

    deinit {
        if ownsSession { session.invalidateAndCancel() }
    }

    @discardableResult
    func fetch(completion: @escaping (Result<AppRelease?, Error>) -> Void) -> () -> Void {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Deskset/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let pending = Guarded(true)
        let task = session.dataTask(with: request) { data, response, error in
            let result: Result<AppRelease?, Error>
            if let error {
                result = .failure(error)
            } else {
                result = Result { try Self.release(data: data, response: response) }
            }
            DispatchQueue.main.async {
                let deliver = pending.access { active -> Bool in
                    defer { active = false }
                    return active
                }
                if deliver { completion(result) }
            }
        }
        task.resume()
        return {
            pending.access { $0 = false }
            task.cancel()
        }
    }

    private struct ReleaseResponse: Decodable {
        let tagName: String
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft, prerelease
        }
    }

    private static func release(data: Data?, response: URLResponse?) throws -> AppRelease? {
        guard let response = response as? HTTPURLResponse else { throw AppUpdateError.invalidResponse }
        switch response.statusCode {
        case 404: return nil
        case 403, 429: throw AppUpdateError.rateLimited
        case 200: break
        default: throw AppUpdateError.httpStatus(response.statusCode)
        }
        guard let data, let release = try? JSONDecoder().decode(ReleaseResponse.self, from: data) else {
            throw AppUpdateError.invalidResponse
        }
        guard !release.draft, !release.prerelease else { return nil }
        guard let version = ReleaseVersion(release.tagName) else { throw AppUpdateError.invalidRelease }
        guard !version.isPrerelease else { return nil }
        guard let components = URLComponents(string: release.htmlURL), components.scheme == "https",
              components.host?.lowercased() == "github.com", components.port == nil,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path == "/jokyme/Deskset/releases/tag/\(release.tagName)",
              let url = components.url else { throw AppUpdateError.invalidRelease }
        return AppRelease(version: version, url: url)
    }
}
