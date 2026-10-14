import Testing
@testable import Zinject

final class PA: @unchecked Sendable {}
final class PB: @unchecked Sendable {}

private func makeParentChild(_ s: ConcurrencyStrategy) -> (Container, Container) {
    (Container(concurrency: s), Container(parent: nil, concurrency: s))
}

@Test(arguments: ConcurrencyStrategy.allCases)
func childFallsBackToParent(_ s: ConcurrencyStrategy) {
    let parent = Container(concurrency: s)
    let child = Container(parent: parent, concurrency: s)
    let a = PA()
    parent.register(PA.self) { _ in a }
    #expect(child.resolve(PA.self) != nil)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func childShadowsParent(_ s: ConcurrencyStrategy) {
    let parent = Container(concurrency: s)
    let child = Container(parent: parent, concurrency: s)
    parent.register(PA.self) { _ in PA() }
    let own = PA()
    child.register(PA.self) { _ in own }
    #expect(child.resolve(PA.self) === own)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func parentScopedInstanceSharedAcrossChildren(_ s: ConcurrencyStrategy) {
    let parent = Container(concurrency: s)
    parent.register(PA.self) { _ in PA() }.scope(.container)
    let c1 = Container(parent: parent, concurrency: s)
    let c2 = Container(parent: parent, concurrency: s)
    let first = c1.resolve(PA.self)!
    #expect(c2.resolve(PA.self) === first)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func grandparentChain(_ s: ConcurrencyStrategy) {
    let gp = Container(concurrency: s)
    let p = Container(parent: gp, concurrency: s)
    let c = Container(parent: p, concurrency: s)
    gp.register(PA.self) { _ in PA() }
    #expect(c.resolve(PA.self) != nil)
    #expect(c.resolve(PB.self) == nil)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func parentFallbackAfterUnregister(_ s: ConcurrencyStrategy) {
    let parent = Container(concurrency: s)
    let child = Container(parent: parent, concurrency: s)
    parent.register(PA.self) { _ in PA() }
    child.register(PA.self) { _ in PA() }
    child.unregister(PA.self)
    #expect(child.resolve(PA.self) != nil)
    child.removeAll()
    #expect(child.resolve(PA.self) != nil)
    parent.unregister(PA.self)
    #expect(child.resolve(PA.self) == nil)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func dependencyInChildResolvedFromParentFactory(_ s: ConcurrencyStrategy) {
    let parent = Container(concurrency: s)
    let child = Container(parent: parent, concurrency: s)
    child.register(PA.self) { _ in PA() }
    parent.register(PB.self) { resolver in
        _ = resolver.resolve(PA.self)
        return PB()
    }
    #expect(child.resolve(PB.self) != nil)
}

@Test(arguments: ConcurrencyStrategy.allCases)
func sameTypeAcrossContainersIsNotACycle(_ s: ConcurrencyStrategy) {
    let parent = Container(concurrency: s)
    let child = Container(parent: parent, concurrency: s)
    parent.register(PA.self) { _ in PA() }
    // The child has no PA registration, so a factory that resolves PA while
    // another PA is in flight in the child must not be mistaken for a cycle:
    // the stack is tagged per container.
    child.register(PB.self) { resolver in
        _ = resolver.resolve(PA.self)
        return PB()
    }
    #expect(child.resolve(PB.self) != nil)
}
