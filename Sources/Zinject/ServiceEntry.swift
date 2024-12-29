public protocol ServiceEntry<Service>: Sendable {
    associatedtype Service

    @discardableResult
    func initCompleted(_ perform: @Sendable @escaping (Resolver, Service) -> Void) -> any ServiceEntry<Service>

    @discardableResult
    func scope(_ scope: Scope) -> any ServiceEntry<Service>
}
