//
//  ForeverTests.swift
//  ForeverTests
//

import Testing
import Combine
import Observation
import SwiftUI
@testable import Forever

@Suite(.serialized)
final class ForeverTests {

    /// Keys created during the current test; cleaned up when this instance is
    /// deinitialized (Swift Testing makes a fresh instance per test).
    private var keysToCleanUp: [String] = []

    deinit {
        for key in keysToCleanUp {
            try? FileManager.default.removeItem(at: Self.archiveURL(for: key))
        }
    }

    /// Returns a unique key and registers it for cleanup.
    private func makeKey(_ name: String) -> String {
        let key = "\(name)-\(UUID().uuidString)"
        keysToCleanUp.append(key)
        return key
    }

    private static func archiveURL(for key: String) -> URL {
        ForeverStore<Int>.archiveURL(for: key)
    }

    // MARK: - Roundtrip

    @Test func setPersistsAndNewStoreRehydrates() throws {
        let key = makeKey("roundtrip")

        var store: ForeverStore<Int>? = ForeverStore.shared(key: key, default: 0)
        store?.set(42)

        // The file exists and decodes to the new value.
        let url = Self.archiveURL(for: key)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let persisted = try JSONDecoder().decode(Int.self, from: Data(contentsOf: url))
        #expect(persisted == 42)

        // Once the store is released, a new store for the same key rehydrates from disk.
        store = nil
        let rehydrated = ForeverStore.shared(key: key, default: 0)
        #expect(rehydrated.value == 42)
    }

    @Test func defaultValueUsedWhenNothingPersisted() {
        let key = makeKey("default")

        let store = ForeverStore.shared(key: key, default: 99)
        #expect(store.value == 99)
    }

    @Test func corruptedFileFallsBackToDefaultAndIsOverwrittenOnNextSet() throws {
        let key = makeKey("corrupted")

        // Pre-seed a corrupt file.
        try Data("not json".utf8).write(to: Self.archiveURL(for: key))

        let store = ForeverStore.shared(key: key, default: 5)
        #expect(store.value == 5, "An undecodable file must fall back to the default")

        // The next set overwrites the corrupt file.
        store.set(7)
        let overwritten = try JSONDecoder().decode(Int.self, from: Data(contentsOf: Self.archiveURL(for: key)))
        #expect(overwritten == 7)
    }

    @Test func differentTypeSameKeyFallsBackToDefaultAndDoesNotDisturbFile() throws {
        let key = makeKey("type-mismatch")

        var intStore: ForeverStore<Int>? = ForeverStore.shared(key: key, default: 1)
        intStore?.set(1)
        intStore = nil

        let url = Self.archiveURL(for: key)
        let intData = try Data(contentsOf: url)

        let stringStore = ForeverStore.shared(key: key, default: "potato")
        #expect(stringStore.value == "potato", "Decoding an Int file as String must fall back to the default")

        // The in-memory default is used; the file is untouched until a String is written.
        let fileAfter = try Data(contentsOf: url)
        #expect(fileAfter == intData)
    }

    // MARK: - Getter never touches disk (headline regression)

    @Test func valueIsReadFromMemoryNotDisk() throws {
        let key = makeKey("getter-never-touches-disk")

        let store = ForeverStore.shared(key: key, default: 7)
        store.set(9)

        let url = Self.archiveURL(for: key)

        // Corrupt the file out from under the store…
        try Data("corrupted".utf8).write(to: url)
        #expect(store.value == 9, "Corrupting the file must not change the in-memory value")

        // …or delete it entirely.
        try FileManager.default.removeItem(at: url)
        #expect(store.value == 9, "Deleting the file must not change the in-memory value")

        // Writes still persist to disk afterwards.
        store.set(10)
        #expect(store.value == 10)
        let reread = try JSONDecoder().decode(Int.self, from: Data(contentsOf: url))
        #expect(reread == 10)
    }

    // MARK: - Shared registry

    @Test func sharedRegistryReturnsSameInstanceForSameKeyAndType() {
        let key = makeKey("identity")

        let a = ForeverStore.shared(key: key, default: 1)
        let b = ForeverStore.shared(key: key, default: 99)
        #expect(a === b, "Same key + same type must return the same store")
        #expect(b.value == 1, "The first store wins hydration; later defaults are ignored")

        let differentType = ForeverStore.shared(key: key, default: "hello")
        #expect(ObjectIdentifier(a) != ObjectIdentifier(differentType),
               "Same key + different type must return a distinct store")

        let differentKey = ForeverStore.shared(key: makeKey("identity-other"), default: 1)
        #expect(a !== differentKey, "Different key must return a distinct store")
    }

    // MARK: - Publisher

    @Test func publisherEmitsExactlyTheNewValuesInOrder() {
        let key = makeKey("publisher")

        let store = ForeverStore.shared(key: key, default: 0)

        var emitted: [Int] = []
        let cancellable = store.values.sink { emitted.append($0) }

        store.set(1)
        store.set(2)
        store.set(3)

        #expect(emitted == [1, 2, 3], "The publisher must emit the new values, not the stale pre-write value")

        withExtendedLifetime(cancellable) {}
    }

    @Test func setNotifiesObservationTrackingWhenValueIsRead() {
        let key = makeKey("observation")

        let store = ForeverStore.shared(key: key, default: 0)

        // Tracking is read-gated: a closure that never reads `value` registers nothing.
        var unobservedChanges = 0
        withObservationTracking {
            _ = store.key // `let` properties are not observable
        } onChange: {
            unobservedChanges += 1
        }
        store.set(1)
        #expect(unobservedChanges == 0, "Only properties actually read inside the tracking closure are tracked")

        // Reading `value` registers a dependency; the next set must fire onChange.
        var changes = 0
        withObservationTracking {
            _ = store.value
        } onChange: {
            changes += 1
        }
        store.set(2)
        #expect(changes == 1, "Each set must invalidate observing views via the Observation registrar")

        // onChange is one-shot: further sets do not fire it again without re-tracking.
        store.set(3)
        #expect(changes == 1, "withObservationTracking's onChange is one-shot")
    }

    // MARK: - Encode failure

    @Test func unencodableValueStaysInMemoryAndFileIsUntouched() throws {
        let key = makeKey("nan")

        let store = ForeverStore.shared(key: key, default: 1.0)
        store.set(1.0)

        let url = Self.archiveURL(for: key)
        let originalData = try Data(contentsOf: url)

        var emitted: [Double] = []
        let cancellable = store.values.sink { emitted.append($0) }

        store.set(.nan)

        #expect(store.value.isNaN, "The in-memory value must update even when encoding fails")
        #expect(emitted.count == 1)
        #expect(emitted[0].isNaN, "The publisher must emit the new value even when persisting failed")

        let diskAfterFailure = try Data(contentsOf: url)
        #expect(diskAfterFailure == originalData, "Disk contents must be unchanged after an encode failure")
        let decodedOriginal = try JSONDecoder().decode(Double.self, from: originalData)
        #expect(decodedOriginal == 1.0)

        withExtendedLifetime(cancellable) {}
    }

    // MARK: - Lifecycle

    @Test func storeDeallocatesAndNextSharedLookupRehydratesFromDisk() {
        let key = makeKey("lifecycle")

        weak var weakStore: ForeverStore<Int>?
        var store: ForeverStore<Int>? = ForeverStore.shared(key: key, default: 5)
        store?.set(11)
        weakStore = store
        #expect(weakStore != nil)

        store = nil
        #expect(weakStore == nil, "The store must deallocate when no strong references remain (registry is weak)")

        let rehydrated = ForeverStore.shared(key: key, default: 0)
        #expect(rehydrated.value == 11, "A fresh store must rehydrate the persisted value from disk")
    }

    // MARK: - Forever (no view hierarchy)

    @Test func foreverInstancesWithSameKeyShareOneStore() {
        let key = makeKey("wrapper-shared")

        var a = Forever(wrappedValue: 0, key)
        var b = Forever(wrappedValue: 0, key)

        a.wrappedValue = 5
        #expect(b.wrappedValue == 5, "A write through one wrapper must be visible through another with the same key")

        b.wrappedValue = 7
        #expect(a.wrappedValue == 7, "Sync must work in both directions")
    }

    /// A UIKit-style class holding a `Forever` macro property, with no SwiftUI
    /// view hierarchy. Exercises the publisher path outside of SwiftUI.
    private final class PlainCounter {
        static var key = "viewless-uninitialized"

        @Forever(Self.key) var value: Int = 0

        var cancellables = Set<AnyCancellable>()
        var emitted: [Int] = []

        init() {
            _value.publisher.sink { [weak self] value in
                self?.emitted.append(value)
            }
            .store(in: &cancellables)
        }
    }

    @Test func viewlessUsagePersistsAndPublishes() {
        let key = makeKey("viewless")

        PlainCounter.key = key
        var counter: PlainCounter? = PlainCounter()
        counter?.value = 1
        counter?.value = 2
        #expect(counter?.emitted == [1, 2], "The publisher must emit the new value, not the stale pre-write value")

        let url = Self.archiveURL(for: key)
        #expect(FileManager.default.fileExists(atPath: url.path))

        counter = nil

        let rehydrated = PlainCounter()
        #expect(rehydrated.value == 2, "A new instance hydrates the persisted value from disk")
        #expect(rehydrated.emitted == [])
    }

    @Test func viewlessAccessReturnsStableRetainedStore() throws {
        let key = makeKey("viewless-stability")

        var wrapper = Forever(wrappedValue: 0, key)

        // Every access resolves the same store instance: `@State` stores the
        // initial value in the struct, so no fresh store is resolved per access
        // (unlike an uninstalled `@StateObject`).
        let first = wrapper.store
        let second = wrapper.store
        #expect(first === second, "Repeated access outside a view hierarchy must return the same store instance")

        // The wrapper retains the store for its whole lifetime.
        weak var weakStore = first
        withExtendedLifetime(wrapper) {
            #expect(weakStore != nil, "The wrapper must retain the store")
        }

        // The stable store still persists and publishes.
        wrapper.wrappedValue = 5
        #expect(second.value == 5, "A write through one access must be visible through another")
        let url = Self.archiveURL(for: key)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let finalOnDisk = try JSONDecoder().decode(Int.self, from: Data(contentsOf: url))
        #expect(finalOnDisk == 5)
    }
}
