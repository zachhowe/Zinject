import Foundation

/// The gate that makes a concurrent first resolve run its factory exactly once.
///
/// One of these is installed per `.container`-scoped service key for as long as
/// that key's factory is running. The thread that installs it constructs; every
/// other thread that arrives meanwhile waits here rather than running a second
/// copy of the factory.
private final class ConstructionToken {
    private let condition = NSCondition()

    /// The thread that installed this token and is running the factory.
    ///
    /// Compared, never messaged. A thread that finds its *own* token has
    /// re-entered its own construction — that is a dependency cycle, not a
    /// race, and it must not wait on itself. See `Container.resolve`.
    let owner: ObjectIdentifier

    private var finished = false

    init(owner: ObjectIdentifier) {
        self.owner = owner
    }

    /// Blocks until the owning thread has published its instance (or given up).
    func waitUntilFinished() {
        condition.lock()
        while !finished {
            condition.wait()
        }
        condition.unlock()
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }
}

public final class Container: @unchecked Sendable, Resolver {
    private let lock = NSRecursiveLock()
    private var serviceFactories: [ServiceKey: any ServiceFactory] = [:]
    private var services: [ServiceKey: Any] = [:]

    /// One entry per `.container`-scoped key whose factory is running right now.
    /// Guarded by `lock`; see `resolve`.
    private var constructing: [ServiceKey: ConstructionToken] = [:]

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
    /// The factory runs inline when the service is first resolved from the main
    /// actor. Resolving it for the first time from any other thread is a
    /// programmer error and traps — see ``resolveAsync(_:)`` for the supported
    /// way to reach one of these from a background context.
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
    /// A `.container`-scoped service is constructed **exactly once**, however
    /// many threads race its first resolve. The container lock is still never
    /// held while user code runs — the factory is serialized by a per-key
    /// ``ConstructionToken`` instead, so a slow factory for one type never
    /// blocks a resolve of another.
    ///
    /// `.transient` services are not gated: constructing per resolve is what
    /// transient means, and serializing them would defeat it.
    public func resolve<Service>(_ type: Service.Type) -> Service? {
        let serviceKey = ServiceKey(resolvingType: type)
        let currentThread = ObjectIdentifier(Thread.current)

        while true {
            lock.lock()

            if let cached = services[serviceKey] {
                lock.unlock()
                return cached as? Service
            }
            guard let serviceFactory = serviceFactories[serviceKey] else {
                lock.unlock()
                return nil
            }

            guard (serviceFactory.scope ?? defaultScope) == .container else {
                lock.unlock()
                return construct(serviceKey, using: serviceFactory, cache: false)
            }

            if let inFlight = constructing[serviceKey] {
                guard inFlight.owner == currentThread else {
                    // Another thread is building this. Wait for it, then loop:
                    // the retry re-reads the cache rather than assuming the
                    // winner succeeded, because a factory can also finish
                    // without publishing (see `construct`).
                    lock.unlock()
                    inFlight.waitUntilFinished()
                    continue
                }
                // This thread is already inside this key's factory, so it has
                // re-entered its own construction: a dependency cycle, not a
                // race. Waiting here would deadlock on ourselves. Fall through
                // and let `pushResolutionStack` trap with the rendered chain,
                // which is the diagnostic that already exists for this.
                lock.unlock()
                return construct(serviceKey, using: serviceFactory, cache: true)
            }

            let token = ConstructionToken(owner: currentThread)
            constructing[serviceKey] = token
            lock.unlock()

            defer {
                lock.lock()
                constructing[serviceKey] = nil
                lock.unlock()
                token.finish()
            }

            return construct(serviceKey, using: serviceFactory, cache: true)
        }
    }

    /// Resolves a service, hopping to the main actor if — and only if — the
    /// registration needs it and nothing has constructed it yet.
    ///
    /// This is the supported way to reach a ``registerMainActor`` service from a
    /// background context. The synchronous ``resolve(_:)`` deliberately traps
    /// there instead of hopping: a synchronous cross-isolation hop deadlocks
    /// whenever the main thread is waiting on the caller, and because it only
    /// happens on a cache miss, it disappears on the second launch.
    ///
    /// Already-cached services return without suspending.
    public func resolveAsync<Service>(_ type: Service.Type) async -> Service? where Service: Sendable {
        switch plan(for: ServiceKey(resolvingType: type)) {
        case .cached(let instance):
            return instance as? Service
        case .unregistered:
            return nil
        case .constructHere:
            return resolve(type)
        case .constructOnMainActor:
            return await MainActor.run { self.resolve(type) }
        }
    }

    /// What ``resolveAsync(_:)`` needs to know before deciding whether to hop.
    ///
    /// Split out because it takes the lock: `NSRecursiveLock` and
    /// `Thread.isMainThread` are both unavailable from an async context, so the
    /// whole decision is made here, synchronously, and the async caller only
    /// switches on the answer.
    private enum ResolutionPlan {
        case cached(Any)
        case unregistered
        case constructHere
        case constructOnMainActor
    }

    private func plan(for serviceKey: ServiceKey) -> ResolutionPlan {
        lock.lock()
        defer { lock.unlock() }

        if let cached = services[serviceKey] {
            return .cached(cached)
        }
        guard let serviceFactory = serviceFactories[serviceKey] else {
            return .unregistered
        }
        return serviceFactory.requiresMainActor ? .constructOnMainActor : .constructHere
    }

    /// Runs a factory and, when asked, publishes what it produced.
    ///
    /// Called with no lock held and — for `.container` scope — with this key's
    /// ``ConstructionToken`` owned by the calling thread.
    private func construct<Service>(
        _ serviceKey: ServiceKey,
        using serviceFactory: any ServiceFactory,
        cache: Bool
    ) -> Service? {
        pushResolutionStack(serviceKey)
        defer { popResolutionStack() }

        guard let created = serviceFactory.create(resolver: self) as? Service else {
            return nil
        }

        if cache {
            lock.lock()
            // The factory ran with no lock held, so `register`, `unregister` or
            // `removeAll` may have landed meanwhile. Caching now would pin an
            // instance built by a registration that no longer exists. `store`
            // always installs a freshly allocated factory object, so identity
            // is an exact test.
            //
            // When this check fails the instance is still returned to its
            // caller — it was built by a registration that was live when the
            // resolve began — it just does not outlive that registration.
            if let current = serviceFactories[serviceKey], current === serviceFactory {
                services[serviceKey] = created
            }
            lock.unlock()
        }

        // The instance is already visible in the cache before callbacks run, so
        // a callback may re-resolve its own type and get this same instance
        // back rather than recursing.
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
    // triggered by a factory run on the same thread as that factory, because a
    // factory now always runs on the thread that asked for it.

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
