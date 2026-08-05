import Foundation

protocol ServiceFactory<Service>: Sendable {
    associatedtype Service

    var scope: Scope? { get }
    func create(resolver: Resolver) -> Service
    func runInitCompleted(resolver: Resolver, instance: Any)
}

final class ServiceFactoryImpl<Service>: @unchecked Sendable, ServiceFactory, ServiceEntry {
    let factory: @Sendable (Resolver) -> Service

    @Atomic internal var scope: Scope?
    @Atomic internal var initCompletedFuncs: [@Sendable (Resolver, Service) -> Void] = []

    init(factory: @Sendable @escaping (Resolver) -> Service) {
        self.factory = factory
    }

    func create(resolver: Resolver) -> Service {
        factory(resolver)
    }

    func runInitCompleted(resolver: Resolver, instance: Any) {
        guard let service = instance as? Service else { return }
        for callback in initCompletedFuncs {
            callback(resolver, service)
        }
    }

    @discardableResult
    func initCompleted(_ perform: @Sendable @escaping (Resolver, Service) -> Void) -> any ServiceEntry<Service> {
        initCompletedFuncs.append(perform)
        return self
    }

    @discardableResult
    func scope(_ scope: Scope) -> any ServiceEntry<Service> {
        self.scope = scope
        return self
    }
}

final class MainActorServiceFactoryImpl<Service>: @unchecked Sendable, ServiceFactory, ServiceEntry where Service: Sendable {
    let factory: @MainActor (Resolver) -> Service

    @Atomic internal var scope: Scope?
    @Atomic internal var initCompletedFuncs: [@Sendable (Resolver, Service) -> Void] = []

    init(factory: @MainActor @escaping (Resolver) -> Service) {
        self.factory = factory
    }

    func create(resolver: Resolver) -> Service {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                factory(resolver)
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    factory(resolver)
                }
            }
        }
    }

    func runInitCompleted(resolver: Resolver, instance: Any) {
        guard let service = instance as? Service else { return }
        for callback in initCompletedFuncs {
            callback(resolver, service)
        }
    }

    @discardableResult
    func initCompleted(_ perform: @Sendable @escaping (Resolver, Service) -> Void) -> any ServiceEntry<Service> {
        initCompletedFuncs.append(perform)
        return self
    }

    @discardableResult
    func scope(_ scope: Scope) -> any ServiceEntry<Service> {
        self.scope = scope
        return self
    }
}
