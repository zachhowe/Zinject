import Foundation
import Testing
@testable import Zinject

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

@Test func resolveRecursive() async throws {
    let container = Container()
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

@Test func initCompleted() async throws {
    let container = Container()
    container.register(A.self) { _ in A() }.initCompleted { resolver, a in
        a.num = 2
    }

    let a = container.resolve(A.self)
    #expect(a?.num == 2)
}

@Test func initCompletedMultipleCallbacks() async throws {
    let container = Container()
    container.register(A.self) { _ in A() }
        .initCompleted { _, a in a.num += 10 }
        .initCompleted { _, a in a.num += 100 }

    let a = container.resolve(A.self)
    #expect(a?.num == 111)
}

@Test func initCompletedCanResolveSelfWhenContainerScoped() async throws {
    let container = Container(defaultScope: .container)
    container.register(A.self) { _ in A() }.initCompleted { resolver, a in
        // The instance is cached before initCompleted runs, so resolving the
        // same type here returns the cached instance instead of recursing.
        let again = resolver.resolve(A.self)
        a.num = (again === a) ? 42 : -1
    }

    let a = container.resolve(A.self)
    #expect(a?.num == 42)
}

@Test func containerScopeContainerDefault() async throws {
    let container = Container(defaultScope: .container)
    container.register(A.self) { _ in A() }

    let a1 = container.resolve(A.self)
    let a2 = container.resolve(A.self)

    #expect(a1 === a2)
}

@Test func containerScopeOnServiceEntry() async throws {
    let container = Container()
    container.register(A.self) { _ in A() }.scope(.container)

    let a1 = container.resolve(A.self)
    let a2 = container.resolve(A.self)

    #expect(a1 === a2)
}

@Test func transientScopeContainerDefault() async throws {
    let container = Container(defaultScope: .transient)
    container.register(A.self) { _ in A() }

    let a1 = container.resolve(A.self)
    let a2 = container.resolve(A.self)

    #expect(a1 !== a2)
}

@Test func transientScopeOnServiceEntry() async throws {
    let container = Container()
    container.register(A.self) { _ in A() }.scope(.transient)

    let a1 = container.resolve(A.self)
    let a2 = container.resolve(A.self)

    #expect(a1 !== a2)
}

@Test func reRegistrationOverridesCachedInstance() async throws {
    let container = Container(defaultScope: .container)
    container.register(String.self) { _ in "prod" }
    #expect(container.resolve(String.self) == "prod")

    container.register(String.self) { _ in "mock" }
    #expect(container.resolve(String.self) == "mock")
}

@Test func unregister() async throws {
    let container = Container()
    container.register(String.self) { _ in "hello" }
    #expect(container.resolve(String.self) == "hello")

    container.unregister(String.self)
    #expect(container.resolve(String.self) == nil)

    container.register(String.self) { _ in "again" }
    #expect(container.resolve(String.self) == "again")
}

@Test func removeAll() async throws {
    let container = Container()
    container.register(String.self) { _ in "hello" }
    container.register(A.self) { _ in A() }

    container.removeAll()

    #expect(container.resolve(String.self) == nil)
    #expect(container.resolve(A.self) == nil)
}

@Test func concurrentResolveReturnsSameInstance() async throws {
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
        let container = Container(defaultScope: .container)
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

// These suites resolve `registerMainActor` registrations, so they are pinned to
// the main actor. That used to be optional: the container hopped via
// `DispatchQueue.main.sync` for you. It no longer does — see
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
@Test func mainActorSyncResolveOffMainTraps() async throws {
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
@Test func resolveAsyncFromBackgroundRunsFactoryOnMain() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in
        #expect(Thread.isMainThread)
        return SendableA()
    }

    let a = await Task.detached { await container.resolveAsync(SendableA.self) }.value
    #expect(a?.num == 1)
}

@Test func resolveAsyncOnPlainRegistrationDoesNotNeedMain() async throws {
    let container = Container()
    container.register(SendableA.self) { _ in SendableA(num: 7) }

    let a = await Task.detached { await container.resolveAsync(SendableA.self) }.value
    #expect(a?.num == 7)
}

@Test func resolveAsyncUnregisteredReturnsNil() async throws {
    let container = Container()
    #expect(await container.resolveAsync(SendableA.self) == nil)
}

// A warm main-actor service is readable from anywhere without a hop: the cache
// is checked before the plan decides it needs the main actor.
@Test @MainActor func resolveAsyncReturnsCachedWithoutHopping() async throws {
    let container = Container(defaultScope: .container)
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

@Test @MainActor func mainActorContainerScopeDefault() async throws {
    let container = Container(defaultScope: .container)
    container.registerMainActor(SendableA.self) { _ in SendableA() }

    let a1 = container.resolve(SendableA.self)
    let a2 = container.resolve(SendableA.self)

    #expect(a1 === a2)
}

@Test @MainActor func mainActorContainerScopeOnServiceEntry() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in SendableA() }.scope(.container)

    let a1 = container.resolve(SendableA.self)
    let a2 = container.resolve(SendableA.self)

    #expect(a1 === a2)
}

@Test @MainActor func mainActorTransientScopeDefault() async throws {
    let container = Container(defaultScope: .transient)
    container.registerMainActor(SendableA.self) { _ in SendableA() }

    let a1 = container.resolve(SendableA.self)
    let a2 = container.resolve(SendableA.self)

    #expect(a1 !== a2)
}

@Test @MainActor func mainActorTransientScopeOnServiceEntry() async throws {
    let container = Container()
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

@Test func circularDependencyTraps() async throws {
    await #expect(processExitsWith: .failure) {
        final class X { init(_ y: Y?) {} }
        final class Y { init(_ x: X?) {} }

        let container = Container()
        container.register(X.self) { resolver in X(resolver.resolve(Y.self)) }
        container.register(Y.self) { resolver in Y(resolver.resolve(X.self)) }

        _ = container.resolve(X.self)
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
@Test func concurrentFirstResolveConstructsExactlyOnce() async throws {
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

    let container = Container(defaultScope: .container)
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

// A waiter must re-read the cache rather than assume the winner published. When
// the registration is replaced while its factory is running, the instance that
// factory built is returned to its own caller but never cached — so the next
// resolve builds from the registration that is actually installed.
@Test func instanceIsNotCachedWhenRegistrationChangesMidConstruction() async throws {
    let container = Container(defaultScope: .container)
    let factoryEntered = DispatchSemaphore(value: 0)
    let releaseFactory = DispatchSemaphore(value: 0)

    container.register(String.self) { _ in
        factoryEntered.signal()
        releaseFactory.wait()
        return "first"
    }

    let firstResult = Counter()
    let firstDone = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var observed: String?
    DispatchQueue.global().async {
        observed = container.resolve(String.self)
        _ = firstResult.incrementAndGet()
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

@Test func concurrentTransientResolvesReturnDistinctInstances() async throws {
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

    let container = Container(defaultScope: .transient)
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

@Test func concurrentResolveOfDependencyChainReturnsSameInstances() async throws {
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

    let container = Container(defaultScope: .container)
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

@Test func concurrentResolveOfDifferentTypes() async throws {
    let container = Container()
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

@Test func concurrentMainActorResolvesReturnSameInstance() async throws {
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

    let container = Container(defaultScope: .container)
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

@Test func initCompletedCallbacksRunInRegistrationOrder() async throws {
    let container = Container()
    container.register(A.self) { _ in A() }
        .initCompleted { _, a in a.num *= 10 }
        .initCompleted { _, a in a.num += 1 }

    let a = container.resolve(A.self)
    #expect(a?.num == 11)
}

@Test func initCompletedRunsOnceForCachedContainerScopedService() async throws {
    let container = Container(defaultScope: .container)
    let callbackRuns = Counter()
    container.register(A.self) { _ in A() }.initCompleted { _, _ in
        _ = callbackRuns.incrementAndGet()
    }

    let a1 = container.resolve(A.self)
    let a2 = container.resolve(A.self)

    #expect(a1 === a2)
    #expect(callbackRuns.current == 1)
}

@Test func initCompletedRunsOnEveryTransientResolve() async throws {
    let container = Container(defaultScope: .transient)
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

@Test func initCompletedReceivesWorkingResolver() async throws {
    let container = Container()
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

@Test func resolveRequiredUnregisteredTraps() async throws {
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
