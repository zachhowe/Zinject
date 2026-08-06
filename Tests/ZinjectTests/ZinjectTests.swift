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
        container.register(A.self) { _ in A() }

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
    }
}

@Test func registerMainActorBasic() async throws {
    let container = Container()
    container.registerMainActor(String.self) { _ in "main actor hello" }

    let string = container.resolve(String.self)
    #expect(string == "main actor hello")
}

@Test func registerMainActorCustomType() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in SendableA() }

    let a = container.resolve(SendableA.self)
    #expect(a?.num == 1)
}

@Test func mainActorResolveFromBackgroundThread() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in
        #expect(Thread.isMainThread)
        return SendableA()
    }

    let a = await withCheckedContinuation { (continuation: CheckedContinuation<SendableA?, Never>) in
        DispatchQueue.global().async {
            continuation.resume(returning: container.resolve(SendableA.self))
        }
    }
    #expect(a?.num == 1)
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

@Test func mainActorContainerScopeDefault() async throws {
    let container = Container(defaultScope: .container)
    container.registerMainActor(SendableA.self) { _ in SendableA() }

    let a1 = container.resolve(SendableA.self)
    let a2 = container.resolve(SendableA.self)

    #expect(a1 === a2)
}

@Test func mainActorContainerScopeOnServiceEntry() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in SendableA() }.scope(.container)

    let a1 = container.resolve(SendableA.self)
    let a2 = container.resolve(SendableA.self)

    #expect(a1 === a2)
}

@Test func mainActorTransientScopeDefault() async throws {
    let container = Container(defaultScope: .transient)
    container.registerMainActor(SendableA.self) { _ in SendableA() }

    let a1 = container.resolve(SendableA.self)
    let a2 = container.resolve(SendableA.self)

    #expect(a1 !== a2)
}

@Test func mainActorTransientScopeOnServiceEntry() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in SendableA() }.scope(.transient)

    let a1 = container.resolve(SendableA.self)
    let a2 = container.resolve(SendableA.self)

    #expect(a1 !== a2)
}

@Test func mainActorInitCompleted() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in SendableA(num: 1) }.initCompleted { resolver, a in
        // initCompleted callback is executed, we can verify by checking the resolved instance
        a.num = 5
    }

    let a = container.resolve(SendableA.self)
    #expect(a?.num == 5)
}

@Test func mainActorRecursiveDependency() async throws {
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

// Deterministically exercises the double-check in Container.resolve: the loser
// of a concurrent first resolve discards its instance, returns the winner's
// cached instance, and its initCompleted callbacks never run.
@Test func raceLoserDiscardsInstanceAndSkipsInitCompleted() async throws {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SendableA?

        func set(_ a: SendableA?) {
            lock.lock()
            value = a
            lock.unlock()
        }

        var get: SendableA? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    final class InitRecords: @unchecked Sendable {
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
    let firstFactoryEntered = DispatchSemaphore(value: 0)
    let winnerCached = DispatchSemaphore(value: 0)
    let initRecords = InitRecords()

    container.register(SendableA.self) { _ in
        if factoryCalls.incrementAndGet() == 1 {
            // Park the losing thread inside its factory until the winner has
            // cached an instance and run its initCompleted.
            firstFactoryEntered.signal()
            winnerCached.wait()
        }
        return SendableA()
    }.initCompleted { _, a in
        initRecords.add(a)
    }

    let loserBox = Box()
    let loserDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        loserBox.set(container.resolve(SendableA.self))
        loserDone.signal()
    }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            firstFactoryEntered.wait()
            continuation.resume()
        }
    }

    let winner = container.resolve(SendableA.self)
    winnerCached.signal()

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            loserDone.wait()
            continuation.resume()
        }
    }

    let loser = loserBox.get
    #expect(winner != nil)
    #expect(loser === winner)
    #expect(factoryCalls.current == 2)
    #expect(initRecords.all.count == 1)
    #expect(initRecords.all.first === winner)
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
    container.registerMainActor(SendableA.self) { _ in SendableA() }

    let results = Results()
    // concurrentPerform must run off the main thread: the main-actor factory
    // hops via DispatchQueue.main.sync and would deadlock otherwise.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 4) { _ in
                if let a = container.resolve(SendableA.self) {
                    results.add(a)
                }
            }
            continuation.resume()
        }
    }

    let all = results.all
    #expect(all.count == 4)
    let first = all.first
    #expect(all.allSatisfy { $0 === first })
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
