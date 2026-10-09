import Foundation

#if ZINJECT_METRICS
import Atomics
#endif

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
    /// race, and it must not wait on itself. See ``Container/construct(_:from:)``.
    ///
    /// A token only exists while its owner is inside the factory, so the owner
    /// is alive for as long as this is compared against and its identity cannot
    /// have been recycled onto another thread.
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
    /// Everything the container mutates, in one value so that a single
    /// Left-Right cell covers it.
    @usableFromInline
    struct State {
        @usableFromInline
        var table = ServiceTable()

        @usableFromInline
        init() {}
    }

    /// Registration and cache state, behind whichever ``StateCell`` this
    /// container was created with.
    ///
    /// An enum of concrete cells rather than an `any StateCell<State>`. The
    /// existential would put a witness-table call on the resolve fast path and
    /// stop the cell's own read from inlining into it — a cost paid by every
    /// strategy equally, which is precisely what would make the strategies
    /// impossible to tell apart. Switching on an immutable tag instead is a
    /// perfectly predicted branch, and each arm inlines its concrete cell.
    @usableFromInline
    enum Storage {
        case leftRight(LeftRight<State>)
        case recursiveLock(MutexCell<RecursiveLock, State>)
        case unfairLock(MutexCell<UnfairLock, State>)
    }

    @usableFromInline
    let storage: Storage

    /// One entry per `.container`-scoped key whose factory is running right
    /// now, with its own lock.
    ///
    /// Deliberately *not* part of ``State``, for two reasons. Installing a
    /// token would then be a cell write, and under
    /// ``ConcurrencyStrategy/leftRight`` a write drains every reader slot
    /// twice — a cost this pays on every cold resolve, to synchronize data no
    /// reader ever looks at. Worse, "install a token unless one is already
    /// there, and tell me which happened" is not a pure function of the state
    /// it is handed, and a Left-Right write body runs once per copy: the second
    /// application would find the token the first one installed and report a
    /// different answer.
    ///
    /// Keeping it out here also keeps it identical under all three strategies,
    /// which is what lets construction semantics stay indistinguishable between
    /// them. It is touched only on a cold resolve, never on the cached path.
    private let constructionLock = NSLock()
    private var constructing: [ServiceKey: ConstructionToken] = [:]

    public let defaultScope: Scope

    /// How this container synchronizes its state.
    ///
    /// Exposed so an application can report which arm of an A/B it is running
    /// alongside whatever it is measuring.
    public let concurrency: ConcurrencyStrategy

    #if ZINJECT_METRICS
    @usableFromInline
    let counters = MetricsCounters()
    #endif

    /// Creates a container.
    ///
    /// - Parameters:
    ///   - defaultScope: The scope used by registrations that do not set one.
    ///   - concurrency: How this container synchronizes its state. Defaults to
    ///     ``defaultConcurrency``, which reads `ZINJECT_CONCURRENCY` — so an
    ///     existing `Container()` call site follows a process-wide override
    ///     without being edited. See ``ConcurrencyStrategy`` for the trade-offs.
    public init(
        defaultScope: Scope = .container,
        concurrency: ConcurrencyStrategy = Container.defaultConcurrency
    ) {
        self.defaultScope = defaultScope
        self.concurrency = concurrency
        switch concurrency {
        case .leftRight:
            storage = .leftRight(LeftRight(State()))
        case .recursiveLock:
            storage = .recursiveLock(MutexCell(State()))
        case .unfairLock:
            storage = .unfairLock(MutexCell(State()))
        }
    }

    /// Borrows the container state. See ``StateCell`` for what a body may do —
    /// briefly, it must be short and must not write back into the container.
    @inlinable
    @inline(__always)
    func readState<R>(_ body: (UnsafePointer<State>) -> R) -> R {
        switch storage {
        case .leftRight(let cell): return cell.read(body)
        case .recursiveLock(let cell): return cell.read(body)
        case .unfairLock(let cell): return cell.read(body)
        }
    }

    /// ``readState(_:)`` for a body that can throw. Used only by
    /// ``withResolvedRequired(_:_:)``, whose body is the caller's.
    @inlinable
    @inline(__always)
    func readState<R>(_ body: (UnsafePointer<State>) throws -> R) rethrows -> R {
        switch storage {
        case .leftRight(let cell): return try cell.read(body)
        case .recursiveLock(let cell): return try cell.read(body)
        case .unfairLock(let cell): return try cell.read(body)
        }
    }

    // MARK: - Section guard
    //
    // Four one-line wrappers so that every call site reads the same in release
    // and in debug, and so the `#if` lives in one place rather than at each of
    // the eight entry points. All four compile to nothing unless the checks are
    // on — see ``SectionGuard`` for why they are off by default, and for what
    // catches the silent half of the same mistake unconditionally instead.
    // `#if DEBUG` inside an `@inlinable` body keys off the *client's* build
    // configuration, which is what the metric hooks already do.

    @inlinable
    @inline(__always)
    func assertNoOpenSection<Service>(_ verb: StaticString, _ type: Service.Type) {
        #if DEBUG || ZINJECT_BORROW_CHECKS
        SectionGuard.assertNoOpenSection(verb, type)
        #endif
    }

    @inlinable
    @inline(__always)
    func assertNoOpenSection(_ what: StaticString) {
        #if DEBUG || ZINJECT_BORROW_CHECKS
        SectionGuard.assertNoOpenSection(what)
        #endif
    }

    @inlinable
    @inline(__always)
    func beginSection<Service>(_ type: Service.Type) {
        #if DEBUG || ZINJECT_BORROW_CHECKS
        SectionGuard.begin(type)
        #endif
    }

    @inlinable
    @inline(__always)
    func endSection() {
        #if DEBUG || ZINJECT_BORROW_CHECKS
        SectionGuard.end()
        #endif
    }

    /// Mutates the container state. The body must be a pure function of the
    /// state it is handed: under ``ConcurrencyStrategy/leftRight`` it runs once
    /// per copy.
    @inline(__always)
    @discardableResult
    private func writeState<R>(_ body: (inout State) -> R) -> R {
        countWrite()
        switch storage {
        case .leftRight(let cell): return cell.write(body)
        case .recursiveLock(let cell): return cell.write(body)
        case .unfairLock(let cell): return cell.write(body)
        }
    }

    @discardableResult
    public func register<Service>(
        _ type: Service.Type,
        factory: @Sendable @escaping (Resolver) -> Service
    ) -> any ServiceEntry<Service> {
        assertNoOpenSection("registered", type)
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
        assertNoOpenSection("registered", type)
        let serviceFactory = MainActorServiceFactoryImpl<Service>(factory: factory)
        store(serviceFactory, for: ServiceKey(resolvingType: type))
        return serviceFactory
    }

    /// Removes the registration and any cached instance for the given type.
    public func unregister<Service>(_ type: Service.Type) {
        assertNoOpenSection("unregistered", type)
        let serviceKey = ServiceKey(resolvingType: type)
        writeState { current in
            current.table.remove(serviceKey)
        }
    }

    /// Removes all registrations and cached instances.
    public func removeAll() {
        assertNoOpenSection("every registration was removed")
        writeState { current in
            current.table.removeAll()
        }
    }

    /// Resolves a service, or returns nil if the type was never registered.
    ///
    /// A `.container`-scoped service is constructed **exactly once**, however
    /// many threads race its first resolve. No lock and no read section is held
    /// while user code (factories, `initCompleted` callbacks) runs — the
    /// factory is serialized by a per-key ``ConstructionToken`` instead, so a
    /// slow factory for one type never blocks a resolve of another.
    ///
    /// `.transient` services are not gated: constructing per resolve is what
    /// transient means, and serializing them would defeat it.
    ///
    /// Resolving a ``registerMainActor`` registration for the first time from
    /// off the main thread traps. Use ``resolveAsync(_:)`` there.
    @inlinable
    public func resolve<Service>(_ type: Service.Type) -> Service? {
        assertNoOpenSection("resolved", type)
        let serviceKey = ServiceKey(resolvingType: type)

        // The fast path — wait-free under `.leftRight`, one lock acquisition
        // otherwise. One probe locates the type's slot; the cached instance and
        // the registration are read from that slot inside the same read section
        // either way, so a resolve never observes a half-applied registration.
        //
        // The cached instance is loaded as a `Service`, not copied out as an
        // `Any` and cast back. The load has to happen here, inside the read
        // section, because that is exactly as long as its storage is guaranteed
        // to be alive — see ``CachedInstance``.
        //
        // It is staged in an ``InstanceBuffer`` rather than a `Service?` local
        // so that the read body names no generic type a caller might not have
        // specialized; that file explains what the difference costs.
        guard InstanceBuffer.fits(Service.self) else {
            return resolveOversized(type, key: serviceKey)
        }

        var staged = InstanceBuffer()
        var isCached = false
        var registered: (any ServiceFactory)?

        readState { current in
            guard let slot = current.pointee.table.slot(for: serviceKey) else {
                return
            }
            if let storage = current.pointee.table.instance(at: slot) {
                staged.initialize(from: storage, as: Service.self)
                isCached = true
                return
            }
            registered = current.pointee.table.factory(at: slot)
        }

        if isCached {
            countCachedResolve()
            return staged.move(as: Service.self)
        }

        guard let serviceFactory = registered else {
            countUnregisteredLookup()
            return nil
        }

        return construct(serviceKey, from: serviceFactory)
    }

    /// The path for a service whose values are too large or too strictly
    /// aligned to stage in an ``InstanceBuffer``.
    ///
    /// Out of line, and deliberately so: its `Service?` local is what the fast
    /// path goes to some trouble to avoid, and keeping it in another function
    /// keeps that cost off every other resolve.
    @usableFromInline
    func resolveOversized<Service>(_ type: Service.Type, key serviceKey: ServiceKey) -> Service? {
        assertNoOpenSection("resolved", type)
        var cached: Service?
        var registered: (any ServiceFactory)?

        readState { current in
            guard let slot = current.pointee.table.slot(for: serviceKey) else {
                return
            }
            if let storage = current.pointee.table.instance(at: slot) {
                cached = storage.assumingMemoryBound(to: Service.self).pointee
                return
            }
            registered = current.pointee.table.factory(at: slot)
        }

        // A double optional, so a service whose own type is `Optional` and
        // whose cached value is `nil` still reads as a cache hit.
        if let cached {
            countCachedResolve()
            return cached
        }

        guard let serviceFactory = registered else {
            countUnregisteredLookup()
            return nil
        }

        return construct(serviceKey, from: serviceFactory)
    }

    // MARK: - Borrowed resolution

    /// Runs `body` on a resolved service without touching its reference count.
    ///
    /// `resolve(_:)` hands back an owned reference, and paying for one is the
    /// single most expensive thing about resolving a shared singleton from many
    /// cores at once: the retain and the release land on the same cache line,
    /// and sixteen cores contending for it drop a 6 ns resolve to 600 ns. This
    /// does not hand back a reference at all. It lends the instance for the
    /// duration of `body` and touches no reference count on the way, which on
    /// that workload is worth roughly a thousandfold.
    ///
    /// Why this is sound, and why it needs no new bookkeeping: a read section
    /// already *is* a grace period. ``resolve(_:)`` copies the instance out only
    /// because the value has to outlive the section — see ``CachedInstance`` for
    /// the lifetime argument. A caller that uses the instance *inside* the
    /// section needs no copy, so nothing about reclamation changes.
    ///
    /// Escaping the instance out of `body` is safe and costs what it should:
    /// assigning it anywhere copies it, which retains, and the caller gets an
    /// ordinary owned reference. What must never escape is an *address* into the
    /// instance, and this API hands out none.
    ///
    /// - Important: `body` runs inside the container's read section, and **no
    ///   container operation may run while this thread holds one**. It must not
    ///   call `resolve(_:)`, `register(_:factory:)`, `unregister(_:)`,
    ///   `removeAll()`, or this method again — on this container or any other —
    ///   and must not call anything that transitively does. The natural body is
    ///   a method call on the resolved service, so if that service lazily
    ///   resolves a dependency of its own, that is a violation written by
    ///   accident. Keep the body short: it stalls every writer for as long as it
    ///   runs.
    ///
    ///   Registering or removing from a body traps in every build. Resolving
    ///   from one traps only where the checks are compiled in — `DEBUG` or
    ///   `-DZINJECT_BORROW_CHECKS` — because that check would otherwise cost
    ///   half of a cached resolve; see ``SectionGuard``.
    ///
    /// Restricted to classes, which costs nothing: a struct has no reference
    /// count, so it never had the contention this exists to remove.
    ///
    /// `@discardableResult` because the common body — call a method on the
    /// service and be done — returns `Void`, and without it every such call
    /// site warns that a generic `R` went unused.
    @inlinable
    @discardableResult
    public func withResolvedRequired<Service: AnyObject, R>(
        _ type: Service.Type,
        _ body: (Service) throws -> R
    ) rethrows -> R {
        // A borrow from inside a borrow is the same contract violation as a
        // resolve from inside one, and is checked before anything is armed so
        // that the guard never trips over itself.
        assertNoOpenSection("borrowed", type)
        let serviceKey = ServiceKey(resolvingType: type)

        // Both conditions fold away when specialized. `R` is staged in an
        // `InstanceBuffer` for the reason the instance is on the resolve path,
        // and the size check on `Service` is what keeps the raw-pointer load
        // below honest — see `borrowCachedInstance`.
        guard InstanceBuffer.fits(R.self), Self.isBareReference(Service.self) else {
            return try withResolvedRequiredCopying(type, body)
        }

        var staged = InstanceBuffer()
        var ran = false
        var registered: (any ServiceFactory)?

        try readState { current in
            guard let slot = current.pointee.table.slot(for: serviceKey) else {
                return
            }
            guard let storage = current.pointee.table.instance(at: slot) else {
                registered = current.pointee.table.factory(at: slot)
                return
            }
            beginSection(Service.self)
            defer { endSection() }
            staged.initialize(to: try Container.borrowCachedInstance(storage, as: Service.self, body))
            ran = true
        }

        if ran {
            countCachedResolve()
            return staged.move(as: R.self)
        }

        guard let serviceFactory = registered,
              let instance: Service = construct(serviceKey, from: serviceFactory)
        else {
            preconditionFailure("Zinject: failed to resolve required service \(type)")
        }

        // Nothing was cached, so the instance was just built with no cell held
        // and arrives owned. Only the cached path is free — which is the path
        // that matters, since it is the one a hot call site takes.
        //
        // The guard is armed here too, even though no section is held and a
        // nested resolve would be harmless. Otherwise the contract would hold
        // on a service's first borrow and break on its second, which is the
        // kind of bug that only shows up on the second launch.
        beginSection(Service.self)
        defer { endSection() }
        return try body(instance)
    }

    /// Lends the instance in `storage` to `body` without retaining it.
    ///
    /// The spelling here is load-bearing and was arrived at by measurement. The
    /// obvious version — `body(storage.assumingMemoryBound(to: Service.self).pointee)`
    /// — is `+0` only when `body` inlines and the optimizer can see that nothing
    /// frees the instance across it. When `body` is an opaque call, which is
    /// what a real body is, it cannot see that, so it keeps the loaded value
    /// alive itself and puts back exactly the retain/release pair this whole
    /// API exists to remove. Measured, that cost 300x: a shared singleton
    /// borrowed by sixteen cores ran at 1.6 M ops/sec with the obvious
    /// spelling and 479 M with this one.
    ///
    /// So no managed `Service` is ever loaded. The reference is read as a raw
    /// pointer — not a value ARC can be asked to keep alive — and handed over
    /// through the stdlib's own primitive for "this object is already
    /// guaranteed to be alive". That guarantee is ``CachedInstance``'s: the
    /// storage is live for exactly the duration of the read section, and this
    /// is only ever called from inside one.
    ///
    /// The underscore on `_withUnsafeGuaranteedRef` means the standard library
    /// makes no source-stability promise for it. That is an accepted risk, and
    /// its shape is the reason accepting it is reasonable: a toolchain that
    /// removes or reshapes the primitive fails this build loudly, in this one
    /// function, rather than miscompiling quietly — and there is no stable
    /// spelling of what it does. Keep it that way; nothing else in the module
    /// may name an underscored API.
    ///
    /// Reading the reference as a single word is what ``isBareReference(_:)``
    /// checks: a class-bound existential also satisfies `AnyObject` but carries
    /// witness tables after the reference, and loading one word of it would
    /// discard them.
    @inlinable
    @inline(__always)
    static func borrowCachedInstance<Service: AnyObject, R>(
        _ storage: UnsafeMutableRawPointer,
        as type: Service.Type,
        _ body: (Service) throws -> R
    ) rethrows -> R {
        let unmanaged = Unmanaged<Service>.fromOpaque(storage.load(as: UnsafeRawPointer.self))
        return try unmanaged._withUnsafeGuaranteedRef { try body($0) }
    }

    /// Whether a `Service` is represented by one bare object reference, and so
    /// can be recovered from its storage with a raw-pointer load.
    ///
    /// Statically known in specialized code, where it folds away along with the
    /// branch on it.
    @inlinable
    @inline(__always)
    static func isBareReference<Service>(_ type: Service.Type) -> Bool {
        MemoryLayout<Service>.size == MemoryLayout<UnsafeRawPointer>.size
    }

    /// The path for shapes the borrow cannot serve: a result too large to stage,
    /// or a service that is not one bare reference.
    ///
    /// It resolves normally and so does retain — correctness first. Out of line
    /// because its `Service?` is what the fast path goes to some trouble to
    /// avoid, and because neither case is what this API is for.
    @usableFromInline
    @discardableResult
    func withResolvedRequiredCopying<Service, R>(
        _ type: Service.Type,
        _ body: (Service) throws -> R
    ) rethrows -> R {
        guard let instance = resolve(type) else {
            preconditionFailure("Zinject: failed to resolve required service \(type)")
        }
        // Armed around the body only: the resolve above is this method's own
        // work, not the caller's, and arming across it would trip the guard on
        // itself.
        beginSection(Service.self)
        defer { endSection() }
        return try body(instance)
    }


    /// Resolves a service, hopping to the main actor if — and only if — the
    /// registration needs it and nothing has constructed it yet.
    ///
    /// This is the supported way to reach a ``registerMainActor`` service from
    /// a background context. The synchronous ``resolve(_:)`` deliberately traps
    /// there instead of hopping: a synchronous cross-isolation hop deadlocks
    /// whenever the main thread is waiting on the caller, and because it only
    /// happens on a cache miss, it disappears on the second launch.
    ///
    /// Already-cached services, and every registration made with `register`,
    /// return without hopping.
    public func resolveAsync<Service>(_ type: Service.Type) async -> Service? where Service: Sendable {
        assertNoOpenSection("resolved", type)
        guard needsMainActor(ServiceKey(resolvingType: type)) else {
            return resolve(type)
        }
        return await MainActor.run { self.resolve(type) }
    }

    /// Whether ``resolveAsync(_:)`` has to hop before resolving this key.
    ///
    /// Synchronous, and separate from its caller on purpose: it borrows the
    /// state, and a read section must never be held across a suspension. Making
    /// the whole decision here means the async caller only branches on the
    /// answer.
    private func needsMainActor(_ serviceKey: ServiceKey) -> Bool {
        readState { current in
            guard let slot = current.pointee.table.slot(for: serviceKey) else {
                // Unregistered. Resolving returns nil wherever it runs.
                return false
            }
            // An instance already exists, so no factory has to run.
            guard current.pointee.table.instance(at: slot) == nil else {
                return false
            }
            return current.pointee.table.factory(at: slot)?.requiresMainActor ?? false
        }
    }

    /// Produces the instance for a resolve that did not find one cached,
    /// running the factory exactly once across every thread racing this key.
    ///
    /// Everything here happens with no cell held, and none of it is on the
    /// cached path, so it stays out of line rather than being inlined into
    /// every call site along with the lookup.
    @usableFromInline
    func construct<Service>(
        _ serviceKey: ServiceKey,
        from serviceFactory: any ServiceFactory
    ) -> Service? {
        var factory = serviceFactory

        while true {
            // Read before the gate, because the gate is only for the scope that
            // caches. A transient resolve is meant to build every time.
            guard (factory.scope ?? defaultScope) == .container else {
                return build(serviceKey, from: factory, cache: false)
            }

            switch enterConstruction(serviceKey) {
            case .owner(let token):
                defer { leaveConstruction(serviceKey, token: token) }
                return build(serviceKey, from: factory, cache: true)

            case .reentrant:
                // This thread is already inside this key's factory, so it has
                // re-entered its own construction: a dependency cycle, not a
                // race. Waiting here would deadlock on ourselves. Fall through
                // and let `pushResolutionStack` trap with the rendered chain,
                // which is the diagnostic that already exists for this.
                return build(serviceKey, from: factory, cache: true)

            case .waited:
                // The thread that was building this key has finished. Re-read
                // the table rather than assuming it published: a factory can
                // also finish without caching (see `publish`), and the
                // registration itself may have been replaced meanwhile.
                switch lookup(serviceKey, as: Service.self) {
                case .cached(let instance):
                    countCachedResolve()
                    return instance
                case .registered(let current):
                    factory = current
                    continue
                case .unregistered:
                    countUnregisteredLookup()
                    return nil
                }
            }
        }
    }

    /// Runs a registration's factory and, for `.container` scope, publishes what
    /// it produced.
    ///
    /// Called with no cell held and — when `cache` is true — with this key's
    /// ``ConstructionToken`` owned by the calling thread.
    private func build<Service>(
        _ serviceKey: ServiceKey,
        from serviceFactory: any ServiceFactory,
        cache: Bool
    ) -> Service? {
        pushResolutionStack(serviceKey)
        defer { popResolutionStack() }

        countFactoryRun()
        guard let created = serviceFactory.create(resolver: self) as? Service else {
            return nil
        }

        // Transient services are never cached, so there is nothing to publish
        // and no reason to pay for a write. This matters more than it used to:
        // a Left-Right write drains every reader slot twice, so routing every
        // transient resolve through one would dominate its cost.
        guard cache else {
            serviceFactory.runInitCompleted(resolver: self, instance: created)
            return created
        }

        let publication = publish(created, for: serviceKey, from: serviceFactory)

        switch publication {
        case .superseded(let winner):
            // Another thread cached its instance first. Discard ours and skip
            // its callbacks; the winner's have already run or are about to.
            //
            // The construction gate means the two threads cannot both have been
            // building this key normally. What is left is a resolve that
            // bypassed the gate: one that entered while the key was registered
            // transient, or the trapping re-entrant case. Kept because it is
            // what makes "only one instance is ever handed out" hold without
            // depending on the gate for correctness.
            countSupersededPublication()
            return winner
        case .notCached:
            countUncachedPublication()
            fallthrough
        case .published:
            // When published, the instance is already visible in the cache
            // before callbacks run, so a callback may re-resolve its own type
            // and get this same instance back rather than recursing.
            serviceFactory.runInitCompleted(resolver: self, instance: created)
            return created
        }
    }

    /// Caches `instance` unless another thread got there first, or unless the
    /// registration changed while the factory was running.
    @usableFromInline
    func publish<Service>(
        _ instance: Service,
        for serviceKey: ServiceKey,
        from serviceFactory: any ServiceFactory
    ) -> Publication<Service> {
        // Built before the write body runs, because the body must be pure: it
        // may run once per copy, and both applications have to install the same
        // storage. If the body decides not to cache, this is the only reference
        // and the storage is freed when it goes out of scope.
        let cached = CachedInstance(instance)

        return writeState { current -> Publication<Service> in
            guard let slot = current.table.slot(for: serviceKey) else {
                return .notCached
            }
            if let existing = current.table.instance(at: slot) {
                return .superseded(existing.assumingMemoryBound(to: Service.self).pointee)
            }
            // The factory ran with no lock held, so `register`, `unregister`,
            // or `removeAll` may have landed in the meantime. Caching now would
            // pin an instance built by a registration that no longer exists.
            // Identity comparison is exact here: `store` always installs a
            // freshly allocated factory object.
            guard let currentFactory = current.table.factory(at: slot),
                  currentFactory === serviceFactory
            else {
                return .notCached
            }
            current.table.setInstance(cached, at: slot)
            return .published
        }
    }

    private func store(_ serviceFactory: any ServiceFactory, for serviceKey: ServiceKey) {
        writeState { current in
            // Installing a registration evicts any instance cached under the
            // one it replaces, so re-registering a type takes effect.
            current.table.setFactory(serviceFactory, for: serviceKey)
        }
    }

    // MARK: - Construction gate

    /// What a thread arriving at a `.container`-scoped key is to do.
    private enum Construction {
        /// This thread installed the token, and must run the factory and then
        /// hand the token back.
        case owner(ConstructionToken)
        /// This thread already owns this key's token — it has re-entered its
        /// own construction, which is a cycle rather than a race.
        case reentrant
        /// Another thread was constructing this key and has now finished.
        case waited
    }

    private func enterConstruction(_ serviceKey: ServiceKey) -> Construction {
        let currentThread = ObjectIdentifier(Thread.current)

        constructionLock.lock()
        if let inFlight = constructing[serviceKey] {
            guard inFlight.owner != currentThread else {
                constructionLock.unlock()
                return .reentrant
            }
            // Unlocked before waiting: the owner has to be able to take this
            // lock to remove its token, and other keys have to stay resolvable
            // while this one is being built.
            constructionLock.unlock()
            inFlight.waitUntilFinished()
            return .waited
        }

        let token = ConstructionToken(owner: currentThread)
        constructing[serviceKey] = token
        constructionLock.unlock()
        return .owner(token)
    }

    /// Retires a token, waking everything parked on it. Called however the
    /// construction ended, including when the factory traps its way out.
    private func leaveConstruction(_ serviceKey: ServiceKey, token: ConstructionToken) {
        constructionLock.lock()
        constructing[serviceKey] = nil
        constructionLock.unlock()
        token.finish()
    }

    /// The outcome of a lookup, resolved inside a single read section so the
    /// instance and the registration are always read consistently.
    ///
    /// Used by the paths that run at most once per type — a resolve that waited
    /// on another thread's construction, and ``resolveAsync(_:)``. The cached
    /// fast path deliberately does not go through this: naming `Service` in a
    /// returned enum is exactly the shape ``InstanceBuffer`` exists to keep off
    /// it.
    private enum Lookup<Service> {
        case cached(Service)
        case registered(any ServiceFactory)
        case unregistered
    }

    private func lookup<Service>(_ serviceKey: ServiceKey, as type: Service.Type) -> Lookup<Service> {
        var cached: Service?
        var registered: (any ServiceFactory)?

        readState { current in
            guard let slot = current.pointee.table.slot(for: serviceKey) else {
                return
            }
            if let storage = current.pointee.table.instance(at: slot) {
                // Copied out inside the read section, which is exactly as long
                // as the storage is guaranteed to be alive — see
                // ``CachedInstance``.
                cached = storage.assumingMemoryBound(to: Service.self).pointee
                return
            }
            registered = current.pointee.table.factory(at: slot)
        }

        // A double optional, so a service whose own type is `Optional` and whose
        // cached value is `nil` still reads as a cache hit.
        if let cached {
            return .cached(cached)
        }
        guard let registered else {
            return .unregistered
        }
        return .registered(registered)
    }

    @usableFromInline
    enum Publication<Service> {
        /// This instance is now the cached one.
        case published
        /// Another thread's instance won the race; this one is discarded.
        case superseded(Service)
        /// The registration changed underneath us. The instance is still
        /// returned to its caller — it was built by a factory that was
        /// registered when the resolve began — but it is not cached, so it
        /// cannot outlive the registration it came from.
        case notCached
    }

    // MARK: - Circular dependency detection

    // The in-flight resolution stack is tracked per thread: nested resolves
    // triggered by a factory run on the same thread as that factory, because a
    // factory now always runs on the thread that asked for it.

    @usableFromInline
    func pushResolutionStack(_ serviceKey: ServiceKey) {
        guard let cycle = ResolutionStack.current.push(
            container: ObjectIdentifier(self),
            key: serviceKey
        ) else {
            return
        }
        let chain = cycle
            .map { String(describing: $0.resolvingType) }
            .joined(separator: " -> ")
        preconditionFailure("Zinject: circular dependency detected: \(chain)")
    }

    @usableFromInline
    func popResolutionStack() {
        ResolutionStack.current.pop(container: ObjectIdentifier(self))
    }

    // MARK: - Metrics

    // Each of these compiles to nothing at all unless `-DZINJECT_METRICS` is
    // set, which is the point: an atomic increment on the resolve fast path is
    // the same order of cost as the read it would be measuring. See
    // ``ContainerMetrics``.

    @inlinable
    @inline(__always)
    func countCachedResolve() {
        #if ZINJECT_METRICS
        counters.cachedResolves.wrappingIncrement(ordering: .relaxed)
        #endif
    }

    @inlinable
    @inline(__always)
    func countFactoryRun() {
        #if ZINJECT_METRICS
        counters.factoryRuns.wrappingIncrement(ordering: .relaxed)
        #endif
    }

    @inlinable
    @inline(__always)
    func countUnregisteredLookup() {
        #if ZINJECT_METRICS
        counters.unregisteredLookups.wrappingIncrement(ordering: .relaxed)
        #endif
    }

    @inlinable
    @inline(__always)
    func countWrite() {
        #if ZINJECT_METRICS
        counters.writes.wrappingIncrement(ordering: .relaxed)
        #endif
    }

    @inlinable
    @inline(__always)
    func countSupersededPublication() {
        #if ZINJECT_METRICS
        counters.supersededPublications.wrappingIncrement(ordering: .relaxed)
        #endif
    }

    @inlinable
    @inline(__always)
    func countUncachedPublication() {
        #if ZINJECT_METRICS
        counters.uncachedPublications.wrappingIncrement(ordering: .relaxed)
        #endif
    }
}
