import CLua
import Foundation

/// Lua scripting (`Measure=Script`, Lua 5.1.5 embedded as the CLua target): registration and limits.
///
/// Call `LuaSupport.register()` once at startup (app and self-tests) so `Skin.makeMeasure` creates
/// `ScriptMeasure` for `Measure=Script`.
public enum LuaSupport {
    public static func register() {
        MeasureRegistry.registerMeasure("Script", ScriptMeasure.self)
        // os.clock counts from here, once for the whole app, whichever skin's thread opens the first state.
        deskset_lua_start_clock()
    }

    /// Memory one script instance (one Lua state) may allocate. Allocations beyond it fail with Lua's
    /// "not enough memory" error, which the script can catch; the state stays usable.
    public static var memoryLimit = 64 * 1024 * 1024
    /// Memory all script instances of the app may allocate together (a skin with hundreds of Script measures must
    /// not be able to exhaust the Mac's memory); beyond it allocations fail the same way.
    public static var totalMemoryLimit = 512 * 1024 * 1024
    /// Memory all script instances use right now.
    static var totalMemoryUsed: Int { Int(deskset_lua_total_memory_used()) }
    /// Lua VM instructions one call may execute (the main chunk, `Initialize()`, one `Update()`, one
    /// `!CommandMeasure`, one inline Lua call — nested calls share the outermost call's budget). About a second
    /// of pure Lua work on Apple Silicon; real skin scripts use a tiny fraction of it.
    public static var instructionLimit: UInt64 = 200_000_000
    /// Wall-clock seconds one call may take (also covers slow library functions called in a loop).
    public static var secondsLimit = 2.0
    /// After this many consecutive calls stopped by a limit, the script instance stops running until the skin is
    /// refreshed (so an endless loop in `Update()` cannot freeze the app on every update).
    public static var maxConsecutiveTimeouts = 3
    /// Script files (ScriptFile, dofile, loadfile) larger than this are not read.
    public static var maxScriptFileSize = 16 * 1024 * 1024
    /// `SKIN:Bang()` calls waiting for the script to return; more are dropped (logged once).
    static let maxPendingBangs = 10_000
    /// `print()` lines per second and script; more are dropped (logged once).
    static let maxPrintsPerSecond = 100
    /// Characters of one `print()` line or error message that reach the log (a script can build huge strings).
    static let maxLoggedCharacters = 2000
    /// UTF-8 bytes of text (bang names and arguments) one call may queue with `SKIN:Bang()`; more are dropped
    /// (logged once).
    static var maxPendingBangBytes = 32 * 1024 * 1024
}
