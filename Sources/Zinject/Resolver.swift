/// The service-resolution surface shared by ``Container`` and any other
/// resolver an application wants to hand to factories.
///
/// Deliberately small. Every requirement here is one a conformer must supply
/// itself, and every method beyond ``resolve(_:)`` costs a conformer
/// something:
///
/// - ``resolveAsync(_:)`` exists because a conformer that registers main-actor
///   factories is the only party that knows how to reach them off the main
///   thread. The default implementation cannot know, so it simply calls
///   ``resolve(_:)`` — correct for conformers with no main-actor
///   registrations, and a trap (by ``resolve(_:)``'s own rule) for those that
///   have them. ``Container`` overrides it with the real main-actor hop.
///
/// - ``withResolvedRequired(_:_:)`` is deliberately *not* a requirement, and
///   must not become one. The only default implementation the protocol could
///   offer is `try body(resolveRequired(type))`, which retains — and an API
///   whose entire value is that it touches no reference count must not have a
///   conforming path where that claim is quietly false. Nor could the
///   existential benefit: lending at +0 depends on the call specializing, and
///   a witness-table dispatch already costs more than the retain it would
///   save. The same reasoning bounds the protocol: additions belong here only
///   when a conformer genuinely needs to vary their behavior.
public protocol Resolver: Sendable {
    /// Resolves a service, or returns nil if the type was never registered.
    ///
    /// For ``Container``, a `.container`-scoped service is constructed exactly
    /// once however many threads race its first resolve, and a container with
    /// a parent falls back to it when it has no registration for the type.
    /// See ``Container/resolve(_:)``.
    func resolve<Service>(_ type: Service.Type) -> Service?

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
    ///
    /// The default implementation simply calls ``resolve(_:)``. That is correct
    /// for any conformer without main-actor registrations; a conformer that
    /// has them should override this, because ``resolve(_:)`` traps off the
    /// main thread on their first resolve by design.
    func resolveAsync<Service>(_ type: Service.Type) async -> Service? where Service: Sendable
}

extension Resolver {
    /// The default: no main-actor awareness, just a plain resolve.
    ///
    /// ``Container`` supplies the real implementation; this exists so that a
    /// conformer with no main-actor registrations — the common case — need not
    /// write a method that only ever forwards.
    public func resolveAsync<Service>(_ type: Service.Type) async -> Service? where Service: Sendable {
        resolve(type)
    }
}

extension Resolver {
    /// Resolves a service, trapping with a descriptive message if it is not
    /// registered. Use this instead of force-unwrapping `resolve(_:)`.
    public func resolveRequired<Service>(_ type: Service.Type) -> Service {
        guard let service = resolve(type) else {
            preconditionFailure("Zinject: failed to resolve required service \(type)")
        }
        return service
    }
}
