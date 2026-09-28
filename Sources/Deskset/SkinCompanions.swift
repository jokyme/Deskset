import AppKit
import DesksetCore

// Window companions (docs/skin-threading.md §15, phase 2 step 5): windows that plugins show with a skin's window —
// FrostedGlass's backdrop behind it, InputText's box over it. They live on the main thread with the window. The plugin
// measures, on the skin's executor, ask for them with values (`SkinCompanionRequest`: the style; the box's settings and
// the skin's size) through the skin's runtime (`SkinCompanionChannel`), in order with the skin's other requests, and
// InputText's answer comes back to the skin as a message (`SkinMessage.inputTextAnswered`). No plugin reaches the
// window controller.

/// What a plugin measure asks of its skin's window: the skin's runtime (`SkinRuntime`), on the skin's executor. Skins
/// without a window (`--render`, thumbnails, the Studio's own instance of a widget) have none.
protocol SkinCompanionChannel: AnyObject {
    /// Asks the window for a companion (FrostedGlass's backdrop).
    func companion(_ companion: SkinCompanionRequest)
    /// Opens an InputText box over the window; `answered` runs on the skin's executor with what the person typed
    /// (nil: dismissed). Returns the box's id.
    func showInputText(_ settings: InputTextSettings, answered: @escaping (String?) -> Void) -> Int
    /// Closes the box `id` without an answer.
    func cancelInputText(_ id: Int)
}

/// What a window companion sees of the skin window it goes with (main thread).
protocol SkinCompanionHost: AnyObject {
    /// The skin's window now (a new panel replaces it when ClickThrough is turned off again).
    var skinWindow: NSWindow { get }
    /// The window's content view: the glass and the view the skin's frames are shown in.
    var skinContentView: NSView { get }
    /// Windows are shown at all (not in the headless self-tests).
    var showsWindows: Bool { get }
    /// The skin was closed.
    var isStopped: Bool { get }
}

/// The companions of one skin window, on the main thread: made when the skin asks for them, they follow the window
/// (`windowChanged`, `animateAlpha`) and go with it (`tearDown`).
final class SkinWindowCompanions {
    private unowned let host: SkinCompanionHost
    private weak var runtime: SkinRuntime?
    /// FrostedGlass's backdrop (kept by `FrostedGlassBackdrop` until it is removed), and the measure whose style it
    /// shows.
    private(set) weak var backdrop: FrostedGlassBackdrop?
    private var backdropOwner: Int?
    /// The open InputText boxes, by id.
    private var prompts: [Int: InputTextPrompting] = [:]

    /// Self-tests: the box shown instead of `InputTextPanelPrompt` (a headless app shows none: the box is dismissed).
    static var inputTextPromptFactory: ((SkinCompanionHost) -> InputTextPrompting)?

    init(host: SkinCompanionHost, runtime: SkinRuntime) {
        self.host = host
        self.runtime = runtime
    }

    /// InputText boxes open now (tests).
    var openInputTexts: Int { prompts.count }

    /// Does what the skin asked (`SkinRequest.companion`).
    func apply(_ request: SkinCompanionRequest) {
        guard !host.isStopped else { return }
        switch request {
        case .frostedGlass(let owner, let style?):
            let b = FrostedGlassBackdrop.attach(to: host)
            backdrop = b
            backdropOwner = owner
            b.update(style)
        case .frostedGlass(let owner, nil):
            // Refreshed or unloaded: the backdrop goes unless a measure claims it first (`FrostedGlassBackdrop.attach`).
            guard owner == backdropOwner else { return }
            backdropOwner = nil
            backdrop?.release(after: 0)
        case .showInputText(let id, let settings, let size):
            let prompt = SkinWindowCompanions.inputTextPromptFactory?(host)
                ?? InputTextPanelPrompt(host: host, skinSize: size)
            prompts[id] = prompt
            prompt.show(settings) { [weak self] text in
                // The skin runs its measure's answer on its executor.
                guard let self, self.prompts.removeValue(forKey: id) != nil else { return }
                self.runtime?.send(.inputTextAnswered(id: id, text: text))
            }
        case .cancelInputText(let id):
            prompts.removeValue(forKey: id)?.cancel()
        }
    }

    /// The window changed (moved, resized, shown, hidden, another level or alpha, a new panel): the backdrop follows.
    func windowChanged() {
        backdrop?.sync()
    }

    /// The window's alpha animates to `alpha` (inside its animation group): the backdrop's goes with it.
    func animateAlpha(to alpha: CGFloat) {
        backdrop?.animateAlpha(to: alpha)
    }

    /// The window closed: the boxes close without an answer (the skin has closed) and the backdrop goes.
    func tearDown() {
        let open = prompts
        prompts = [:]
        for prompt in open.values { prompt.cancel() }
        backdrop?.remove()
        backdrop = nil
        backdropOwner = nil
    }
}
