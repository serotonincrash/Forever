//
//  ForeverTests.swift
//  ForeverTests
//

import XCTest
import Combine
@testable import Forever

final class ForeverTests: XCTestCase {

    /// Keys created during the current test; cleaned up in `tearDown`.
    private var keysToCleanUp: [String] = []

    override func tearDown() {
        for key in keysToCleanUp {
            try? FileManager.default.removeItem(at: Self.archiveURL(for: key))
        }
        keysToCleanUp.removeAll()
        super.tearDown()
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

    func testSetPersistsAndNewStoreRehydrates() throws {
        let key = makeKey("roundtrip")

        var store: ForeverStore<Int>? = ForeverStore.shared(key: key, default: 0)
        store?.set(42)

        // The file exists and decodes to the new value.
        let url = Self.archiveURL(for: key)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: Data(contentsOf: url)), 42)

        // Once the store is released, a new store for the same key rehydrates from disk.
        store = nil
        let rehydrated = ForeverStore.shared(key: key, default: 0)
        XCTAssertEqual(rehydrated.value, 42)
    }

    func testDefaultValueUsedWhenNothingPersisted() {
        let key = makeKey("default")

        let store = ForeverStore.shared(key: key, default: 99)
        XCTAssertEqual(store.value, 99)
    }

    func testCorruptedFileFallsBackToDefaultAndIsOverwrittenOnNextSet() throws {
        let key = makeKey("corrupted")

        // Pre-seed a corrupt file.
        try Data("not json".utf8).write(to: Self.archiveURL(for: key))

        let store = ForeverStore.shared(key: key, default: 5)
        XCTAssertEqual(store.value, 5, "An undecodable file must fall back to the default")

        // The next set overwrites the corrupt file.
        store.set(7)
        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: Data(contentsOf: Self.archiveURL(for: key))), 7)
    }

    func testDifferentTypeSameKeyFallsBackToDefaultAndDoesNotDisturbFile() throws {
        let key = makeKey("type-mismatch")

        var intStore: ForeverStore<Int>? = ForeverStore.shared(key: key, default: 1)
        intStore?.set(1)
        intStore = nil

        let url = Self.archiveURL(for: key)
        let intData = try Data(contentsOf: url)

        let stringStore = ForeverStore.shared(key: key, default: "potato")
        XCTAssertEqual(stringStore.value, "potato", "Decoding an Int file as String must fall back to the default")

        // The in-memory default is used; the file is untouched until a String is written.
        XCTAssertEqual(try Data(contentsOf: url), intData)
    }

    // MARK: - Getter never touches disk (headline regression)

    func testValueIsReadFromMemoryNotDisk() throws {
        let key = makeKey("getter-never-touches-disk")

        let store = ForeverStore.shared(key: key, default: 7)
        store.set(9)

        let url = Self.archiveURL(for: key)

        // Corrupt the file out from under the store…
        try Data("corrupted".utf8).write(to: url)
        XCTAssertEqual(store.value, 9, "Corrupting the file must not change the in-memory value")

        // …or delete it entirely.
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(store.value, 9, "Deleting the file must not change the in-memory value")

        // Writes still persist to disk afterwards.
        store.set(10)
        XCTAssertEqual(store.value, 10)
        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: Data(contentsOf: url)), 10)
    }

    // MARK: - Shared registry

    func testSharedRegistryReturnsSameInstanceForSameKeyAndType() {
        let key = makeKey("identity")

        let a = ForeverStore.shared(key: key, default: 1)
        let b = ForeverStore.shared(key: key, default: 99)
        XCTAssertTrue(a === b, "Same key + same type must return the same store")
        XCTAssertEqual(b.value, 1, "The first store wins hydration; later defaults are ignored")

        let differentType = ForeverStore.shared(key: key, default: "hello")
        XCTAssertNotEqual(ObjectIdentifier(a), ObjectIdentifier(differentType),
                          "Same key + different type must return a distinct store")

        let differentKey = ForeverStore.shared(key: makeKey("identity-other"), default: 1)
        XCTAssertFalse(a === differentKey, "Different key must return a distinct store")
    }

    // MARK: - Publisher

    func testPublisherEmitsExactlyTheNewValuesInOrder() {
        let key = makeKey("publisher")

        let store = ForeverStore.shared(key: key, default: 0)

        var emitted: [Int] = []
        let cancellable = store.values.sink { emitted.append($0) }

        store.set(1)
        store.set(2)
        store.set(3)

        XCTAssertEqual(emitted, [1, 2, 3], "The publisher must emit the new values, not the stale pre-write value")

        withExtendedLifetime(cancellable) {}
    }

    func testSetNotifiesObjectWillChange() {
        let key = makeKey("objectWillChange")

        let store = ForeverStore.shared(key: key, default: 0)

        var changes = 0
        let cancellable = store.objectWillChange.sink { changes += 1 }

        store.set(1)
        store.set(2)

        XCTAssertEqual(changes, 2, "Each set must invalidate observing SwiftUI views via objectWillChange")

        withExtendedLifetime(cancellable) {}
    }

    // MARK: - Encode failure

    func testUnencodableValueStaysInMemoryAndFileIsUntouched() throws {
        let key = makeKey("nan")

        let store = ForeverStore.shared(key: key, default: 1.0)
        store.set(1.0)

        let url = Self.archiveURL(for: key)
        let originalData = try Data(contentsOf: url)

        var emitted: [Double] = []
        let cancellable = store.values.sink { emitted.append($0) }

        store.set(.nan)

        XCTAssertTrue(store.value.isNaN, "The in-memory value must update even when encoding fails")
        XCTAssertEqual(emitted.count, 1)
        XCTAssertTrue(emitted[0].isNaN, "The publisher must emit the new value even when persisting failed")

        XCTAssertEqual(try Data(contentsOf: url), originalData, "Disk contents must be unchanged after an encode failure")
        XCTAssertEqual(try JSONDecoder().decode(Double.self, from: originalData), 1.0)

        withExtendedLifetime(cancellable) {}
    }

    // MARK: - Lifecycle

    func testStoreDeallocatesAndNextSharedLookupRehydratesFromDisk() {
        let key = makeKey("lifecycle")

        weak var weakStore: ForeverStore<Int>?
        var store: ForeverStore<Int>? = ForeverStore.shared(key: key, default: 5)
        store?.set(11)
        weakStore = store
        XCTAssertNotNil(weakStore)

        store = nil
        XCTAssertNil(weakStore, "The store must deallocate when no strong references remain (registry is weak)")

        let rehydrated = ForeverStore.shared(key: key, default: 0)
        XCTAssertEqual(rehydrated.value, 11, "A fresh store must rehydrate the persisted value from disk")
    }

    // MARK: - Forever wrapper (no view hierarchy)

    func testForeverWrapperInstancesWithSameKeyShareOneStore() {
        let key = makeKey("wrapper-shared")

        var a = Forever(wrappedValue: 0, key)
        var b = Forever(wrappedValue: 0, key)

        a.wrappedValue = 5
        XCTAssertEqual(b.wrappedValue, 5, "A write through one wrapper must be visible through another with the same key")

        b.wrappedValue = 7
        XCTAssertEqual(a.wrappedValue, 7, "Sync must work in both directions")
    }

    /// A UIKit-style class holding a `Forever` property, with no SwiftUI view hierarchy.
    private final class PlainCounter {
        @Forever var value: Int

        var cancellables = Set<AnyCancellable>()
        var emitted: [Int] = []

        init(key: String) {
            _value = Forever(wrappedValue: 0, key)
            _value.publisher.sink { [weak self] value in
                self?.emitted.append(value)
            }
            .store(in: &cancellables)
        }
    }

    func testViewlessUsagePersistsAndPublishes() {
        let key = makeKey("viewless")

        var counter: PlainCounter? = PlainCounter(key: key)
        counter?.value = 1
        counter?.value = 2
        XCTAssertEqual(counter?.emitted, [1, 2], "The publisher must emit the new value, not the stale pre-write value")

        let url = Self.archiveURL(for: key)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        counter = nil

        let rehydrated = PlainCounter(key: key)
        XCTAssertEqual(rehydrated.value, 2, "A new instance hydrates the persisted value from disk")
        XCTAssertEqual(rehydrated.emitted, [])
    }
}
