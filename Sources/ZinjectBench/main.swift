import Foundation
import Zinject

// Measures the three `ConcurrencyStrategy` options against each other, and all
// of them against a vendored copy of the container as it was before any of this
// existed.
//
//   swift run -c release ZinjectBench
//
// Release mode is not optional — a debug build measures unspecialized generics
// and unoptimized ARC traffic, not the design.
//
// What the tables are for. The cached-resolve rows answer "which strategy reads
// fastest", which is the question Left-Right was adopted to win. The write-side
// and app-shaped rows answer "does an application ever perform enough of the
// operation that reads fastest to notice", which is the question that actually
// decides whether any of this is worth keeping. The thread-population row
// answers the third one: whether Left-Right still works at all once a process
// has more live threads than it has reader slots.
//
// The two `borrowed resolve` tables answer a fourth, and they are a pair. The
// class-typed shared-key row is the only read row `.leftRight` loses, and it
// loses it to reference counting on the returned instance rather than to
// anything in the container — which is why lending the instance instead of
// returning it wins it back. The first table says how large that is; the second
// says how much survives a call site that does real work. Reading either alone
// gets the wrong answer, in opposite directions.
//
// Harness notes: each worker runs for a fixed wall-clock window and counts how
// many resolves it completed, and the reported figure is the sum of those
// counts. Dividing total operations by wall time instead would let one slow
// thread (an efficiency core, say) set the number for every thread, which
// reads as a scaling collapse that is really just core heterogeneity.

// MARK: - Services

// Eight distinct types so each thread can be given a key of its own.
final class Service0 { var n = 0 }
final class Service1 { var n = 1 }
final class Service2 { var n = 2 }
final class Service3 { var n = 3 }
final class Service4 { var n = 4 }
final class Service5 { var n = 5 }
final class Service6 { var n = 6 }
final class Service7 { var n = 7 }
final class Service8 { var n = 8 }
final class Service9 { var n = 9 }
final class Service10 { var n = 10 }
final class Service11 { var n = 11 }
final class Service12 { var n = 12 }
final class Service13 { var n = 13 }
final class Service14 { var n = 14 }
final class Service15 { var n = 15 }

/// A single-word value type. Resolving one exercises the whole container read
/// path but hands back something with no reference count, which isolates the
/// container's own synchronization from ARC traffic on the returned instance.
struct Marker {
    var n: Int
}

/// Enough distinct keys that every worker can have one to itself.
private let serviceTypeCount = 16

/// Ordered worst-expected to best-expected, so each table reads left to right as
/// the argument for the rewrite.
private let strategies: [ConcurrencyStrategy] = [.recursiveLock, .unfairLock, .leftRight]

// MARK: - Timing

private let nanosecondsPerSecond: Double = 1_000_000_000

@inline(__always)
private func nowNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

private func elapsedSeconds(_ body: () -> Void) -> Double {
    let start = nowNanoseconds()
    body()
    return Double(nowNanoseconds() - start) / nanosecondsPerSecond
}

/// How long each throughput sample runs. Long enough to swamp scheduling noise,
/// short enough that the whole suite stays interactive.
private let sampleDuration = 0.25

/// Samples taken per data point; the best is reported.
private let sampleCount = 3

/// Resolves are checked against the deadline in batches so the clock read does
/// not become the thing being measured.
private let batchSize = 512

// MARK: - Hot loops

/// Reads the instance's address so the optimizer cannot delete the resolve.
@inline(__always)
private func consume<T: AnyObject>(_ value: T?) -> UInt {
    guard let value else { return 0 }
    return UInt(bitPattern: Unmanaged.passUnretained(value).toOpaque())
}

// The service type is bound once, outside the loop, so each loop body is a
// fully specialized cached resolve with no closure or switch inside it.
//
// Still two overloads per shape, even though the strategy is now a constructor
// argument rather than a type: `LockedContainer` remains a separate type, and it
// has to, since the whole point of it is to be the read path as it was written
// rather than the read path with a strategy threaded through it.

@inline(never)
private func hammerClass<Service: AnyObject>(
    _ container: Container,
    _ type: Service.Type,
    deadline: UInt64
) -> Int {
    var operations = 0
    var sink: UInt = 0
    while nowNanoseconds() < deadline {
        for _ in 0 ..< batchSize {
            sink &+= consume(container.resolve(type))
        }
        operations += batchSize
    }
    if sink == 0xDEAD_BEEF { print("") }
    return operations
}

@inline(never)
private func hammerClass<Service: AnyObject>(
    _ container: LockedContainer,
    _ type: Service.Type,
    deadline: UInt64
) -> Int {
    var operations = 0
    var sink: UInt = 0
    while nowNanoseconds() < deadline {
        for _ in 0 ..< batchSize {
            sink &+= consume(container.resolve(type))
        }
        operations += batchSize
    }
    if sink == 0xDEAD_BEEF { print("") }
    return operations
}

@inline(never)
private func hammerMarker(_ container: Container, deadline: UInt64) -> Int {
    var operations = 0
    var sink = 0
    while nowNanoseconds() < deadline {
        for _ in 0 ..< batchSize {
            sink &+= container.resolve(Marker.self)?.n ?? 0
        }
        operations += batchSize
    }
    if sink == 0xDEAD_BEEF { print("") }
    return operations
}

@inline(never)
private func hammerMarker(_ container: LockedContainer, deadline: UInt64) -> Int {
    var operations = 0
    var sink = 0
    while nowNanoseconds() < deadline {
        for _ in 0 ..< batchSize {
            sink &+= container.resolve(Marker.self)?.n ?? 0
        }
        operations += batchSize
    }
    if sink == 0xDEAD_BEEF { print("") }
    return operations
}

/// The same shared-key resolve, borrowed at `+0` instead of returned.
///
/// The body is an opaque call on purpose. A body the optimizer can see through
/// is not the case that matters and not the case that can regress: `+0` there
/// survives even a naive implementation. It is exactly when the body is opaque
/// that the compiler is tempted to keep the instance alive itself, putting back
/// the retain/release pair this measures the absence of. If this row ever
/// collapses to the row above it, that is what happened.
@inline(never)
private func hammerBorrowedClass<Service: AnyObject>(
    _ container: Container,
    _ type: Service.Type,
    deadline: UInt64
) -> Int {
    var operations = 0
    var sink: UInt = 0
    while nowNanoseconds() < deadline {
        for _ in 0 ..< batchSize {
            sink &+= container.withResolvedRequired(type) {
                opaque(UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()))
            }
        }
        operations += batchSize
    }
    if sink == 0xDEAD_BEEF { print("") }
    return operations
}

/// Stands in for what a call site actually does with the service it asked for.
/// A chain of `@inline(never)` calls, so the optimizer cannot fold it away and
/// cannot pretend the body is free.
private let workCalls = 24

@inline(never)
private func realisticWork(_ seed: UInt) -> UInt {
    var value = seed
    for _ in 0 ..< workCalls {
        value = opaque(value)
    }
    return value
}

/// Nanoseconds one ``realisticWork`` costs alone, so the `+work` table can be
/// read as "a resolve plus this much" rather than taken on trust.
private func realisticWorkCost() -> Double {
    var operations = 0
    var sink: UInt = 1
    let deadline = nowNanoseconds() + UInt64(sampleDuration * nanosecondsPerSecond)
    let seconds = elapsedSeconds {
        while nowNanoseconds() < deadline {
            for _ in 0 ..< batchSize {
                sink = realisticWork(sink)
            }
            operations += batchSize
        }
    }
    if sink == 0xDEAD_BEEF { print("") }
    return seconds / Double(operations) * nanosecondsPerSecond
}

@inline(never)
private func hammerBorrowedClassWorking<Service: AnyObject>(
    _ container: Container,
    _ type: Service.Type,
    deadline: UInt64
) -> Int {
    var operations = 0
    var sink: UInt = 0
    while nowNanoseconds() < deadline {
        for _ in 0 ..< batchSize {
            sink &+= container.withResolvedRequired(type) {
                realisticWork(UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()))
            }
        }
        operations += batchSize
    }
    if sink == 0xDEAD_BEEF { print("") }
    return operations
}

@inline(never)
private func hammerClassWorking<Service: AnyObject>(
    _ container: Container,
    _ type: Service.Type,
    deadline: UInt64
) -> Int {
    var operations = 0
    var sink: UInt = 0
    while nowNanoseconds() < deadline {
        for _ in 0 ..< batchSize {
            sink &+= realisticWork(consume(container.resolve(type)))
        }
        operations += batchSize
    }
    if sink == 0xDEAD_BEEF { print("") }
    return operations
}

private func hammerZinject(_ container: Container, typeIndex: Int, deadline: UInt64) -> Int {
    switch typeIndex % serviceTypeCount {
    case 0: return hammerClass(container, Service0.self, deadline: deadline)
    case 1: return hammerClass(container, Service1.self, deadline: deadline)
    case 2: return hammerClass(container, Service2.self, deadline: deadline)
    case 3: return hammerClass(container, Service3.self, deadline: deadline)
    case 4: return hammerClass(container, Service4.self, deadline: deadline)
    case 5: return hammerClass(container, Service5.self, deadline: deadline)
    case 6: return hammerClass(container, Service6.self, deadline: deadline)
    case 7: return hammerClass(container, Service7.self, deadline: deadline)
    case 8: return hammerClass(container, Service8.self, deadline: deadline)
    case 9: return hammerClass(container, Service9.self, deadline: deadline)
    case 10: return hammerClass(container, Service10.self, deadline: deadline)
    case 11: return hammerClass(container, Service11.self, deadline: deadline)
    case 12: return hammerClass(container, Service12.self, deadline: deadline)
    case 13: return hammerClass(container, Service13.self, deadline: deadline)
    case 14: return hammerClass(container, Service14.self, deadline: deadline)
    default: return hammerClass(container, Service15.self, deadline: deadline)
    }
}

private func hammerLocked(_ container: LockedContainer, typeIndex: Int, deadline: UInt64) -> Int {
    switch typeIndex % serviceTypeCount {
    case 0: return hammerClass(container, Service0.self, deadline: deadline)
    case 1: return hammerClass(container, Service1.self, deadline: deadline)
    case 2: return hammerClass(container, Service2.self, deadline: deadline)
    case 3: return hammerClass(container, Service3.self, deadline: deadline)
    case 4: return hammerClass(container, Service4.self, deadline: deadline)
    case 5: return hammerClass(container, Service5.self, deadline: deadline)
    case 6: return hammerClass(container, Service6.self, deadline: deadline)
    case 7: return hammerClass(container, Service7.self, deadline: deadline)
    case 8: return hammerClass(container, Service8.self, deadline: deadline)
    case 9: return hammerClass(container, Service9.self, deadline: deadline)
    case 10: return hammerClass(container, Service10.self, deadline: deadline)
    case 11: return hammerClass(container, Service11.self, deadline: deadline)
    case 12: return hammerClass(container, Service12.self, deadline: deadline)
    case 13: return hammerClass(container, Service13.self, deadline: deadline)
    case 14: return hammerClass(container, Service14.self, deadline: deadline)
    default: return hammerClass(container, Service15.self, deadline: deadline)
    }
}

// MARK: - ARC calibration

private final class SharedTarget: @unchecked Sendable {}

/// Opaque to the optimizer, so it cannot reason across a call to it. The result
/// feeds back into its own next argument, which stops the call being hoisted out
/// of the loop and leaving the retain/release pair adjacent and removable again.
@inline(never)
private func opaque(_ value: UInt) -> UInt { value &+ 1 }

/// Calibration, not a comparison. Nothing here but a retain/release pair on one
/// shared object — no container, no dictionary, no atomics of ours. This is the
/// floor any lock-free container that hands back a shared class instance has to
/// live with, and it is what the shared-key rows below should be read against
/// before the container gets blamed for them.
///
/// The second column funnels the identical traffic through a mutex, the way the
/// old container's critical section incidentally did. That column is why the
/// mutex strategies win the shared-key row at all: they are not faster at
/// reference counting, they serialize it into a hand-off convoy so each retain
/// finds the line already exclusive. Moving the retain outside the critical
/// section drops `.unfairLock` straight onto `.leftRight`'s number.
///
/// The floor this establishes is also what the `borrowed resolve` tables escape
/// — not by making the retain cheaper, but by not performing one.
private func arcBaseline(_ threadCounts: [Int]) {
    let target = SharedTarget()
    let gate = NSRecursiveLock()

    print("baseline: bare retain/release of one shared object (M ops/sec)")
    print("  threads    unsynchronized     serialized")
    for threads in threadCounts {
        let unsynchronized = throughput(threads: threads) { _, deadline in
            let unmanaged = Unmanaged.passUnretained(target)
            var operations = 0
            var sink: UInt = 0
            while nowNanoseconds() < deadline {
                for _ in 0 ..< batchSize {
                    // The opaque call between the two halves is what keeps this
                    // pair alive: ARC deletes a retain/release with nothing
                    // observable in between, which silently turns this loop
                    // into a no-op measuring tens of billions of ops/sec.
                    _ = unmanaged.retain()
                    sink = opaque(sink)
                    unmanaged.release()
                }
                operations += batchSize
            }
            if sink == 0xDEAD_BEEF { print("") }
            return operations
        }

        let serialized = throughput(threads: threads) { _, deadline in
            let unmanaged = Unmanaged.passUnretained(target)
            var operations = 0
            var sink: UInt = 0
            while nowNanoseconds() < deadline {
                for _ in 0 ..< batchSize {
                    // Same opaque barrier as above, so both columns measure the
                    // same work and differ only in the mutex around it.
                    gate.lock()
                    _ = unmanaged.retain()
                    sink = opaque(sink)
                    unmanaged.release()
                    gate.unlock()
                }
                operations += batchSize
            }
            if sink == 0xDEAD_BEEF { print("") }
            return operations
        }

        print("  \(pad(String(threads), 7)) \(rate(unsynchronized)) \(rate(serialized))")
    }
    print("")
}

// MARK: - Fixtures

private func registerAll(_ container: Container) {
    container.register(Service0.self) { _ in Service0() }
    container.register(Service1.self) { _ in Service1() }
    container.register(Service2.self) { _ in Service2() }
    container.register(Service3.self) { _ in Service3() }
    container.register(Service4.self) { _ in Service4() }
    container.register(Service5.self) { _ in Service5() }
    container.register(Service6.self) { _ in Service6() }
    container.register(Service7.self) { _ in Service7() }
    container.register(Service8.self) { _ in Service8() }
    container.register(Service9.self) { _ in Service9() }
    container.register(Service10.self) { _ in Service10() }
    container.register(Service11.self) { _ in Service11() }
    container.register(Service12.self) { _ in Service12() }
    container.register(Service13.self) { _ in Service13() }
    container.register(Service14.self) { _ in Service14() }
    container.register(Service15.self) { _ in Service15() }
    container.register(Marker.self) { _ in Marker(n: 1) }
}

private func registerAll(_ container: LockedContainer) {
    container.register(Service0.self) { _ in Service0() }
    container.register(Service1.self) { _ in Service1() }
    container.register(Service2.self) { _ in Service2() }
    container.register(Service3.self) { _ in Service3() }
    container.register(Service4.self) { _ in Service4() }
    container.register(Service5.self) { _ in Service5() }
    container.register(Service6.self) { _ in Service6() }
    container.register(Service7.self) { _ in Service7() }
    container.register(Service8.self) { _ in Service8() }
    container.register(Service9.self) { _ in Service9() }
    container.register(Service10.self) { _ in Service10() }
    container.register(Service11.self) { _ in Service11() }
    container.register(Service12.self) { _ in Service12() }
    container.register(Service13.self) { _ in Service13() }
    container.register(Service14.self) { _ in Service14() }
    container.register(Service15.self) { _ in Service15() }
    container.register(Marker.self) { _ in Marker(n: 1) }
}

/// Resolves every registration exactly once, which both warms a container for a
/// throughput run and *is* the measured work in the composition-root scenario.
///
/// Written out rather than routed through the hammers: those loop until a
/// deadline, and the previous version of this file passed them `deadline: 0`,
/// which made the loop body run zero times and warmed nothing at all.
@inline(never)
private func resolveAll(_ container: Container) -> UInt {
    var sink: UInt = 0
    sink &+= consume(container.resolve(Service0.self))
    sink &+= consume(container.resolve(Service1.self))
    sink &+= consume(container.resolve(Service2.self))
    sink &+= consume(container.resolve(Service3.self))
    sink &+= consume(container.resolve(Service4.self))
    sink &+= consume(container.resolve(Service5.self))
    sink &+= consume(container.resolve(Service6.self))
    sink &+= consume(container.resolve(Service7.self))
    sink &+= consume(container.resolve(Service8.self))
    sink &+= consume(container.resolve(Service9.self))
    sink &+= consume(container.resolve(Service10.self))
    sink &+= consume(container.resolve(Service11.self))
    sink &+= consume(container.resolve(Service12.self))
    sink &+= consume(container.resolve(Service13.self))
    sink &+= consume(container.resolve(Service14.self))
    sink &+= consume(container.resolve(Service15.self))
    sink &+= UInt(container.resolve(Marker.self)?.n ?? 0)
    return sink
}

@inline(never)
private func resolveAll(_ container: LockedContainer) -> UInt {
    var sink: UInt = 0
    sink &+= consume(container.resolve(Service0.self))
    sink &+= consume(container.resolve(Service1.self))
    sink &+= consume(container.resolve(Service2.self))
    sink &+= consume(container.resolve(Service3.self))
    sink &+= consume(container.resolve(Service4.self))
    sink &+= consume(container.resolve(Service5.self))
    sink &+= consume(container.resolve(Service6.self))
    sink &+= consume(container.resolve(Service7.self))
    sink &+= consume(container.resolve(Service8.self))
    sink &+= consume(container.resolve(Service9.self))
    sink &+= consume(container.resolve(Service10.self))
    sink &+= consume(container.resolve(Service11.self))
    sink &+= consume(container.resolve(Service12.self))
    sink &+= consume(container.resolve(Service13.self))
    sink &+= consume(container.resolve(Service14.self))
    sink &+= consume(container.resolve(Service15.self))
    sink &+= UInt(container.resolve(Marker.self)?.n ?? 0)
    return sink
}

private func makeZinjectContainer(_ strategy: ConcurrencyStrategy) -> Container {
    let container = Container(defaultScope: .container, concurrency: strategy)
    registerAll(container)
    _ = resolveAll(container)
    return container
}

private func makeLockedContainer() -> LockedContainer {
    let container = LockedContainer()
    registerAll(container)
    _ = resolveAll(container)
    return container
}

// MARK: - Harness

private final class OperationTally: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    func add(_ count: Int) {
        lock.lock()
        total += count
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}

/// Runs `worker` on `threads` cores for a fixed window and returns aggregate
/// millions of resolves per second.
private func throughput(
    threads: Int,
    _ worker: @escaping @Sendable (Int, UInt64) -> Int
) -> Double {
    // Best of several samples. A single sample occasionally lands on a bad
    // scheduling window — the whole run migrated onto efficiency cores, say —
    // which shows up as a row that contradicts its neighbours in both columns.
    // The best sample is the one least polluted by that.
    var best = 0.0
    for _ in 0 ..< sampleCount {
        let tally = OperationTally()
        let deadline = nowNanoseconds() + UInt64(sampleDuration * nanosecondsPerSecond)
        let seconds = elapsedSeconds {
            DispatchQueue.concurrentPerform(iterations: threads) { index in
                tally.add(worker(index, deadline))
            }
        }
        best = max(best, Double(tally.value) / seconds / 1_000_000)
    }
    return best
}

private func pad(_ text: String, _ width: Int) -> String {
    String(repeating: " ", count: max(0, width - text.count)) + text
}

private func rate(_ value: Double) -> String {
    pad(String(format: "%.1f", value), 12)
}

private func columns(_ titles: [String]) -> String {
    titles.map { pad($0, 12) }.joined(separator: " ")
}

private func costRow(_ label: String, _ vendored: Double, _ perStrategy: [Double]) -> String {
    "  " + pad(label, 12) + " " + rate(vendored) + " " + perStrategy.map(rate).joined(separator: " ")
}

/// One row per thread count: the vendored pre-rewrite container, then every
/// strategy, then how far the best strategy is ahead of `.recursiveLock` — which
/// is the only honest denominator, since that is what the container used to do.
private func scenario(
    _ title: String,
    _ note: String,
    zinject: @escaping @Sendable (Container, Int, UInt64) -> Int,
    locked: @escaping @Sendable (LockedContainer, Int, UInt64) -> Int
) {
    print(title)
    print("  \(note)")
    print("  threads " + columns(["vendored"] + strategies.map(\.description) + ["best/recursive"]))

    for threads in threadCounts {
        let lockedContainer = makeLockedContainer()
        let lockedRate = throughput(threads: threads) { index, deadline in
            locked(lockedContainer, index, deadline)
        }

        var rates: [Double] = []
        for strategy in strategies {
            // A fresh container per strategy per row, so no measurement inherits
            // another's warmed caches or reader-slot state.
            let container = makeZinjectContainer(strategy)
            rates.append(throughput(threads: threads) { index, deadline in
                zinject(container, index, deadline)
            })
        }

        let baseline = rates.first ?? 1
        let speedup = (rates.max() ?? 0) / max(baseline, .leastNonzeroMagnitude)
        print("  \(pad(String(threads), 7)) \(rate(lockedRate)) "
            + rates.map(rate).joined(separator: " ")
            + " \(pad(String(format: "%.2f", speedup) + "x", 12))")
    }
    print("")
}

/// The `+0` hand-off against the row it was built for.
///
/// Read against the class-typed shared-key table above: same container, same
/// singleton, same cores, one retain/release pair apart. The trailing ratio is
/// the whole argument for the API, and it is also the only instrument sensitive
/// enough to catch the API silently losing its `+0` — a surviving retain does
/// not shave a few percent off this, it puts the row back on top of the
/// returning one.
///
/// Two bodies, and both have to be here. The bare one says how big the effect
/// can be; the `+work` one says whether any of it is left once the call site
/// does something, which is the question that nearly killed this API. Sixteen
/// cores touching one cache line back to back with nothing in between is not a
/// workload, and contention falls off sharply as soon as the accesses are
/// spaced out — a win visible only in an empty loop would not be a win.
private func borrowScenario(
    _ title: String,
    _ note: String,
    borrowed: @escaping @Sendable (Container, UInt64) -> Int,
    returning: @escaping @Sendable (Container, UInt64) -> Int
) {
    print(title)
    print("  \(note)")
    print("  threads " + columns(strategies.map(\.description) + ["lr vs resolve"]))

    for threads in threadCounts {
        var rates: [Double] = []
        for strategy in strategies {
            let container = makeZinjectContainer(strategy)
            rates.append(throughput(threads: threads) { _, deadline in
                borrowed(container, deadline)
            })
        }

        // Measured here rather than read off the table above, so both numbers
        // in the ratio come from the same machine conditions.
        let baseline = makeZinjectContainer(.leftRight)
        let baselineRate = throughput(threads: threads) { _, deadline in
            returning(baseline, deadline)
        }

        let ratio = (rates.last ?? 0) / max(baselineRate, .leastNonzeroMagnitude)
        let formatted = String(format: ratio < 10 ? "%.1f" : "%.0f", ratio)
        print("  \(pad(String(threads), 7)) " + rates.map(rate).joined(separator: " ")
            + " \(pad(formatted + "x", 12))")
    }
    print("")
}

// MARK: - Thread-population stress

/// Runs `worker` on `threadCount` threads that are all alive at once, and
/// returns aggregate millions of operations per second.
///
/// Deliberately not `DispatchQueue.concurrentPerform`, which caps its width at
/// the core count and so can never put more than a machine's worth of threads in
/// flight. Reader slots are held by *live* threads, so only real threads,
/// started together and kept running together, can exhaust them.
private func throughputOnDedicatedThreads(
    threadCount: Int,
    _ worker: @escaping @Sendable (UInt64) -> Int
) -> Double {
    final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func set(_ new: UInt64) {
            lock.lock()
            value = new
            lock.unlock()
        }

        var get: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    var best = 0.0
    for _ in 0 ..< sampleCount {
        let tally = OperationTally()
        let deadline = Deadline()
        let ready = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()

        for _ in 0 ..< threadCount {
            finished.enter()
            let thread = Thread {
                ready.signal()
                go.wait()
                tally.add(worker(deadline.get))
                finished.leave()
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }

        // Every thread must be running before the clock starts, or the early
        // ones would finish and give their slots back before the late ones ever
        // asked for one — which is exactly the situation being tested for.
        for _ in 0 ..< threadCount { ready.wait() }
        deadline.set(nowNanoseconds() + UInt64(sampleDuration * nanosecondsPerSecond))

        let seconds = elapsedSeconds {
            for _ in 0 ..< threadCount { go.signal() }
            finished.wait()
        }
        best = max(best, Double(tally.value) / seconds / 1_000_000)
    }
    return best
}

/// The failure mode a benchmark sized to the machine cannot see.
///
/// `ReaderRegistry` hands out a fixed number of wait-free reader slots, recycled
/// only when a thread exits. Past that, a reader takes the writer lock instead —
/// the same serialization a mutex would impose, plus Left-Right's much more
/// expensive writes. A server, or any app with a large thread pool, can sit
/// permanently on the wrong side of that line and never be told.
private func threadPopulationScenario(_ threadCounts: [Int]) {
    print("thread-population stress: cached resolve, one shared value-typed key (M ops/sec)")
    print("  `.leftRight` has \(ZinjectDiagnostics.readerSlotCapacity) wait-free reader slots; past that, reads take the writer lock")
    print("  threads " + columns(strategies.map(\.description) + ["slotless reads"]))

    for threads in threadCounts {
        var rates: [Double] = []
        var slotless = 0

        for strategy in strategies {
            let container = makeZinjectContainer(strategy)
            ZinjectDiagnostics.reset()
            rates.append(throughputOnDedicatedThreads(threadCount: threads) { deadline in
                hammerMarker(container, deadline: deadline)
            })
            if strategy == .leftRight {
                slotless = ZinjectDiagnostics.slotlessReads
            }
        }

        print("  \(pad(String(threads), 7)) "
            + rates.map(rate).joined(separator: " ")
            + " \(pad(String(slotless), 12))")
    }
    print("")
}

// MARK: - App-shaped load

/// What a composition root actually costs, once, at launch.
///
/// Every other table on this page measures a loop that no application runs. This
/// one measures the thing every application does run exactly once: construct a
/// container, register its services, and resolve each of them the first time.
/// It is all write-path and first-resolve work, which is precisely where
/// Left-Right is slowest — and it is reported in microseconds because that is
/// the unit in which the answer should be judged against a launch budget.
private func compositionRootScenario() {
    // Modest, because each sample is a whole live container and `.leftRight`
    // allocates 16 KiB of reader-slot storage per container. Twenty thousand of
    // those held at once is a third of a gigabyte for no extra signal.
    let samples = 2_000
    let registrations = serviceTypeCount + 1

    print("app-shaped: build one composition root and resolve every service once (microseconds)")
    print("  \(registrations) registrations + \(registrations) first resolves, the whole of what a launch pays")
    print("  " + columns(["vendored"] + strategies.map(\.description)))

    var lockedContainers: [LockedContainer] = []
    lockedContainers.reserveCapacity(samples)
    let lockedCost = elapsedSeconds {
        for _ in 0 ..< samples {
            lockedContainers.append(makeLockedContainer())
        }
    } / Double(samples) * 1_000_000

    var costs: [Double] = []
    var held: [Container] = []
    held.reserveCapacity(samples * strategies.count)
    for strategy in strategies {
        var containers: [Container] = []
        containers.reserveCapacity(samples)
        let cost = elapsedSeconds {
            for _ in 0 ..< samples {
                containers.append(makeZinjectContainer(strategy))
            }
        } / Double(samples) * 1_000_000
        costs.append(cost)
        held.append(contentsOf: containers)
    }

    print("  " + pad(String(format: "%.2f", lockedCost), 12)
        + " " + costs.map { pad(String(format: "%.2f", $0), 12) }.joined(separator: " "))

    let worst = costs.max() ?? 0
    let best = costs.min() ?? 0
    print("  worst strategy costs \(String(format: "%.2f", worst - best)) µs more per composition root — "
        + "\(Int((1000.0 / max(worst - best, .leastNonzeroMagnitude)).rounded())) of them to add a millisecond to launch")
    print("")

    withExtendedLifetime(lockedContainers) {}
    withExtendedLifetime(held) {}
}


// MARK: - Run

let cores = ProcessInfo.processInfo.activeProcessorCount
let threadCounts = Array(Set([1, 2, 4, 8, cores])).sorted()

print("Zinject — concurrency strategies compared")
print("machine: \(cores) active cores, \(sampleDuration)s per sample")
print("default strategy for this process: \(Container.defaultConcurrency)")
print("")

arcBaseline(threadCounts)

scenario(
    "cached resolve, value-typed service, one shared key (M ops/sec)",
    "no reference counting on the result — isolates the container's own synchronization",
    zinject: { container, _, deadline in hammerMarker(container, deadline: deadline) },
    locked: { container, _, deadline in hammerMarker(container, deadline: deadline) }
)

scenario(
    "cached resolve, class-typed service, distinct key per thread (M ops/sec)",
    "each thread owns its instance, so no reference count is shared between cores",
    zinject: { container, index, deadline in
        hammerZinject(container, typeIndex: index, deadline: deadline)
    },
    locked: { container, index, deadline in
        hammerLocked(container, typeIndex: index, deadline: deadline)
    }
)

scenario(
    "cached resolve, class-typed service, one shared key (M ops/sec)",
    "every core retains and releases the same object, back to back — the adversarial worst case",
    zinject: { container, _, deadline in
        hammerZinject(container, typeIndex: 0, deadline: deadline)
    },
    locked: { container, _, deadline in
        hammerLocked(container, typeIndex: 0, deadline: deadline)
    }
)


borrowScenario(
    "borrowed resolve, class-typed service, one shared key (M ops/sec)",
    "the row above with the instance lent for the call instead of returned",
    borrowed: { container, deadline in
        hammerBorrowedClass(container, Service0.self, deadline: deadline)
    },
    returning: { container, deadline in
        hammerClass(container, Service0.self, deadline: deadline)
    }
)

borrowScenario(
    "borrowed resolve, with a body that does real work (M ops/sec)",
    "the same two, each doing \(String(format: "%.0f", realisticWorkCost())) ns per call — does the win survive a call site?",
    borrowed: { container, deadline in
        hammerBorrowedClassWorking(container, Service0.self, deadline: deadline)
    },
    returning: { container, deadline in
        hammerClassWorking(container, Service0.self, deadline: deadline)
    }
)

// Straddle the slot ceiling deliberately: one row comfortably under it, one at
// it, two past it.
let slotCapacity = ZinjectDiagnostics.readerSlotCapacity
threadPopulationScenario([cores, slotCapacity, slotCapacity * 2, slotCapacity * 4])

// The costs Left-Right adds: writes apply twice and drain every reader slot
// twice, and each container allocates its own read-indicator storage.
print("write-side and setup costs (nanoseconds per operation)")
print("  " + pad("operation", 12) + " " + columns(["vendored"] + strategies.map(\.description)))

let writeSamples = 20_000

let lockedRegister = elapsedSeconds {
    let container = makeLockedContainer()
    for _ in 0 ..< writeSamples {
        container.register(Service0.self) { _ in Service0() }
    }
} / Double(writeSamples) * nanosecondsPerSecond

let registerCosts = strategies.map { strategy in
    elapsedSeconds {
        let container = makeZinjectContainer(strategy)
        for _ in 0 ..< writeSamples {
            container.register(Service0.self) { _ in Service0() }
        }
    } / Double(writeSamples) * nanosecondsPerSecond
}

let constructionSamples = 20_000

var lockedContainers: [LockedContainer] = []
lockedContainers.reserveCapacity(constructionSamples)
let lockedConstruction = elapsedSeconds {
    for _ in 0 ..< constructionSamples {
        lockedContainers.append(LockedContainer())
    }
} / Double(constructionSamples) * nanosecondsPerSecond

var constructedByStrategy: [[Container]] = []
let constructionCosts = strategies.map { strategy -> Double in
    var containers: [Container] = []
    containers.reserveCapacity(constructionSamples)
    let cost = elapsedSeconds {
        for _ in 0 ..< constructionSamples {
            containers.append(Container(concurrency: strategy))
        }
    } / Double(constructionSamples) * nanosecondsPerSecond
    constructedByStrategy.append(containers)
    return cost
}

let lockedFirstResolve = elapsedSeconds {
    for container in lockedContainers {
        container.register(Service0.self) { _ in Service0() }
        _ = consume(container.resolve(Service0.self))
    }
} / Double(constructionSamples) * nanosecondsPerSecond

let firstResolveCosts = constructedByStrategy.map { containers in
    elapsedSeconds {
        for container in containers {
            container.register(Service0.self) { _ in Service0() }
            _ = consume(container.resolve(Service0.self))
        }
    } / Double(constructionSamples) * nanosecondsPerSecond
}

print(costRow("register", lockedRegister, registerCosts))
print(costRow("construction", lockedConstruction, constructionCosts))
print(costRow("first resolve", lockedFirstResolve, firstResolveCosts))
print("")

withExtendedLifetime(lockedContainers) {}
withExtendedLifetime(constructedByStrategy) {}

compositionRootScenario()

print("Reading this: the cached-resolve tables say which strategy is fastest at the")
print("operation Left-Right optimizes. The write-side, thread-population, and")
print("app-shaped tables say whether your application performs that operation often")
print("enough, on few enough threads, to collect. The borrowed-resolve tables say what")
print("returning an owned reference costs rather than lending one, and how much of that")
print("is left once the call site does real work. Set ZINJECT_CONCURRENCY and measure")
print("the application, not this file.")
