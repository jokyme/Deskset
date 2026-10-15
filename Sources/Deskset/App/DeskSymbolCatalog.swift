import DeskLanguage

/// Checks names against this Mac's symbol library without loading widget files or retaining native images.
struct DeskSymbolCatalog: SymbolValidating {
    func exists(_ symbol: String) -> Bool {
        !symbol.isEmpty && !symbol.contains("\0") && SymbolImages.exists(symbol)
    }

    // AppKit reports current availability, not the first macOS version that supplied a symbol.
    func minimumMacOS(of symbol: String) -> Int? { nil }

    // AppKit has no public symbol-name inventory. The language service retains its verified common completions.
    func similarSymbols(to symbol: String) -> [String] { [] }
}
