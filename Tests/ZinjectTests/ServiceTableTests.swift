import Foundation
import Testing
@testable import Zinject

// `ServiceTable` on its own: probing, growth, and the removal path that rebuilds
// the whole table rather than back-shifting a cluster. The container tests cover
// what these mean for a resolve; these cover the cases a container would need an
// improbable set of registrations to reach.

/// Distinct service types to fill a table with. The table is keyed by type
/// metadata, so every instantiation of this is a key of its own.
private struct Probe<Tag> {}

private func makeKey<Service>(_ type: Service.Type) -> ServiceKey {
    ServiceKey(resolvingType: type)
}

private func makeFactory() -> any ServiceFactory {
    ServiceFactoryImpl<Int> { _ in 0 }
}

/// Twenty keys: enough to take an eight-slot table through two growths, and
/// enough that some of them collide on the way in.
private let probeKeys: [ServiceKey] = [
    makeKey(Probe<Int>.self), makeKey(Probe<Int8>.self),
    makeKey(Probe<Int16>.self), makeKey(Probe<Int32>.self),
    makeKey(Probe<Int64>.self), makeKey(Probe<UInt>.self),
    makeKey(Probe<UInt8>.self), makeKey(Probe<UInt16>.self),
    makeKey(Probe<UInt32>.self), makeKey(Probe<UInt64>.self),
    makeKey(Probe<Float>.self), makeKey(Probe<Double>.self),
    makeKey(Probe<Bool>.self), makeKey(Probe<String>.self),
    makeKey(Probe<Character>.self), makeKey(Probe<[Int]>.self),
    makeKey(Probe<[String]>.self), makeKey(Probe<Int?>.self),
    makeKey(Probe<Never>.self), makeKey(Probe<Void>.self),
]

@Test func emptyTableFindsNothing() async throws {
    let table = ServiceTable()
    #expect(table.slot(for: makeKey(A.self)) == nil)
    #expect(table.keys.isEmpty)
}

@Test func factoryRoundTripsThroughASlot() async throws {
    var table = ServiceTable()
    let factory = makeFactory()
    table.setFactory(factory, for: makeKey(A.self))

    let slot = try #require(table.slot(for: makeKey(A.self)))
    #expect(table.factory(at: slot) === factory)
    #expect(table.instance(at: slot) == nil)
    #expect(table.slot(for: makeKey(B.self)) == nil)
}

@Test func instanceRoundTripsThroughASlot() async throws {
    var table = ServiceTable()
    table.setFactory(makeFactory(), for: makeKey(A.self))

    let slot = try #require(table.slot(for: makeKey(A.self)))
    table.setInstance(CachedInstance(A()), at: slot)

    let storage = try #require(table.instance(at: slot))
    #expect(storage.assumingMemoryBound(to: A.self).pointee.num == 1)
}

@Test func reRegistrationReusesTheSlotAndDropsTheInstance() async throws {
    var table = ServiceTable()
    let key = makeKey(A.self)
    table.setFactory(makeFactory(), for: key)
    let slot = try #require(table.slot(for: key))
    table.setInstance(CachedInstance(A()), at: slot)

    let replacement = makeFactory()
    table.setFactory(replacement, for: key)

    #expect(table.slot(for: key) == slot)
    #expect(table.count == 1)
    #expect(table.factory(at: slot) === replacement)
    #expect(table.instance(at: slot) == nil)
}

@Test func growthKeepsEveryEntryFindable() async throws {
    var table = ServiceTable()
    var factories: [any ServiceFactory] = []

    for key in probeKeys {
        let factory = makeFactory()
        factories.append(factory)
        table.setFactory(factory, for: key)
    }

    #expect(table.count == probeKeys.count)
    // Two growths from the initial eight slots, and never past the ¾ load limit.
    #expect(table.keys.count == 32)

    for (key, factory) in zip(probeKeys, factories) {
        let slot = try #require(table.slot(for: key))
        #expect(table.factory(at: slot) === factory)
    }
}

@Test func removeKeepsEveryOtherEntryFindable() async throws {
    var table = ServiceTable()
    var factories: [any ServiceFactory] = []
    for key in probeKeys {
        let factory = makeFactory()
        factories.append(factory)
        table.setFactory(factory, for: key)
    }

    // Removing from the middle is the case a back-shifting delete would get
    // wrong: everything after it in a probe cluster has to stay reachable.
    for index in stride(from: 0, to: probeKeys.count, by: 3) {
        table.remove(probeKeys[index])
    }

    for (index, key) in probeKeys.enumerated() {
        if index % 3 == 0 {
            #expect(table.slot(for: key) == nil)
            continue
        }
        let slot = try #require(table.slot(for: key))
        #expect(table.factory(at: slot) === factories[index])
    }
    #expect(table.count == probeKeys.count - (probeKeys.count + 2) / 3)
}

@Test func removeOfAnAbsentKeyChangesNothing() async throws {
    var table = ServiceTable()
    table.setFactory(makeFactory(), for: makeKey(A.self))
    table.remove(makeKey(B.self))

    #expect(table.count == 1)
    #expect(table.slot(for: makeKey(A.self)) != nil)
}

@Test func removeAllEmptiesTheTable() async throws {
    var table = ServiceTable()
    for key in probeKeys {
        table.setFactory(makeFactory(), for: key)
    }
    table.removeAll()

    #expect(table.count == 0)
    for key in probeKeys {
        #expect(table.slot(for: key) == nil)
    }
}

@Test func droppingAnEntryFreesItsInstanceStorage() async throws {
    var table = ServiceTable()
    let key = makeKey(A.self)
    table.setFactory(makeFactory(), for: key)
    let slot = try #require(table.slot(for: key))

    weak var storage: CachedInstance<A>?
    do {
        let cached = CachedInstance(A())
        storage = cached
        table.setInstance(cached, at: slot)
    }
    #expect(storage != nil)

    table.remove(key)
    #expect(storage == nil)
}

@Test func aTableIsAValueAndCopiesDoNotShareState() async throws {
    var original = ServiceTable()
    original.setFactory(makeFactory(), for: makeKey(A.self))

    var copy = original
    copy.setFactory(makeFactory(), for: makeKey(B.self))

    // The two Left-Right copies of the container's state are exactly this: one
    // value copied, then mutated independently.
    #expect(original.slot(for: makeKey(B.self)) == nil)
    #expect(copy.slot(for: makeKey(B.self)) != nil)
    #expect(original.count == 1)
    #expect(copy.count == 2)
}
