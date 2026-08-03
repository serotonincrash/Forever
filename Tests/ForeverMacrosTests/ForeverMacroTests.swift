//
//  ForeverMacroTests.swift
//  ForeverMacrosTests
//

import Testing
import SwiftSyntaxMacros
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
@testable import ForeverMacros

/// The macros registered for expansion in these tests.
private let macros: [String: Macro.Type] = ["Forever": ForeverMacro.self]

/// Wraps swift-syntax's generic `assertMacroExpansion` so call sites read like
/// the XCTest convenience API (`macros:`), while recording any mismatch as a
/// Swift Testing `Issue` with an accurate source location.
///
/// `SwiftSyntaxMacrosTestSupport.assertMacroExpansion` records failures via
/// `XCTFail`/`Issue.record` chosen at *its* compile time, which is unreliable
/// when driven from a Swift Testing test. Going through the generic support and
/// supplying our own `failureHandler` guarantees failures land in Swift Testing.
private func assertMacroExpansion(
    _ originalSource: String,
    expandedSource: String,
    diagnostics: [DiagnosticSpec] = [],
    macros: [String: Macro.Type],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) {
    SwiftSyntaxMacrosGenericTestSupport.assertMacroExpansion(
        originalSource,
        expandedSource: expandedSource,
        diagnostics: diagnostics,
        macroSpecs: macros.mapValues { MacroSpec(type: $0) },
        failureHandler: { spec in
            Issue.record(
                Comment(rawValue: spec.message),
                sourceLocation: SourceLocation(
                    fileID: spec.location.fileID,
                    filePath: spec.location.filePath,
                    line: spec.location.line,
                    column: spec.location.column
                )
            )
        },
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}

// MARK: - Happy paths

@Test func structExpansion() {
    assertMacroExpansion(
        """
        struct ContentView {
            @Forever("todos") var todos: [Todo] = []
        }
        """,
        expandedSource: """
        struct ContentView {
            var todos: [Todo] {
                @storageRestrictions(initializes: _todos)
                init(initialValue) {
                    _todos = Forever(wrappedValue: initialValue, "todos")
                }
                get {
                    _todos.wrappedValue
                }
                nonmutating set {
                    _todos.wrappedValue = newValue
                }
            }

            private var _todos: Forever<[Todo]>

            var $todos: Binding<[Todo]> {
                _todos.projectedValue
            }
        }
        """,
        macros: macros
    )
}

@Test func classExpansionUsesPlainSetter() {
    assertMacroExpansion(
        """
        final class ViewModel {
            @Forever("counter") var counter: Int = 0
        }
        """,
        expandedSource: """
        final class ViewModel {
            var counter: Int {
                @storageRestrictions(initializes: _counter)
                init(initialValue) {
                    _counter = Forever(wrappedValue: initialValue, "counter")
                }
                get {
                    _counter.wrappedValue
                }
                set {
                    _counter.wrappedValue = newValue
                }
            }

            private var _counter: Forever<Int>

            var $counter: Binding<Int> {
                _counter.projectedValue
            }
        }
        """,
        macros: macros
    )
}

@Test func accessLevelIsMirroredOnProjection() {
    assertMacroExpansion(
        """
        public struct Model {
            @Forever("name") public var name: String = ""
        }
        """,
        expandedSource: """
        public struct Model {
            public var name: String {
                @storageRestrictions(initializes: _name)
                init(initialValue) {
                    _name = Forever(wrappedValue: initialValue, "name")
                }
                get {
                    _name.wrappedValue
                }
                nonmutating set {
                    _name.wrappedValue = newValue
                }
            }

            private var _name: Forever<String>

            public var $name: Binding<String> {
                _name.projectedValue
            }
        }
        """,
        macros: macros
    )
}

@Test func keyExpressionPassesThroughVerbatim() {
    assertMacroExpansion(
        """
        struct Model {
            @Forever(Self.key) var value: Int = 0
        }
        """,
        expandedSource: """
        struct Model {
            var value: Int {
                @storageRestrictions(initializes: _value)
                init(initialValue) {
                    _value = Forever(wrappedValue: initialValue, Self.key)
                }
                get {
                    _value.wrappedValue
                }
                nonmutating set {
                    _value.wrappedValue = newValue
                }
            }

            private var _value: Forever<Int>

            var $value: Binding<Int> {
                _value.projectedValue
            }
        }
        """,
        macros: macros
    )
}

@Test func dontDieAliasExpandsToForeverBacking() {
    assertMacroExpansion(
        """
        struct ContentView {
            @DontDie("todos") var todos: [Todo] = []
        }
        """,
        expandedSource: """
        struct ContentView {
            var todos: [Todo] {
                @storageRestrictions(initializes: _todos)
                init(initialValue) {
                    _todos = Forever(wrappedValue: initialValue, "todos")
                }
                get {
                    _todos.wrappedValue
                }
                nonmutating set {
                    _todos.wrappedValue = newValue
                }
            }

            private var _todos: Forever<[Todo]>

            var $todos: Binding<[Todo]> {
                _todos.projectedValue
            }
        }
        """,
        macros: ["DontDie": ForeverMacro.self]
    )
}

// MARK: - Diagnostics

@Test func missingTypeAnnotationIsDiagnosed() {
    assertMacroExpansion(
        """
        struct Model {
            @Forever("k") var value = 0
        }
        """,
        expandedSource: """
        struct Model {
            var value = 0
        }
        """,
        diagnostics: [
            DiagnosticSpec(
                message: "'@Forever' requires an explicit type annotation, for example: var todos: [Todo] = []",
                line: 2,
                column: 5)
        ],
        macros: macros
    )
}

@Test func missingInitialValueIsDiagnosed() {
    assertMacroExpansion(
        """
        struct Model {
            @Forever("k") var value: Int
        }
        """,
        expandedSource: """
        struct Model {
            var value: Int
        }
        """,
        diagnostics: [
            DiagnosticSpec(
                message: "'@Forever' requires an initial value, for example: var todos: [Todo] = []",
                line: 2,
                column: 5)
        ],
        macros: macros
    )
}

@Test func letIsDiagnosed() {
    assertMacroExpansion(
        """
        struct Model {
            @Forever("k") let value: Int = 0
        }
        """,
        expandedSource: """
        struct Model {
            let value: Int = 0
        }
        """,
        diagnostics: [
            DiagnosticSpec(
                message: "'@Forever' cannot be applied to a 'let' declaration; the value must be mutable.",
                line: 2,
                column: 19)
        ],
        macros: macros
    )
}

@Test func staticIsDiagnosed() {
    assertMacroExpansion(
        """
        struct Model {
            @Forever("k") static var value: Int = 0
        }
        """,
        expandedSource: """
        struct Model {
            static var value: Int = 0
        }
        """,
        diagnostics: [
            DiagnosticSpec(
                message: "'@Forever' cannot be applied to a 'static' (or 'class') declaration.",
                line: 2,
                column: 5)
        ],
        macros: macros
    )
}

@Test func computedPropertyIsDiagnosed() {
    assertMacroExpansion(
        """
        struct Model {
            @Forever("k") var value: Int { 0 }
        }
        """,
        expandedSource: """
        struct Model {
            var value: Int { 0 }
        }
        """,
        diagnostics: [
            DiagnosticSpec(
                message: "'@Forever' cannot be applied to a computed property or a property with accessors/observers.",
                line: 2,
                column: 5)
        ],
        macros: macros
    )
}

@Test func topLevelVariableIsDiagnosed() {
    assertMacroExpansion(
        """
        @Forever("k") var value: Int = 0
        """,
        expandedSource: """
        var value: Int = 0
        """,
        diagnostics: [
            DiagnosticSpec(
                message: "'@Forever' cannot be applied to a top-level variable; declare the property inside a type.",
                line: 1,
                column: 1)
        ],
        macros: macros
    )
}

@Test func extensionMemberIsDiagnosed() {
    assertMacroExpansion(
        """
        extension Model {
            @Forever("k") var value: Int = 0
        }
        """,
        expandedSource: """
        extension Model {
            var value: Int = 0
        }
        """,
        diagnostics: [
            DiagnosticSpec(
                message: "'@Forever' cannot be applied inside an extension; declare the property in the type's main body.",
                line: 2,
                column: 5)
        ],
        macros: macros
    )
}

@Test func multipleBindingsAreDiagnosed() {
    assertMacroExpansion(
        """
        struct Model {
            @Forever("k") var a: Int = 0, b: Int = 0
        }
        """,
        expandedSource: """
        struct Model {
            var a: Int = 0, b: Int = 0
        }
        """,
        diagnostics: [
            DiagnosticSpec(
                message: "accessor macro can only be applied to a single variable",
                line: 2,
                column: 5),
            DiagnosticSpec(
                message: "peer macro can only be applied to a single variable",
                line: 2,
                column: 5)
        ],
        macros: macros
    )
}
