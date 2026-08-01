//
//  ForeverMacroBehaviorTests.swift
//  ForeverTests
//
//  Viewless behavioral tests for the `@Forever` attached macro: the expansion
//  must wire into the same shared runtime as the property wrapper.
//

import XCTest
import Combine
import SwiftUI
@testable import Forever

/// A viewless (UIKit-style) user of the macro. The key is indirected through a
/// static so each test can use a unique, cleanup-registered key.
final class MacroUser {
    static var key = "macro-behavior-uninitialized"

    @Forever(Self.key) var value: Int = 0
}

extension MacroUser {
    /// `_value` is `private`; same-file extensions can still reach it.
    var publisherForTesting: AnyPublisher<Int, Never> { _value.publisher }
}

final class ForeverMacroBehaviorTests: XCTestCase {

    private var keysToCleanUp: [String] = []

    override func tearDown() {
        for key in keysToCleanUp {
            try? FileManager.default.removeItem(at: ForeverStore<Int>.archiveURL(for: key))
        }
        keysToCleanUp.removeAll()
        super.tearDown()
    }

    private func makeKey(_ name: String) -> String {
        let key = "\(name)-\(UUID().uuidString)"
        keysToCleanUp.append(key)
        return key
    }

    func testMacroPropertySetPersistsAndPublishes() {
        MacroUser.key = makeKey("macro-behavior")
        let user = MacroUser()

        var emitted: [Int] = []
        let cancellable = user.publisherForTesting.sink { emitted.append($0) }

        user.value = 42

        XCTAssertEqual(user.value, 42)
        XCTAssertEqual(emitted, [42], "publisher must emit the new value")

        let url = ForeverStore<Int>.archiveURL(for: MacroUser.key)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try? JSONDecoder().decode(Int.self, from: Data(contentsOf: url)), 42)

        _ = cancellable
    }

    func testMacroInstancesWithSameKeySync() {
        MacroUser.key = makeKey("macro-sync")
        let first = MacroUser()
        let second = MacroUser()

        first.value = 7

        XCTAssertEqual(second.value, 7, "same-key instances must share one store")
    }

    func testDollarProjectionReadsAndWrites() {
        MacroUser.key = makeKey("macro-projection")
        let user = MacroUser()
        user.value = 1

        let binding: Binding<Int> = user.$value
        XCTAssertEqual(binding.wrappedValue, 1)

        binding.wrappedValue = 5
        XCTAssertEqual(user.value, 5)

        let url = ForeverStore<Int>.archiveURL(for: MacroUser.key)
        XCTAssertEqual(try? JSONDecoder().decode(Int.self, from: Data(contentsOf: url)), 5)
    }

    func testMacroPropertyHydratesFromDisk() {
        let key = makeKey("macro-hydrate")

        // Persist a value through the runtime directly.
        let store = ForeverStore.shared(key: key, default: 0)
        store.set(99)

        MacroUser.key = key
        let user = MacroUser()
        XCTAssertEqual(user.value, 99, "macro property must hydrate from the persisted value")
    }
}
