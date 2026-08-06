import Atomics
import Foundation

/// How a ``Container`` synchronizes its registration and cache state.
///
/// ## Re-entrancy first, throughput second
///
/// Read this part before the numbers. The numbers below point at ``unfairLock``,
/// and that is the right answer only because of what this section settles; a
/// reader who takes the throughput argument on its own reaches it for the wrong
/// reason and would keep it after the reason expired.
///
/// A container has to decide whether its synchronization is held *across* the
/// user code it runs — factories and `initCompleted` callbacks, which can
/// resolve further services and so re-enter the container:
///
/// | model | ``recursiveLock`` | ``unfairLock`` | ``leftRight`` |
/// |---|---|---|---|
/// | **A** — sections closed around user code | safe | safe | safe |
/// | **B** — sections held open across user code | safe | deadlock: the lock is not recursive | impossible by construction |
///
/// **This library is model A.** ``Container/resolve(_:)`` closes its read
/// section before running a factory, so a factory that resolves its own
/// dependencies re-enters with nothing held. That is what keeps all three arms
/// valid and lets the choice between them be about speed.
///
/// Model B is not a knob that was left unturned; it is unavailable. Left-Right's
/// central invariant is that a writer waits for every grace period to close, and
/// a thread cannot hold one open and wait for all of them at once — no amount of
/// recursive locking changes that. Choosing model B would mean deleting this
/// enum and keeping ``recursiveLock``.
///
/// ``Container/withResolvedRequired(_:_:)`` is the one deliberate exception: it
/// runs a caller's closure inside the read section, which is exactly what lets
/// it lend an instance without retaining one. The contract that comes with it —
/// no container operation while the section is open — is the model A rule
/// applied to user code, and it is enforced rather than merely documented. See
/// `SectionGuard`.
///
/// ## Throughput
///
/// The three options exist to be measured against each other. Left-Right wins
/// the synthetic cached-resolve benchmark by a wide margin, but it pays for that
/// on writes and on container construction, and it degrades below a plain mutex
/// once a process has more live resolving threads than `ReaderRegistry` has
/// slots. Whether the trade is worth it depends on an application's actual
/// resolve rate, container count, and thread population — none of which a
/// microbenchmark can tell you. Pick a strategy per container, or set one
/// process-wide via ``Container/defaultConcurrency``.
public enum ConcurrencyStrategy: Sendable, CaseIterable, Hashable {
    /// Wait-free readers, expensive writers. The default.
    case leftRight

    /// One `NSRecursiveLock` around the state — what `Container` used before the
    /// Left-Right rewrite. Present so "what did the rewrite buy" stays an
    /// answerable question rather than a historical claim.
    case recursiveLock

    /// One `os_unfair_lock` around the state (`NSLock` off Darwin). The cheap
    /// modern mutex, and the more demanding comparison: it asks whether
    /// Left-Right is beating a real design or merely a slow lock.
    case unfairLock

    /// Parses a strategy from an environment variable or launch argument.
    ///
    /// Punctuation and case are ignored, so `left-right`, `leftRight`,
    /// `LEFT_RIGHT`, and `leftright` all parse to ``leftRight``.
    public init?(environmentValue: String) {
        let normalized = environmentValue
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }

        switch normalized {
        case "leftright", "lr":
            self = .leftRight
        case "recursivelock", "recursive", "lock", "nsrecursivelock":
            self = .recursiveLock
        case "unfairlock", "unfair", "osunfairlock":
            self = .unfairLock
        default:
            return nil
        }
    }
}

extension ConcurrencyStrategy: CustomStringConvertible {
    public var description: String {
        switch self {
        case .leftRight: return "leftRight"
        case .recursiveLock: return "recursiveLock"
        case .unfairLock: return "unfairLock"
        }
    }
}

extension Container {
    /// The strategy used by any ``Container`` created without an explicit one.
    ///
    /// Seeded on first use from the `ZINJECT_CONCURRENCY` environment variable,
    /// which is what makes A/B testing a shipping application practical: flip an
    /// Xcode scheme variable, a launch argument, or a remote-config value and
    /// restart, with no change to the composition root and no rebuild.
    ///
    /// ```
    /// ZINJECT_CONCURRENCY=unfairLock ./MyApp
    /// ```
    ///
    /// Reading this is one relaxed atomic load, and because default arguments
    /// are evaluated at the call site, an existing `Container()` picks up the
    /// override with no other change.
    public static var defaultConcurrency: ConcurrencyStrategy {
        get { ConcurrencyStrategy(index: defaultConcurrencyStorage.load(ordering: .relaxed)) }
        set { defaultConcurrencyStorage.store(newValue.index, ordering: .relaxed) }
    }
}

extension ConcurrencyStrategy {
    /// A stable integer encoding, so the process-wide default can live in an
    /// atomic rather than behind a lock.
    fileprivate var index: Int {
        switch self {
        case .leftRight: return 0
        case .recursiveLock: return 1
        case .unfairLock: return 2
        }
    }

    fileprivate init(index: Int) {
        switch index {
        case 1: self = .recursiveLock
        case 2: self = .unfairLock
        default: self = .leftRight
        }
    }
}

/// Backing storage for ``Container/defaultConcurrency``.
///
/// A global `let` is initialized through `swift_once`, so the environment is
/// read lazily and exactly once, with no explicit synchronization.
private let defaultConcurrencyStorage = ManagedAtomic<Int>(environmentStrategy.index)

/// The strategy named by `ZINJECT_CONCURRENCY`, or ``ConcurrencyStrategy/leftRight``.
///
/// An unrecognized value warns rather than trapping or passing silently: a typo
/// in a scheme would otherwise produce a run that looks like a valid data point
/// for the default strategy, which is the worst possible failure for an
/// experiment whose entire purpose is comparison.
private let environmentStrategy: ConcurrencyStrategy = {
    guard let raw = ProcessInfo.processInfo.environment["ZINJECT_CONCURRENCY"],
          !raw.isEmpty
    else {
        return .leftRight
    }
    guard let strategy = ConcurrencyStrategy(environmentValue: raw) else {
        let names = ConcurrencyStrategy.allCases.map(\.description).joined(separator: ", ")
        FileHandle.standardError.write(Data(
            "Zinject: unrecognized ZINJECT_CONCURRENCY value '\(raw)'; expected one of \(names). Using leftRight.\n".utf8
        ))
        return .leftRight
    }
    return strategy
}()
