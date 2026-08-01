import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// Implementation of the `@Forever` attached macro.
///
/// The macro is pure sugar over the ``Forever`` property wrapper: it emits
/// `init`/`get`/`set` accessors that forward to a peer `_<name>: Forever<T>`
/// backing property, plus a `$<name>: Binding<T>` projection peer that mimics
/// the property-wrapper `$` syntax (the `prefixed($)` special case).
///
/// All persistence, observation and synchronization logic lives in the runtime
/// (`Forever` / `ForeverStore`); the expansion contains none of it.
public struct ForeverMacro: AccessorMacro, PeerMacro {

    /// The property-wrapper type referenced by expansions.
    ///
    /// A macro and a property-wrapper type may share the name `Forever`:
    /// the macro wins in attribute position, so expansions can still name
    /// the wrapper type directly.
    private static let wrapperType = "Forever"

    // MARK: - Shared validation

    private struct Info {
        var name: TokenSyntax
        var type: TypeSyntax?
        var key: ExprSyntax?
        var accessModifiers: DeclModifierListSyntax
    }

    private static func diagnose(
        _ message: String,
        on node: some SyntaxProtocol,
        context: some MacroExpansionContext
    ) {
        context.diagnose(Diagnostic(node: node, message: MacroExpansionErrorMessage(message)))
    }

    /// Validates the declaration; returns the info needed to build expansions.
    ///
    /// - Parameter emitDiagnostics: `true` for the accessor role (which reports
    ///   the problems), `false` for the peer role (which stays silent so each
    ///   problem is only diagnosed once).
    private static func validated(
        _ declaration: some DeclSyntaxProtocol,
        attribute: AttributeSyntax,
        emitDiagnostics: Bool,
        context: some MacroExpansionContext
    ) -> Info? {
        func diagnose(_ message: String, on node: some SyntaxProtocol) {
            if emitDiagnostics { self.diagnose(message, on: node, context: context) }
        }

        guard let variable = declaration.as(VariableDeclSyntax.self) else {
            diagnose("'@Forever' can only be applied to a variable declaration.", on: declaration)
            return nil
        }

        guard variable.bindings.count == 1,
              let binding = variable.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
            diagnose("'@Forever' can only be applied to a single variable; declare each variable separately.",
                     on: variable)
            return nil
        }

        let name = pattern.identifier

        // M4: `let` declarations cannot have accessors.
        if variable.bindingSpecifier.tokenKind == .keyword(.let) {
            diagnose("'@Forever' cannot be applied to a 'let' declaration; the value must be mutable.",
                     on: variable.bindingSpecifier)
            return nil
        }

        // M4: `static`/`class` declarations are not supported.
        if variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }) {
            diagnose("'@Forever' cannot be applied to a 'static' (or 'class') declaration.", on: variable)
            return nil
        }

        // M4: computed properties / existing accessors and observers are not supported.
        if binding.accessorBlock != nil {
            diagnose("'@Forever' cannot be applied to a computed property or a property with accessors/observers.",
                     on: variable)
            return nil
        }

        // Init accessors and stored backing storage are illegal in extensions.
        if enclosingContext(declaration, context: context) == .extension {
            diagnose("'@Forever' cannot be applied inside an extension; declare the property in the type's main body.",
                     on: variable)
            return nil
        }

        // Init accessors are illegal on top-level variables.
        if enclosingContext(declaration, context: context) == .topLevel {
            diagnose("'@Forever' cannot be applied to a top-level variable; declare the property inside a type.",
                     on: variable)
            return nil
        }

        // M2: an explicit type annotation is required.
        guard let type = binding.typeAnnotation?.type else {
            diagnose("'@Forever' requires an explicit type annotation, for example: var todos: [Todo] = []",
                     on: variable)
            return nil
        }

        // M3: an initial value is required.
        guard binding.initializer != nil else {
            diagnose("'@Forever' requires an initial value, for example: var todos: [Todo] = []", on: variable)
            return nil
        }

        // M6: the key argument passes through verbatim.
        let key = attribute.arguments?.as(LabeledExprListSyntax.self)?.first?.expression

        let accessModifiers = variable.modifiers.filter { modifier in
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.private), .keyword(.fileprivate), .keyword(.internal), .keyword(.package):
                return true
            default:
                return false
            }
        }

        return Info(name: name, type: type, key: key, accessModifiers: accessModifiers)
    }

    /// The nearest enclosing type-like declaration, from `context.lexicalContext`
    /// (innermost first). `declaration.parent` is not populated in the plugin,
    /// so the host-provided lexical context is the only reliable ancestor chain.
    private enum EnclosingContext {
        case classLike
        case structLike
        case `extension`
        case topLevel
    }

    private static func enclosingContext(
        _ declaration: some DeclSyntaxProtocol,
        context: some MacroExpansionContext
    ) -> EnclosingContext {
        for ancestor in context.lexicalContext {
            if ancestor.is(ClassDeclSyntax.self) || ancestor.is(ActorDeclSyntax.self) {
                return .classLike
            }
            if ancestor.is(StructDeclSyntax.self) || ancestor.is(EnumDeclSyntax.self) {
                return .structLike
            }
            if ancestor.is(ExtensionDeclSyntax.self) {
                return .extension
            }
        }
        return .topLevel
    }

    // MARK: - AccessorMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let info = validated(declaration, attribute: node, emitDiagnostics: true, context: context) else {
            return []
        }

        let name = info.name
        let backing = "_\(name.text)"
        let key = info.key?.trimmedDescription ?? ""

        // init(initialValue) { _todos = Forever(wrappedValue: initialValue, "todos") }
        let initAccessor = AccessorDeclSyntax("""
            @storageRestrictions(initializes: \(raw: backing))
            init(initialValue) {
                \(raw: backing) = \(raw: Self.wrapperType)(wrappedValue: initialValue, \(raw: key))
            }
            """)

        // get { _todos.wrappedValue }
        let getAccessor = AccessorDeclSyntax("""
            get {
                \(raw: backing).wrappedValue
            }
            """)

        // `nonmutating set` in struct contexts (required for mutation from
        // escaping view-body closures); plain `set` in classes/actors, where
        // `nonmutating` is illegal.
        let setAccessor: AccessorDeclSyntax
        if enclosingContext(declaration, context: context) == .classLike {
            setAccessor = AccessorDeclSyntax("""
                set {
                    \(raw: backing).wrappedValue = newValue
                }
                """)
        } else {
            setAccessor = AccessorDeclSyntax("""
                nonmutating set {
                    \(raw: backing).wrappedValue = newValue
                }
                """)
        }

        return [initAccessor, getAccessor, setAccessor]
    }

    // MARK: - PeerMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Silent on invalid declarations: the accessor role already diagnosed them.
        guard let info = validated(declaration, attribute: node, emitDiagnostics: false, context: context) else {
            return []
        }

        let name = info.name
        let backing = "_\(name.text)"
        let type = info.type!.trimmedDescription

        // private var _todos: Forever<[Todo]>
        let backingDecl = DeclSyntax(
            stringLiteral: "private var \(backing): \(Self.wrapperType)<\(type)>")

        // var $todos: Binding<[Todo]> { _todos.projectedValue }   (access level mirrored)
        let accessLevel = info.accessModifiers.isEmpty
            ? ""
            : info.accessModifiers.map { $0.name.text }.joined(separator: " ") + " "
        let projectionDecl = DeclSyntax(
            stringLiteral: "\(accessLevel)var $\(name.text): Binding<\(type)> { \(backing).projectedValue }")

        return [backingDecl, projectionDecl]
    }
}
