import Foundation

public final class Container: @unchecked Sendable, Resolver {
    private let lock = NSRecursiveLock()
    private var serviceFactories: [ServiceKey: any ServiceFactory] = [:]
    private var services: [ServiceKey: Any] = [:]

    public let defaultScope: Scope

    public init(defaultScope: Scope = .container) {
        self.defaultScope = defaultScope
    }

    @discardableResult
    public func register<Service>(
        _ type: Service.Type,
        factory: @Sendable @escaping (Resolver) -> Service
    ) -> any ServiceEntry<Service> {
        let serviceFactory = ServiceFactoryImpl<Service>(factory: factory)
        store(serviceFactory, for: ServiceKey(resolvingType: type))
        return serviceFactory
    }

    /// Registers a service whose factory runs on the main actor.
    ///
    /// Resolving from the main thread runs the factory inline; resolving from
    /// any other thread synchronously hops to the main queue.
    @discardableResult
    public func registerMainActor<Service>(
        _ type: Service.Type,
        factory: @MainActor @escaping (Resolver) -> Service
    ) -> any ServiceEntry<Service> where Service: Sendable {
        let serviceFactory = MainActorServiceFactoryImpl<Service>(factory: factory)
        store(serviceFactory, for: ServiceKey(resolvingType: type))
        return serviceFactory
    }

    /// Removes the registration and any cached instance for the given type.
    public func unregister<Service>(_ type: Service.Type) {
        let serviceKey = ServiceKey(resolvingType: type)
        lock.lock()
        serviceFactories[serviceKey] = nil
        services[serviceKey] = nil
        lock.unlock()
    }

    /// Removes all registrations and cached instances.
    public func removeAll() {
        lock.lock()
        serviceFactories.removeAll()
        services.removeAll()
        lock.unlock()
    }

    /// Resolves a service, or returns nil if the type was never registered.
    ///
    /// The container lock is never held while user code (factories,
    /// `initCompleted` callbacks) runs. As a consequence, when multiple
    /// threads race to resolve a `.container`-scoped service for the first
    /// time, the factory may run more than once — but only one instance is
    /// ever cached and returned; the others are discarded and their
    /// `initCompleted` callbacks never run.
    public func resolve<Service>(_ type: Service.Type) -> Service? {
        let serviceKey = ServiceKey(resolvingType: type)

        lock.lock()
        if let cached = services[serviceKey] {
            lock.unlock()
            return cached as? Service
        }
        guard let serviceFactory = serviceFactories[serviceKey] else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        pushResolutionStack(serviceKey)
        defer { popResolutionStack() }

        guard let created = serviceFactory.create(resolver: self) as? Service else {
            return nil
        }

        let scope = serviceFactory.scope ?? defaultScope

        lock.lock()
        if let cached = services[serviceKey] as? Service {
            // Another thread cached an instance while we were creating ours;
            // return the winner and discard ours.
            lock.unlock()
            return cached
        }
        if scope == .container {
            services[serviceKey] = created
        }
        lock.unlock()

        serviceFactory.runInitCompleted(resolver: self, instance: created)
        return created
    }

    private func store(_ serviceFactory: any ServiceFactory, for serviceKey: ServiceKey) {
        lock.lock()
        serviceFactories[serviceKey] = serviceFactory
        // Evict any cached instance so re-registration takes effect.
        services[serviceKey] = nil
        lock.unlock()
    }

    // MARK: - Circular dependency detection

    // The in-flight resolution stack is tracked per thread: nested resolves
    // triggered by a factory run on the same thread as that factory (a
    // main-actor hop starts a fresh stack on the main thread, where any cycle
    // that spans the hop is still caught, since resolution proceeds there).

    private var resolutionStackKey: String {
        "Zinject.Container.resolutionStack.\(UInt(bitPattern: ObjectIdentifier(self).hashValue))"
    }

    private func pushResolutionStack(_ serviceKey: ServiceKey) {
        let threadDictionary = Thread.current.threadDictionary
        var stack = threadDictionary[resolutionStackKey] as? [ServiceKey] ?? []
        if stack.contains(serviceKey) {
            let chain = (stack + [serviceKey])
                .map { String(describing: $0.resolvingType) }
                .joined(separator: " -> ")
            preconditionFailure("Zinject: circular dependency detected: \(chain)")
        }
        stack.append(serviceKey)
        threadDictionary[resolutionStackKey] = stack
    }

    private func popResolutionStack() {
        let threadDictionary = Thread.current.threadDictionary
        guard var stack = threadDictionary[resolutionStackKey] as? [ServiceKey], !stack.isEmpty else {
            return
        }
        stack.removeLast()
        threadDictionary[resolutionStackKey] = stack.isEmpty ? nil : stack
    }
}
