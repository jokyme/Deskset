import DesksetCore

/// A projection's published drawing facts, with live versions from the app's existing resource services.
final class AppSceneEnvironment: SceneEnvironment {
    private let scale: Double
    private let appearance: AppearanceStamp

    init(scale: Double, appearance: SkinAppearance, appearanceName: String) {
        self.scale = scale
        self.appearance = AppearanceStamp(value: appearance, name: appearanceName)
    }

    var stamp: EnvironmentStamp {
        EnvironmentStamp(scale: scale, fontGeneration: UInt64(Fonts.generation), appearance: appearance,
                         imageGeneration: Images.purgeGeneration)
    }

    func imageStamp(_ path: String) -> ImageStamp? {
        Images.imageStamp(atPath: path)
    }
}
