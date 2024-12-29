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
