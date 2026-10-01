import CoreGraphics
import DesksetCore
import DesksetDraw

/// C-path contents for one fixed plan, scale and actual RGB profile. This mutable owner is not Sendable.
/// Every build redraws all content; geometry validation is not a guarantee that members' raster ink fits their boxes.
package final class LayerContentBuilder {
    package typealias Failure = Rasterizer.Failure

    package struct Content {
        package let plan: LayerPlan
        package let image: CGImage
        package let contentsRect: CGRect
    }

    private enum Mode { case empty, single, components }
    private struct Recipes {
        let base: [DrawItem]
        let layers: [[DrawItem]]
    }

    private let plan: PartitionPlan
    private let scale: CGFloat
    private let mode: Mode
    private let base: Rasterizer?
    private let bitmaps: [[Rasterizer]]
    private var nextBitmap = 0
    private var building = false

    /// The budget covers owned bitmap contexts, including both rotating slots. Retained CGImage snapshots and
    /// their copy-on-write storage or native drawing caches are outside this budget, not a process-wide memory cap.
    package init(plan: PartitionPlan, scale: CGFloat, colorSpace: CGColorSpace, maximumOwnedBitmapBytes: Int) throws {
        guard scale.isFinite, scale > 0 else { throw Failure.invalidInput("Scale must be finite and positive") }
        guard colorSpace.model == .rgb else { throw Failure.incompatibleColorSpace }
        guard maximumOwnedBitmapBytes > 0 else { throw Failure.invalidInput("Owned bitmap budget must be positive") }
        let mode = try Self.validateGeometry(plan)
        let required = try Self.requiredStorage(plan, mode: mode)
        guard required <= maximumOwnedBitmapBytes else { throw Failure.resourceLimit("Plan exceeds its owned bitmap budget") }
        var used = 0
        func allocate(_ rect: InkBounds.DeviceRect) throws -> Rasterizer {
            let remaining = maximumOwnedBitmapBytes - used
            guard remaining > 0 else { throw Failure.resourceLimit("No bitmap storage budget remains") }
            let bitmap = try Rasterizer(width: rect.width, height: rect.height, colorSpace: colorSpace,
                                        maximumBitmapBytes: remaining)
            let (total, overflow) = used.addingReportingOverflow(bitmap.storageByteCount)
            guard !overflow, total <= maximumOwnedBitmapBytes else { throw Failure.resourceLimit("Actual row storage exceeds budget") }
            used = total
            return bitmap
        }
        let base: Rasterizer?
        switch mode {
        case .components: base = try allocate(plan.window)
        case .empty, .single: base = nil
        }
        var bitmaps: [[Rasterizer]] = []
        for layer in plan.layers {
            switch layer.content {
            case .fullScene, .group: bitmaps.append([try allocate(layer.rect), try allocate(layer.rect)])
            case .baseSlice: bitmaps.append([])
            }
        }
        self.plan = plan
        self.scale = scale
        self.mode = mode
        self.base = base
        self.bitmaps = bitmaps
    }

    /// No owner, scene, drawing context or callback is retained by a result. A plan or destination change requires
    /// a new builder. Nil resource stamps never authorize bitmap reuse: all recipes execute again on every build.
    package func build(_ scene: WidgetScene, context: DrawContext, cycle: Int, glass: GlassPaint) throws -> [Content] {
        guard !building else { throw Failure.invalidInput("Content building is not reentrant") }
        let recipes = try resolve(scene)
        building = true
        defer { building = false }
        switch mode {
        case .empty: return []
        case .single:
            let layer = plan.layers[0]
            let image = try bitmaps[0][nextBitmap].image(of: recipes.layers[0], in: layer.rect, scale: scale,
                                                        baseCrop: nil, context: context, cycle: cycle, glass: glass)
            nextBitmap = 1 - nextBitmap
            return [Content(plan: layer, image: image, contentsRect: CGRect(x: 0, y: 0, width: 1, height: 1))]
        case .components:
            guard let base else { throw Failure.resourceFailure("The component base bitmap is unavailable") }
            // Background already contains scene glass. Render it and the base members once, at full-window clip.
            let baseImage = try base.image(of: recipes.base, in: plan.window, scale: scale, baseCrop: nil,
                                           context: context, cycle: cycle, glass: glass)
            var result: [Content] = []
            for (index, layer) in plan.layers.enumerated() {
                switch layer.content {
                case .fullScene:
                    throw Failure.invalidPlan("A component plan cannot contain a full-scene layer")
                case .group:
                    let rect = Self.cgRect(layer.rect)
                    guard let crop = baseImage.cropping(to: rect) else {
                        throw Failure.resourceFailure("Cannot crop the group's integer base rectangle")
                    }
                    let image = try bitmaps[index][nextBitmap].image(of: recipes.layers[index], in: layer.rect,
                                                                    scale: scale, baseCrop: crop, context: context,
                                                                    cycle: cycle, glass: glass)
                    result.append(Content(plan: layer, image: image, contentsRect: CGRect(x: 0, y: 0, width: 1, height: 1)))
                case let .baseSlice(source):
                    // Every slice keeps exactly the same image object. Normalized Y starts at its top pixel row.
                    let unit = CGRect(x: CGFloat(source.minX) / CGFloat(plan.window.width),
                                      y: CGFloat(source.minY) / CGFloat(plan.window.height),
                                      width: CGFloat(source.width) / CGFloat(plan.window.width),
                                      height: CGFloat(source.height) / CGFloat(plan.window.height))
                    result.append(Content(plan: layer, image: baseImage, contentsRect: unit))
                }
            }
            nextBitmap = 1 - nextBitmap
            return result
        }
    }

    private func resolve(_ scene: WidgetScene) throws -> Recipes {
        let width = CGFloat(scene.size.width) * scale, height = CGFloat(scene.size.height) * scale
        guard scene.size.width.isFinite, scene.size.height.isFinite, scene.size.width >= 0, scene.size.height >= 0,
              width.isFinite, height.isFinite, width.rounded(.up) == CGFloat(plan.window.width),
              height.rounded(.up) == CGFloat(plan.window.height) else {
            throw Failure.invalidInput("Scene size does not match the plan's canonical device window")
        }
        var sceneIDs = Set<ElementID>()
        for element in scene.elements {
            guard sceneIDs.insert(element.id).inserted else { throw Failure.invalidPlan("Scene contains duplicate element IDs") }
        }
        switch mode {
        case .empty: return Recipes(base: [], layers: [])
        case .single: return Recipes(base: [], layers: [scene.drawingItems])
        case .components: break
        }
        let top = scene.topLevelElements
        var positions: [ElementID: Int] = [:]
        for (index, element) in top.enumerated() { positions[element.id] = index }
        var assigned = Set<ElementID>()
        func members(_ ids: [ElementID]) throws -> [SceneElement] {
            var previous = -1
            var elements: [SceneElement] = []
            for id in ids {
                guard let index = positions[id] else {
                    throw Failure.invalidPlan("Plan member is missing, hidden or a container child: \(id.name)#\(id.index)")
                }
                guard index > previous else { throw Failure.invalidPlan("Plan members must keep scene file order") }
                guard assigned.insert(id).inserted else { throw Failure.invalidPlan("A top-level unit is assigned more than once") }
                previous = index
                elements.append(top[index])
            }
            return elements
        }
        let baseMembers = try members(plan.baseMembers)
        var layers: [[DrawItem]] = []
        for layer in plan.layers {
            switch layer.content {
            case .fullScene: throw Failure.invalidPlan("Full-scene and component recipes cannot mix")
            case let .group(ids):
                // A top-level container expands only through the complete-scene atomic recipe, never selection drawing.
                layers.append(try members(ids).flatMap { scene.drawingItems(for: $0) })
            case .baseSlice: layers.append([])
            }
        }
        _ = try members(plan.skipped)
        guard assigned.count == top.count else { throw Failure.invalidPlan("Plan omits an unclassified top-level unit") }
        let skipped = Set(plan.skipped)
        let drawnIDs = top.map(\.id).filter { !skipped.contains($0) }
        guard Array(drawnIDs.prefix(plan.baseMembers.count)) == plan.baseMembers else {
            throw Failure.invalidPlan("Base members must form the drawn scene's leading prefix")
        }
        return Recipes(base: scene.background + baseMembers.flatMap { scene.drawingItems(for: $0) }, layers: layers)
    }

    private static func validateGeometry(_ plan: PartitionPlan) throws -> Mode {
        let window = plan.window
        guard window.minX == 0, window.minY == 0 else { throw Failure.invalidPlan("Device window origin must be zero") }
        guard window.width <= Rasterizer.maximumDimension, window.height <= Rasterizer.maximumDimension else {
            throw Failure.resourceLimit("Window exceeds the supported bitmap dimensions")
        }
        if window.isEmpty {
            guard plan.layers.isEmpty, plan.baseMembers.isEmpty, plan.skipped.isEmpty else {
                throw Failure.invalidPlan("An empty window cannot contain drawing roles")
            }
            return .empty
        }
        guard !plan.layers.isEmpty else { throw Failure.invalidPlan("A nonempty window needs a complete layer tiling") }
        if plan.layers.contains(where: { if case .fullScene = $0.content { return true }; return false }) {
            guard plan.layers.count == 1, plan.layers[0].id == .single, plan.layers[0].rect == window,
                  plan.baseMembers.isEmpty, plan.skipped.isEmpty else {
                throw Failure.invalidPlan("The Single reference must exclusively cover the full window")
            }
            return .single
        }
        var ids = Set<ElementID>()
        for id in plan.baseMembers + plan.skipped {
            guard ids.insert(id).inserted else { throw Failure.invalidPlan("Duplicate base or skipped member") }
        }
        let (windowArea, windowOverflow) = window.width.multipliedReportingOverflow(by: window.height)
        guard !windowOverflow else { throw Failure.resourceLimit("Window area overflows Int") }
        var area = 0
        for (index, layer) in plan.layers.enumerated() {
            let rect = layer.rect
            guard !rect.isEmpty, rect.minX >= 0, rect.minY >= 0, rect.maxX <= window.maxX, rect.maxY <= window.maxY else {
                throw Failure.invalidPlan("Every layer must be a positive rectangle inside the window")
            }
            for previous in plan.layers.prefix(index) {
                guard previous.id != layer.id else { throw Failure.invalidPlan("Layer identity is duplicated") }
                let other = previous.rect
                guard rect.maxX <= other.minX || other.maxX <= rect.minX || rect.maxY <= other.minY || other.maxY <= rect.minY else {
                    throw Failure.invalidPlan("Layer rectangles share device pixels")
                }
            }
            switch (layer.id, layer.content) {
            case let (.group(fileIndex), .group(members)):
                guard let first = members.map(\.index).min(), first == fileIndex else {
                    throw Failure.invalidPlan("A group needs members and their minimum file index as identity")
                }
                for id in members {
                    guard ids.insert(id).inserted else { throw Failure.invalidPlan("Plan member is assigned to multiple roles") }
                }
            case let (.baseSlice(index), .baseSlice(source)):
                guard index >= 0, source == rect else { throw Failure.invalidPlan("Base slices must select their own device rectangle") }
            default: throw Failure.invalidPlan("Layer identity and content role do not match")
            }
            let (part, partOverflow) = rect.width.multipliedReportingOverflow(by: rect.height)
            let (total, sumOverflow) = area.addingReportingOverflow(part)
            guard !partOverflow, !sumOverflow else { throw Failure.resourceLimit("Layer area sum overflows Int") }
            area = total
        }
        guard area == windowArea else { throw Failure.invalidPlan("Layer rectangles do not completely tile the window") }
        return .components
    }

    private static func requiredStorage(_ plan: PartitionPlan, mode: Mode) throws -> Int {
        var total: Int
        switch mode {
        case .empty: return 0
        case .single: total = 0
        case .components: total = try Rasterizer.requiredBytes(width: plan.window.width, height: plan.window.height)
        }
        for layer in plan.layers {
            switch layer.content {
            case .baseSlice: continue
            case .fullScene, .group:
                let bytes = try Rasterizer.requiredBytes(width: layer.rect.width, height: layer.rect.height)
                let (pair, pairOverflow) = bytes.multipliedReportingOverflow(by: 2)
                let (sum, sumOverflow) = total.addingReportingOverflow(pair)
                guard !pairOverflow, !sumOverflow else { throw Failure.resourceLimit("Plan bitmap budget arithmetic overflows Int") }
                total = sum
            }
        }
        return total
    }

    private static func cgRect(_ rect: InkBounds.DeviceRect) -> CGRect {
        CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}
