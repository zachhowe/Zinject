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
