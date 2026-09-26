import Foundation
import ObjectiveC

/// Fails a self-test suite that asks the system's icon service for an icon (a file's or an app's icon, a window
/// title's document icon…) on the main thread. On CI's Intel runner that service never answers, and the first request
/// waits for it forever: on the main thread, the whole run stops there. Here it answers, so the suite goes on, but it
/// fails with the caller's stack: fake the icon (`ApplicationLocating.icon`), leave the icon out headless, or — for a
/// suite about real icons — allow it (`beginAllowing` / `endAllowing`) and make the request on a background thread,
/// with a time-out. Background requests are never reported: one that waits forever holds only its own thread (and may
/// reach the service long after its suite gave up waiting, as FileView's did on the Intel runner).
///
/// It watches `+[ISIconManager sharedInstance]` (IconServices, a private framework; every icon asks it). When the class
/// cannot be found, it watches nothing.
enum IconServiceGuard {
    /// Called with the suite's first request and its stack.
    static var onUse: ((_ stack: [String]) -> Void)?
    private static var allowedDepth = 0
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        _ = dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_LAZY)
        let selector = NSSelectorFromString("sharedInstance")
        guard let iconManager = NSClassFromString("ISIconManager"),
              let method = class_getClassMethod(iconManager, selector) else { return }
        typealias SharedInstance = @convention(c) (AnyClass, Selector) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: SharedInstance.self)
        let watched: @convention(block) (AnyClass) -> AnyObject? = { cls in
            if Thread.isMainThread, allowedDepth == 0 { IconServiceGuard.report() }
            return original(cls, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(watched))
    }

    /// Requests to the icon service are allowed until `endAllowing` (a suite about real icons; main thread).
    static func beginAllowing() { allowedDepth += 1 }
    static func endAllowing() { allowedDepth -= 1 }

    private static func report() {
        onUse?(Array(Thread.callStackSymbols.dropFirst(2).filter { $0.contains("Deskset ") }.prefix(12)))
    }
}
