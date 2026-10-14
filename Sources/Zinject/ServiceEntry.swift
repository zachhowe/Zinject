/// The handle a ``Container/register(_:factory:)`` call returns, for fluent
/// configuration of the registration it created.
///
/// The methods are additive and accumulate: every `initCompleted` callback is
/// kept and run in registration order, and each `scope` call replaces the one
/// before it. Configuring after the service has already been constructed has
/// defined but limited effect — a new scope takes effect only when the cached
/// instance is gone (see `Container.unregister(_:)`), while a new
/// `initCompleted` callback never runs retroactively on an instance already
/// built.
public protocol ServiceEntry<Service>: Sendable {
    /// The service type this entry configures.
    associatedtype Service

    /// Adds a callback run with the instance after its factory returns and —
    /// for ``Scope/container`` — after it is published to the cache, so a
    /// callback may re-resolve its own type and get the same instance back.
    /// Multiple callbacks accumulate and run in the order added.
    ///
    /// Runs with no container lock or read section held, so the callback may
    /// resolve further services freely.
    @discardableResult
    func initCompleted(_ perform: @Sendable @escaping (Resolver, Service) -> Void) -> any ServiceEntry<Service>

    /// Sets the registration's ``Scope``, replacing any previous setting.
    /// Defaults to ``Scope/container`` unless the container was created with a
    /// different `defaultScope`.
    @discardableResult
    func scope(_ scope: Scope) -> any ServiceEntry<Service>
}
