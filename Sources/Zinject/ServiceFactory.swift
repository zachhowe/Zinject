protocol ServiceFactory<Service>: Sendable {
    associatedtype Service

    func create(resolver: Resolver) -> Service
}

final class ServiceFactoryImpl<Service>: @unchecked Sendable, ServiceFactory, ServiceEntry {
    let factory: @Sendable (Resolver) -> Service

    @Atomic private var initCompletedFunc: (@Sendable (Resolver, Service) -> Void)?

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
}
