public protocol Resolver: Sendable {
    func resolve<Service>(_ type: Service.Type) -> Service?
}
