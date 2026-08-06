import Foundation

/// Class-constrained so the container can compare registrations by identity
/// and tell "the factory I started with" from "a factory registered since".
@usableFromInline
protocol ServiceFactory<Service>: AnyObject, Sendable {
    associatedtype Service

    var scope: Scope? { get }

    /// Whether ``create(resolver:)`` must be called from the main thread. Lets
    /// ``Container/resolveAsync(_:)`` hop only for the registrations that need
    /// it, and leave every other resolve on the thread that asked for it.
    var requiresMainActor: Bool { get }

    func create(resolver: Resolver) -> Service
    func runInitCompleted(resolver: Resolver, instance: Any)
}

final class ServiceFactoryImpl<Service>: @unchecked Sendable, ServiceFactory, ServiceEntry {
    let factory: @Sendable (Resolver) -> Service

    @Atomic internal var scope: Scope?
    @Atomic internal var initCompletedFuncs: [@Sendable (Resolver, Service) -> Void] = []

    let requiresMainActor = false

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

    let requiresMainActor = true

    init(factory: @MainActor @escaping (Resolver) -> Service) {
        self.factory = factory
    }

    func create(resolver: Resolver) -> Service {
        guard Thread.isMainThread else {
            preconditionFailure("""
                Zinject: \(Service.self) was registered with `registerMainActor` and \
                resolved for the first time off the main thread. Zinject will not hop \
                synchronously — that deadlocks whenever the main thread is waiting on \
                the caller, and it only happens on a cache miss, so it would not \
                reproduce. Resolve it from the main actor, or `await \
                container.resolveAsync(_:)`.
                """)
        }
        return MainActor.assumeIsolated {
            factory(resolver)
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
