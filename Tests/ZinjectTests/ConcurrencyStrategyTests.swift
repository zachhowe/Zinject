import Foundation
import Testing
@testable import Zinject

// The selection plumbing itself: parsing, the process-wide default, and the
// container reporting which arm it is on. `ZinjectTests.swift` covers the much
// more important question of whether the three strategies behave identically.

// MARK: - Parsing

@Test func environmentValueParsesEveryStrategy() async throws {
    #expect(ConcurrencyStrategy(environmentValue: "leftRight") == .leftRight)
    #expect(ConcurrencyStrategy(environmentValue: "recursiveLock") == .recursiveLock)
    #expect(ConcurrencyStrategy(environmentValue: "unfairLock") == .unfairLock)
}

// A value typed into an Xcode scheme is not going to be camel-cased reliably,
// and a run that silently fell back to the default would look like a valid
// measurement of the wrong strategy.
@Test(arguments: ["left-right", "LEFT_RIGHT", "leftright", "  Left-Right  ".trimmingCharacters(in: .whitespaces), "lr"])
func environmentValueIgnoresCaseAndPunctuation(_ raw: String) async throws {
    #expect(ConcurrencyStrategy(environmentValue: raw) == .leftRight)
}

@Test func environmentValueAcceptsLockAliases() async throws {
    #expect(ConcurrencyStrategy(environmentValue: "lock") == .recursiveLock)
    #expect(ConcurrencyStrategy(environmentValue: "NSRecursiveLock") == .recursiveLock)
    #expect(ConcurrencyStrategy(environmentValue: "os_unfair_lock") == .unfairLock)
}

@Test(arguments: ["", "mutex", "spinlock", "true", "1"])
func environmentValueRejectsUnknownNames(_ raw: String) async throws {
    #expect(ConcurrencyStrategy(environmentValue: raw) == nil)
}

@Test func descriptionRoundTripsThroughParsing() async throws {
    for strategy in ConcurrencyStrategy.allCases {
        #expect(ConcurrencyStrategy(environmentValue: strategy.description) == strategy)
    }
}

// MARK: - Selection

@Test(arguments: ConcurrencyStrategy.allCases)
func containerReportsItsStrategy(_ strategy: ConcurrencyStrategy) async throws {
    #expect(Container(concurrency: strategy).concurrency == strategy)
    #expect(Container(defaultScope: .transient, concurrency: strategy).defaultScope == .transient)
}

@Test func defaultConcurrencyIsLeftRightAbsentAnOverride() async throws {
    // The test process is launched without ZINJECT_CONCURRENCY, so this also
    // pins that an unset variable leaves the shipped default in place.
    #expect(ProcessInfo.processInfo.environment["ZINJECT_CONCURRENCY"] == nil)
    #expect(Container.defaultConcurrency == .leftRight)
    #expect(Container().concurrency == .leftRight)
}

// The point of the static: an application flips it once (or sets the
// environment variable) and every existing `Container()` call site follows,
// because a default argument is evaluated at the call site.
@Test func settingDefaultConcurrencyChangesUnannotatedContainers() async throws {
    let original = Container.defaultConcurrency
    defer { Container.defaultConcurrency = original }

    Container.defaultConcurrency = .unfairLock
    #expect(Container().concurrency == .unfairLock)
    // An explicit argument still wins.
    #expect(Container(concurrency: .leftRight).concurrency == .leftRight)

    Container.defaultConcurrency = .recursiveLock
    #expect(Container().concurrency == .recursiveLock)
}

// MARK: - Diagnostics
//
// Both of these once compared `ZinjectDiagnostics.slotlessReads` before and
// after. That counter is process-global and the suite runs in parallel, so any
// other test that legitimately takes the fallback — and two of them exist to —
// failed these at random. They assert on the calling thread's registry state
// instead, which nothing else in the process can perturb.
//
// It is also the sharper statement. `LeftRight.read` takes the fallback if and
// only if `currentID()` hands back `invalidID`, so what a thread's own slot
// state says about which path it took is exact rather than circumstantial.

@Test func aSlotHolderNeverTakesTheFallbackPath() async throws {
    // A thread holding a reader slot must never reach `readWithoutSlot` — the
    // whole claim about the fast path being unchanged rests on it.
    let container = Container(concurrency: .leftRight)
    container.register(A.self) { _ in A() }

    let observed = onAFreshThread {
        for _ in 0 ..< 1_000 {
            _ = container.resolve(A.self)
        }
        return ReaderRegistry.assignedID()
    }

    #expect(observed != ReaderRegistry.invalidID, "a resolve must claim a slot, not fall back")
}

// Only `.leftRight` has a slot-based read path at all, so the mutex strategies
// must never ask the registry for anything, however many threads pile on.
@Test(arguments: [ConcurrencyStrategy.recursiveLock, .unfairLock])
func mutexStrategiesNeverTouchReaderSlots(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }

    // A fresh thread, so "never asked for a slot" is distinguishable from "had
    // one already from some earlier test".
    let observed = onAFreshThread {
        for _ in 0 ..< 200 {
            _ = container.resolve(A.self)
        }
        return ReaderRegistry.assignedID()
    }

    #expect(observed == ReaderRegistry.invalidID, "a mutex strategy claimed a reader slot")
}

/// Runs `body` on a thread of its own and hands back what it returned.
///
/// The point is the thread, not the concurrency: reader slots are per-thread and
/// held for a thread's lifetime, so a test that wants to observe how a slot was
/// acquired needs one that has not acquired one yet.
private func onAFreshThread(_ body: @escaping @Sendable () -> Int) -> Int {
    let finished = DispatchGroup()
    nonisolated(unsafe) var observed = 0

    finished.enter()
    let thread = Thread {
        observed = body()
        finished.leave()
    }
    thread.start()
    _ = finished.wait(timeout: .now() + 60)

    return observed
}

#if ZINJECT_METRICS
@Test(arguments: ConcurrencyStrategy.allCases)
func metricsTallyTheResolvePaths(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(defaultScope: .container, concurrency: strategy)
    container.register(A.self) { _ in A() } // one write

    _ = container.resolve(A.self)  // factory run, then one write to publish
    _ = container.resolve(A.self)  // cached
    _ = container.resolve(A.self)  // cached
    _ = container.resolve(B.self)  // never registered

    let metrics = container.metrics
    #expect(metrics.factoryRuns == 1)
    #expect(metrics.cachedResolves == 2)
    #expect(metrics.unregisteredLookups == 1)
    #expect(metrics.writes == 2)
    #expect(metrics.supersededPublications == 0)
    #expect(metrics.uncachedPublications == 0)
}

// A borrow is a resolve by another name, and has to tally as one — otherwise
// switching a hot call site to `withResolvedRequired` would silently make a
// container's metrics stop adding up.
@Test(arguments: ConcurrencyStrategy.allCases)
func metricsTallyBorrowsAsResolves(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(defaultScope: .container, concurrency: strategy)
    container.register(A.self) { _ in A() } // one write

    _ = container.withResolvedRequired(A.self) { $0.num } // factory run, then one write
    _ = container.withResolvedRequired(A.self) { $0.num } // cached
    _ = container.withResolvedRequired(A.self) { $0.num } // cached

    let metrics = container.metrics
    #expect(metrics.factoryRuns == 1)
    #expect(metrics.cachedResolves == 2)
    #expect(metrics.writes == 2)
}

@Test func metricsRecordAnUncachedPublication() async throws {
    let container = Container(defaultScope: .container)
    let interceptor = ResolveInterceptor()

    container.register(SendableA.self) { _ in
        interceptor.park()
        return SendableA(num: 1)
    }

    interceptor.startResolve(on: container)
    await waitOffPool(interceptor.factoryEntered)
    container.unregister(SendableA.self)
    interceptor.mayProceed.signal()
    await waitOffPool(interceptor.resolveFinished)

    #expect(container.metrics.uncachedPublications == 1)
}
#endif
