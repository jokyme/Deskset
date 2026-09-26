// swift-tools-version:5.9
// Behaviour checks for the example skins in DefaultSkins/Deskset (see Sources/CheckExamples/main.swift).
// Run from the repository root:  swift run --package-path TestSkins/Examples/Checks CheckExamples
import Foundation
import PackageDescription

// The repository is a path dependency; its package identity is the name of the folder it was cloned into.
let repository = Context.packageDirectory + "/../../.."
let repositoryIdentity = URL(fileURLWithPath: repository).standardizedFileURL.lastPathComponent

let package = Package(
    name: "CheckExamples",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: repository)],
    targets: [
        .executableTarget(name: "CheckExamples",
                          dependencies: [.product(name: "DesksetCore", package: repositoryIdentity)]),
    ]
)
