import Foundation

/// Queried in projection order, without an eagerly copied owner state or retained owner.
protocol SceneProjectionSource: AnyObject {
    var meters: [Meter] { get }
    var width: Double { get }
    var height: Double { get }
    var settings: SkinSettings { get }
    func assertOwned(_ entry: StaticString)
    func projectionGlass(_ source: SceneProjector.GlassSource) -> [GlassRegion]
    func makeHitMap() -> SkinHitMap
}

extension Skin: SceneProjectionSource {
    func projectionGlass(_ source: SceneProjector.GlassSource) -> [GlassRegion] {
        switch source {
        case .published: return glassRegions
        case .current: return currentGlassRegions()
        }
    }
}

/// Captures a complete scene on the skin's owner. The projector keeps only its sequence number, so old scenes
/// stay independent after the owner updates, refreshes or unloads. Drawing inputs are captured on every call:
/// measure ranges and files can change without a meter's draw generation changing.
public final class SceneProjector {
    public enum GlassSource {
        /// The regions published by the last redraw, as shown by the skin window.
        case published
        /// The regions computed from the current layout, as used by live Studio and offscreen previews.
        case current
    }

    private var generation: UInt64 = 0

    public init() {}

    public func project(_ skin: Skin, environment: SceneEnvironment, glassSource: GlassSource = .current) -> WidgetScene {
        project(source: skin, environment: environment, glassSource: glassSource)
    }

    func project(source skin: any SceneProjectionSource, environment: SceneEnvironment,
                 glassSource: GlassSource = .current) -> WidgetScene {
        skin.assertOwned(#function)
        generation &+= 1
        let stamp = environment.stamp
        let ids = Dictionary(uniqueKeysWithValues: skin.meters.enumerated().map {
            (ObjectIdentifier($0.element), ElementID(name: $0.element.name, index: $0.offset))
        })
        var dependencies: [String: ImageDependency] = [:]
        func captureDependencies(_ items: [DrawItem]) -> [ImageDependency] {
            imageDependencies(items, environment: environment, captured: &dependencies)
        }
        let elements = skin.meters.enumerated().map { index, meter in
            capture(meter, id: ElementID(name: meter.name, index: index),
                    container: meter.container.flatMap { ids[ObjectIdentifier($0)] },
                    dependencies: captureDependencies)
        }
        let glass = skin.projectionGlass(glassSource)
        let background = glass.map(DrawItem.glass) + backgroundItems(skin)
        return WidgetScene(generation: generation, size: SkinSize(width: skin.width, height: skin.height),
                           background: background, backgroundImageDependencies: captureDependencies(background),
                           glass: glass, elements: elements, hitMap: skin.makeHitMap(), environment: stamp)
    }

    /// A selection's own drawing, independent of hidden state and container composition. Its metadata still
    /// identifies its position in the complete scene, while glass follows the single-meter preview contract.
    public func projectElement(_ meter: Meter, index: Int = 0, environment: SceneEnvironment) -> SceneElement {
        meter.skin.assertOwned()
        var captured: [String: ImageDependency] = [:]
        let container = meter.container.flatMap { owner -> ElementID? in
            guard let position = meter.skin.meters.firstIndex(where: { $0 === owner }) else { return nil }
            return ElementID(name: owner.name, index: position)
        }
        return capture(meter, id: ElementID(name: meter.name, index: index), container: container) {
            imageDependencies($0, environment: environment, captured: &captured)
        }
    }

    private func capture(_ meter: Meter, id: ElementID, container: ElementID?,
                         dependencies: ([DrawItem]) -> [ImageDependency]) -> SceneElement {
        let (kind, leaf) = leafItem(meter)
        var items: [DrawItem] = []
        if meter.solidColor.a > 0 || (meter.solidColor2?.a ?? 0) > 0 {
            items.append(.fill(meter.frame, Paint(color: meter.solidColor, secondColor: meter.solidColor2,
                                                 angle: meter.gradientAngle)))
        }
        items.append(.bevel(meter.frame, BevelDraw(type: meter.bevelType, light: meter.bevelColor,
                                                  dark: meter.bevelColor2)))
        if let leaf { items.append(leaf) }
        let transform: ShapeTransform
        if let m = meter.transformationMatrix {
            transform = ShapeTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
        } else {
            transform = .identity
        }
        let ownItems: [DrawItem] = [.transformed(transform, items)]
        return SceneElement(id: id, kind: kind, frame: meter.frame,
                            anchor: SkinPoint(x: meter.anchorX, y: meter.anchorY),
                            visibility: meter.hidden ? .collapsed : .visible, container: container,
                            isContainer: meter.isContainer, items: ownItems, glass: meter.glassRegion,
                            imageDependencies: dependencies(ownItems), drawGeneration: meter.drawGeneration)
    }

    private func leafItem(_ meter: Meter) -> (ElementKind, DrawItem?) {
        switch meter {
        case let m as StringMeter: return (.string, .text(m.lower()))
        case let m as ImageMeter: return (.image, .image(m.lower()))
        case let m as BarMeter: return (.bar, .bar(m.lower()))
        case let m as LineMeter: return (.line, .graph(.line(m.lower())))
        case let m as HistogramMeter: return (.histogram, .graph(.histogram(m.lower())))
        case let m as RoundlineMeter: return (.roundline, .roundline(m.lower()))
        case let m as RotatorMeter: return (.rotator, .rotator(m.lower()))
        case let m as ShapeMeter: return (.shape, .shape(m.lower()))
        case let m as ButtonMeter: return (.button, .sprite(m.lower()))
        case let m as BitmapMeter: return (.bitmap, .sprite(m.lower()))
        default: return (.unknown(meter.type), nil)
        }
    }

    private func backgroundItems(_ skin: any SceneProjectionSource) -> [DrawItem] {
        let settings = skin.settings
        let frame = SkinRect(width: skin.width, height: skin.height)
        switch settings.backgroundMode {
        case 2:
            return [.fill(frame, Paint(color: settings.solidColor, secondColor: settings.solidColor2,
                                      angle: settings.gradientAngle)),
                    .bevel(frame, BevelDraw(type: settings.bevelType, light: settings.bevelColor,
                                           dark: settings.bevelColor2))]
        case 0, 3, 4:
            guard let path = settings.backgroundImage else { return [] }
            let placement: ImageDraw.Placement
            switch settings.backgroundMode {
            case 0: placement = .backgroundNatural
            case 4: placement = .backgroundTiled
            default: placement = .meter
            }
            let m = settings.backgroundMargins
            let margins = settings.backgroundMode == 3 && (m.left != 0 || m.top != 0 || m.right != 0 || m.bottom != 0)
                ? m : nil
            return [.image(ImageDraw(contentFrame: frame, path: path, options: settings.backgroundImageOptions,
                                     maskPath: nil, maskOptions: ImageOptions(), preserveAspectRatio: 0, tile: false,
                                     scaleMargins: margins, decodesAtDrawnSize: false, placement: placement))]
        default:
            return []
        }
    }

    private func imageDependencies(_ items: [DrawItem], environment: SceneEnvironment,
                                   captured: inout [String: ImageDependency]) -> [ImageDependency] {
        var seen: Set<String> = []
        return resourcePaths(items).compactMap { path in
            guard seen.insert(path).inserted else { return nil }
            if let dependency = captured[path] { return dependency }
            let dependency = ImageDependency(path: path, stamp: environment.imageStamp(path))
            captured[path] = dependency
            return dependency
        }
    }

    private func resourcePaths(_ items: [DrawItem]) -> [String] {
        items.flatMap { item -> [String] in
            switch item {
            case .image(let image): return [image.path, image.maskPath].compactMap { $0 }
            case .bar(let bar): return [bar.path].compactMap { $0 }
            case .rotator(let rotator): return [rotator.path].compactMap { $0 }
            case .sprite(let sprite): return [sprite.path].compactMap { $0 }
            case .graph(.histogram(let graph)):
                return [graph.primaryImage?.path, graph.secondaryImage?.path, graph.bothImage?.path].compactMap { $0 }
            case .transformed(_, let children), .antialias(_, let children): return resourcePaths(children)
            case .container(_, let mask, let content): return resourcePaths(mask) + resourcePaths(content)
            default: return []
            }
        }
    }
}
