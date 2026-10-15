/// The on-disk version of an image source. Decoded images and their caches remain with the renderer.
public struct ImageStamp: Equatable, Sendable {
    public let seconds: Int
    public let nanoseconds: Int
    public let size: Int64
    public let inode: UInt64

    public init(seconds: Int, nanoseconds: Int, size: Int64, inode: UInt64) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
        self.size = size
        self.inode = inode
    }
}

/// Both the skin's resolved semantic colors and the view's drawing appearance affect a scene.
public struct AppearanceStamp: Equatable, Sendable {
    public let value: SkinAppearance
    public let name: String

    public init(value: SkinAppearance, name: String) {
        self.value = value
        self.name = name
    }
}

/// Drawing facts and resource versions captured for one projection. Generations are cache invalidation tokens,
/// not a content digest that can be compared between processes.
public struct EnvironmentStamp: Equatable, Sendable {
    public let scale: Double
    public let fontGeneration: UInt64
    public let appearance: AppearanceStamp
    public let imageGeneration: UInt64

    public init(scale: Double, fontGeneration: UInt64, appearance: AppearanceStamp, imageGeneration: UInt64) {
        self.scale = scale
        self.fontGeneration = fontGeneration
        self.appearance = appearance
        self.imageGeneration = imageGeneration
    }
}

/// Projection reads this service on the skin's owner and carries only its returned values into a scene.
public protocol SceneEnvironment: AnyObject {
    /// The source file's current version, without decoding it. Symbol paths and unavailable files return nil.
    func imageStamp(_ path: String) -> ImageStamp?
    var stamp: EnvironmentStamp { get }
}

/// Keep the path even when its file is missing: it may appear before the next projection. Canonical symbol paths
/// identify their complete style and have no file stamp.
public struct ImageDependency: Equatable, Sendable {
    public let path: String
    public let stamp: ImageStamp?

    public init(path: String, stamp: ImageStamp?) {
        self.path = path
        self.stamp = stamp
    }
}
