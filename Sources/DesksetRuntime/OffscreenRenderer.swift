import CoreGraphics
import Dispatch
import Foundation
import Metal
import QuartzCore

/// One fixed-size offscreen destination, confined to its caller's serialized owner. Trees must be fully built
/// with their explicit transactions committed; their geometry, scale and animation time are not rewritten here.
/// This object is not Sendable. It reuses one renderer, texture and queue across successive trees.
package final class OffscreenRenderer {
    package struct Readback: Equatable, Sendable {
        package let width: Int
        package let height: Int
        /// Tightly packed, premultiplied RGBA bytes in the configured RGB output space, with the top row first.
        /// Each result owns its storage.
        package let rgba: [UInt8]
    }

    package indirect enum Failure: Error, Equatable {
        case invalidInput(String)
        case resourceLimit(String)
        case resourceFailure(String)
        case unavailable(String)
        case commandFailure(stage: String, status: UInt, detail: String)
        case canaryFailure(String)
        case timeout
        case invalidated(Failure)
    }

    /// Diagnostic state only: a business frame cannot bypass this first-render check.
    package private(set) var hasVerifiedCanary = false

    private let width: Int
    private let height: Int
    private let rowBytes: Int
    private let byteCount: Int
    private var resources: Resources?
    private var invalidation: Failure?
    private var rendering = false

    private struct Resources {
        let queue: any MTLCommandQueue
        let texture: any MTLTexture
        let renderer: CARenderer
        let colorSpace: CGColorSpace
    }

    /// Metal's completed handler is @Sendable. This immutable lease only extends native object lifetimes;
    /// the handler never reads or mutates their state, calls Core Animation, or captures the owner. On timeout
    /// the owner drops its resources, while this lease keeps them alive until actual GPU completion.
    private final class CompletionLease: @unchecked Sendable {
        let resources: Resources
        let tree: CALayer

        init(resources: Resources, tree: CALayer) {
            self.resources = resources
            self.tree = tree
        }
    }

    /// The budget bounds one readback, not total process/GPU memory. Canary image/provider storage and a raw
    /// scribble also consume memory. Optional native allocations are checked; Swift array OOM is not recoverable.
    /// A nil colorSpace preserves the existing sRGB output. A supplied RGB space is retained by the native
    /// destination and its known-image canary; readback bytes are not subsequently converted to sRGB.
    package init(width: Int, height: Int, device: (any MTLDevice)?, maximumReadbackBytes: Int,
                 colorSpace: CGColorSpace? = nil) throws {
        guard width > 0, height > 0 else { throw Failure.invalidInput("Dimensions must be positive") }
        guard maximumReadbackBytes > 0 else { throw Failure.invalidInput("Readback budget must be positive") }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, byteOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !byteOverflow else { throw Failure.resourceLimit("Readback dimensions overflow Int") }
        guard byteCount <= maximumReadbackBytes else { throw Failure.resourceLimit("Readback exceeds byte budget") }
        guard !byteCount.multipliedReportingOverflow(by: 4).overflow else {
            throw Failure.resourceLimit("Canary temporary byte counts overflow Int")
        }
        guard let device else { throw Failure.unavailable("Metal device is unavailable") }
        // Metal 3 supports 16K textures; use the conservative 8K limit for earlier supported families.
        let maximumDimension = device.supportsFamily(.metal3) ? 16_384 : 8_192
        guard width <= maximumDimension, height <= maximumDimension else {
            throw Failure.resourceLimit("Dimensions exceed the supported \(maximumDimension)-pixel limit")
        }
        guard let colorSpace = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw Failure.resourceFailure("Cannot create the sRGB color space")
        }
        guard colorSpace.model == .rgb else { throw Failure.invalidInput("Output color space must be RGB") }
        guard let queue = device.makeCommandQueue() else { throw Failure.resourceFailure("Cannot create Metal queue") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                 height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        // Keep the system texture default for CPU readback; unified memory does not imply shared texture support.
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw Failure.resourceFailure("Cannot allocate the offscreen texture")
        }
        // CARenderer's NSDictionary bridge requires heterogeneous values: CGColorSpace and MTLCommandQueue.
        let options: [String: Any] = [kCARendererColorSpace: colorSpace, kCARendererMetalCommandQueue: queue]
        let renderer = CARenderer(mtlTexture: texture, options: options)
        renderer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        self.width = width
        self.height = height
        self.rowBytes = rowBytes
        self.byteCount = byteCount
        self.resources = Resources(queue: queue, texture: texture, renderer: renderer, colorSpace: colorSpace)
    }

    /// A deadline bounds GPU completion waiting, including automatic canary work. It cannot interrupt native
    /// synchronous calls such as CATransaction.flush, CARenderer.render or getBytes; the process watchdog remains
    /// necessary. A timeout after submission invalidates this instance, and no texture bytes are read afterward.
    package func render(_ tree: CALayer, at frameTime: CFTimeInterval, deadline: DispatchTime) throws -> Readback {
        if let invalidation { throw Failure.invalidated(invalidation) }
        guard frameTime.isFinite else { throw Failure.invalidInput("Frame time must be finite") }
        guard !rendering else { throw Failure.invalidInput("Offscreen rendering is not reentrant") }
        try checkDeadline(deadline)
        guard let resources else { throw Failure.resourceFailure("Offscreen resources are unavailable") }
        rendering = true
        defer { rendering = false }
        if !hasVerifiedCanary {
            try verifyCanary(resources, at: frameTime, deadline: deadline)
            hasVerifiedCanary = true
        }
        return try renderFrame(tree, resources: resources, at: frameTime, deadline: deadline)
    }

    private func checkDeadline(_ deadline: DispatchTime) throws {
        guard deadline != .distantFuture else { throw Failure.invalidInput("A finite GPU deadline is required") }
        guard DispatchTime.now() < deadline else { throw Failure.timeout }
    }

    private func invalidate(_ failure: Failure) {
        invalidation = failure
        resources = nil
    }

    private func renderFrame(_ tree: CALayer, resources: Resources, at frameTime: CFTimeInterval,
                             deadline: DispatchTime) throws -> Readback {
        try checkDeadline(deadline)
        // Allocate and encode all caller-owned commands before submitting any work, so an allocation/encoder
        // failure cannot strand already submitted CA work without our completion lease and fence.
        guard let clear = resources.queue.makeCommandBuffer(), let done = resources.queue.makeCommandBuffer() else {
            throw Failure.resourceFailure("Cannot create offscreen command buffers")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = resources.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = clear.makeRenderCommandEncoder(descriptor: pass) else {
            throw Failure.resourceFailure("Cannot create the transparent clear encoder")
        }
        encoder.endEncoding()
        if resources.texture.storageMode == .managed {
            guard let blit = done.makeBlitCommandEncoder() else {
                throw Failure.resourceFailure("Cannot create the managed readback synchronization encoder")
            }
            blit.synchronize(resource: resources.texture)
            blit.endEncoding()
        }

        resources.renderer.layer = tree
        CATransaction.flush()
        // Expiry before submission leaves no in-flight frame and does not poison a reusable instance.
        do { try checkDeadline(deadline) } catch {
            resources.renderer.layer = nil
            throw error
        }
        let completion = DispatchSemaphore(value: 0)
        let lease = CompletionLease(resources: resources, tree: tree)
        done.addCompletedHandler { _ -> Void in
            withExtendedLifetime(lease) { _ = completion.signal() }
        }
        clear.commit()
        resources.renderer.beginFrame(atTime: frameTime, timeStamp: nil)
        resources.renderer.addUpdate(resources.renderer.bounds)
        resources.renderer.render()
        resources.renderer.endFrame()
        done.commit()
        // A synchronous native call may return after the deadline. Even an already-signalled semaphore must
        // not turn that expired frame into a successful readback; the committed tail still releases its lease.
        guard DispatchTime.now() < deadline, completion.wait(timeout: deadline) == .success else {
            invalidate(.timeout)
            throw Failure.timeout
        }
        // The tail has completed on the same queue. Detach only now, never while a timed-out frame is in flight.
        defer { resources.renderer.layer = nil }
        for (stage, command) in [("clear", clear), ("readback", done)] {
            guard command.status == .completed, command.error == nil else {
                let failure = Failure.commandFailure(stage: stage, status: command.status.rawValue,
                                                     detail: command.error?.localizedDescription ?? "No Metal error detail")
                invalidate(failure)
                throw failure
            }
        }
        return try read(resources.texture)
    }

    private func read(_ texture: any MTLTexture) throws -> Readback {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        try bytes.withUnsafeMutableBytes { storage in
            guard let base = storage.baseAddress else { throw Failure.resourceFailure("Cannot access readback bytes") }
            texture.getBytes(base, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        // CARenderer's Metal destination is bottom-row first. Convert storage order and BGRA channels in place;
        // there is no color conversion or unpremultiplication here.
        for y in 0..<(height / 2) {
            let top = y * rowBytes, bottom = (height - 1 - y) * rowBytes
            for byte in 0..<rowBytes { bytes.swapAt(top + byte, bottom + byte) }
        }
        for pixel in stride(from: 0, to: byteCount, by: 4) { bytes.swapAt(pixel, pixel + 2) }
        return Readback(width: width, height: height, rgba: bytes)
    }

    private func verifyCanary(_ resources: Resources, at frameTime: CFTimeInterval, deadline: DispatchTime) throws {
        let expected = canaryBytes()
        guard let provider = CGDataProvider(data: Data(expected) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: rowBytes, space: resources.colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure.resourceFailure("Cannot allocate the known-image canary")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let tree = CALayer()
        tree.anchorPoint = .zero
        tree.bounds = resources.renderer.bounds
        tree.isGeometryFlipped = true
        tree.contentsFormat = .RGBA8Uint
        let imageLayer = CALayer()
        imageLayer.anchorPoint = .zero
        imageLayer.frame = tree.bounds
        imageLayer.contents = image
        imageLayer.contentsScale = 1
        imageLayer.contentsFormat = .RGBA8Uint
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        tree.addSublayer(imageLayer)
        CATransaction.commit()

        try checkDeadline(deadline)
        // Poison the actual reusable destination. Equality of two stale or empty readbacks is not a canary.
        let scribble = [UInt8](repeating: 0xA5, count: byteCount)
        try scribble.withUnsafeBytes { storage in
            guard let base = storage.baseAddress else { throw Failure.resourceFailure("Cannot access canary scribble") }
            resources.texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                      withBytes: base, bytesPerRow: rowBytes)
        }
        let result = try renderFrame(tree, resources: resources, at: frameTime, deadline: deadline)
        if let difference = expected.indices.first(where: { expected[$0] != result.rgba[$0] }) {
            let failure = Failure.canaryFailure("byte \(difference): expected \(expected[difference]), got \(result.rgba[difference]); "
                + "blank=\(result.rgba.allSatisfy { $0 == 0 }), stillScribbled=\(result.rgba.allSatisfy { $0 == 0xA5 }); "
                + "device=\(resources.texture.device.name), storage=\(resources.texture.storageMode.rawValue)")
            invalidate(failure)
            throw failure
        }
    }

    private func canaryBytes() -> [UInt8] {
        // Integer-only premultiplied pixels: unequal R/B, asymmetric rows, opaque, translucent and clear points.
        let alphas = [255, 200, 128, 37, 0]
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for y in 0..<height {
            for x in 0..<width {
                let alpha = alphas[(x + 3 * y) % alphas.count]
                let rgb = [(x * 17 + y * 31 + 73) & 255, (x * 43 + y * 7 + 11) & 255,
                           (x * 5 + y * 59 + 193) & 255]
                let pixel = (y * width + x) * 4
                for channel in 0..<3 { bytes[pixel + channel] = UInt8((rgb[channel] * alpha + 127) / 255) }
                bytes[pixel + 3] = UInt8(alpha)
            }
        }
        return bytes
    }
}
