#if ZINJECT_METRICS
import Atomics

/// Per-container tallies of what a container actually did.
///
/// Compiled in only under `-DZINJECT_METRICS`, because collecting them puts an
/// atomic increment on the resolve fast path — small, but the same order as the
/// read it is measuring, which is exactly the wrong thing to add to a build you
/// are timing. Enable it to answer *how much* an application resolves; disable
/// it to measure *how fast*. Never both at once.
///
/// The question it exists to settle: a benchmark can show a strategy difference
/// of hundreds of millions of resolves per second, and it still does not matter
/// if the application under test resolves four thousand times at launch and
/// then stops. These numbers say which world you are in.
///
///     swift build -Xswiftc -DZINJECT_METRICS
///
/// ```swift
/// let m = container.metrics
/// print("\(m.cachedResolves) cached, \(m.factoryRuns) factory runs, \(m.writes) writes")
/// ```
public struct ContainerMetrics: Sendable, Equatable {
    /// Resolves satisfied entirely from the instance cache — the fast path, and
    /// the only one whose cost a strategy change materially affects.
    public var cachedResolves: Int

    /// Factory invocations. Exceeds the number of distinct `.container`-scoped
    /// services when threads race a first resolve, and grows without bound for
    /// `.transient` registrations.
    public var factoryRuns: Int

    /// Resolves for a type that was never registered.
    public var unregisteredLookups: Int

    /// Writes to the container state: `register`, `unregister`, `removeAll`, and
    /// each successful publication of a cached instance. The operation
    /// Left-Right makes roughly ten times more expensive.
    public var writes: Int

    /// Instances discarded because another thread cached its own first.
    /// Non-zero means threads are racing first resolves.
    public var supersededPublications: Int

    /// Instances returned but not cached, because the registration changed while
    /// the factory was running.
    public var uncachedPublications: Int
}

extension Container {
    /// A snapshot of this container's counters.
    ///
    /// Each field is read independently, so a snapshot taken while other threads
    /// are resolving is internally consistent only to within a resolve or two.
    /// That is fine for the question these answer, and a consistent snapshot
    /// would need a lock on the fast path.
    public var metrics: ContainerMetrics {
        counters.snapshot()
    }
}

/// The mutable side of ``ContainerMetrics``.
@usableFromInline
final class MetricsCounters: @unchecked Sendable {
    @usableFromInline
    let cachedResolves = ManagedAtomic<Int>(0)
    @usableFromInline
    let factoryRuns = ManagedAtomic<Int>(0)
    @usableFromInline
    let unregisteredLookups = ManagedAtomic<Int>(0)
    @usableFromInline
    let writes = ManagedAtomic<Int>(0)
    @usableFromInline
    let supersededPublications = ManagedAtomic<Int>(0)
    @usableFromInline
    let uncachedPublications = ManagedAtomic<Int>(0)

    func snapshot() -> ContainerMetrics {
        ContainerMetrics(
            cachedResolves: cachedResolves.load(ordering: .relaxed),
            factoryRuns: factoryRuns.load(ordering: .relaxed),
            unregisteredLookups: unregisteredLookups.load(ordering: .relaxed),
            writes: writes.load(ordering: .relaxed),
            supersededPublications: supersededPublications.load(ordering: .relaxed),
            uncachedPublications: uncachedPublications.load(ordering: .relaxed)
        )
    }
}
#endif
