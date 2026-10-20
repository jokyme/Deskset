import Foundation

/// A clipboard read may wait for an earlier copy from another skin's executor. Only its resolved string crosses
/// back to an editing owner; the platform clipboard remains on the main thread.
final class SkinTextClipboardRead {
    private let lock = NSLock()
    private var resolved = false
    private var value: String?
    private var observers: [(String?) -> Void] = []

    func whenReady(_ observer: @escaping (String?) -> Void) {
        lock.lock()
        if resolved {
            let result = value
            lock.unlock()
            observer(result)
        } else {
            observers.append(observer)
            lock.unlock()
        }
    }

    fileprivate func resolve(_ value: String?) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        self.value = value
        let waiting = observers
        observers = []
        lock.unlock()
        waiting.forEach { $0(value) }
    }
}

/// User clipboard gestures are ordered across skin windows, including copies which finish asynchronously.
/// A failed or forbidden copy leaves the previous clipboard intact. Main thread only.
final class SkinTextClipboard {
    static let shared = SkinTextClipboard()

    private final class Copy {
        var completed = false
        var value: String?
    }
    private enum Operation { case copy(Copy), read(SkinTextClipboardRead) }
    private var operations: [Operation] = []
    private var draining = false

    func beginCopy() -> (String?) -> Void {
        precondition(Thread.isMainThread)
        let copy = Copy()
        operations.append(.copy(copy))
        return { value in
            precondition(Thread.isMainThread)
            guard !copy.completed else { return }
            copy.completed = true
            copy.value = value
            self.drain()
        }
    }

    func read() -> SkinTextClipboardRead {
        precondition(Thread.isMainThread)
        let read = SkinTextClipboardRead()
        operations.append(.read(read))
        drain()
        return read
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while let first = operations.first {
            switch first {
            case .copy(let copy):
                guard copy.completed else { return }
                operations.removeFirst()
                if let value = copy.value { SkinView.writeTextEditClipboard(value) }
            case .read(let read):
                operations.removeFirst()
                read.resolve(SkinView.readTextEditClipboard())
            }
        }
    }
}
