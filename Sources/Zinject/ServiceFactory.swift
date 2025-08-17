protocol ServiceFactory<Service>: Sendable {
    associatedtype Service

    var scope: Scope? { get }
    func create(resolver: Resolver) -> Service
}

final class ServiceFactoryImpl<Service>: @unchecked Sendable, ServiceFactory, ServiceEntry {
    let factory: @Sendable (Resolver) -> Service

    @Atomic internal var scope: Scope?
    @Atomic internal var initCompletedFunc: (@Sendable (Resolver, Service) -> Void)?

    init(factory: @Sendable @escaping (Resolver) -> Service) {
        self.factory = factory
    }

    func create(resolver: Resolver) -> Service {
        let newObj = factory(resolver)
        initCompletedFunc?(resolver, newObj)
        return newObj
    }

    @discardableResult
    func initCompleted(_ perform: @Sendable @escaping (Resolver, Service) -> Void) -> any ServiceEntry<Service> {
        initCompletedFunc = perform
        return self
    }

    @discardableResult
    func scope(_ scope: Scope) -> any ServiceEntry<Service> {
        self.scope = scope
        return self
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class MainActorServiceFactoryImpl<Service>: @unchecked Sendable, ServiceFactory, ServiceEntry where Service: Sendable {
    let factory: @MainActor (Resolver) -> Service

    @Atomic internal var scope: Scope?
    @Atomic internal var initCompletedFunc: (@Sendable (Resolver, Service) -> Void)?

    init(factory: @MainActor @escaping (Resolver) -> Service) {
        self.factory = factory
    }

    func create(resolver: Resolver) -> Service {
        let newObj = MainActor.assumeIsolated {
            factory(resolver)
        }
        initCompletedFunc?(resolver, newObj)
        return newObj
    }

    @discardableResult
    func initCompleted(_ perform: @Sendable @escaping (Resolver, Service) -> Void) -> any ServiceEntry<Service> {
        initCompletedFunc = perform
        return self
    }

    @discardableResult
    func scope(_ scope: Scope) -> any ServiceEntry<Service> {
        self.scope = scope
        return self
    }
}
