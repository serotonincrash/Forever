# Forever

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fjiachenyee%2Fforever%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/jiachenyee/forever)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fjiachenyee%2Fforever%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/jiachenyee/forever)

## Persist any `Codable` value.

> For full documentation, click [here](https://forever.jiachen.app/documentation/forever/forever).

```swift
@Forever("todos") var todos: [Todo] = [Todo(title: "Feed the cat", isCompleted: true),
                                      Todo(title: "Play with cat"),
                                      Todo(title: "Get allergies"),
                                      Todo(title: "Run away from cat"),
                                      Todo(title: "Get a new cat")]
```
```swift
struct Todo: Codable {
    var title: String
    var isCompleted = false
}
```

`@Forever` is an attached macro: give it a key, an explicit type, and an initial value. It reads and writes like a normal property, projects a classic `Binding` (`$todos`), and persists every mutation to `<key>.plist` in the documents directory.

## One line and it lasts `@Forever`.
```swift
@Forever("counter") var counter: Int = 1
```

## One value, many views

Every `@Forever` instance with the same key (and same value type) is backed by a single shared store: write from any view, and every other view with that key updates immediately — no app restart needed.

## Using UIKit? `Forever`+Combine
Thanks https://github.com/jiachenyee/Forever/issues/1.
```swift
class ViewController: UIViewController {

    @Forever("counter") var counter: Int = 1
    var cancellables = Set<AnyCancellable>()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        _counter.publisher.sink(receiveValue: { value in
            print(value)
        })
        .store(in: &cancellables)
    }
    //...
}
```

## Prefer a different name?
`@DontDie`, `@DontLeaveMe`, and `@BePersistent` are alternate names for the same `@Forever` macro — same store, same `$` projection, same everything:
```swift
@DontDie("counter") var counter: Int = 0
@DontLeaveMe("counter") var alsoCounter: Int = 0   // same store
```
Like `@Forever`, they need an explicit type and an initial value.

> **Migrating to 2.0:** `@Forever` and its aliases are macros only. The previous property-wrapper form with type inference — `@DontDie("k") var x = 0` — is no longer supported; add an explicit type and initial value: `@DontDie("k") var x: Int = 0`.

## Installation
### Requirements
| Platform | Version       |
|:--------:|:--------------|
|   iOS    | 17.0 or later |
|  macOS   | 14.0 or later |
| watchOS  | 10.0 or later |
|   tvOS   | 17.0 or later |

> Forever is built on the Observation framework, so it requires iOS 17 / macOS 14 / watchOS 10 / tvOS 17 and Xcode 15+. The `main` branch remains available for clients targeting older OS versions.
>
> The Combine `publisher` API is retained for UIKit and other non-SwiftUI clients.

### Add as Swift Package
In Xcode, File → Add Packages… → Paste `https://github.com/jiachenyee/forever` in the search field.
