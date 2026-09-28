// Lists every place where the engine or the app reads a clock, a time zone or locale, or a random source, starts a
// timer or a wait, hands work to another thread or process, subscribes to a system callback, or reaches outside the
// app (opens a URL, writes a file, sets the volume...) — the inputs that make two runs of the same skin differ, and the
// effects a run must not repeat. The runtime design routes all of them through injectable seams (a skin clock, a
// seeded random source, a virtual-time executor, fakes for background work and services, one protocol for outside
// effects), so that the old engine and a new runtime can be fed exactly the same inputs; this script is the inventory
// of what is left to route, and the guard that keeps new direct calls from appearing unnoticed.
//
//     swift scripts/check-seams.swift                  every use, grouped by class, with file:line and the code
//     swift scripts/check-seams.swift --summary        counts per class and per kind
//     swift scripts/check-seams.swift --markdown       the same inventory as Markdown tables
//     swift scripts/check-seams.swift --check          exit 1 when a file uses a kind more often than the allow list says,
//                                                      or the list allows more than the sources use (CI runs this)
//     swift scripts/check-seams.swift --update         rewrite the allow list with today's counts (keeps the notes)
//     swift scripts/check-seams.swift --kinds          the kinds this script knows, with their patterns
//
// Scanned: Sources/DesksetCore and Sources/Deskset (Swift; self-test files — names ending in Tests.swift,
// SelfTest.swift or SelfTests.swift — are skipped), and from Sources/CLua Deskset's own shims and the two Lua libraries
// behind os.time, os.date, os.clock and math.random (loslib.c, lmathlib.c). Comments and string contents are ignored
// (a string's interpolations are code); string contents are searched only for names passed as strings (sysctl and
// IORegistry keys) and, in the Lua support, for the Lua library calls of the embedded Lua code. A use is a line: a line
// with two matches of the same kind counts once.
//
// The allow list (scripts/seams-allowlist.tsv) has one line per kind and file: `kind<TAB>file<TAB>count<TAB>note`.
// `count` is how many lines of that kind the file may have; `*` allows any number (UI and tooling code that never runs
// inside a skin). `--check` fails when a file has more lines of a kind than allowed (a new direct call: route it
// through a seam, or add it to the list with a reason), and also when an allowance is higher than needed (a count
// above today's uses, a * entry or an entry for a kind the file no longer uses, a file that is gone) or has no note:
// the list only shrinks as seams replace direct calls. `--update` rewrites the counts, keeping the notes and the
// * entries still in use; a new entry it adds has no note until someone writes one.
// Exit status: 0 fine, 1 a new use or a stale or unexplained allowance (--check), 2 a usage error or an unreadable
// file or allow list.
import Foundation

// MARK: - Kinds

struct Kind {
    let id: String
    let klass: String
    let pattern: NSRegularExpression
    let language: Language
    let about: String
}

/// swift: Swift code; swiftText: the contents of Swift string literals (names passed as strings, such as sysctl and
/// IORegistry keys); c: C code; lua: Lua code embedded in the Lua support's Swift strings.
enum Language { case swift, swiftText, c, lua }

let classes: [(id: String, title: String)] = [
    ("wall", "Wall clock"),
    ("mono", "Monotonic clock"),
    ("zone", "Time zone, locale and calendar"),
    ("random", "Random sources and process identity"),
    ("timer", "Timers and delayed work"),
    ("wait", "Blocking waits with a deadline"),
    ("background", "Background work and completion points"),
    ("event", "System callbacks and notifications"),
    ("effect", "Outside effects"),
    ("lua", "Lua library entry points"),
]

var kinds: [Kind] = []
func kind(_ id: String, _ klass: String, _ pattern: String, lang language: Language = .swift, _ about: String) {
    let regex = try! NSRegularExpression(pattern: pattern)
    kinds.append(Kind(id: id, klass: klass, pattern: regex, language: language, about: about))
}

// Wall clock
kind("wall.Date()", "wall", #"\b(NS)?Date\(\)"#, "the current date")
kind("wall.Date.now", "wall", #"\bDate\.now\b"#, "the current date")
kind("wall.sinceNow", "wall", #"\btimeIntervalSinceNow\b"#,
     "Date(timeIntervalSinceNow:) or date.timeIntervalSinceNow: relative to the current date")
kind("wall.referenceDate", "wall", #"\bDate\.timeIntervalSinceReferenceDate\b"#,
     "the static Date.timeIntervalSinceReferenceDate (the current date)")
kind("wall.CFAbsoluteTimeGetCurrent", "wall", #"\bCFAbsoluteTimeGetCurrent\b"#, "the current date")
kind("wall.time()", "wall", #"\btime\(\s*(nil|NULL|0|&)"#, "C time(): seconds since 1970")
kind("wall.gettimeofday", "wall", #"\bgettimeofday\b"#, "C wall clock")
kind("wall.clock_gettime", "wall", #"\bclock_gettime\w*\(\s*_?CLOCK_REALTIME"#, "C wall clock")
kind("wall.C", "wall", #"\btime\s*\(\s*(NULL|0)\s*\)"#, lang: .c, "C time(NULL)")

// Monotonic clock
kind("mono.systemUptime", "mono", #"\bsystemUptime\b"#,
     "ProcessInfo.systemUptime (a skin's clock, rate and throttle timing)")
kind("mono.machTime", "mono", #"\bmach_(absolute|continuous)_time\b"#, "mach tick counter")
kind("mono.DispatchTime.now", "mono", #"\bDispatchTime\.now\(\)"#, "dispatch clock")
kind("mono.CACurrentMediaTime", "mono", #"\bCACurrentMediaTime\b"#, "Core Animation clock")
kind("mono.clock_gettime", "mono", #"\bclock_gettime\w*\(\s*_?CLOCK_(MONOTONIC|UPTIME)"#,
     "C monotonic clock")
kind("mono.threadCPUTime", "mono", #"\bthread_info\s*\("#,
     "a thread's CPU time (regular expression time limits)")
kind("mono.idleTime", "mono", #"\bHIDIdleTime\b"#, lang: .swiftText,
     "seconds since the last keyboard or mouse input (IORegistry)")
kind("mono.bootTime", "mono", #"\bkern\.boottime\b"#, lang: .swiftText,
     "the boot time (sysctl), read against the wall clock for Uptime")
kind("mono.C", "mono", #"\b(mach_absolute_time|clock_gettime|clock)\s*\("#, lang: .c,
     "C clocks (Lua's os.clock and the script time limits)")

// Time zone, locale, calendar
kind("zone.TimeZone.current", "zone", #"\b(TimeZone|NSTimeZone)\.(current|autoupdatingCurrent|local|system|default)\b"#,
     "the system time zone")
kind("zone.Locale.current", "zone", #"\b(Locale|NSLocale)\.(current|autoupdatingCurrent|preferredLanguages|system)\b"#,
     "the user's locale or languages")
kind("zone.Calendar.current", "zone", #"\b(Calendar|NSCalendar)\.(current|autoupdatingCurrent)\b"#,
     "the user's calendar (its time zone and first weekday)")
kind("zone.inferredCurrent", "zone",
     #"\b\w*(zone|Zone|locale|Locale|calendar|Calendar)\w*\s*[:=]\s*\.(current|autoupdatingCurrent)\b"#,
     "`zone: .current` and the like: the system time zone, locale or calendar by type inference")
kind("zone.implicitFormatter", "zone",
     #"\b(DateFormatter|NumberFormatter|DateComponentsFormatter|RelativeDateTimeFormatter|MeasurementFormatter|DateIntervalFormatter)\(\)|\bCalendar\(identifier:"#,
     "a formatter or calendar that uses the current locale and time zone unless they are set")
kind("zone.localizedText", "zone",
     #"\blocalized(Standard|CaseInsensitive)?Compare\b|\blocalized(Standard|CaseInsensitive)Contains\b|\blocalized(Uppercase|Lowercase|Capitalized)String\b|\.formatted\("#,
     "comparison, case mapping or formatting in the current locale")
kind("zone.C", "zone", #"\b(localtime|localtime_r|gmtime|mktime|timegm|tzset|strftime|setlocale)\s*\("#,
     "C time zone and locale (TZ, LC_TIME)")
kind("zone.C", "zone", #"\b(localtime|localtime_r|mktime|tzset|strftime|setlocale)\s*\("#, lang: .c,
     "C time zone and locale (Lua's os.date, os.time with a table)")

// Random
kind("random.swift", "random",
     #"\b[A-Z]\w*\.random\(|\.random\(\s*(in|using):|\brandomElement\(|\bshuffled?\(\)"#,
     "Swift's system random generator")
kind("random.C", "random",
     #"(?<![.\w])(arc4random(_uniform|_buf)?|drand48|lrand48|srand48|random|srandom|rand|srand|SecRandomCopyBytes)\s*\("#,
     "C random sources")
kind("random.generator", "random", #"\bSystemRandomNumberGenerator\b"#, "the system generator")
kind("random.UUID", "random", #"\b(NS)?UUID\(\)|\bgloballyUniqueString\b"#, "a random identifier")
kind("random.pid", "random", #"\bprocessIdentifier\b|\bgetpid\(\)"#, "the process identifier")
kind("random.hashSeed", "random", #"\.hashValue\b|\bHasher\(\)"#,
     "Swift hashing, seeded at random per process (set SWIFT_DETERMINISTIC_HASHING to fix it)")
kind("random.C", "random", #"\b(rand|srand|random|srandom|arc4random\w*|tmpnam|lua_tmpnam|mkstemp)\s*\("#, lang: .c,
     "C random sources (Lua's math.random, os.tmpname)")

// Timers
kind("timer.Timer", "timer", #"\b(NS)?Timer\s*\(|\bscheduledTimer\(|\bTimer\.publish\("#,
     "a Foundation timer")
kind("timer.asyncAfter", "timer", #"\.asyncAfter\("#, "DispatchQueue.asyncAfter")
kind("timer.dispatchSource", "timer", #"\bmakeTimerSource\("#, "a dispatch timer source")
kind("timer.runLoopAdd", "timer", #"\.add\([^)\n]*forMode:|\bCFRunLoopAddTimer\("#,
     "a timer added to a run loop")
kind("timer.afterDelay", "timer", #"\bafterDelay:"#, "perform(_:with:afterDelay:)")
kind("timer.CFRunLoopTimer", "timer", #"\bCFRunLoopTimerCreate\w*\("#, "a Core Foundation timer")
kind("timer.displayLink", "timer", #"\bCVDisplayLink\w*\(|\bCADisplayLink\b|\bdisplayLink\("#,
     "a display-synchronised timer")
kind("timer.animation", "timer",
     #"\bNSAnimationContext\.runAnimationGroup\b|\bCABasicAnimation\(|\bCATransaction\.setAnimationDuration\("#,
     "an animation with a duration (window fades) and its completion handler")
kind("timer.executorTimer", "timer", #"\.timer\(\s*interval:"#,
     "SkinExecutor.timer (already a seam: a virtual-time executor drives it)")
kind("timer.executorAfter", "timer", #"\.async\(\s*after:"#,
     "SkinExecutor.async(after:) (already a seam: a virtual-time executor drives it)")

// Waits
kind("wait.sleep", "wait", #"\b(Thread\.sleep|usleep|nanosleep|sleep)\s*\(|\bTask\.sleep\b"#,
     "sleeping the thread")
kind("wait.deadline", "wait", #"\.wait\(\s*(timeout|wallTimeout|until)\s*:|\bwait\(until:"#,
     "a semaphore, group or condition wait with a deadline")
kind("wait.runLoop", "wait", #"\brun(Mode)?\(\s*(until|mode:[^)\n]*before)\s*:|\bCFRunLoopRunInMode\("#,
     "pumping a run loop until a date")

// Background work
kind("background.global", "background", #"\bDispatchQueue\.global\("#,
     "a global concurrent queue")
kind("background.queue", "background", #"\bDispatchQueue\(\s*label:"#, "a private dispatch queue")
kind("background.operationQueue", "background", #"\bOperationQueue\(\)"#, "an operation queue")
kind("background.thread", "background", #"\bThread\s*\(\s*(block|target):|\bThread\.detachNewThread\b|\bpthread_create\("#,
     "a thread of its own")
kind("background.task", "background", #"\bTask(\.detached)?\s*(\(\s*priority:[^)\n]*\))?\s*\{"#,
     "a Swift concurrency task")
kind("background.URLSession", "background",
     #"\bURLSession(\.shared\b|\()|\.(dataTask|downloadTask|uploadTask|webSocketTask)\("#,
     "a URL session request")
kind("background.process", "background",
     #"\b(Process|NSTask)\(\)|\bposix_spawnp?\s*\(|\bterminationHandler\b|\breadabilityHandler\b"#,
     "a child process, and its completion handlers")
kind("background.socket", "background", #"\bsocket\s*\(\s*(AF_|PF_)|\bNWConnection\(|\bNWPathMonitor\(|\bCFSocketCreate"#,
     "a socket or network connection")
kind("background.fileEvents", "background",
     #"\bFSEventStream\w*Create\w*\(|\bmakeFileSystemObjectSource\(|\bmakeReadSource\(|\bmakeProcessSource\(|\bmakeSignalSource\("#,
     "file-system events and other dispatch sources")
kind("background.mainHop", "background",
     #"\bDispatchQueue\.main\.(async|sync)\b|\bOperationQueue\.main\.addOperation\b|\bRunLoop\.main\.perform\b|\bperformSelector\(\s*onMainThread"#,
     "work handed to the main thread (how most service results come back)")
kind("background.hop", "background", #"\.hop\(\)"#,
     "Skin.hop(): a skin starts background work and its result comes back through the executor")

// System callbacks
kind("event.notification", "event", #"\.addObserver\(|\.publisher\(\s*for:|\bNSDistributedNotificationCenter\b"#,
     "a notification observer")
kind("event.KVO", "event", #"\.observe\(\s*\\"#, "key-value observation")
kind("event.coreAudio", "event", #"\bAudioObjectAddPropertyListener\w*\b|\bAudioDeviceCreateIOProcID\w*\b"#,
     "a Core Audio listener or I/O callback")
kind("event.IOKit", "event", #"\bIOService(AddMatching|AddInterest)Notification\b|\bIONotificationPortCreate\b|\bIOPSNotificationCreateRunLoopSource\b"#,
     "an IOKit notification")
kind("event.eventMonitor", "event", #"\bNSEvent\.add(Global|Local)MonitorForEvents\b|\bCGEvent\.tapCreate\b"#,
     "a mouse or keyboard event monitor")
kind("event.location", "event", #"\bCLLocationManager\(\)"#, "Core Location updates")
kind("event.pointerState", "event",
     #"\bNSEvent\.(mouseLocation|pressedMouseButtons|modifierFlags)\b|\bCGEventSource\.(keyState|buttonState|flagsState)\("#,
     "the pointer position, buttons or modifier keys read directly (polled input)")
kind("event.captureStream", "event", #"\bSCStream\(|\baddStreamOutput\("#, "a ScreenCaptureKit stream")
kind("event.runLoopObserver", "event", #"\bCFRunLoopObserverCreate\w*\("#,
     "a run-loop observer")

// Outside effects: every way a skin reaches outside itself (the runtime design sends them all through one protocol,
// with a recording implementation for the runs that must not touch the Mac)
kind("effect.workspace", "effect",
     #"\bNSWorkspace\.shared\.(open|openApplication|activateFileViewerSelecting|setDesktopImageURL|recycle|launchApplication)\b"#,
     "opening a URL, file or app; the desktop picture")
kind("effect.pasteboard", "effect", #"\bNSPasteboard\.general\.(setString|setData|writeObjects|setPropertyList)\("#,
     "writing the clipboard")
kind("effect.sound", "effect", #"\bNSSound\(|\bNSSound\.beep\(|\bAudioServicesPlay\w*Sound\w*\("#,
     "playing a sound")
kind("effect.audioHardware", "effect", #"\bAudioObjectSetPropertyData\b"#,
     "changing an audio device (volume, mute, default device)")
kind("effect.postEvent", "effect", #"\.post\(\s*tap:|\bCGEventPost\w*\("#, "posting a keyboard event (media keys)")
kind("effect.appleScript", "effect",
     #"\bNSAppleScript\(|\bNSUserAppleScriptTask\(|\bNSAppleEventDescriptor\(\s*bundleIdentifier:|\bAESendMessage\("#,
     "AppleScript and Apple events (controlling Music, Spotify)")
kind("effect.signal", "effect", #"(?<![.\w])kill\s*\("#, "signalling a process")
kind("effect.terminate", "effect", #"\bNSApp\.terminate\("#, "quitting the app")
kind("effect.pluginProcess", "effect", #"\bPluginProcess\.run\("#,
     "a plugin starts a program (open, osascript) through PluginProcess, whose launcher is already replaceable")
kind("effect.iniWrite", "effect", #"\bIniWriter\.(writeValue|removeSection|removeKey|moveSection|withFileLock)\("#,
     "writing a skin's .ini file")
kind("effect.fileWrite", "effect",
     #"\.write\(\s*(to|toFile):|\b(FileManager\.default|fm|fileManager)\.(removeItem|moveItem|copyItem|trashItem|replaceItemAt|createDirectory|createSymbolicLink|setAttributes|createFile|linkItem)\("#,
     "writing, moving or deleting a file")

// Lua (the libraries scripts call, and Lua code embedded in Swift strings)
kind("lua.library", "lua", #"\bos\.(time|clock|date|tmpname)\b|\bmath\.random(seed)?\b"#, lang: .lua,
     "a Lua clock, date or random function named in embedded Lua code")

// MARK: - Files

let root: URL = {
    let script = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let candidate = script.deletingLastPathComponent().deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) { return candidate }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}()

func isSelfTest(_ path: String) -> Bool {
    path.hasSuffix("Tests.swift") || path.hasSuffix("SelfTest.swift") || path.hasSuffix("SelfTests.swift")
}

func sourceFiles() -> [String] {
    var files: [String] = []
    for folder in ["Sources/DesksetCore", "Sources/Deskset", "Sources/CLua"] {
        guard let walker = FileManager.default.enumerator(atPath: root.appendingPathComponent(folder).path) else { continue }
        for case let relative as String in walker {
            let path = folder + "/" + relative
            if path.hasSuffix(".swift") && !isSelfTest(path) { files.append(path) }
            if path.hasSuffix(".c") && folder == "Sources/CLua" { files.append(path) }
        }
    }
    return files.sorted()
}

// MARK: - Lexer

/// Splits source text into code (comments and string contents blanked, interpolations kept) and embedded text
/// (only the string contents); both keep every line break where it was.
func split(_ text: String, swift: Bool) -> (code: String, strings: String) {
    let bytes = Array(text.utf8)
    var code = [UInt8](repeating: 0x20, count: bytes.count)
    var strings = [UInt8](repeating: 0x20, count: bytes.count)
    for i in bytes.indices where bytes[i] == 0x0A {
        code[i] = 0x0A
        strings[i] = 0x0A
    }

    enum Context {
        case code(parens: Int)            // parens: open parentheses of an interpolation (-1 at the top level)
        case string(multiline: Bool, hashes: Int)
        case blockComment(depth: Int)
    }
    var stack: [Context] = [.code(parens: -1)]
    var i = 0
    let n = bytes.count
    func at(_ k: Int) -> UInt8 { k < n ? bytes[k] : 0 }
    func hashes(from k: Int) -> Int {
        var j = k
        while at(j) == UInt8(ascii: "#") { j += 1 }
        return j - k
    }

    while i < n {
        let c = bytes[i]
        switch stack[stack.count - 1] {
        case .code(let parens):
            if c == UInt8(ascii: "/") && at(i + 1) == UInt8(ascii: "/") {
                while i < n && bytes[i] != 0x0A { i += 1 }
                continue
            }
            if c == UInt8(ascii: "/") && at(i + 1) == UInt8(ascii: "*") {
                stack.append(.blockComment(depth: 1))
                i += 2
                continue
            }
            // Strings: "…", """…""", and in Swift #"…"#, #"""…"""# with any number of #.
            var h = 0
            if swift && c == UInt8(ascii: "#") {
                h = hashes(from: i)
                if at(i + h) != UInt8(ascii: "\"") { code[i] = c; i += 1; continue }
            }
            if at(i + h) == UInt8(ascii: "\"") && (c == UInt8(ascii: "\"") || h > 0) {
                let start = i + h
                let multiline = swift && at(start + 1) == UInt8(ascii: "\"") && at(start + 2) == UInt8(ascii: "\"")
                i = start + (multiline ? 3 : 1)
                stack.append(.string(multiline: multiline, hashes: h))
                continue
            }
            if !swift && c == UInt8(ascii: "'") {
                // A C character literal.
                i += 1
                while i < n && bytes[i] != UInt8(ascii: "'") && bytes[i] != 0x0A {
                    if bytes[i] == UInt8(ascii: "\\") { i += 1 }
                    i += 1
                }
                i += 1
                continue
            }
            if parens >= 0 {
                if c == UInt8(ascii: "(") {
                    stack[stack.count - 1] = .code(parens: parens + 1)
                } else if c == UInt8(ascii: ")") {
                    if parens == 0 {
                        stack.removeLast()  // back into the string
                        i += 1
                        continue
                    }
                    stack[stack.count - 1] = .code(parens: parens - 1)
                }
            }
            code[i] = c
            i += 1
        case .blockComment(let depth):
            if c == UInt8(ascii: "*") && at(i + 1) == UInt8(ascii: "/") {
                if depth == 1 { stack.removeLast() } else { stack[stack.count - 1] = .blockComment(depth: depth - 1) }
                i += 2
            } else if swift && c == UInt8(ascii: "/") && at(i + 1) == UInt8(ascii: "*") {
                stack[stack.count - 1] = .blockComment(depth: depth + 1)
                i += 2
            } else {
                i += 1
            }
        case .string(let multiline, let h):
            if c == UInt8(ascii: "\\") && hashes(from: i + 1) >= h {
                let after = i + 1 + h
                if swift && at(after) == UInt8(ascii: "(") {
                    stack.append(.code(parens: 0))
                    i = after + 1
                    continue
                }
                if h == 0 || hashes(from: i + 1) == h {
                    i = after + 1  // an escape: skip the escaped character
                    continue
                }
            }
            if c == UInt8(ascii: "\"") {
                let closes = multiline
                    ? at(i + 1) == UInt8(ascii: "\"") && at(i + 2) == UInt8(ascii: "\"") && hashes(from: i + 3) >= h
                    : hashes(from: i + 1) >= h
                if closes {
                    stack.removeLast()
                    i += (multiline ? 3 : 1) + h
                    continue
                }
            }
            if c == 0x0A && !multiline {
                stack.removeLast()  // an unterminated string: stop at the end of the line
            }
            if c != 0x0A { strings[i] = c }
            i += 1
        }
    }
    return (String(decoding: code, as: UTF8.self), String(decoding: strings, as: UTF8.self))
}

// MARK: - Scan

struct Hit {
    let kind: Kind
    let file: String
    let line: Int
    let text: String
}

/// The 1-based line of each match of `kinds` in `text`, one per kind and line.
func matchLines(_ text: String, _ kinds: [Kind]) -> [(Kind, Int)] {
    let ns = text as NSString
    var breaks: [Int] = []
    for i in 0..<ns.length where ns.character(at: i) == 0x0A { breaks.append(i) }
    func line(_ offset: Int) -> Int {
        var lo = 0, hi = breaks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if breaks[mid] < offset { lo = mid + 1 } else { hi = mid }
        }
        return lo + 1
    }
    var result: [(Kind, Int)] = []
    for kind in kinds {
        var last = 0
        for match in kind.pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let l = line(match.range.location)
            if l != last { result.append((kind, l)) }
            last = l
        }
    }
    return result
}

func scan() -> [Hit] {
    var hits: [Hit] = []
    for file in sourceFiles() {
        guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) else {
            FileHandle.standardError.write("cannot read \(file)\n".data(using: .utf8)!)
            exit(2)
        }
        let isSwift = file.hasSuffix(".swift")
        // Only Deskset's own C files and the Lua libraries that scripts reach (os, math) are of interest in CLua.
        if !isSwift {
            let name = (file as NSString).lastPathComponent
            guard name.hasPrefix("deskset_") || name == "loslib.c" || name == "lmathlib.c" else { continue }
        }
        let (code, strings) = split(text, swift: isSwift)
        let raw = text.components(separatedBy: "\n")
        var found = matchLines(code, kinds.filter { $0.language == (isSwift ? .swift : .c) })
        if isSwift {
            // String contents: names passed as strings everywhere, Lua code in the Lua support.
            let languages: Set<Language> = file.contains("/Lua/") ? [.swiftText, .lua] : [.swiftText]
            found += matchLines(strings, kinds.filter { languages.contains($0.language) })
        }
        for (kind, line) in found {
            hits.append(Hit(kind: kind, file: file, line: line, text: raw[line - 1]))
        }
    }
    let order = Dictionary(uniqueKeysWithValues: classes.enumerated().map { ($1.id, $0) })
    let kindOrder = Dictionary(kinds.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    return hits.sorted {
        (order[$0.kind.klass]!, kindOrder[$0.kind.id]!, $0.file, $0.line)
            < (order[$1.kind.klass]!, kindOrder[$1.kind.id]!, $1.file, $1.line)
    }
}

// MARK: - Allow list

struct Allowance {
    var kind: String
    var file: String
    var count: Int?   // nil: any number
    var note: String
}

let allowListURL = root.appendingPathComponent("scripts/seams-allowlist.tsv")

let allowListHeader = """
# Direct uses of clocks, time zones and locales, random sources, timers, waits, background work, system callbacks and
# outside effects that are allowed today (scripts/check-seams.swift). One line per kind and file, tab-separated:
#
#     kind    file    count    note
#
# count: how many lines of that kind the file may have; * allows any number (UI and tooling code that never runs inside
# a skin).
# A new direct use makes `swift scripts/check-seams.swift --check` fail (CI runs it): route it through a seam (the
# skin's clock, random source or executor, background work, SideEffects, a service protocol with a fake), or raise the
# count here with a note saying why. The list only shrinks: --check also fails on a count above the uses, a * entry
# for a kind the file no longer uses, and an entry without a note. `--update` rewrites the counts from the sources and
# keeps the notes and the * entries still in use. The kinds and what each one matches:
# `swift scripts/check-seams.swift --kinds`.


"""

func readAllowList() -> [Allowance] {
    guard let text = try? String(contentsOf: allowListURL, encoding: .utf8) else { return [] }
    var result: [Allowance] = []
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let fields = line.components(separatedBy: "\t")
        guard fields.count >= 3 else {
            FileHandle.standardError.write("seams-allowlist.tsv: cannot read line: \(line)\n".data(using: .utf8)!)
            exit(2)
        }
        let count = fields[2] == "*" ? nil : Int(fields[2])
        if fields[2] != "*" && count == nil {
            FileHandle.standardError.write("seams-allowlist.tsv: bad count in line: \(line)\n".data(using: .utf8)!)
            exit(2)
        }
        result.append(Allowance(kind: fields[0], file: fields[1], count: count,
                                note: fields.count > 3 ? fields[3...].joined(separator: " ") : ""))
    }
    return result
}

struct Key: Hashable, Comparable {
    let kind: String
    let file: String
    static func < (a: Key, b: Key) -> Bool { (a.file, a.kind) < (b.file, b.kind) }
}

func counts(_ hits: [Hit]) -> [Key: Int] {
    var result: [Key: Int] = [:]
    for hit in hits { result[Key(kind: hit.kind.id, file: hit.file), default: 0] += 1 }
    return result
}

// MARK: - Output

func write(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }

func code(_ text: String) -> String {
    var t = text.trimmingCharacters(in: .whitespaces)
    if t.count > 140 { t = String(t.prefix(137)) + "..." }
    return t
}

func title(_ klass: String) -> String { classes.first { $0.id == klass }!.title }

func listing(_ hits: [Hit]) {
    var lastClass = ""
    var lastKind = ""
    for hit in hits {
        if hit.kind.klass != lastClass {
            write("\n== \(title(hit.kind.klass)) (\(hits.filter { $0.kind.klass == hit.kind.klass }.count))")
            lastClass = hit.kind.klass
            lastKind = ""
        }
        if hit.kind.id != lastKind {
            write("-- \(hit.kind.id): \(hit.kind.about)")
            lastKind = hit.kind.id
        }
        write("   \(hit.file):\(hit.line)  \(code(hit.text))")
    }
}

func summary(_ hits: [Hit]) {
    write("Total: \(hits.count) uses in \(Set(hits.map(\.file)).count) files")
    for klass in classes {
        let inClass = hits.filter { $0.kind.klass == klass.id }
        write("\(klass.title): \(inClass.count) uses in \(Set(inClass.map(\.file)).count) files")
        var seen: [String] = []
        for hit in inClass where !seen.contains(hit.kind.id) { seen.append(hit.kind.id) }
        for id in seen {
            let ofKind = inClass.filter { $0.kind.id == id }
            write("   \(id): \(ofKind.count) in \(Set(ofKind.map(\.file)).count) files")
        }
    }
}

/// Per class: the uses the allow list counts file by file (the engine, plugins, services, the app's skin handling)
/// first, then those in UI and tooling code (the allow list's * entries), each with the allow list's note.
func markdown(_ hits: [Hit]) {
    var notes: [Key: Allowance] = [:]
    for a in readAllowList() { notes[Key(kind: a.kind, file: a.file)] = a }
    func table(_ rows: [Hit]) {
        write("| Kind | Location | Code | Note |")
        write("|---|---|---|---|")
        for hit in rows {
            let file = hit.file.replacingOccurrences(of: "Sources/", with: "")
            let text = code(hit.text).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "`", with: "'")
            let note = (notes[Key(kind: hit.kind.id, file: hit.file)]?.note ?? "").replacingOccurrences(of: "|", with: "\\|")
            write("| \(hit.kind.id) | \(file):\(hit.line) | `\(text)` | \(note) |")
        }
    }
    for klass in classes {
        let inClass = hits.filter { $0.kind.klass == klass.id }
        guard !inClass.isEmpty else { continue }
        let ui = inClass.filter { notes[Key(kind: $0.kind.id, file: $0.file)].map { $0.count == nil } ?? false }
        let skin = inClass.filter { notes[Key(kind: $0.kind.id, file: $0.file)].map { $0.count != nil } ?? true }
        write("\n#### \(klass.title) (\(inClass.count): \(skin.count) counted file by file, \(ui.count) in UI and tooling)\n")
        if !skin.isEmpty { table(skin) }
        if !ui.isEmpty {
            write("\nUI and tooling:\n")
            table(ui)
        }
    }
}

/// Fails on a new direct use (a file uses a kind more often than allowed), and — so that the list only ever shrinks —
/// on an allowance that is no longer needed in full: a count above today's uses, a * entry for a kind the file no
/// longer uses, an entry for a file or kind that is gone, an entry listed twice, or an entry without a note.
func check(_ hits: [Hit]) -> Int32 {
    let now = counts(hits)
    let allowances = readAllowList()
    var allowed: [Key: Allowance] = [:]
    var duplicates: [String] = []
    for a in allowances {
        let key = Key(kind: a.kind, file: a.file)
        if allowed[key] != nil { duplicates.append("   \(a.kind) in \(a.file): listed more than once") }
        allowed[key] = a
    }
    var failures: [String] = []
    for (key, count) in now.sorted(by: { $0.key < $1.key }) {
        let allowance = allowed[key]
        if let allowance, allowance.count == nil { continue }
        let limit = allowance?.count ?? 0
        if count > limit {
            let lines = hits.filter { $0.kind.id == key.kind && $0.file == key.file }
                .map { "      \($0.file):\($0.line)  \(code($0.text))" }.joined(separator: "\n")
            failures.append("   \(key.kind) in \(key.file): \(count) uses, \(limit) allowed\n\(lines)")
        }
    }
    let knownKinds = Set(kinds.map(\.id))
    var stale: [String] = duplicates
    var unnoted: [String] = []
    for a in allowances {
        let count = now[Key(kind: a.kind, file: a.file)] ?? 0
        if !knownKinds.contains(a.kind) {
            stale.append("   \(a.kind) in \(a.file): no such kind (swift scripts/check-seams.swift --kinds)")
        } else if !FileManager.default.fileExists(atPath: root.appendingPathComponent(a.file).path) {
            stale.append("   \(a.kind) in \(a.file): no such file")
        } else if let limit = a.count, count < limit {
            stale.append("   \(a.kind) in \(a.file): \(count) uses, \(limit) allowed")
        } else if a.count == nil && count == 0 {
            stale.append("   \(a.kind) in \(a.file): no uses, any number allowed")
        } else if a.count == 0 {
            stale.append("   \(a.kind) in \(a.file): an allowance of 0")
        }
        if a.note.trimmingCharacters(in: .whitespaces).isEmpty {
            unnoted.append("   \(a.kind) in \(a.file)")
        }
    }
    if failures.isEmpty && stale.isEmpty && unnoted.isEmpty {
        write("Seams: no direct uses beyond the allow list, and no allowance beyond them (\(hits.count) uses known).")
        return 0
    }
    if !failures.isEmpty {
        write("Seams: new direct uses of clocks, random sources, timers, background work, system callbacks or outside")
        write("effects. Route them through a seam (the skin's clock, random source or executor, background work,")
        write("SideEffects, or a service with a fake), or add them to scripts/seams-allowlist.tsv with a note saying why:")
        failures.forEach(write)
    }
    if !stale.isEmpty {
        write("Seams: allowances higher than needed. The list only shrinks: lower or remove them (--update does it):")
        stale.forEach(write)
    }
    if !unnoted.isEmpty {
        write("Seams: allowances without a note. Say which seam will replace each use, or why it stays:")
        unnoted.forEach(write)
    }
    return 1
}

func update(_ hits: [Hit]) {
    let now = counts(hits)
    let old = readAllowList()
    var notes: [Key: String] = [:]
    var wildcards: [Allowance] = []
    for a in old {
        notes[Key(kind: a.kind, file: a.file)] = a.note
        if a.count == nil { wildcards.append(a) }
    }
    var entries: [Allowance] = []
    let wildKeys = Set(wildcards.map { Key(kind: $0.kind, file: $0.file) })
    for (key, count) in now where !wildKeys.contains(key) {
        entries.append(Allowance(kind: key.kind, file: key.file, count: count, note: notes[key] ?? ""))
    }
    entries += wildcards.filter { now[Key(kind: $0.kind, file: $0.file)] != nil }
    entries.sort { Key(kind: $0.kind, file: $0.file) < Key(kind: $1.kind, file: $1.file) }
    var text = allowListHeader
    var lastFile = ""
    for e in entries {
        if e.file != lastFile && !lastFile.isEmpty { text += "\n" }
        lastFile = e.file
        text += "\(e.kind)\t\(e.file)\t\(e.count.map(String.init) ?? "*")\t\(e.note)\n"
    }
    try! text.write(to: allowListURL, atomically: true, encoding: .utf8)
    write("Wrote \(entries.count) allowances to scripts/seams-allowlist.tsv.")
}

// MARK: - Main

let arguments = Set(CommandLine.arguments.dropFirst())
let known: Set<String> = ["--check", "--update", "--summary", "--markdown", "--kinds", "--help", "-h"]
if !arguments.isSubset(of: known) {
    FileHandle.standardError.write("unknown argument: \(arguments.subtracting(known).sorted().joined(separator: " "))\n"
        .data(using: .utf8)!)
    exit(2)
}
if arguments.contains("--help") || arguments.contains("-h") {
    write("usage: swift scripts/check-seams.swift [--summary | --markdown | --check | --update | --kinds]")
    exit(0)
}
if arguments.contains("--kinds") {
    for k in kinds { write("\(k.id)\t\(k.klass)\t\(k.about)\n\t\(k.pattern.pattern)") }
    exit(0)
}
let hits = scan()
if arguments.contains("--update") { update(hits); exit(0) }
if arguments.contains("--check") { exit(check(hits)) }
if arguments.contains("--summary") { summary(hits); exit(0) }
if arguments.contains("--markdown") { markdown(hits); exit(0) }
listing(hits)
