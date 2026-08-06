import Foundation
import Testing
@testable import Zinject

// Every test that pins an observable behavior — scoping, caching, initCompleted,
// cycle detection, and everything the README's "Thread safety" section promises
// — runs against all three values of `ConcurrencyStrategy`. The strategies are
// only interchangeable if they are indistinguishable from outside the container,
// and an application that flips `ZINJECT_CONCURRENCY` to gather data is entitled
// to assume that. Tests that construct a container without exercising any of
// that keep using the default.

final class A {
    var num: Int = 1
}

final class B {
    let a: A

    init(a: A) {
        self.a = a
    }
}

final class C {
    let b: B

    init(b: B) {
        self.b = b
    }
}

final class SendableA: @unchecked Sendable {
    @Atomic var num: Int

    init(num: Int = 1) {
        self.num = num
    }
}

final class SendableB: Sendable {
    let a: SendableA

    init(a: SendableA) {
        self.a = a
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Test func resolveEmptyContainer() async throws {
    let container = Container()
    let service = container.resolve(String.self)

    #expect(service == nil)
}

@Test func resolveString() async throws {
    let container = Container()
    container.register(String.self) { _ in "hello world" }

    let string = container.resolve(String.self)
    #expect(string == "hello world")
}

@Test func resolveCustomType() async throws {
    let container = Container()
    container.register(A.self) { _ in A() }

    let a = container.resolve(A.self)
    #expect(a?.num == 1)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func resolveRecursive(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }
    container.register(B.self) { resolver in B(a: resolver.resolve(A.self)!) }
    container.register(C.self) { resolver in C(b: resolver.resolve(B.self)!) }

    let c = container.resolve(C.self)
    #expect(c?.b.a.num == 1)
}

@Test func resolveRequired() async throws {
    let container = Container()
    container.register(String.self) { _ in "hello world" }

    let string = container.resolveRequired(String.self)
    #expect(string == "hello world")
}

@Test(arguments: ConcurrencyStrategy.allCases)
func initCompleted(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }.initCompleted { resolver, a in
        a.num = 2
    }

    let a = container.resolve(A.self)
    #expect(a?.num == 2)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func initCompletedMultipleCallbacks(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }
        .initCompleted { _, a in a.num += 10 }
        .initCompleted { _, a in a.num += 100 }

    let a = container.resolve(A.self)
    #expect(a?.num == 111)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func initCompletedCanResolveSelfWhenContainerScoped(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(defaultScope: .container, concurrency: strategy)
    container.register(A.self) { _ in A() }.initCompleted { resolver, a in
        // The instance is cached before initCompleted runs, so resolving the
        // same type here returns the cached instance instead of recursing.
        let again = resolver.resolve(A.self)
        a.num = (again === a) ? 42 : -1
    }

    let a = container.resolve(A.self)
    #expect(a?.num == 42)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func containerScopeContainerDefault(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(defaultScope: .container, concurrency: strategy)
    container.register(A.self) { _ in A() }

    let a1 = container.resolve(A.self)
    let a2 = container.resolve(A.self)

    #expect(a1 === a2)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func containerScopeOnServiceEntry(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }.scope(.container)

    let a1 = container.resolve(A.self)
    let a2 = container.resolve(A.self)

    #expect(a1 === a2)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func transientScopeContainerDefault(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(defaultScope: .transient, concurrency: strategy)
    container.register(A.self) { _ in A() }

    let a1 = container.resolve(A.self)
    let a2 = container.resolve(A.self)

    #expect(a1 !== a2)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func transientScopeOnServiceEntry(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }.scope(.transient)

    let a1 = container.resolve(A.self)
    let a2 = container.resolve(A.self)

    #expect(a1 !== a2)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func reRegistrationOverridesCachedInstance(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(defaultScope: .container, concurrency: strategy)
    container.register(String.self) { _ in "prod" }
    #expect(container.resolve(String.self) == "prod")

    container.register(String.self) { _ in "mock" }
    #expect(container.resolve(String.self) == "mock")
}

@Test(arguments: ConcurrencyStrategy.allCases)
func unregister(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(String.self) { _ in "hello" }
    #expect(container.resolve(String.self) == "hello")

    container.unregister(String.self)
    #expect(container.resolve(String.self) == nil)

    container.register(String.self) { _ in "again" }
    #expect(container.resolve(String.self) == "again")
}

@Test(arguments: ConcurrencyStrategy.allCases)
func removeAll(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(String.self) { _ in "hello" }
    container.register(A.self) { _ in A() }

    container.removeAll()

    #expect(container.resolve(String.self) == nil)
    #expect(container.resolve(A.self) == nil)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func concurrentResolveReturnsSameInstance(_ strategy: ConcurrencyStrategy) async throws {
    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [A] = []

        func add(_ a: A) {
            lock.lock()
            items.append(a)
            lock.unlock()
        }

        var all: [A] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    for _ in 0..<100 {
        let container = Container(defaultScope: .container, concurrency: strategy)
        let factoryCalls = Counter()
        container.register(A.self) { _ in
            _ = factoryCalls.incrementAndGet()
            return A()
        }

        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if let a = container.resolve(A.self) {
                results.add(a)
            }
        }

        let all = results.all
        #expect(all.count == 8)
        let first = all.first
        #expect(all.allSatisfy { $0 === first })
        // Unparked stress version of `concurrentFirstResolveConstructsExactlyOnce`:
        // 100 rounds of a genuine 8-way race, none of which may build twice.
        #expect(factoryCalls.current == 1)
    }
}

// These tests resolve `registerMainActor` registrations synchronously, so they
// are pinned to the main actor. That used to be optional: the container hopped
// via `DispatchQueue.main.sync` for you. It no longer does — see
// `mainActorSyncResolveOffMainTraps` for why.

@Test @MainActor func registerMainActorBasic() async throws {
    let container = Container()
    container.registerMainActor(String.self) { _ in "main actor hello" }

    let string = container.resolve(String.self)
    #expect(string == "main actor hello")
}

@Test @MainActor func registerMainActorCustomType() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in SendableA() }

    let a = container.resolve(SendableA.self)
    #expect(a?.num == 1)
}

// The synchronous hop is gone. It deadlocked whenever the main thread was
// waiting on the caller, and because it only ran on a cache miss it stopped
// reproducing as soon as anything warmed the type.
//
// Not parameterized over the strategy, and cannot be: a `processExitsWith` body
// runs in a spawned process and so must not capture. No loss of coverage — the
// refusal is in `MainActorServiceFactoryImpl`, which no strategy touches.
@Test(.enabled(if: !isRunningUnderThreadSanitizer)) func mainActorSyncResolveOffMainTraps() async throws {
    await #expect(processExitsWith: .failure) {
        let container = Container()
        container.registerMainActor(SendableA.self) { _ in SendableA() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = container.resolve(SendableA.self)
                continuation.resume()
            }
        }
    }
}

// ...and `resolveAsync` is what replaces it. It hops with `await`, which cannot
// deadlock.
@Test(arguments: ConcurrencyStrategy.allCases)
func resolveAsyncFromBackgroundRunsFactoryOnMain(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.registerMainActor(SendableA.self) { _ in
        #expect(Thread.isMainThread)
        return SendableA()
    }

    let a = await Task.detached { await container.resolveAsync(SendableA.self) }.value
    #expect(a?.num == 1)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func resolveAsyncOnPlainRegistrationDoesNotNeedMain(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(SendableA.self) { _ in SendableA(num: 7) }

    let a = await Task.detached { await container.resolveAsync(SendableA.self) }.value
    #expect(a?.num == 7)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func resolveAsyncUnregisteredReturnsNil(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    #expect(await container.resolveAsync(SendableA.self) == nil)
}

// A warm main-actor service is readable from anywhere without a hop: the cached
// instance is found before the decision to hop is taken.
@Test(arguments: ConcurrencyStrategy.allCases)
@MainActor func resolveAsyncReturnsCachedWithoutHopping(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(defaultScope: .container, concurrency: strategy)
    let factoryCalls = Counter()
    container.registerMainActor(SendableA.self) { _ in
        _ = factoryCalls.incrementAndGet()
        return SendableA()
    }

    let warm = container.resolve(SendableA.self)
    let fromBackground = await Task.detached { await container.resolveAsync(SendableA.self) }.value

    #expect(fromBackground === warm)
    #expect(factoryCalls.current == 1)
}

@Test @MainActor func mainActorResolveOnMainThread() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in
        #expect(Thread.isMainThread)
        return SendableA()
    }

    let a = container.resolve(SendableA.self)
    #expect(a?.num == 1)
}

@Test(arguments: ConcurrencyStrategy.allCases)
@MainActor func mainActorContainerScopeDefault(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(defaultScope: .container, concurrency: strategy)
    container.registerMainActor(SendableA.self) { _ in SendableA() }

    let a1 = container.resolve(SendableA.self)
    let a2 = container.resolve(SendableA.self)

    #expect(a1 === a2)
}

@Test(arguments: ConcurrencyStrategy.allCases)
@MainActor func mainActorContainerScopeOnServiceEntry(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.registerMainActor(SendableA.self) { _ in SendableA() }.scope(.container)

    let a1 = container.resolve(SendableA.self)
    let a2 = container.resolve(SendableA.self)

    #expect(a1 === a2)
}

@Test(arguments: ConcurrencyStrategy.allCases)
@MainActor func mainActorTransientScopeDefault(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(defaultScope: .transient, concurrency: strategy)
    container.registerMainActor(SendableA.self) { _ in SendableA() }

    let a1 = container.resolve(SendableA.self)
    let a2 = container.resolve(SendableA.self)

    #expect(a1 !== a2)
}

@Test(arguments: ConcurrencyStrategy.allCases)
@MainActor func mainActorTransientScopeOnServiceEntry(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.registerMainActor(SendableA.self) { _ in SendableA() }.scope(.transient)

    let a1 = container.resolve(SendableA.self)
    let a2 = container.resolve(SendableA.self)

    #expect(a1 !== a2)
}

@Test @MainActor func mainActorInitCompleted() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in SendableA(num: 1) }.initCompleted { resolver, a in
        // initCompleted callback is executed, we can verify by checking the resolved instance
        a.num = 5
    }

    let a = container.resolve(SendableA.self)
    #expect(a?.num == 5)
}

@Test @MainActor func mainActorRecursiveDependency() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in SendableA() }
    container.registerMainActor(SendableB.self) { resolver in
        SendableB(a: resolver.resolve(SendableA.self)!)
    }

    let b = container.resolve(SendableB.self)
    #expect(b?.a.num == 1)
}

// Not parameterized over the strategy, and cannot be: the body of a
// `processExitsWith` expectation runs in a spawned process, so it has to be a
// non-capturing closure. No loss of coverage — cycle detection is entirely in
// `ResolutionStack`, which is per-thread and tagged by container object, and
// never touches the state cell.
@Test(.enabled(if: !isRunningUnderThreadSanitizer)) func circularDependencyTraps() async throws {
    await #expect(processExitsWith: .failure) {
        final class X { init(_ y: Y?) {} }
        final class Y { init(_ x: X?) {} }

        let container = Container()
        container.register(X.self) { resolver in X(resolver.resolve(Y.self)) }
        container.register(Y.self) { resolver in Y(resolver.resolve(X.self)) }

        _ = container.resolve(X.self)
    }
}

// The resolution stack is shared by every container on a thread, so entries are
// tagged by container. Resolving the same type from a second container while
// the first is still resolving it is legitimate delegation, not a cycle.
@Test(arguments: ConcurrencyStrategy.allCases)
func sameTypeInFlightInTwoContainersIsNotACycle(_ strategy: ConcurrencyStrategy) async throws {
    let backing = Container(concurrency: strategy)
    backing.register(A.self) { _ in A() }

    let front = Container(concurrency: strategy)
    front.register(A.self) { _ in
        let delegated = backing.resolveRequired(A.self)
        delegated.num = 42
        return delegated
    }

    #expect(front.resolve(A.self)?.num == 42)
}

// A container that traps on its own cycle must do so even while another
// container has an unrelated resolution of the same type in flight.
// Also unparameterized, for the same reason as `circularDependencyTraps`.
@Test(.enabled(if: !isRunningUnderThreadSanitizer)) func cycleIsStillDetectedWithAnotherContainerOnTheStack() async throws {
    await #expect(processExitsWith: .failure) {
        final class X { init(_ y: Y?) {} }
        final class Y { init(_ x: X?) {} }

        let outer = Container()
        let inner = Container()

        inner.register(X.self) { resolver in X(resolver.resolve(Y.self)) }
        inner.register(Y.self) { resolver in Y(resolver.resolve(X.self)) }

        outer.register(X.self) { _ in inner.resolveRequired(X.self) }

        _ = outer.resolve(X.self)
    }
}

// MARK: - Concurrency

// The guarantee this container exists to make: a `.container`-scoped service is
// constructed EXACTLY ONCE, however many threads race its first resolve.
//
// This test used to assert the opposite — `factoryCalls.current == 2` — because
// the container released its lock before running the factory and let every
// racing thread run a copy, keeping one and discarding the rest. For a service
// that owns a keychain handle, a CloudKit container or a crypto key, building a
// second one and throwing it away is not a wasted allocation, it is a
// correctness bug.
//
// The winner is parked inside its factory so the other threads are guaranteed to
// arrive while construction is genuinely in flight, which is the window the old
// implementation got wrong.
@Test(arguments: ConcurrencyStrategy.allCases)
func concurrentFirstResolveConstructsExactlyOnce(_ strategy: ConcurrencyStrategy) async throws {
    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SendableA] = []

        func add(_ a: SendableA) {
            lock.lock()
            items.append(a)
            lock.unlock()
        }

        var all: [SendableA] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    let container = Container(defaultScope: .container, concurrency: strategy)
    let factoryCalls = Counter()
    let initRuns = Counter()
    let winnerParked = DispatchSemaphore(value: 0)
    let releaseWinner = DispatchSemaphore(value: 0)

    container.register(SendableA.self) { _ in
        if factoryCalls.incrementAndGet() == 1 {
            winnerParked.signal()
            releaseWinner.wait()
        }
        return SendableA()
    }.initCompleted { _, _ in
        _ = initRuns.incrementAndGet()
    }

    let results = Results()
    let group = DispatchGroup()
    for _ in 0..<8 {
        group.enter()
        DispatchQueue.global().async {
            if let a = container.resolve(SendableA.self) {
                results.add(a)
            }
            group.leave()
        }
    }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            winnerParked.wait()
            continuation.resume()
        }
    }
    releaseWinner.signal()

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            group.wait()
            continuation.resume()
        }
    }

    let all = results.all
    #expect(all.count == 8)
    let first = all.first
    #expect(all.allSatisfy { $0 === first })
    #expect(factoryCalls.current == 1)
    #expect(initRuns.current == 1)
}

// A thread that waited on another's construction must re-read the table rather
// than assume the winner published. When the registration is replaced while its
// factory is running, the instance that factory built is returned to its own
// caller but never cached — so the next resolve builds from the registration
// that is actually installed.
@Test(arguments: ConcurrencyStrategy.allCases)
func instanceIsNotCachedWhenRegistrationChangesMidConstruction(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(defaultScope: .container, concurrency: strategy)
    let factoryEntered = DispatchSemaphore(value: 0)
    let releaseFactory = DispatchSemaphore(value: 0)

    container.register(String.self) { _ in
        factoryEntered.signal()
        releaseFactory.wait()
        return "first"
    }

    let firstDone = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var observed: String?
    DispatchQueue.global().async {
        observed = container.resolve(String.self)
        firstDone.signal()
    }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            factoryEntered.wait()
            continuation.resume()
        }
    }

    // Land a new registration while the first factory is still running.
    container.register(String.self) { _ in "second" }
    releaseFactory.signal()

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            firstDone.wait()
            continuation.resume()
        }
    }

    // Its own caller still gets what it asked for...
    #expect(observed == "first")
    // ...but it was never cached, so the live registration wins from here on.
    #expect(container.resolve(String.self) == "second")
}

@Test(arguments: ConcurrencyStrategy.allCases)
func concurrentTransientResolvesReturnDistinctInstances(_ strategy: ConcurrencyStrategy) async throws {
    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [A] = []

        func add(_ a: A) {
            lock.lock()
            items.append(a)
            lock.unlock()
        }

        var all: [A] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    let container = Container(defaultScope: .transient, concurrency: strategy)
    container.register(A.self) { _ in A() }

    let results = Results()
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
        if let a = container.resolve(A.self) {
            results.add(a)
        }
    }

    let all = results.all
    #expect(all.count == 8)
    #expect(Set(all.map(ObjectIdentifier.init)).count == 8)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func concurrentResolveOfDependencyChainReturnsSameInstances(_ strategy: ConcurrencyStrategy) async throws {
    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [C] = []

        func add(_ c: C) {
            lock.lock()
            items.append(c)
            lock.unlock()
        }

        var all: [C] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    let container = Container(defaultScope: .container, concurrency: strategy)
    container.register(A.self) { _ in A() }
    container.register(B.self) { resolver in B(a: resolver.resolve(A.self)!) }
    container.register(C.self) { resolver in C(b: resolver.resolve(B.self)!) }

    let results = Results()
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
        if let c = container.resolve(C.self) {
            results.add(c)
        }
    }

    let all = results.all
    #expect(all.count == 8)
    let first = all.first
    #expect(all.allSatisfy { $0 === first })
    let firstA = first?.b.a
    #expect(all.allSatisfy { $0.b.a === firstA })
}

@Test(arguments: ConcurrencyStrategy.allCases)
func concurrentResolveOfDifferentTypes(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(String.self) { _ in "hello" }
    container.register(A.self) { _ in A() }
    container.register(SendableA.self) { _ in SendableA() }

    let successes = Counter()
    DispatchQueue.concurrentPerform(iterations: 12) { index in
        switch index % 3 {
        case 0:
            if container.resolve(String.self) == "hello" {
                _ = successes.incrementAndGet()
            }
        case 1:
            if container.resolve(A.self) != nil {
                _ = successes.incrementAndGet()
            }
        default:
            if container.resolve(SendableA.self) != nil {
                _ = successes.incrementAndGet()
            }
        }
    }

    #expect(successes.current == 12)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func concurrentMainActorResolvesReturnSameInstance(_ strategy: ConcurrencyStrategy) async throws {
    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SendableA] = []

        func add(_ a: SendableA) {
            lock.lock()
            items.append(a)
            lock.unlock()
        }

        var all: [SendableA] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    let container = Container(defaultScope: .container, concurrency: strategy)
    let factoryCalls = Counter()
    container.registerMainActor(SendableA.self) { _ in
        _ = factoryCalls.incrementAndGet()
        return SendableA()
    }

    // `resolveAsync`, not `resolve`: these tasks are not on the main actor, and
    // the synchronous path now refuses rather than hopping.
    let results = Results()
    await withTaskGroup(of: SendableA?.self) { group in
        for _ in 0..<4 {
            group.addTask { await container.resolveAsync(SendableA.self) }
        }
        for await a in group {
            if let a { results.add(a) }
        }
    }

    let all = results.all
    #expect(all.count == 4)
    let first = all.first
    #expect(all.allSatisfy { $0 === first })
    #expect(factoryCalls.current == 1)
}

// MARK: - initCompleted

@Test(arguments: ConcurrencyStrategy.allCases)
func initCompletedCallbacksRunInRegistrationOrder(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }
        .initCompleted { _, a in a.num *= 10 }
        .initCompleted { _, a in a.num += 1 }

    let a = container.resolve(A.self)
    #expect(a?.num == 11)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func initCompletedRunsOnceForCachedContainerScopedService(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(defaultScope: .container, concurrency: strategy)
    let callbackRuns = Counter()
    container.register(A.self) { _ in A() }.initCompleted { _, _ in
        _ = callbackRuns.incrementAndGet()
    }

    let a1 = container.resolve(A.self)
    let a2 = container.resolve(A.self)

    #expect(a1 === a2)
    #expect(callbackRuns.current == 1)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func initCompletedRunsOnEveryTransientResolve(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(defaultScope: .transient, concurrency: strategy)
    let callbackRuns = Counter()
    container.register(A.self) { _ in A() }.initCompleted { _, _ in
        _ = callbackRuns.incrementAndGet()
    }

    let a1 = container.resolve(A.self)
    let a2 = container.resolve(A.self)
    let a3 = container.resolve(A.self)

    #expect(a1 !== a2)
    #expect(a2 !== a3)
    #expect(callbackRuns.current == 3)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func initCompletedReceivesWorkingResolver(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(SendableA.self) { _ in SendableA() }
    container.register(SendableB.self) { resolver in
        SendableB(a: resolver.resolve(SendableA.self)!)
    }.initCompleted { resolver, b in
        if resolver.resolve(SendableA.self) != nil {
            b.a.num = 99
        }
    }

    let b = container.resolve(SendableB.self)
    #expect(b?.a.num == 99)
}

// MARK: - Registration changing under an in-flight resolve

// A factory runs with no lock held, so a registration can be replaced or
// removed while a resolve is still inside it. The instance that resolve
// produces belongs to a registration that no longer exists, so it is handed to
// its own caller but must never reach the cache — otherwise every later resolve
// would keep receiving a service built by a factory the container has forgotten.

// Parks an in-flight resolve inside its factory so the test can mutate the
// container underneath it, then releases it.
final class ResolveInterceptor: @unchecked Sendable {
    let factoryEntered = DispatchSemaphore(value: 0)
    let mayProceed = DispatchSemaphore(value: 0)
    let resolveFinished = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var resolved: SendableA?

    /// Runs `resolve` on a background thread and blocks it inside the factory.
    func startResolve(on container: Container) {
        DispatchQueue.global().async {
            self.setResult(container.resolve(SendableA.self))
            self.resolveFinished.signal()
        }
    }

    func park() {
        factoryEntered.signal()
        mayProceed.wait()
    }

    private func setResult(_ value: SendableA?) {
        lock.lock()
        resolved = value
        lock.unlock()
    }

    var result: SendableA? {
        lock.lock()
        defer { lock.unlock() }
        return resolved
    }
}

// Waits off the cooperative pool so a blocking semaphore cannot starve it.
func waitOffPool(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            semaphore.wait()
            continuation.resume()
        }
    }
}

@Test(arguments: ConcurrencyStrategy.allCases)
func resolveRacingReRegistrationDoesNotCacheTheStaleInstance(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(defaultScope: .container, concurrency: strategy)
    let interceptor = ResolveInterceptor()

    container.register(SendableA.self) { _ in
        interceptor.park()
        return SendableA(num: 1)
    }

    interceptor.startResolve(on: container)
    await waitOffPool(interceptor.factoryEntered)

    // Replace the registration while the first resolve is still in its factory.
    container.register(SendableA.self) { _ in SendableA(num: 2) }

    interceptor.mayProceed.signal()
    await waitOffPool(interceptor.resolveFinished)

    // The in-flight resolve still returns what its own factory built...
    #expect(interceptor.result?.num == 1)
    // ...but the cache must reflect the registration that is actually current.
    #expect(container.resolve(SendableA.self)?.num == 2)
    // And it must stay that way, rather than the stale instance surfacing later.
    #expect(container.resolve(SendableA.self)?.num == 2)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func resolveRacingUnregisterDoesNotRepopulateTheCache(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(defaultScope: .container, concurrency: strategy)
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

    #expect(interceptor.result?.num == 1)
    #expect(container.resolve(SendableA.self) == nil)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func resolveRacingRemoveAllDoesNotRepopulateTheCache(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(defaultScope: .container, concurrency: strategy)
    let interceptor = ResolveInterceptor()

    container.register(SendableA.self) { _ in
        interceptor.park()
        return SendableA(num: 1)
    }

    interceptor.startResolve(on: container)
    await waitOffPool(interceptor.factoryEntered)

    container.removeAll()

    interceptor.mayProceed.signal()
    await waitOffPool(interceptor.resolveFinished)

    #expect(interceptor.result?.num == 1)
    #expect(container.resolve(SendableA.self) == nil)
}

// MARK: - Coverage

// Known-unreachable lines, left uncovered by design:
// - Container.resolve's `create(...) as? Service` failure branch: factories
//   are keyed by their service type, so the cast cannot fail.
// - popResolutionStack's empty-stack guard: pop only runs via the defer paired
//   with a successful push.
// - The `instance as? Service` guards in runInitCompleted: the container only
//   passes instances the same factory just created.
// - preconditionFailure bodies: exercised by the exit tests, but the child
//   process aborts before the coverage profile is flushed.

@Test(.enabled(if: !isRunningUnderThreadSanitizer)) func resolveRequiredUnregisteredTraps() async throws {
    await #expect(processExitsWith: .failure) {
        let container = Container()
        _ = container.resolveRequired(String.self)
    }
}

@Test func defaultScopeProperty() async throws {
    #expect(Container().defaultScope == .container)
    #expect(Container(defaultScope: .transient).defaultScope == .transient)
}

@Test func serviceKeyEqualityAndHashing() async throws {
    let key1 = ServiceKey(resolvingType: A.self)
    let key2 = ServiceKey(resolvingType: A.self)
    let key3 = ServiceKey(resolvingType: B.self)

    #expect(key1 == key2)
    #expect(key1 != key3)
    #expect(Set([key1, key2, key3]).count == 2)
}

// MARK: - Instance storage shapes

// A cached instance is kept in `Service`-typed storage and staged through a
// fixed-size buffer on its way out of the read section, so the shape of the
// service type — how big it is, how strictly aligned, whether it is even a
// concrete type — is now something resolve can be sensitive to. These pin the
// cases that take a different path through it.

/// Eight words: too large for `InstanceBuffer`, so it takes the out-of-line
/// path.
struct Oversized: Equatable {
    var a = 1.0, b = 2.0, c = 3.0, d = 4.0, e = 5.0, f = 6.0, g = 7.0, h = 8.0
}

/// Small, and holds a reference: the staged copy has to retain it.
struct HoldsAReference {
    var object: A
}

protocol Greeter {
    func greet() -> String
}

struct EnglishGreeter: Greeter {
    let name: String
    func greet() -> String { "hello, \(name)" }
}

@Test func bufferFitsTheCommonShapesAndNotTheOthers() async throws {
    #expect(InstanceBuffer.fits(A.self))
    #expect(InstanceBuffer.fits(Int.self))
    #expect(InstanceBuffer.fits(String.self))
    #expect(InstanceBuffer.fits(HoldsAReference.self))
    #expect(InstanceBuffer.fits((any Greeter).self))
    #expect(!InstanceBuffer.fits(Oversized.self))

    // The alignment half of `fits` cannot fire on this toolchain — Swift caps
    // type alignment at sixteen bytes, which is what the buffer already is —
    // but it is what makes the rule a rule rather than a size coincidence.
    #expect(MemoryLayout<InstanceBuffer>.alignment == 16)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func oversizedServiceResolvesFromTheCache(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(Oversized.self) { _ in Oversized() }

    #expect(container.resolve(Oversized.self) == Oversized())
    #expect(container.resolve(Oversized.self) == Oversized())
}

@Test(arguments: ConcurrencyStrategy.allCases)
func cachedStructKeepsItsReferenceAlive(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(HoldsAReference.self) { _ in HoldsAReference(object: A()) }

    let first = try #require(container.resolve(HoldsAReference.self))
    first.object.num = 42

    let second = try #require(container.resolve(HoldsAReference.self))
    #expect(second.object === first.object)
    #expect(second.object.num == 42)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func protocolTypedRegistrationResolves(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register((any Greeter).self) { _ in EnglishGreeter(name: "world") }

    #expect(container.resolve((any Greeter).self)?.greet() == "hello, world")
    #expect(container.resolve((any Greeter).self)?.greet() == "hello, world")
}

@Test(arguments: ConcurrencyStrategy.allCases)
func manyRegistrationsSurviveTableGrowth(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }
    container.register(B.self) { resolver in B(a: resolver.resolveRequired(A.self)) }
    container.register(C.self) { resolver in C(b: resolver.resolveRequired(B.self)) }
    container.register(Int.self) { _ in 1 }
    container.register(Int8.self) { _ in 2 }
    container.register(Int16.self) { _ in 3 }
    container.register(Int32.self) { _ in 4 }
    container.register(Int64.self) { _ in 5 }
    container.register(UInt.self) { _ in 6 }
    container.register(Float.self) { _ in 7 }
    container.register(Double.self) { _ in 8 }
    container.register(Bool.self) { _ in true }
    container.register(String.self) { _ in "nine" }
    container.register([Int].self) { _ in [10] }
    container.register(Oversized.self) { _ in Oversized() }

    #expect(container.resolve(C.self)?.b.a === container.resolve(A.self))
    #expect(container.resolve(Int.self) == 1)
    #expect(container.resolve(Int64.self) == 5)
    #expect(container.resolve(String.self) == "nine")
    #expect(container.resolve([Int].self) == [10])
    #expect(container.resolve(Oversized.self) == Oversized())
    #expect(container.resolve(UInt8.self) == nil)
}

// MARK: - Cached instance lifetime

@Test(arguments: ConcurrencyStrategy.allCases)
func unregisterReleasesTheCachedInstance(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }

    weak var cached: A?
    do {
        cached = container.resolve(A.self)
    }
    #expect(cached != nil)

    container.unregister(A.self)
    #expect(cached == nil)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func removeAllReleasesCachedInstances(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }

    weak var cached: A?
    do {
        cached = container.resolve(A.self)
    }
    #expect(cached != nil)

    container.removeAll()
    #expect(cached == nil)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func reRegistrationReleasesTheInstanceItEvicts(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }

    weak var cached: A?
    do {
        cached = container.resolve(A.self)
    }
    #expect(cached != nil)

    container.register(A.self) { _ in A() }
    #expect(cached == nil)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func releasingTheContainerReleasesItsInstances(_ strategy: ConcurrencyStrategy) async throws {
    weak var cached: A?
    do {
        let container = Container(concurrency: strategy)
        container.register(A.self) { _ in A() }
        cached = container.resolve(A.self)
        #expect(cached != nil)
    }
    #expect(cached == nil)
}

// MARK: - Borrowed resolution

/// Class-bound, so `any ClassGreeter` satisfies `AnyObject` and can be asked
/// for by ``Container/withResolvedRequired(_:_:)`` — while being two words
/// wide, which is the shape that must *not* take the raw-pointer load.
protocol ClassGreeter: AnyObject {
    func greet() -> String
}

final class FrenchGreeter: ClassGreeter {
    func greet() -> String { "bonjour" }
}

@Test(arguments: ConcurrencyStrategy.allCases)
func aBorrowLendsTheInstanceResolveWouldReturn(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }

    let resolved = try #require(container.resolve(A.self))
    let borrowed = container.withResolvedRequired(A.self) { ObjectIdentifier($0) }
    #expect(borrowed == ObjectIdentifier(resolved))
}

// A borrow that misses the cache has to go through the same `ConstructionToken`
// gate a resolve does, cache what it built, and run `initCompleted` — otherwise
// it is a second, subtly different way to construct a service.
@Test(arguments: ConcurrencyStrategy.allCases)
func aBorrowConstructsOnFirstUseAndCaches(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    let factoryCalls = Counter()
    let initRuns = Counter()

    container.register(A.self) { _ in
        _ = factoryCalls.incrementAndGet()
        return A()
    }.initCompleted { _, _ in
        _ = initRuns.incrementAndGet()
    }

    let first = container.withResolvedRequired(A.self) { ObjectIdentifier($0) }
    let second = container.withResolvedRequired(A.self) { ObjectIdentifier($0) }

    #expect(first == second)
    #expect(factoryCalls.current == 1)
    #expect(initRuns.current == 1)
    #expect(container.resolve(A.self).map(ObjectIdentifier.init) == first)
}

// `.transient` never caches, so every borrow takes the construct-and-lend path
// rather than the read section. The body still runs, and gets a fresh instance.
//
// The instances are escaped rather than compared by `ObjectIdentifier` in the
// body, and that is not fussiness: nothing retains a transient instance past
// the body, so the first one is deallocated on the way out and the second
// allocation lands at the same address. Identity of a dead object proves
// nothing. Escaping them also exercises the property `CachedInstance` documents
// — copying the borrowed value out is safe and gives the caller an ordinary
// owned reference.
@Test(arguments: ConcurrencyStrategy.allCases)
func aBorrowOfATransientServiceBuildsEveryTime(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    let factoryCalls = Counter()
    container.register(A.self) { _ in
        _ = factoryCalls.incrementAndGet()
        return A()
    }.scope(.transient)

    var escaped: [A] = []
    container.withResolvedRequired(A.self) { escaped.append($0) }
    container.withResolvedRequired(A.self) { escaped.append($0) }

    #expect(factoryCalls.current == 2)
    #expect(escaped.count == 2)
    #expect(escaped[0] !== escaped[1])
}

// The result comes back through an `InstanceBuffer`, so its shape matters in
// the same way the instance's does on the resolve path: a result too large to
// stage takes the out-of-line path instead.
@Test(arguments: ConcurrencyStrategy.allCases)
func aBorrowReturnsResultsOfEveryShape(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }
    container.resolve(A.self)?.num = 42

    #expect(container.withResolvedRequired(A.self) { $0.num } == 42)
    #expect(container.withResolvedRequired(A.self) { "\($0.num)" } == "42")

    // Larger than the buffer, so this is the `withResolvedRequiredCopying` path
    // — reached on the result axis rather than the service axis.
    #expect(!InstanceBuffer.fits(Oversized.self))
    #expect(container.withResolvedRequired(A.self) { _ in Oversized() } == Oversized())

    var ran = false
    container.withResolvedRequired(A.self) { _ in ran = true }
    #expect(ran)
}

// `isBareReference` is a guard, not a code path this can currently reach.
//
// A class-bound existential is two words — an object pointer followed by a
// witness table — so reading one word of it would hand `body` a value missing
// half of itself. That is what the check exists to prevent. As it turns out
// this toolchain rejects `withResolvedRequired((any ClassGreeter).self)` at the
// call site, because `any ClassGreeter` does not satisfy `Service: AnyObject`,
// so the guard is belt-and-braces today. It is kept because it costs nothing —
// it folds away with the branch on it when specialized — and because the rule
// it encodes is a property of the representation, not of what the type checker
// happens to admit this year.
@Test func onlyBareReferencesTakeTheRawPointerLoad() async throws {
    #expect(Container.isBareReference(A.self))
    #expect(Container.isBareReference(AnyObject.self))

    #expect(!Container.isBareReference((any ClassGreeter).self))
    #expect(!Container.isBareReference((any Greeter).self))
    #expect(!Container.isBareReference(Oversized.self))
    #expect(MemoryLayout<any ClassGreeter>.size == 2 * MemoryLayout<UnsafeRawPointer>.size)
}

// What a unit test can prove about the reference count, and what it cannot.
//
// It can prove there is no *unbalanced* retain: if the borrow leaked one, the
// instance would survive `removeAll` and the weak reference below would stay
// non-nil. `CFGetRetainCount` is Darwin-only and unreliable, and
// `isKnownUniquelyReferenced` only distinguishes one reference from more, which
// cannot help here — the container itself always holds one, so the good case is
// two and the bad case is three.
//
// It cannot prove the absence of a *balanced* retain/release pair, which is the
// property the API is actually for. Nothing in a test suite has the resolution;
// the benchmark does, at roughly 900x, and the `borrowed resolve` table is
// where that is pinned. This is the same division of labour `InstanceBuffer`
// already lives under.
@Test(arguments: ConcurrencyStrategy.allCases)
func aBorrowLeavesNoReferenceBehind(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }

    weak var probe: A?
    container.withResolvedRequired(A.self) { probe = $0 }
    #expect(probe != nil)

    container.removeAll()
    #expect(probe == nil)
}

// The borrow path shares the construction gate with `resolve`, so the same race
// must produce the same single instance. Mirrors
// `concurrentFirstResolveConstructsExactlyOnce`, with the winner parked inside
// its factory so the others are guaranteed to arrive mid-construction.
@Test(arguments: ConcurrencyStrategy.allCases)
func concurrentFirstBorrowConstructsExactlyOnce(_ strategy: ConcurrencyStrategy) async throws {
    final class Identities: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ObjectIdentifier] = []

        func add(_ identity: ObjectIdentifier) {
            lock.lock()
            items.append(identity)
            lock.unlock()
        }

        var all: [ObjectIdentifier] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    let container = Container(defaultScope: .container, concurrency: strategy)
    let factoryCalls = Counter()
    let winnerParked = DispatchSemaphore(value: 0)
    let releaseWinner = DispatchSemaphore(value: 0)

    container.register(SendableA.self) { _ in
        if factoryCalls.incrementAndGet() == 1 {
            winnerParked.signal()
            releaseWinner.wait()
        }
        return SendableA()
    }

    let identities = Identities()
    let group = DispatchGroup()
    for _ in 0..<8 {
        group.enter()
        DispatchQueue.global().async {
            identities.add(container.withResolvedRequired(SendableA.self) { ObjectIdentifier($0) })
            group.leave()
        }
    }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            winnerParked.wait()
            continuation.resume()
        }
    }
    releaseWinner.signal()

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            group.wait()
            continuation.resume()
        }
    }

    #expect(factoryCalls.current == 1)
    #expect(identities.all.count == 8)
    #expect(Set(identities.all).count == 1)
}


// The borrow contract, enforced. `withResolvedRequired` runs its body inside the
// container's read section, and no container operation may run while a thread
// holds one: a nested call spins forever under `.leftRight`, aborts under
// `.unfairLock`, and quietly frees the instance being borrowed under
// `.recursiveLock`.
//
// Not parameterized over the strategy, and cannot be: a `processExitsWith` body
// runs in a spawned process and so must not capture. No loss of coverage — the
// guard lives in `ResolutionStack`, which no cell touches, so it is
// strategy-independent by construction.
//
// The two below are outside any `#if`, and that is the whole claim about
// release builds: a *write* nested in a live read is the silent half of the
// mistake — an endless spin, or a mutation under a pointer the borrow is still
// holding — so the cells refuse it themselves rather than relying on a guard
// that is compiled out. These pass in a release build with no flags set.

@Test(.enabled(if: !isRunningUnderThreadSanitizer)) func registeringInsideABorrowTraps() async throws {
    await #expect(processExitsWith: .failure) {
        let container = Container()
        container.register(A.self) { _ in A() }
        _ = container.resolve(A.self)

        container.withResolvedRequired(A.self) { _ in
            container.register(B.self) { resolver in B(a: resolver.resolveRequired(A.self)) }
        }
    }
}

@Test(.enabled(if: !isRunningUnderThreadSanitizer)) func removeAllInsideABorrowTraps() async throws {
    await #expect(processExitsWith: .failure) {
        let container = Container()
        container.register(A.self) { _ in A() }
        _ = container.resolve(A.self)

        container.withResolvedRequired(A.self) { _ in
            container.removeAll()
        }
    }
}

// A nested *read*, by contrast, is the loud half: it works under `.leftRight`
// and `.recursiveLock` and aborts under `.unfairLock`, so catching it uniformly
// is the guard's job and costs a thread-local read on the resolve path. These
// two are therefore compiled only where the checks are, and that `#if` is
// load-bearing rather than tidiness: without the guard they do not merely fail,
// they perform the real violation, and `resolvingInsideABorrowTraps` would hang
// a release test run outright.
#if DEBUG || ZINJECT_BORROW_CHECKS

@Test(.enabled(if: !isRunningUnderThreadSanitizer)) func resolvingInsideABorrowTraps() async throws {
    await #expect(processExitsWith: .failure) {
        let container = Container()
        container.register(A.self) { _ in A() }
        container.register(B.self) { resolver in B(a: resolver.resolveRequired(A.self)) }
        _ = container.resolve(A.self)

        container.withResolvedRequired(A.self) { _ in
            _ = container.resolve(B.self)
        }
    }
}

@Test(.enabled(if: !isRunningUnderThreadSanitizer)) func borrowingInsideABorrowTraps() async throws {
    await #expect(processExitsWith: .failure) {
        let container = Container()
        container.register(A.self) { _ in A() }
        _ = container.resolve(A.self)

        container.withResolvedRequired(A.self) { _ in
            container.withResolvedRequired(A.self) { _ in }
        }
    }
}

#endif

// The guard has to disarm on every exit, or the first legitimate resolve after a
// borrow trips it. Covers the constructed path too, where the body runs with no
// section held but the guard is armed anyway — deliberately, so the contract
// does not differ between a service's first borrow and its second.
@Test(arguments: ConcurrencyStrategy.allCases)
func theContainerIsUsableAgainAfterABorrow(_ strategy: ConcurrencyStrategy) async throws {
    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }

    // Cold: nothing is cached yet, so this goes through `construct`.
    let constructed = container.withResolvedRequired(A.self) { ObjectIdentifier($0) }
    // Warm: the same instance, now borrowed out of the read section.
    let borrowed = container.withResolvedRequired(A.self) { ObjectIdentifier($0) }
    #expect(constructed == borrowed)
    #expect(container.resolve(A.self).map(ObjectIdentifier.init) == borrowed)

    container.register(B.self) { resolver in B(a: resolver.resolveRequired(A.self)) }
    #expect(container.resolve(B.self) != nil)
    container.removeAll()
}

// A body that throws must leave the read indicator exactly as a body that
// returns does, and must disarm the guard. Under `.leftRight` a leaked arrival
// means the next write waits on this thread forever, so the `register` below is
// the real assertion and the time limit is what turns a regression into a
// failure instead of a hung suite.
@Test(.timeLimit(.minutes(1)), arguments: ConcurrencyStrategy.allCases)
func aThrowingBorrowBodyLeavesTheContainerUsable(_ strategy: ConcurrencyStrategy) async throws {
    struct Failure: Error {}

    let container = Container(concurrency: strategy)
    container.register(A.self) { _ in A() }
    _ = container.resolve(A.self)

    #expect(throws: Failure.self) {
        try container.withResolvedRequired(A.self) { _ in throw Failure() }
    }

    container.register(B.self) { resolver in B(a: resolver.resolveRequired(A.self)) }
    #expect(container.resolve(B.self) != nil)
}

// MARK: - Exit tests under sanitizers

/// Whether this process is running under ThreadSanitizer.
///
/// A `processExitsWith` expectation spawns a child, and TSan's interceptors are
/// not installed in that child — it dies at startup with "Interceptors are not
/// working. This may be because ThreadSanitizer is loaded too late". A test that
/// expects `.failure` therefore *passes* under `swift test --sanitize=thread`
/// without its body having run at all, which is worse than being skipped: the
/// run reports coverage it does not have.
///
/// So every exit test carries `.enabled(if: !isRunningUnderThreadSanitizer)`.
/// None of them are racy anyway — they are single-threaded trap checks, or in
/// one case a slot-exhaustion probe whose synchronization is exercised by the
/// non-sanitized run.
///
/// Detected by looking for a symbol only the TSan runtime defines. `RTLD_DEFAULT`
/// is `-2` on Darwin and `nil` elsewhere.
let isRunningUnderThreadSanitizer: Bool = {
    #if canImport(Darwin)
    let handle = UnsafeMutableRawPointer(bitPattern: -2)
    #else
    let handle: UnsafeMutableRawPointer? = nil
    #endif
    return dlsym(handle, "__tsan_init") != nil
}()
