/// Persists any `Codable` value, automatically.
///
/// ```swift
/// @Forever("todos") var todos: [Todo] = [Todo(title: "Feed the cat", isCompleted: true),
///                                        Todo(title: "Play with cat"),
///                                        Todo(title: "Get allergies")]
/// ```
///
/// `@Forever` works just like `@AppStorage` or `@SceneStorage`, but for anything
/// that is [`Codable`](https://developer.apple.com/documentation/swift/codable).
/// The value is hydrated from disk once, kept in memory while in use, and written
/// back to `<key>.plist` in the app's documents directory on every mutation.
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
/// store, so a write through any one of them is immediately reflected in all
/// of the others — in SwiftUI and UIKit alike.
///
/// Requirements:
/// - The property needs an explicit type annotation and an initial value
///   (the initial value is the fallback used when nothing is persisted yet).
/// - Apply it to instance variables of types only — not to `let`, `static`,
///   computed properties, top-level variables, or properties in extensions.
///
/// For Combine, access ``Forever/publisher`` through the backing property:
/// `_todos.publisher`. For the classic property-wrapper syntax with type
/// inference, see the typealiases such as ``DontDie``.
///
/// - Parameter key: A key to retrieve the stored value. Must be unique per
///   stored item and non-empty.
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_), prefixed(`$`))
public macro Forever(_ key: String) = #externalMacro(module: "ForeverMacros", type: "ForeverMacro")
