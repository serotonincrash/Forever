//
//  ForeverStore.swift
//  Forever
//
//  Created by Jia Chen Yee on 1/8/24.
//

import Foundation
import Combine
import OSLog

/// The shared, in-memory source of truth behind ``Forever``.
///
/// `ForeverStore` keeps a single `Codable` value in memory, persists it to disk
/// as JSON on every mutation, and publishes every new value through ``values``.
/// All ``Forever`` instances that share a key (and value type) are backed by the
/// same store, so a write through any one of them is immediately visible to all
/// of them.
public final class ForeverStore<Value: Codable>: ObservableObject {

    /// The current value. This is the single source of truth while the store is alive.
    @Published public private(set) var value: Value

    /// The key this store persists under (`<key>.plist` in the documents directory).
    public let key: String

    /// Publishes every new value, immediately after the in-memory update and the
    /// persist attempt. The value is published even when persisting to disk failed.
    public let values = PassthroughSubject<Value, Never>()

    private let logger = Logger(subsystem: "com.jiachenyee.Forever", category: "persistence")

    private init(key: String, defaultValue: Value) {
        self.key = key
        // Hydrate exactly once: prefer the persisted value, fall back to the default.
        self.value = Self.load(key: key) ?? defaultValue
    }

    /// Replaces the in-memory value, attempts to persist it, then publishes it.
    ///
    /// Order matters:
    /// 1. `value` is updated first; `@Published` notifies SwiftUI through
    ///    `objectWillChange`, invalidating every view observing this store.
    /// 2. The value is written to disk. Failures (for example a `Double`
    ///    containing `nan`, which `JSONEncoder` cannot encode) are logged via
    ///    OSLog and never thrown. The value still lives in memory, but it will
    ///    not survive a relaunch.
    /// 3. The new value is published to ``values`` subscribers.
    public func set(_ newValue: Value) {
        value = newValue

        let url = Self.archiveURL(for: key)
        do {
            let data = try JSONEncoder().encode(newValue)
            try data.write(to: url, options: .noFileProtection)
        } catch {
            logger.error("Failed to persist value for key '\(self.key, privacy: .public)' at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        values.send(value)
    }

    /// Returns the existing store for `(Value.self, key)`, or creates one.
    ///
    /// The registry holds stores weakly, so a store lives exactly as long as
    /// something references it. When the last reference is dropped, the next
    /// call creates a fresh store that rehydrates from disk.
    public static func shared(key: String, default defaultValue: Value) -> ForeverStore<Value> {
        ForeverStoreRegistry.lock.lock()
        defer { ForeverStoreRegistry.lock.unlock() }

        // Purge entries whose store has been deallocated.
        ForeverStoreRegistry.registry = ForeverStoreRegistry.registry.filter { $0.value.store != nil }

        let registryKey = RegistryKey(typeID: ObjectIdentifier(Value.self), key: key)
        if let existing = ForeverStoreRegistry.registry[registryKey],
           let store = existing.store as? ForeverStore<Value> {
            return store
        }

        let store = ForeverStore(key: key, defaultValue: defaultValue)
        ForeverStoreRegistry.registry[registryKey] = WeakBox(store)
        return store
    }

    // MARK: - Persistence

    /// The on-disk location: `<key>.plist` in the app's documents directory.
    static func archiveURL(for key: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("\(key).plist")
    }

    private static func load(key: String) -> Value? {
        let url = archiveURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Value.self, from: data) else {
            return nil
        }
        return decoded
    }

    // MARK: - Registry

}

private struct RegistryKey: Hashable {
    let typeID: ObjectIdentifier
    let key: String
}

private final class WeakBox {
    weak var store: AnyObject?

    init(_ store: AnyObject) {
        self.store = store
    }
}

/// Holds the shared registry. Kept in a non-generic type because Swift does not
/// allow static stored properties on generic types.
private enum ForeverStoreRegistry {
    static let lock = NSLock()
    static var registry: [RegistryKey: WeakBox] = [:]
}

/// A stable strong reference to a ``ForeverStore``.
///
/// ``Forever``'s `@StateObject` storage is only installed inside a SwiftUI view
/// hierarchy; accessed from a plain class (UIKit + Combine usage) it resolves a
/// fresh store on every access and retains nothing. The box resolves the shared
/// registry store once and retains it, so every access — inside or outside a
/// view — sees the same instance.
final class ForeverStoreBox<Value: Codable> {
    private let key: String
    private let defaultValue: Value
    private var resolved: ForeverStore<Value>?

    init(key: String, defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var store: ForeverStore<Value> {
        if let resolved {
            return resolved
        }
        let store = ForeverStore.shared(key: key, default: defaultValue)
        resolved = store
        return store
    }
}
