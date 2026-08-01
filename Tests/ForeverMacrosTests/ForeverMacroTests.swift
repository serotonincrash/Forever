//
//  ForeverMacroTests.swift
//  ForeverMacrosTests
//

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import ForeverMacros

final class ForeverMacroTests: XCTestCase {

    private let macros: [String: Macro.Type] = ["Forever": ForeverMacro.self]

    // MARK: - Happy paths

    func testStructExpansion() {
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

    func testClassExpansionUsesPlainSetter() {
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

    func testAccessLevelIsMirroredOnProjection() {
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

    func testKeyExpressionPassesThroughVerbatim() {
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

    // MARK: - Diagnostics

    func testMissingTypeAnnotationIsDiagnosed() {
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

    func testMissingInitialValueIsDiagnosed() {
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

    func testLetIsDiagnosed() {
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

    func testStaticIsDiagnosed() {
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

    func testComputedPropertyIsDiagnosed() {
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

    func testTopLevelVariableIsDiagnosed() {
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

    func testExtensionMemberIsDiagnosed() {
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

    func testMultipleBindingsAreDiagnosed() {
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
}
