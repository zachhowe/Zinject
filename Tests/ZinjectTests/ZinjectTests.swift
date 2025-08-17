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

@Test func initCompleted() async throws {
    let container = Container()
    container.register(A.self) { _ in A() }.initCompleted { resolver, a in
        a.num = 2
    }

    let a = container.resolve(A.self)
    #expect(a?.num == 2)
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

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
@Test func registerMainActorBasic() async throws {
    let container = Container()
    container.registerMainActor(String.self) { _ in "main actor hello" }

    let string = container.resolve(String.self)
    #expect(string == "main actor hello")
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
@Test func registerMainActorCustomType() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in SendableA() }

    let a = container.resolve(SendableA.self)
    #expect(a?.num == 1)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
@Test func mainActorContainerScopeDefault() async throws {
    let container = Container(defaultScope: .container)
    container.registerMainActor(SendableA.self) { _ in SendableA() }

    let a1 = container.resolve(SendableA.self)
    let a2 = container.resolve(SendableA.self)

    #expect(a1 === a2)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
@Test func mainActorContainerScopeOnServiceEntry() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in SendableA() }.scope(.container)

    let a1 = container.resolve(SendableA.self)
    let a2 = container.resolve(SendableA.self)

    #expect(a1 === a2)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
@Test func mainActorTransientScopeDefault() async throws {
    let container = Container(defaultScope: .transient)
    container.registerMainActor(SendableA.self) { _ in SendableA() }

    let a1 = container.resolve(SendableA.self)
    let a2 = container.resolve(SendableA.self)

    #expect(a1 !== a2)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
@Test func mainActorTransientScopeOnServiceEntry() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in SendableA() }.scope(.transient)

    let a1 = container.resolve(SendableA.self)
    let a2 = container.resolve(SendableA.self)

    #expect(a1 !== a2)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
@Test func mainActorInitCompleted() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in SendableA(num: 1) }.initCompleted { resolver, a in
        // initCompleted callback is executed, we can verify by checking the resolved instance
        a.num = 5
    }

    let a = container.resolve(SendableA.self)
    #expect(a?.num == 5)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
@Test func mainActorRecursiveDependency() async throws {
    let container = Container()
    container.registerMainActor(SendableA.self) { _ in SendableA() }
    container.registerMainActor(SendableB.self) { resolver in 
        SendableB(a: resolver.resolve(SendableA.self)!) 
    }

    let b = container.resolve(SendableB.self)
    #expect(b?.a.num == 1)
}
