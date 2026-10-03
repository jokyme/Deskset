/// Names keep the engine's case-insensitive identity; the file index distinguishes separate occurrences.
public struct ElementID: Equatable, Hashable, Sendable {
    public let name: String
    public let index: Int

    public init(name: String, index: Int) {
        self.name = name.lowercased()
        self.index = index
    }
}

public enum ElementKind: Equatable, Sendable {
    case string, image, bar, line, histogram, roundline, rotator, shape, button, bitmap
    case unknown(String)
}

public enum Visibility: Equatable, Sendable {
    case visible, collapsed, hiddenKeepsSpace
}

public enum Backing: Equatable, Sendable {
    case content
    case native(NativeKind)
}

public enum NativeKind: Equatable, Sendable {
    case glass, symbolEffect, control, animation
}

/// One element's own drawing, kept separately from the composition of a container and its children. Studio
/// selection previews draw these items directly, including selections that are hidden in the full scene.
public struct SceneElement: Equatable, Sendable {
    public var id: ElementID
    public var kind: ElementKind
    public var frame: SkinRect
    public var anchor: SkinPoint
    public var visibility: Visibility
    public var container: ElementID?
    public var isContainer: Bool
    public var items: [DrawItem]
    public var glass: GlassRegion?
    public var imageDependencies: [ImageDependency]
    public var backing: Backing
    /// The owner's drawing revision, captured as a conservative cache invalidation token. It is not a pixel digest.
    public var drawGeneration: Int

    public init(id: ElementID, kind: ElementKind, frame: SkinRect, anchor: SkinPoint, visibility: Visibility,
                container: ElementID?, isContainer: Bool, items: [DrawItem], glass: GlassRegion?,
                imageDependencies: [ImageDependency], backing: Backing = .content, drawGeneration: Int = 0) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.anchor = anchor
        self.visibility = visibility
        self.container = container
        self.isContainer = isContainer
        self.items = items
        self.glass = glass
        self.imageDependencies = imageDependencies
        self.backing = backing
        self.drawGeneration = drawGeneration
    }
}

/// One owner-side projection. Graphics resources, color spaces and caches live outside this transferable value.
public struct WidgetScene: Equatable, Sendable {
    public var generation: UInt64
    public var size: SkinSize
    public var background: [DrawItem]
    public var backgroundImageDependencies: [ImageDependency]
    public var glass: [GlassRegion]
    public var elements: [SceneElement]
    public var hitMap: SkinHitMap
    public var environment: EnvironmentStamp

    public init(generation: UInt64, size: SkinSize, background: [DrawItem],
                backgroundImageDependencies: [ImageDependency], glass: [GlassRegion], elements: [SceneElement],
                hitMap: SkinHitMap, environment: EnvironmentStamp) {
        self.generation = generation
        self.size = size
        self.background = background
        self.backgroundImageDependencies = backgroundImageDependencies
        self.glass = glass
        self.elements = elements
        self.hitMap = hitMap
        self.environment = environment
    }

    public var topLevelElements: [SceneElement] {
        elements.filter { $0.visibility == .visible && $0.container == nil }
    }

    /// One top-level element as drawn in the complete scene. A container's matrix is already inside its mask,
    /// while the clip remains its untransformed layout frame and its children remain in skin coordinates.
    public func drawingItems(for element: SceneElement) -> [DrawItem] {
        guard element.isContainer else { return element.items }
        let children = elements.filter { $0.container == element.id && $0.visibility == .visible }
        guard !children.isEmpty else { return [] }
        return [.container(clip: element.frame, mask: element.items, content: children.flatMap(\.items))]
    }

    /// The bitmap run cache's order: base first, then each top-level composition. Even an empty composition
    /// keeps its position, so run indices continue to identify the same top-level element.
    public var drawingRuns: [[DrawItem]] {
        [background] + topLevelElements.map { drawingItems(for: $0) }
    }

    public var drawingItems: [DrawItem] { drawingRuns.flatMap { $0 } }
}
