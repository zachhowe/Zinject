/// Catches a container operation performed while this thread holds one of the
/// container's read or write sections open.
///
/// The rule it encodes, stated once so that it does not have to be re-derived:
/// **no container operation may run while this thread holds a section.** Not
/// "nothing may run inside a `withResolvedRequired` body" — that is today's only
/// way to reach the state, not the state itself. Anything that later holds a
/// section across user code, including whatever makes `resolve` recursive, arms
/// this same guard rather than inventing a second rule.
///
/// The container is not re-entrant inside a section, and worse, is not
/// re-entrant in three *different* ways:
///
/// | | nested cached resolve | nested write |
/// |---|---|---|
/// | ``ConcurrencyStrategy/leftRight`` | works | spins forever: the drain waits on this thread's own arrival |
/// | ``ConcurrencyStrategy/recursiveLock`` | works | "works", and frees the instance being borrowed |
/// | ``ConcurrencyStrategy/unfairLock`` | aborts: the lock is not recursive | aborts |
///
/// Three failure modes for one mistake, and which one you get depends on a
/// runtime flag. The strategies are supposed to be indistinguishable from
/// outside the container, so this makes the answer uniform: it always traps,
/// before anything has locked or drained, and with a message naming what was
/// attempted.
///
/// ## What this costs, and what covers the rest
///
/// The check is a thread-local load and a comparison — around 2 ns, on a cached
/// resolve that costs 4. Paying that on every resolve to catch a mistake in a
/// different method would be a poor trade, so it follows the ``ContainerMetrics``
/// precedent and compiles to nothing unless `DEBUG` or `ZINJECT_BORROW_CHECKS`
/// is set. `swift test` is a debug build, so the tests get it for free.
///
/// What that leaves uncovered in a release build is now only the top column of
/// the table — a nested *read*, which either works or aborts loudly. The bottom
/// column, whose failures are silent, is caught unconditionally and much lower
/// down: ``LeftRight`` traps in its drain when the counter refusing to clear is
/// the calling thread's own, and ``MutexCell`` traps when a recursive lock is
/// about to let a write through a live read. Both use
/// ``StateCellContract/reentrantWrite()``, so the diagnosis is the same
/// wherever it comes from.
///
/// Those two are the reason this can stay debug-only without leaving an infinite
/// spin in a shipping build. Build once with `-DZINJECT_BORROW_CHECKS` if a
/// release-only *read*-side violation needs ruling in or out.
@usableFromInline
enum SectionGuard {
    /// Arms the guard for the duration of one open section. Must be balanced by
    /// ``end()``, which every caller does with `defer`.
    ///
    /// - Parameter type: The service whose section this is, used only to make
    ///   the failure message name something the caller recognizes.
    @usableFromInline
    static func begin(_ type: Any.Type) {
        ResolutionStack.current.openSection = type
    }

    @usableFromInline
    static func end() {
        ResolutionStack.current.openSection = nil
    }

    /// Traps if the calling thread is holding a section open.
    ///
    /// - Parameters:
    ///   - verb: What was attempted, as it reads in the message — "resolved",
    ///     "registered", and so on.
    ///   - type: The service the attempted operation names.
    @usableFromInline
    static func assertNoOpenSection(_ verb: StaticString, _ type: Any.Type) {
        guard let held = ResolutionStack.current.openSection else { return }
        fail("\(type) was \(verb)", holding: held)
    }

    /// The same check for an operation that names no service — ``removeAll()``.
    @usableFromInline
    static func assertNoOpenSection(_ what: StaticString) {
        guard let held = ResolutionStack.current.openSection else { return }
        fail("\(what)", holding: held)
    }

    private static func fail(_ attempt: String, holding held: Any.Type) -> Never {
        preconditionFailure(
            """
            Zinject: \(attempt) from inside a `withResolvedRequired(\(held).self)` body. \
            That body runs inside the container's read section, and no container operation may \
            run while this thread holds one: this spins forever under `.leftRight`, aborts under \
            `.unfairLock`, and mutates state you are still borrowing under `.recursiveLock`. Do \
            it before or after the borrow, or use `resolve(_:)` and hold the result.
            """
        )
    }
}
