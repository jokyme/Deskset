import Foundation

extension Skin {
    /// Resolves a debugger expression using the skin's current values, without updating measures or meters.
    /// Like any section-variable read, an inline script or plugin function may perform work of its own.
    /// Must be called on the skin's executor.
    public func evaluateDebugString(_ expression: String) -> String {
        assertOwned()
        hostFactsChanged()
        return work {
            return resolve(expression, in: nil, sectionVariables: true)
        }
    }

    /// Resolves variables and strictly evaluates a numeric debugger expression on the skin's executor.
    /// Syntax errors and unknown identifiers retain the formula engine's diagnostics.
    public func evaluateDebugFormula(_ expression: String) throws -> Double {
        assertOwned()
        hostFactsChanged()
        return try work {
            let resolved = resolve(expression, in: nil, sectionVariables: true)
            return try Formula.evaluate(resolved, lookup: { self.formulaValue(of: $0, from: nil) })
        }
    }

    /// The loaded INI/include files and the resolved paths of scripts with a live Lua state.
    /// Reads the paths already used by Script measures; it does not re-evaluate their ScriptFile options.
    /// Must be called on the skin's executor.
    public var debugDependencyFiles: [URL] {
        assertOwned()
        let scripts = measures.compactMap { measure -> URL? in
            guard let script = measure as? ScriptMeasure, script.lua != nil, !script.scriptPath.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: script.scriptPath)
        }
        var seen = Set<URL>()
        return (sourceFiles + scripts).filter { seen.insert($0.standardizedFileURL).inserted }
    }
}
