import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ForeverMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [ForeverMacro.self]
}
