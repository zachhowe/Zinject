/// The lifetime of the instance a registration produces.
///
/// - ``transient``: a new instance is built on every resolve, and nothing is
///   cached. Transient resolves deliberately skip the container's write path
///   entirely — caching is what transient means, and serializing their
///   construction through a write would defeat it.
///
/// - ``container``: the first resolve constructs the instance, and every later
///   resolve — from any thread, through any container that falls back to the
///   one holding the registration — returns that same instance. Constructed
///   exactly once under a concurrent first resolve; see
///   ``Container/resolve(_:)``.
///
/// Note the scope is a property of the *registration*, not of the container
/// asked: resolving a container-scoped type through a child whose parent owns
/// the registration caches in the parent, shared with its other children.
public enum Scope: Sendable {
    /// Build a fresh instance on every resolve; never cached.
    case transient

    /// Build once, on first resolve, and cache the instance for every resolve
    /// after it.
    case container
}
