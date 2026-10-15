import Foundation
import DeskLanguage

/// Main owns the request and its decision; the serial file queue alone owns the mutable installation lease.
/// Cancellation invalidates a pending decision without deleting a directory that Main may already have saved.
final class DeskPackageInstallationRequest {
    typealias Outcome = Result<DeskWidgetInstallation.InstalledPackage, Error>
    private static let fileQueue = DispatchQueue(label: "deskset.package.install", qos: .userInitiated)

    private final class Worker {
        var staged: DeskWidgetInstallation.PackageStaged?
    }

    private let cancelled = Guarded(false)
    private let worker = Worker()
    private let queue: DispatchQueue
    private var completion: ((Outcome) -> Void)?
    private var finishObservers: [() -> Void] = []
    private(set) var isFinished = false

    private init(queue: DispatchQueue, completion: @escaping (Outcome) -> Void) {
        self.queue = queue
        self.completion = completion
    }

    /// A caller-supplied queue must be serial. `current` runs only on Main and checks the current editor/request.
    /// The request stays alive through the worker acknowledgement even if its originating window closes.
    static func start(snapshot: DeskSnapshot, capture: DeskPackageCapture,
                      plan: DeskWidgetInstallation.PackagePlan, root: URL, state: AppState,
                      queue: DispatchQueue? = nil, current: @escaping () -> Bool,
                      didRegister: (() -> Void)? = nil,
                      completion: @escaping (Outcome) -> Void) -> DeskPackageInstallationRequest {
        precondition(Thread.isMainThread)
        let request = DeskPackageInstallationRequest(queue: queue ?? fileQueue, completion: completion)
        request.queue.async {
            do {
                let admitted = try DeskWidgetInstallation.admitPackage(snapshot, capture: capture,
                                                                       isCancelled: request.isCancelled)
                let staged = try DeskWidgetInstallation.preparePackage(admitted, plan: plan, root: root,
                                                                        isCancelled: request.isCancelled)
                request.worker.staged = staged
                let publication = try staged.publish(isCancelled: request.isCancelled)
                DispatchQueue.main.async {
                    let result: Outcome
                    do {
                        let installed = try DeskWidgetInstallation.registerPackage(publication, to: state) {
                            !request.isCancelled() && current()
                        }
                        result = .success(installed)
                        // Main observation follows durable registration and precedes the worker acknowledgement.
                        didRegister?()
                    } catch {
                        result = .failure(error)
                    }
                    let decision: DeskWidgetInstallation.PackageDecision
                    switch result {
                    case .success: decision = .registered
                    case .failure: decision = .rejected
                    }
                    request.queue.async {
                        let cleanupError = request.finishLease(decision)
                        DispatchQueue.main.async {
                            if let cleanupError {
                                Log.write("Package installation cleanup failed: \(cleanupError)", level: .error)
                            }
                            request.finish(result)
                        }
                    }
                }
            } catch {
                let cleanupError = request.finishLease(.rejected)
                DispatchQueue.main.async {
                    if let cleanupError {
                        Log.write("Package installation cleanup failed: \(cleanupError)", level: .error)
                    }
                    request.finish(.failure(error))
                }
            }
        }
        return request
    }

    func cancel() {
        precondition(Thread.isMainThread)
        cancelled.access { $0 = true }
    }

    /// Used by normal quit to await cleanup asynchronously, without blocking Main on the file queue.
    func whenFinished(_ body: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        if isFinished { body() } else { finishObservers.append(body) }
    }

    private func isCancelled() -> Bool { cancelled.current }

    private func finishLease(_ decision: DeskWidgetInstallation.PackageDecision) -> Error? {
        dispatchPrecondition(condition: .onQueue(queue))
        defer { worker.staged = nil }
        do { try worker.staged?.finish(decision); return nil }
        catch { return error }
    }

    private func finish(_ result: Outcome) {
        precondition(Thread.isMainThread)
        guard !isFinished else { return }
        isFinished = true
        let reply = completion
        completion = nil
        let observers = finishObservers
        finishObservers.removeAll()
        reply?(result)
        for observer in observers { observer() }
    }
}
