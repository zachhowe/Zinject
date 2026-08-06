/// Owns the storage for one cached `.container`-scoped instance.
///
/// The instance lives in manually allocated, `Service`-typed memory rather than
/// inside an `Any`, so that a cached resolve can recover it with a typed load
/// instead of `swift_dynamicCast`. That cast measured about 7 ns of a 30 ns
/// cached resolve — the second most expensive thing on the path, after
/// `Dictionary` hashing. Nothing else about the instance changes: it is copied
/// out of this storage exactly as it would be out of any other, retaining if it
/// is a class.
///
/// ## Why the load is sound
///
/// A slot in ``ServiceTable`` is keyed by the metadata of the service type as
/// written at the call site, and `Container.publish` initializes this storage
/// from a value of that same static type. A reader that found the slot by
/// probing for `Service` is therefore looking at memory bound to `Service` —
/// not at something merely convertible to it, which is the distinction the
/// dynamic cast was paying to establish.
///
/// ## Why the lifetime is sound
///
/// ARC does the ordering. The table holds this object in a column that no
/// reader touches, so the last reference always goes away inside the write that
/// evicts it:
///
/// - Under ``ConcurrencyStrategy/leftRight`` that write releases one reference
///   per copy of the state. The first application takes the pointer out of the
///   copy nobody is reading; only after the flip and the drain does the second
///   application release the last reference and run `deinit`. By then no reader
///   can still be inside a section that named this storage, and no new reader
///   can reach it.
/// - Under a mutex cell the write holds the lock that every reader needs, and
///   the read that copies the value out has already finished.
///
/// The one thing that must not happen is a reader keeping the *pointer* past
/// its read section. `Container` does not: it loads the value inside the
/// section and returns the value.
///
/// ## Why the instance can be lent without retaining it
///
/// ``Container/withResolvedRequired(_:_:)`` hands the instance to user code
/// without touching its reference count. Three properties make that sound, and
/// all three are here rather than there because this type is what owns them:
///
/// - **The window is exactly the read section**, which is the same guarantee
///   the paragraph above establishes for the pointer. Nothing about reclamation
///   changes to accommodate the borrow; the borrow is simply confined to a
///   grace period the algorithm already provides.
/// - **This storage is written exactly once.** `init` initializes it and
///   `deinit` tears it down; nothing in between ever writes through it.
///   `ServiceTable.setInstance` and `setFactory` replace the *column entries*
///   that point here, never the pointee. So a borrower cannot observe a torn
///   value even while another thread publishes a different instance for the
///   same key.
/// - **The value may escape; the address may not.** Assigning the borrowed
///   instance anywhere copies it, which retains, and the escapee is an ordinary
///   owned reference that outlives this storage on its own terms. That is the
///   whole difference between lending inside a section and handing out an
///   `Unmanaged`: one cannot be held wrong, the other can only be held right.
///
/// The corresponding hazard is a *write* from inside a borrow body: it would
/// drop the owner and free this storage while it is lent out. That is what
/// ``SectionGuard`` exists to catch, and why the borrow contract forbids
/// touching the container from a body at all.
final class CachedInstance<Service> {
    let storage: UnsafeMutablePointer<Service>

    init(_ instance: Service) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: instance)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }
}
