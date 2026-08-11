# Zinject

A lightweight, thread-safe dependency injection container for Swift.

## Installation

Add Zinject to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/zachhowe/Zinject.git", branch: "master"),
]
```

Requires Swift 6.0+. Supports macOS 10.15+, iOS 13+, tvOS 13+, and watchOS 6+.

## Usage

### Registering and resolving

```swift
import Zinject

let container = Container()

container.register(APIClient.self) { _ in APIClient() }
container.register(UserService.self) { resolver in
    UserService(client: resolver.resolve(APIClient.self)!)
}

let service = container.resolve(UserService.self)          // UserService?
let required = container.resolveRequired(UserService.self) // UserService, traps if unregistered
```

### Scopes

Services default to `.container` scope (one shared instance per container). Use `.transient` for a new instance on every resolve. The default is configurable per container, and overridable per registration:

```swift
let container = Container(defaultScope: .transient)

container.register(Logger.self) { _ in Logger() }
    .scope(.container) // override: shared instance
```

### Post-initialization callbacks

```swift
container.register(Coordinator.self) { _ in Coordinator() }
    .initCompleted { resolver, coordinator in
        coordinator.delegate = resolver.resolve(AppDelegateProxy.self)
    }
```

Multiple `initCompleted` callbacks may be attached; they run in registration order. For `.container`-scoped services, the instance is cached before the callbacks run, so a callback may resolve its own type without recursing.

### Main-actor factories

For services that must be constructed on the main actor (e.g. UI-related objects):

```swift
container.registerMainActor(ViewModelFactory.self) { resolver in
    ViewModelFactory() // runs on the main actor
}
```

Resolving from the main thread runs the factory inline. Resolving one of these for the first time from any other thread **traps** — use `resolveAsync(_:)` instead:

```swift
let factory = await container.resolveAsync(ViewModelFactory.self)
```

`resolveAsync` hops to the main actor with `await` only when the registration needs it and nothing has constructed the service yet; an already-cached service returns without suspending. It works for any `Sendable` service, whichever way it was registered.

> **Why it traps rather than hopping.** Before 0.1.0 the container hopped for you via `DispatchQueue.main.sync`. That deadlocks whenever the main thread is already waiting on the calling thread — and because the hop only ran on a *cache miss*, the deadlock stopped reproducing as soon as anything warmed the type. A hang that vanishes on the second launch and never reproduces under a debugger is worse than a crash, so the synchronous path now refuses.
>
> The trap covers a cold resolve only. A *warm* off-main `resolve` still hands a main-actor service to a background thread, and the container cannot see that — the caller's isolation is the caller's to get right.

### Teardown

```swift
container.register(Config.self) { _ in Config(env: "test") } // re-registering evicts the cached instance
container.unregister(Config.self)                            // remove one registration
container.removeAll()                                        // remove everything
```

## Thread safety

`Container` is safe to use from multiple threads. Three behaviors are worth knowing:

- **A `.container`-scoped service is constructed exactly once**, however many threads race its first resolve. The container's lock is still never held while your code (factories, `initCompleted` callbacks) runs — construction is serialized per service key instead, so a slow factory for one type never blocks resolving another. `.transient` registrations are deliberately not serialized: constructing per resolve is what transient means.
- If a registration is replaced (`register`, `unregister`, `removeAll`) while its factory is running, the instance that factory built is still returned to its own caller but is **not** cached — it cannot outlive the registration it came from.
- Circular dependencies (A → B → A) are detected during resolution and trap with a message describing the cycle.

> Before 0.1.0 a racing first resolve could run the factory more than once, keeping one instance and discarding the rest — so callers were told to keep factories free of one-shot side effects. For a service holding a keychain handle, a CloudKit container or a crypto key, building a second one and throwing it away is a correctness bug rather than a wasted allocation. Factories no longer need to be idempotent.

## License

Public domain, via [the Unlicense](https://unlicense.org). See [LICENSE](LICENSE).
