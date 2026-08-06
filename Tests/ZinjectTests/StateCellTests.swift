import Foundation
import Testing
@testable import Zinject

// `LeftRightTests.swift` covers the Left-Right algorithm's own machinery — the
// double application, the drains, the slot registry. These tests cover the
// weaker property that makes `ConcurrencyStrategy` legitimate at all: that every
// `StateCell` implementation is indistinguishable from the outside. Each one
// runs against all three.
//
// Generic over the cell rather than parameterized with a value, because
// `StateCell` has an associated type and the tests need to construct one.

private struct Paired: Equatable {
    var left = 0
    var right = 0
}

private func exercise<Cell: StateCell>(_: Cell.Type) where Cell.Value == Int {
    let cell = Cell(7)
    #expect(cell.read { $0.pointee } == 7)

    cell.write { $0 += 5 }
    #expect(cell.read { $0.pointee } == 12)
}

@Test func everyCellStartsAtItsInitialValue() async throws {
    exercise(LeftRight<Int>.self)
    exercise(MutexCell<RecursiveLock, Int>.self)
    exercise(MutexCell<UnfairLock, Int>.self)
}

// The value handed back to the caller comes from the first application of the
// body. Under Left-Right the body also runs a second time against the other
// copy, and that second result must not be the one returned.
private func checkWriteReturnsFirstApplication<Cell: StateCell>(_: Cell.Type) where Cell.Value == Int {
    let cell = Cell(0)
    let first = cell.write { state -> Int in
        state += 1
        return state
    }
    let second = cell.write { state -> Int in
        state += 1
        return state
    }
    #expect(first == 1)
    #expect(second == 2)
    #expect(cell.read { $0.pointee } == 2)
}

@Test func writeReturnsTheFirstApplicationsResult() async throws {
    checkWriteReturnsFirstApplication(LeftRight<Int>.self)
    checkWriteReturnsFirstApplication(MutexCell<RecursiveLock, Int>.self)
    checkWriteReturnsFirstApplication(MutexCell<UnfairLock, Int>.self)
}

// Repeated relative writes are where a half-implemented Left-Right diverges:
// applying each change to only one copy leaves the two disagreeing, and the
// error compounds. Every cell must land on the same total.
private func checkAccumulation<Cell: StateCell>(_: Cell.Type) where Cell.Value == Int {
    let cell = Cell(0)
    for _ in 0 ..< 1_000 {
        cell.write { $0 += 3 }
    }
    #expect(cell.read { $0.pointee } == 3_000)
}

@Test func repeatedWritesAccumulateIdentically() async throws {
    checkAccumulation(LeftRight<Int>.self)
    checkAccumulation(MutexCell<RecursiveLock, Int>.self)
    checkAccumulation(MutexCell<UnfairLock, Int>.self)
}

// A reader must never see one field of a write applied without the other. This
// is the property `Container.resolve` depends on when it reads `services` and
// `factories` in one section.
private func checkNoPartialWriteObserved<Cell: StateCell>(_: Cell.Type) where Cell.Value == Paired {
    let cell = Cell(Paired())
    let torn = ManagedCounter()
    let stop = ManagedFlag()

    let writer = Thread {
        for step in 1 ... 20_000 {
            cell.write { state in
                state.left = step
                state.right = step
            }
        }
        stop.set()
    }
    writer.start()

    DispatchQueue.concurrentPerform(iterations: 4) { _ in
        while !stop.isSet {
            let seen = cell.read { $0.pointee }
            if seen.left != seen.right {
                torn.increment()
            }
        }
    }

    #expect(torn.value == 0)
}

@Test func readersNeverObserveAPartiallyAppliedWrite() async throws {
    checkNoPartialWriteObserved(LeftRight<Paired>.self)
    checkNoPartialWriteObserved(MutexCell<RecursiveLock, Paired>.self)
    checkNoPartialWriteObserved(MutexCell<UnfairLock, Paired>.self)
}

// Readers and writers running flat out against each other must still leave the
// cell holding exactly the number of writes that were issued — no lost updates.
private func checkWritesSurviveConcurrentReads<Cell: StateCell>(_: Cell.Type) where Cell.Value == Int {
    let cell = Cell(0)
    let stop = ManagedFlag()

    let readers = Thread {
        while !stop.isSet {
            _ = cell.read { $0.pointee }
        }
    }
    readers.start()

    DispatchQueue.concurrentPerform(iterations: 4) { _ in
        for _ in 0 ..< 500 {
            cell.write { $0 += 1 }
        }
    }
    stop.set()

    #expect(cell.read { $0.pointee } == 2_000)
}

@Test func writesAreNotLostUnderConcurrentReads() async throws {
    checkWritesSurviveConcurrentReads(LeftRight<Int>.self)
    checkWritesSurviveConcurrentReads(MutexCell<RecursiveLock, Int>.self)
    checkWritesSurviveConcurrentReads(MutexCell<UnfairLock, Int>.self)
}

// MARK: - Helpers

private final class ManagedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private struct ReadFailure: Error {}

// The throwing `read` overload exists so `Container.withResolvedRequired` can
// take the caller's body. It has to leave the cell exactly as the non-throwing
// one does on the way out, and the interesting case is `LeftRight`: its reader
// departs in a `defer`, and if an unwind skipped that, the cell would keep a
// permanent arrival on this thread's indicator and the next write would drain
// forever. So the assertion that matters is the write *after* the throw.
private func checkThrowingReadUnwindsCleanly<Cell: StateCell>(_: Cell.Type) where Cell.Value == Int {
    let cell = Cell(1)

    #expect(cell.read { $0.pointee } == 1)
    #expect(throws: ReadFailure.self) {
        try cell.read { _ -> Int in throw ReadFailure() }
    }

    // Would hang rather than fail if the arrival leaked.
    cell.write { $0 += 1 }
    #expect(cell.read { $0.pointee } == 2)

    // And a body that could throw but does not is just a read. No `try` here:
    // a non-throwing closure selects the non-throwing overload.
    #expect(cell.read { pointer -> Int in pointer.pointee * 10 } == 20)
}

@Test(.timeLimit(.minutes(1)))
func everyCellSurvivesAThrowingReadBody() async throws {
    checkThrowingReadUnwindsCleanly(LeftRight<Int>.self)
    checkThrowingReadUnwindsCleanly(MutexCell<RecursiveLock, Int>.self)
    checkThrowingReadUnwindsCleanly(MutexCell<UnfairLock, Int>.self)
}

// MARK: - A write nested inside a read

// The sharpest form of "indistinguishable from the outside": one mistake, and
// every cell refuses it. Until now they did not — `LeftRight` spun forever,
// `MutexCell<RecursiveLock, _>` went through and mutated state the enclosing
// read was still holding a pointer to, and only `MutexCell<UnfairLock, _>`
// stopped it. Two of the three now trap with the same message; the third keeps
// its `os_unfair_lock` abort, which arrives before any check of ours could run.
//
// `processExitsWith` bodies run in a spawned process and so cannot capture,
// which is why these are three tests rather than one parameterized over the
// cells.

@Test(.enabled(if: !isRunningUnderThreadSanitizer)) func leftRightTrapsOnAWriteInsideARead() async throws {
    let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
        let cell = LeftRight(0)
        cell.read { _ in
            cell.write { $0 += 1 }
        }
    }
    // Observed, not just the exit status: before this trap existed the same
    // mistake was an infinite spin, and a test that only checked for failure
    // would be satisfied by any other way of dying.
    let diagnosis = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
    #expect(diagnosis.contains("write was performed from inside this thread's own read section"))
}

@Test(.enabled(if: !isRunningUnderThreadSanitizer)) func recursiveLockCellTrapsOnAWriteInsideARead() async throws {
    let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
        let cell = MutexCell<RecursiveLock, Int>(0)
        cell.read { _ in
            cell.write { $0 += 1 }
        }
    }
    // The same wording as Left-Right's, which is the point: one mistake, one
    // explanation, whichever strategy the container happens to be running.
    let diagnosis = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
    #expect(diagnosis.contains("write was performed from inside this thread's own read section"))
}

#if canImport(Darwin)
// Darwin only: off Darwin this strategy is an `NSLock`, which is documented as
// undefined when relocked rather than as a trap, and would hang here instead.
@Test(.enabled(if: !isRunningUnderThreadSanitizer)) func unfairLockCellRefusesAWriteInsideARead() async throws {
    await #expect(processExitsWith: .failure) {
        let cell = MutexCell<UnfairLock, Int>(0)
        cell.read { _ in
            cell.write { $0 += 1 }
        }
    }
}
#endif

private final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
