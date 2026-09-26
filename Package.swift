// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Deskset",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Deskset", targets: ["Deskset"]),
        .executable(name: "DesksetSelfTest", targets: ["DesksetSelfTest"]),
        .library(name: "DesksetCore", targets: ["DesksetCore"]),
    ],
    targets: [
        // Lua 5.1.5 for Measure=Script (MIT): Lua's own files are embedded unmodified; Deskset's shim files
        // (include/deskset_lua.h + deskset_lua.c: the Swift bridge, limits and library restrictions;
        // deskset_lstrlib.c: bounded string.find/match/gmatch/gsub, derived from lstrlib.c) adapt it at run time.
        // See Sources/CLua/README.md.
        .target(
            name: "CLua",
            exclude: ["COPYRIGHT", "README.md"],
            cSettings: [.define("LUA_USE_POSIX")]
        ),
        // Pure logic engine. Foundation (+ embedded Lua) only.
        .target(name: "DesksetCore", dependencies: ["CLua"]),
        // AppKit menu bar app.
        .executableTarget(
            name: "Deskset",
            dependencies: ["DesksetCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreText"),
            ]
        ),
        // Self-test runner (no XCTest): `swift run DesksetSelfTest [suite-filter]`
        .executableTarget(name: "DesksetSelfTest", dependencies: ["DesksetCore"]),
    ]
)
