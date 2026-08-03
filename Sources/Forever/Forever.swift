//
//  Forever.swift
//  Forever
//
//  Created by Jia Chen Yee on 18/1/23.
//

import Foundation
import SwiftUI

/// The storage-holder type that the ``Forever`` attached macro expands to.
///
/// You rarely construct `Forever` directly. Apply the ``Forever`` macro to a
/// stored property and it expands to a `Forever<Value>` backing property plus
/// `init`/`get`/`set` accessors that forward to it:
///
/// ```swift
/// @Forever("todos") var todos: [Todo] = [Todo(title: "Feed the cat", isCompleted: true),
///                                        Todo(title: "Play with cat"),
///                                        Todo(title: "Get allergies")]
/// ```
///
/// `Forever` automatically manages persistence for any
/// [`Codable`](https://developer.apple.com/documentation/swift/codable) value.
/// The value is hydrated from disk once, kept in memory while in use, and
/// written back to `<key>.plist` in the app's documents directory on every
/// mutation. It works just like `@AppStorage` or `@SceneStorage`, but for
/// anything that is `Codable`.
///
/// Read and write the value like a normal property, and pass it to child views
/// with the projected [`Binding`](https://developer.apple.com/documentation/swiftui/binding):
///
/// ```swift
/// List($todos, editActions: .all) { $todo in
///     Button { todo.isCompleted.toggle() } label: {
///         Text(todo.title)
///     }
/// }
/// ```
///
/// All properties that share a ``key`` (and value type) are backed by the same
/// ``ForeverStore``, so a write through any one of them is immediately
/// reflected in all of the others — in SwiftUI and UIKit alike.
///
/// Views that read the value in their `body` are invalidated through the
/// Observation framework: `Forever` holds an `@Observable` store, and every
/// write funnels through ``ForeverStore/set(_:)``, which updates the value,
/// attempts to persist it, and publishes it through ``publisher``.
///
/// If a value cannot be retrieved — either because nothing is persisted yet or
/// because decoding fails — the default value provided to the macro is used.
/// The on-disk file is only overwritten once a value of the declared type is
/// written.
///
/// Values are persisted to disk as JSON on every change. If persisting fails —
/// for example a `Double` set to `nan`, which `JSONEncoder` cannot encode — the
/// error is logged with `OSLog` and the value still lives in memory for the
/// current session, but it will not survive a relaunch.
///
/// - Note: `Forever` is not a property wrapper; it is a plain `DynamicProperty`
///   the macro targets. The `wrappedValue`/`projectedValue` members exist so
///   the macro-generated accessors have something to forward to, and so the
///   type can be constructed directly for advanced (non-macro) use.
///
/// ## Topics
/// ### Creating Forever
/// - ``init(wrappedValue:_:file:line:)``
/// - ``key``
///
/// ### Getting the value
/// - ``projectedValue``
/// - ``wrappedValue``
///
/// ### Combine
/// - ``publisher``
public struct Forever<Value: Codable>: DynamicProperty {

    /// A key to retrieve the stored value
    public var key: String

    @State var store: ForeverStore<Value>

    /// The current value. Reading it registers Observation tracking; setting it
    /// funnels through ``ForeverStore/set(_:)`` (persist + publish).
    public var wrappedValue: Value {
        get {
            store.value
        }
        nonmutating set {
            store.set(newValue)
        }
    }

    /// A binding to the ``Forever`` value.
    ///
    /// This is deliberately a manual `Binding(get:set:)` rather than
    /// `Bindable(store).value`: `value` is `private(set)`, so the key path is
    /// read-only, and a writable direct set would bypass the ``set(_:)`` funnel
    /// (persistence + publisher). Do not "modernize" this to `Bindable`.
    public var projectedValue: Binding<Value> {
        Binding(get: {
            store.value
        }, set: { value in
            store.set(value)
        })
    }

    public init(wrappedValue: Value, _ key: String, file: String = #file, line: UInt = #line) {
        precondition(!key.isEmpty, "The key cannot be an empty String.\n\(file):\(line)")

        self.key = key

        _store = State(wrappedValue: ForeverStore.shared(key: key, default: wrappedValue))
    }
}
