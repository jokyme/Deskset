#if DEBUG
import Foundation
import Darwin
import DesksetCore

/// Explicit offline WebParser responses for an additional renderer corpus. The JSON maps each supported work kind
/// (`webParserPage`, `webParserDownload`) to exact request URLs and relative fixture files. Unknown requests stay
/// unverified; a mapped file must be nonempty, regular and inside the manifest's folder, including after symlinks.
struct LegacyRenderWebFixtures {
    private let files: [BackgroundWorkKind: [String: URL]]

    init(manifest: URL) throws {
        let manifest = manifest.standardizedFileURL.resolvingSymlinksInPath()
        guard let bytes = Self.readRegularFile(manifest.path, limit: 1_048_576),
              let object = try JSONValue.parse(bytes).object else {
            throw Self.error("the web fixture manifest must be a JSON object in a regular file of at most 1 MiB")
        }
        let root = manifest.deletingLastPathComponent()
        var files: [BackgroundWorkKind: [String: URL]] = [:]
        for key in object.keys.sorted() {
            guard let kind = BackgroundWorkKind(rawValue: key),
                  kind == .webParserPage || kind == .webParserDownload,
                  let responses = object[key]?.object else {
                throw Self.error("\(key): expected webParserPage or webParserDownload with a URL-to-file object")
            }
            var mapped: [String: URL] = [:]
            for subject in responses.keys.sorted() {
                guard let url = URLComponents(string: subject),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      url.host?.isEmpty == false else {
                    throw Self.error("\(key): a fixture requires a complete HTTP or HTTPS request URL")
                }
                guard let path = responses[subject]?.string, !path.isEmpty,
                      !(path as NSString).isAbsolutePath, !path.hasPrefix("~") else {
                    throw Self.error("\(key): a fixture file must be relative to the manifest")
                }
                let file = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                guard Self.contains(file, in: root) else {
                    throw Self.error("\(key): a fixture file leaves the manifest's folder")
                }
                mapped[subject] = file
            }
            files[kind] = mapped
        }
        self.files = files
    }

    /// nil means the manifest has no response for this exact kind and subject. Invalid mapped inputs throw rather
    /// than behaving like a successful empty response. Recheck the path when reading: a fixture may have changed.
    func response(for request: BackgroundWorkRequest) throws -> Data? {
        guard let file = files[request.kind]?[request.subject] else { return nil }
        guard file.standardizedFileURL.resolvingSymlinksInPath() == file,
              let bytes = Self.readFixture(file.path, kind: request.kind), !bytes.isEmpty else {
            throw Self.error("\(request.kind.rawValue): the mapped fixture is missing, empty, oversized or not a regular file")
        }
        return bytes
    }

    /// WebParserNetwork's file limits also apply to local WebParser inputs without a manifest.
    static func readFixture(_ path: String, kind: BackgroundWorkKind) -> Data? {
        guard kind == .webParserPage || kind == .webParserDownload else { return nil }
        return readRegularFile(path, limit: (kind == .webParserDownload ? 64 : 16) * 1_048_576)
    }

    private static func readRegularFile(_ path: String, limit: Int) -> Data? {
        // As in the package reader: inspect the opened descriptor, without following a replaced final symlink or
        // waiting on a pipe that appeared between a fixture-path check and the read.
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= Int64(limit) else { return nil }
        do {
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            return data.count <= limit ? data : nil
        } catch { return nil }
    }

    private static func contains(_ file: URL, in root: URL) -> Bool {
        file.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") && file.path != root.path
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "LegacyRenderWebFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
