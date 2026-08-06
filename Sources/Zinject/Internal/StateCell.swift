/// A container for shared mutable state that can be read and written from any
/// thread.
///
/// The point of the abstraction is that ``LeftRight`` and ``MutexCell`` are
/// interchangeable behind it, so a `Container` can pick one at run time and an
/// application can measure the difference on its own workload.
///
/// ## Contract
///
/// This is the *union* of what the implementations require, not the weakest of
/// them. Code written against `StateCell` has to satisfy all of it, because the
/// implementation is a run-time choice:
///
/// - **Write bodies must be pure functions of the state handed to them.**
///   ``LeftRight`` runs the body twice, once per copy; a mutex cell runs it
///   once. Only a body that reaches the same decision from the same input is
///   correct under both. Captured mutable state, side effects, and dependence
///   on time or randomness are all unsound. The value returned to the caller
///   comes from the first application.
/// - **Read bodies must be short and non-blocking.** Under ``LeftRight`` a
///   writer cannot finish until every reader that entered before its flip has
///   left; under a mutex cell a read body holds the lock outright. Either way,
///   running arbitrary user code inside one stalls every writer behind it.
/// - **Read bodies must not re-enter ``write(_:)`` on the same cell.** It
///   deadlocks under ``LeftRight`` (the writer would wait on a drain that
///   includes its own slot) and under ``MutexCell`` unless the lock happens to
///   be recursive. Do not depend on the one case that survives.
///
/// `Container` satisfies all three: its read body probes one table and copies
/// out at most one instance, its write bodies are pure, and user code
/// (factories, `initCompleted` callbacks) always runs with no cell held.
///
/// ## The one exception, and what it costs
///
/// `Container.withResolvedRequired(_:_:)` runs a *caller's* closure inside a
/// read section. That is the point of it — a section is the window in which the
/// cached instance can be lent without retaining it — but it means the second
/// and third clauses above have stopped being notes to ourselves and become an
/// API contract with the library's users. They are enforced by `SectionGuard`
/// where enforcement is affordable, and documented where it is not.
///
/// A body that throws is fine. Both implementations depart in a `defer`, so an
/// unwind is an early exit and nothing is left behind; the `rethrows` overload
/// of ``read(_:)`` exists for exactly that.
@usableFromInline
protocol StateCell<Value>: AnyObject, Sendable {
    associatedtype Value

    init(_ initial: Value)

    /// Borrows the current state for the duration of `body`.
    func read<R>(_ body: (UnsafePointer<Value>) -> R) -> R

    /// ``read(_:)`` for a body that can throw. Both implementations leave the
    /// cell in a usable state when one does — the reader's departure and the
    /// mutex's unlock are both `defer`red, so an unwind is just an early exit.
    ///
    /// Deliberately a second method rather than a `rethrows` replacement for
    /// the first. A `rethrows` function is compiled with a throwing convention,
    /// and the non-throwing `read` is on `Container.resolve`'s path, which is
    /// the most measured code in this package. Folding the two together is a
    /// performance change, not a tidy-up.
    func read<R>(_ body: (UnsafePointer<Value>) throws -> R) rethrows -> R

    /// Applies `body` to the state and returns its result.
    @discardableResult
    func write<R>(_ body: (inout Value) -> R) -> R
}

/// The diagnostic for the one clause of the contract above that every
/// implementation now enforces rather than documents: a write nested inside a
/// read.
///
/// Shared, and worded so that it names the mistake rather than the mechanism.
/// The strategies are meant to be indistinguishable from outside the container,
/// and three differently-phrased crashes for one mistake would be one more way
/// to tell them apart — which is what they were until they started trapping.
///
/// Unconditional, unlike ``SectionGuard``. That guard is compiled out of release
/// builds because it sits on the resolve path and catches a nested *read*, which
/// is at worst a loud abort. This catches a nested *write*, whose symptoms are
/// an infinite spin and a mutation under a live reader's pointer, and every
/// place it is checked already costs far more than a comparison.
@usableFromInline
enum StateCellContract {
    /// `fatalError`, deliberately, and not `precondition`.
    ///
    /// The standard library's `precondition` and `preconditionFailure` discard
    /// their message outside a debug build — in release they lower to a
    /// `condfail` carrying the fixed string "precondition failure" — so a
    /// release build would trap with nothing to read. That is most of the value
    /// gone: the whole reason to trap here rather than spin is that somebody
    /// reading a crash log can tell what they did. `fatalError` prints its
    /// message in every configuration.
    ///
    /// It also survives `-Ounchecked`, which is correct for this one. The
    /// alternative to trapping is not a slightly slower program, it is an
    /// endless spin or a mutation under a live reader's pointer.
    @usableFromInline
    static func reentrantWrite() -> Never {
        fatalError(
            """
            Zinject: a write was performed from inside this thread's own read section. A read \
            section is a grace period and a writer waits for every grace period to close, so a \
            thread that does both waits for itself — which is why making a lock recursive cannot \
            fix this. It is what `withResolvedRequired(_:_:)` means by saying the container is \
            not re-entrant inside a borrow: register, unregister, or remove before or after the \
            borrow, never during it.
            """
        )
    }
}
