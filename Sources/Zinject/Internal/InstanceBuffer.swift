/// Staging space for a cached instance on its way out of a read section.
///
/// A `Service?` local would be the obvious thing to copy into, and it is what
/// this replaces. In a caller that specialized `resolve` it costs nothing —
/// but a caller that did not, which is any call through `any Resolver`, cannot
/// know `Optional<Service>`'s layout statically. It has to ask the runtime for
/// that type's metadata on every resolve, and the cache lookup behind
/// `swift_getGenericMetadata` measured about 35 ns — more than the rest of a
/// cached resolve put together.
///
/// This buffer is a concrete type, so allocating one is free at any
/// specialization. The instance is copied into it inside the read section and
/// moved out of it afterwards, straight into the return slot the caller
/// provided — which needs no metadata of its own, since the tag for `.some` is
/// written through `Service`'s own value witnesses.
///
/// Six words, aligned to sixteen. Sized for the shapes a container actually
/// caches: a class reference is one word, most value types are a few, and
/// `any Protocol` — which is what a protocol-typed registration resolves to,
/// and the reason this is not four words — is five, or six for two protocols.
/// Nothing about a larger buffer costs anything at run time; only `Service`'s
/// own size is ever copied. ``fits(_:)`` says when it is not enough, and
/// `Container` keeps a slower path for that case.
@usableFromInline
struct InstanceBuffer {
    @usableFromInline
    var storage: (SIMD2<UInt64>, SIMD2<UInt64>, SIMD2<UInt64>)

    @inlinable
    init() {
        storage = (.zero, .zero, .zero)
    }

    /// Whether a `Service` value can be staged here at all.
    ///
    /// Statically known in specialized code, where it folds away along with the
    /// branch on it.
    @inlinable
    static func fits<Service>(_ type: Service.Type) -> Bool {
        MemoryLayout<Service>.size <= MemoryLayout<Self>.size
            && MemoryLayout<Service>.alignment <= MemoryLayout<Self>.alignment
    }

    /// Copies the `Service` at `source` into this buffer.
    ///
    /// A real copy through `Service`'s value witnesses — a class instance is
    /// retained here, exactly as it would be on its way out of any other
    /// storage — not a copy of raw bytes.
    @inlinable
    mutating func initialize<Service>(from source: UnsafeRawPointer, as type: Service.Type) {
        withUnsafeMutableBytes(of: &storage) { raw in
            raw.baseAddress.unsafelyUnwrapped
                .bindMemory(to: Service.self, capacity: 1)
                .initialize(to: source.assumingMemoryBound(to: Service.self).pointee)
        }
    }

    /// Moves `value` into this buffer.
    ///
    /// The other direction from ``initialize(from:as:)``: that one copies a
    /// value that stays where it is, retaining a class; this one takes
    /// ownership of a value that was already computed, so nothing is retained.
    ///
    /// This is how ``Container/withResolvedRequired(_:_:)`` gets its body's
    /// result out of the read section. Staging it here rather than in a
    /// `Result?` local is the same trade this type was built for, on a
    /// different type parameter: `Optional<Result>` has a layout that depends
    /// on `Result`, so an unspecialized caller would pay a metadata lookup per
    /// call to allocate one. A bare `Result` costs nothing — its metadata is
    /// already an argument there.
    @inlinable
    mutating func initialize<Value>(to value: Value) {
        withUnsafeMutableBytes(of: &storage) { raw in
            raw.baseAddress.unsafelyUnwrapped
                .bindMemory(to: Value.self, capacity: 1)
                .initialize(to: value)
        }
    }

    /// Moves the staged value out, leaving the buffer uninitialized. Must be
    /// called exactly once after ``initialize(from:as:)``, and not at all
    /// otherwise — nothing else here releases what was staged.
    @inlinable
    mutating func move<Service>(as type: Service.Type) -> Service {
        withUnsafeMutableBytes(of: &storage) { raw in
            raw.baseAddress.unsafelyUnwrapped.assumingMemoryBound(to: Service.self).move()
        }
    }
}
