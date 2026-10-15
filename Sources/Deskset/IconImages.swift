import AppKit
import CoreText
import DesksetCore
import DesksetDraw
import SwiftUI

/// Main creates immutable native symbol documents. Each owner keeps and rasterizes its own prepared resources;
/// no owner waits synchronously for Main, and no SwiftUI view or renderer crosses that boundary.
final class DeskIconResources {
    static let maximumPDFBytes = 16 << 20

    struct Demand: Hashable {
        let request: IconRequest
        let font: ResolvedFont
        let fontGeneration: Int

        static func == (a: Self, b: Self) -> Bool {
            a.request == b.request && a.fontGeneration == b.fontGeneration && CFEqual(a.font.font, b.font.font)
                && a.font.syntheticBold == b.font.syntheticBold && a.font.slant == b.font.slant
                && a.font.characterMap == b.font.characterMap && a.font.lineMetrics == b.font.lineMetrics
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(request.name); hasher.combine(request.style); hasher.combine(request.colors.rawValue)
            hasher.combine(request.appearance.name); hasher.combine(request.appearance.value.isDark)
            hasher.combine(request.scale); hasher.combine(fontGeneration); hasher.combine(CFHash(font.font))
            hasher.combine(font.syntheticBold); hasher.combine(font.slant)
        }
    }

    struct Prepared {
        let size: SkinSize
        let pdf: Data
    }
    struct Entry { let demand: Demand; let prepared: Prepared? }
    struct Batch { let entries: [Entry] }
    enum Lookup { case missing, unknown, ready(Prepared) }
    enum Failure: Error {
        case notPrepared(Demand), invalidResource, resourceBudget, unsupportedRasterContent, nativeRendering
        case invalidMediaBox(expected: SkinSize, actual: SkinRect)
    }

    /// Cancellation is safe from the owner; Main checks it before every native preparation and completion.
    final class Ticket {
        private let cancelled = Guarded(false)
        private let onCancel: (() -> Void)?
        init(onCancel: (() -> Void)? = nil) { self.onCancel = onCancel }
        var isCancelled: Bool { cancelled.current }
        func cancel() {
            let changed = cancelled.access { value -> Bool in
                guard !value else { return false }; value = true; return true
            }
            if changed { onCancel?() }
        }
    }

    private struct Stored {
        let prepared: Prepared?
        let document: CGPDFDocument?
        var used: UInt64
    }
    private var stored: [Demand: Stored] = [:]
    private var committedPins = Set<Demand>()
    private var candidatePins = Set<Demand>()
    private var clock: UInt64 = 0
    private(set) var pdfBytes = 0
    var count: Int { stored.count }

    func beginProjection() { candidatePins.removeAll(keepingCapacity: true) }
    func commitProjection() { committedPins = candidatePins; candidatePins.removeAll(keepingCapacity: true) }
    func cancelProjection() { candidatePins.removeAll(keepingCapacity: true) }

    func lookup(_ demand: Demand) -> Lookup {
        candidatePins.insert(demand)
        guard var entry = stored[demand] else { return .missing }
        clock &+= 1; entry.used = clock; stored[demand] = entry
        return entry.prepared.map(Lookup.ready) ?? .unknown
    }

    /// Installation is atomic and keeps the currently committed scene replayable while a candidate is pending.
    func install(_ batch: Batch) throws {
        var candidate = stored
        var seen = Set<Demand>()
        for entry in batch.entries {
            guard seen.insert(entry.demand).inserted else { throw Failure.invalidResource }
            let document = try entry.prepared.map(Self.document)
            clock &+= 1
            candidate[entry.demand] = Stored(prepared: entry.prepared, document: document, used: clock)
        }
        let protected = committedPins.union(candidatePins)
        var bytes = 0
        for entry in candidate.values {
            let next = bytes.addingReportingOverflow(entry.prepared?.pdf.count ?? 0)
            guard !next.overflow else { throw Failure.resourceBudget }; bytes = next.partialValue
        }
        // A frame may legitimately use more than 1024 small symbols; only historical entries are trimmed.
        while bytes > Self.maximumPDFBytes || candidate.count > 1024 {
            guard let oldest = candidate.filter({ !protected.contains($0.key) }).min(by: { $0.value.used < $1.value.used }) else {
                if bytes > Self.maximumPDFBytes { throw Failure.resourceBudget }
                break
            }
            bytes -= oldest.value.prepared?.pdf.count ?? 0
            candidate.removeValue(forKey: oldest.key)
        }
        stored = candidate; pdfBytes = bytes
    }

    fileprivate func page(_ demand: Demand) throws -> CGPDFPage? {
        switch lookup(demand) {
        case .missing: throw Failure.notPrepared(demand)
        case .unknown: return nil
        case .ready:
            guard let page = stored[demand]?.document?.page(at: 1) else { throw Failure.invalidResource }
            return page
        }
    }

    static func prepare(_ demands: [Demand], completion: @escaping (Result<Batch, Error>) -> Void) -> Ticket {
        let ticket = Ticket()
        let job = Job(demands: demands, ticket: ticket, completion: completion)
        DispatchQueue.main.async { job.step() }
        return ticket
    }

    private final class Job {
        let demands: [Demand]
        let ticket: Ticket
        let completion: (Result<Batch, Error>) -> Void
        var entries: [Entry] = []
        var index = 0
        var bytes = 0
        init(demands: [Demand], ticket: Ticket, completion: @escaping (Result<Batch, Error>) -> Void) {
            var seen = Set<Demand>()
            self.demands = demands.filter { seen.insert($0).inserted }
            self.ticket = ticket; self.completion = completion
        }
        func step() {
            precondition(Thread.isMainThread)
            guard !ticket.isCancelled else { return }
            do {
                // Yield between small batches, so closing a preview can cancel a large source promptly.
                let end = min(index + 8, demands.count)
                while index < end {
                    guard !ticket.isCancelled else { return }
                    let demand = demands[index]
                    let prepared = try MainActor.assumeIsolated { try DeskIconResources.make(demand) }
                    let next = bytes.addingReportingOverflow(prepared?.pdf.count ?? 0)
                    guard !next.overflow, next.partialValue <= DeskIconResources.maximumPDFBytes else {
                        throw Failure.resourceBudget
                    }
                    bytes = next.partialValue; entries.append(Entry(demand: demand, prepared: prepared)); index += 1
                }
                guard !ticket.isCancelled else { return }
                if index == demands.count { completion(.success(Batch(entries: entries))) }
                else { DispatchQueue.main.async { self.step() } }
            } catch {
                if !ticket.isCancelled { completion(.failure(error)) }
            }
        }
    }

    @MainActor
    private static func make(_ demand: Demand) throws -> Prepared? {
        let request = demand.request, color = request.style.color
        let points = TextStyle.pixelSize(points: request.style.fontSize)
        guard points.isFinite, points > 0, points <= Double(IconCache.maximumDimension),
              request.scale.isFinite, request.scale > 0,
              request.scale <= Double(IconCache.maximumDimension),
              [color.r, color.g, color.b, color.a].allSatisfy(\.isFinite) else { throw Failure.invalidResource }
        guard !request.name.isEmpty,
              NSImage(systemSymbolName: request.name, accessibilityDescription: nil) != nil else { return nil }
        let font = CTFontCreateCopyWithAttributes(demand.font.font, points, nil, nil)
        var nativeFont = SwiftUI.Font(font)
        if demand.font.syntheticBold { nativeFont = nativeFont.bold() }
        if demand.font.slant != 0 { nativeFont = nativeFont.italic() }
        let mode: SymbolRenderingMode
        switch request.colors {
        case .monochrome: mode = .monochrome
        case .hierarchical: mode = .hierarchical
        case .multicolor: mode = .multicolor
        }
        let foreground = Color(.sRGB, red: min(max(color.r / 255, 0), 1), green: min(max(color.g / 255, 0), 1),
                               blue: min(max(color.b / 255, 0), 1), opacity: min(max(color.a / 255, 0), 1))
        // Native SF Symbols use the font's size/weight. Family/design/italic remain in this complete request;
        // the system decides their effect rather than a Desk-specific synthetic distortion of the symbol.
        let content = SwiftUI.Image(systemName: request.name).font(nativeFont)
            .symbolRenderingMode(mode).foregroundStyle(foreground)
            .environment(\.colorScheme, request.appearance.value.isDark ? .dark : .light)
            .environment(\.displayScale, request.scale).fixedSize()
        let renderer = SwiftUI.ImageRenderer(content: content)
        renderer.scale = request.scale; renderer.colorMode = .nonLinear
        let data = NSMutableData()
        var logical = CGSize.zero
        var written = false
        let appearance = NSAppearance(named: NSAppearance.Name(request.appearance.name))
            ?? NSAppearance(named: request.appearance.value.isDark ? .darkAqua : .aqua)
        let render = {
            renderer.render(rasterizationScale: 1) { size, draw in
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                      size.width <= CGFloat(IconCache.maximumDimension), size.height <= CGFloat(IconCache.maximumDimension) else { return }
                logical = size
                var box = CGRect(origin: .zero, size: size)
                guard let consumer = CGDataConsumer(data: data as CFMutableData),
                      let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
                pdf.beginPDFPage(nil); draw(pdf); pdf.endPDFPage(); pdf.closePDF(); written = true
            }
        }
        if let appearance { appearance.performAsCurrentDrawingAppearance(render) } else { render() }
        guard written else { throw Failure.nativeRendering }
        let prepared = Prepared(size: SkinSize(width: logical.width, height: logical.height), pdf: data as Data)
        _ = try document(prepared)
        return prepared
    }

    private static func document(_ prepared: Prepared) throws -> CGPDFDocument {
        guard prepared.size.width.isFinite, prepared.size.height.isFinite, prepared.size.width > 0, prepared.size.height > 0,
              !prepared.pdf.isEmpty, prepared.pdf.count <= maximumPDFBytes,
              let provider = CGDataProvider(data: prepared.pdf as CFData), let document = CGPDFDocument(provider),
              document.numberOfPages == 1, let page = document.page(at: 1) else { throw Failure.invalidResource }
        let box = page.getBoxRect(.mediaBox)
        // Quartz serializes native fractional page bounds to five decimal places (for example 28 2/3
        // becomes 28.66667). This tolerance covers that serialization; layout retains the original size.
        guard box.minX == 0, box.minY == 0,
              abs(box.width - prepared.size.width) < 0.000_01,
              abs(box.height - prepared.size.height) < 0.000_01 else {
            throw Failure.invalidMediaBox(expected: prepared.size,
                actual: SkinRect(x: box.minX, y: box.minY, width: box.width, height: box.height))
        }
        let audit = PDFAudit(), content = CGPDFContentStreamCreateWithPage(page)
        audit.inspect(content)
        if let dictionary = page.dictionary { audit.inspect(dictionary, parent: content) }
        guard !audit.unsupported else { throw Failure.unsupportedRasterContent }
        return document
    }

    /// Qualifies the native producer's page/Form content for image XObjects and inline bitmap fallback.
    /// This is not an arbitrary-PDF validator; other vector resources remain the system producer's contract.
    private final class PDFAudit {
        var unsupported = false
        var depth = 0
        var parents: [CGPDFContentStreamRef] = []

        func inspect(_ content: CGPDFContentStreamRef) {
            guard let operators = CGPDFOperatorTableCreate() else { unsupported = true; return }
            // CGPDFScanner reports an inline image at EI, after consuming its dictionary and bytes.
            CGPDFOperatorTableSetCallback(operators, "EI") { _, info in
                guard let info else { return }
                Unmanaged<DeskIconResources.PDFAudit>.fromOpaque(info).takeUnretainedValue().unsupported = true
            }
            let scanner = CGPDFScannerCreate(content, operators, Unmanaged.passUnretained(self).toOpaque())
            if !CGPDFScannerScan(scanner) { unsupported = true }
        }

        func inspect(_ dictionary: CGPDFDictionaryRef, parent: CGPDFContentStreamRef) {
            guard depth < 16 else { unsupported = true; return }
            var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
                  CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return }
            depth += 1
            parents.append(parent)
            defer { depth -= 1; parents.removeLast() }
            CGPDFDictionaryApplyFunction(objects, { _, object, info in
                guard let info else { return }
                let audit = Unmanaged<DeskIconResources.PDFAudit>.fromOpaque(info).takeUnretainedValue()
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let dictionary = CGPDFStreamGetDictionary(stream) else { return }
                var type: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dictionary, "Subtype", &type), let type else { return }
                switch String(cString: type) {
                case "Image": audit.unsupported = true
                case "Form":
                    var resources: CGPDFDictionaryRef?
                    _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                    guard let parent = audit.parents.last else { audit.unsupported = true; return }
                    let content = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, parent)
                    audit.inspect(content)
                    audit.inspect(dictionary, parent: content)
                default: break
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        }
    }
}

struct AppIconRasterizer: IconRasterizing {
    let resources: DeskIconResources

    func isPrepared(_ request: IconRequest, font: ResolvedFont, fontGeneration: Int) -> Bool {
        if case .missing = resources.lookup(.init(request: request, font: font, fontGeneration: fontGeneration)) { return false }
        return true
    }

    func measure(_ request: IconRequest, font: ResolvedFont, fontGeneration: Int) throws -> SkinSize? {
        let demand = DeskIconResources.Demand(request: request, font: font, fontGeneration: fontGeneration)
        switch resources.lookup(demand) {
        case .missing: throw DeskIconResources.Failure.notPrepared(demand)
        case .unknown: return nil
        case .ready(let prepared): return prepared.size
        }
    }

    func rasterize(_ request: IconRequest, font: ResolvedFont, fontGeneration: Int, naturalSize: SkinSize,
                   pixelWidth: Int, pixelHeight: Int) throws -> RasterizedSymbol {
        let demand = DeskIconResources.Demand(request: request, font: font, fontGeneration: fontGeneration)
        guard let page = try resources.page(demand), pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= IconCache.maximumDimension, pixelHeight <= IconCache.maximumDimension else {
            throw IconDrawingError.rasterization
        }
        let row = pixelWidth.multipliedReportingOverflow(by: 4)
        let bytes = row.partialValue.multipliedReportingOverflow(by: pixelHeight)
        guard !row.overflow, !bytes.overflow, bytes.partialValue <= IconCache.maximumBitmapBytes,
              naturalSize.width > 0, naturalSize.height > 0,
              naturalSize.width.isFinite, naturalSize.height.isFinite,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: row.partialValue, space: space,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                        | CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw IconDrawingError.bitmapBudget }
        context.scaleBy(x: CGFloat(pixelWidth) / naturalSize.width, y: CGFloat(pixelHeight) / naturalSize.height)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw IconDrawingError.rasterization }
        return RasterizedSymbol(image: image, pointSize: CGSize(width: naturalSize.width, height: naturalSize.height))
    }
}
