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

`resolveAsync` hops to the main actor with `await` only when the registration needs it and nothing has constructed the service yet; an already-cached service returns without hopping. It works for any `Sendable` service, whichever way it was registered.

> The trap covers a cold resolve only. A *warm* off-main `resolve` still hands a main-actor service to a background thread, and the container cannot see that — the caller's isolation is the caller's to get right.

### Borrowing instead of resolving

`resolve` hands back an owned reference, which means a retain and a release. For a singleton being resolved from many threads at once, that pair — not anything in the container — is the dominant cost. `withResolvedRequired` lends the instance for the duration of a closure instead:

```swift
container.withResolvedRequired(Logger.self) { logger in
    logger.log("hello")
}
```

**Read the contract before reaching for it.** The closure runs inside the container's read section, and the container is not re-entrant there:

- It must not call `resolve`, `register`, `unregister`, `removeAll`, or `withResolvedRequired` again — on this container or any other — and must not call anything that transitively does. The natural body is a method call on the resolved service, so a service that lazily resolves its own dependencies is a deadlock written by accident.
- It must be short. It stalls writers for as long as it runs.
- Debug builds trap on a violation; release builds are undefined behaviour, and what you get depends on the strategy. Build with `-DZINJECT_BORROW_CHECKS` to keep the check in a release build.

What the closure *may* do is let the instance escape — assigning it anywhere copies it, and the copy is an ordinary strong reference that outlives the call:

```swift
var held: Logger?
container.withResolvedRequired(Logger.self) { held = $0 }  // fine
```

Classes only, which costs nothing: a struct has no reference count and so never had the problem. Everything else about it matches `resolve` — same construction gate, same `initCompleted`, same caching, same metrics. It traps if the service is not registered, like `resolveRequired`.

### Teardown

```swift
container.register(Config.self) { _ in Config(env: "test") } // re-registering evicts the cached instance
container.unregister(Config.self)                            // remove one registration
container.removeAll()                                        // remove everything
```

## Thread safety

`Container` is safe to use from multiple threads, under every [concurrency strategy](#choosing-a-strategy). Three behaviors are worth knowing:

- **A `.container`-scoped service is constructed exactly once**, however many threads race its first resolve. No lock is still held while your code (factories, `initCompleted` callbacks) runs — construction is serialized per service key instead, so a slow factory for one type never blocks resolving another. `.transient` registrations are deliberately not serialized: constructing per resolve is what transient means.
- If a registration is replaced or removed while a resolve is still inside its factory, that resolve returns the instance its own factory produced but does not cache it. The cache always reflects the registration that is currently installed.
- Circular dependencies (A → B → A) are detected during resolution and trap with a message describing the cycle. One exception: a cycle that only ever forms across two threads at once — thread 1 inside A's factory resolving B while thread 2 is inside B's factory resolving A — blocks instead of trapping. Resolve either type on one thread and it traps as usual.
- [`withResolvedRequired`](#borrowing-instead-of-resolving) is the one method that is **not** re-entrant: its closure runs inside the container's read section and must not call back into the container. Everything else here is.

## Concurrency design

Resolution is read-mostly by nature: registration happens once at the composition root, each `.container`-scoped service is constructed once, and every resolve after that is a lookup. `Container` is built around that asymmetry using [Left-Right](https://hal.science/hal-01207881/document) rather than a mutex.

Two copies of the registration and cache state are kept. Readers are directed at one of them and are wait-free — no locks, no retry loops, and no writes to any cache line another reader touches, because each thread announces itself in a slot of its own. Writers take a mutex, apply their change to the copy nobody is reading, redirect readers to it, wait for the stragglers to leave, then replay the change on the other copy.

That is the default, not a commitment. Which strategy is right depends on facts about *your* application that no benchmark here can supply, so all three are selectable.

### Choosing a strategy

```swift
let container = Container(concurrency: .leftRight)      // default: wait-free readers, expensive writers
let container = Container(concurrency: .unfairLock)     // os_unfair_lock around the state
let container = Container(concurrency: .recursiveLock)  // NSRecursiveLock — what Zinject used before Left-Right
```

Behavior is identical across all three; only the performance profile differs. Every test that pins an observable behavior runs against all three.

To A/B a real application without editing its composition root, set `ZINJECT_CONCURRENCY` — an Xcode scheme variable, a launch argument, or anything else that reaches the process environment:

```
ZINJECT_CONCURRENCY=unfairLock ./MyApp
```

Case and punctuation are ignored (`left-right`, `leftRight`, `LEFT_RIGHT` all work). An unrecognized value warns on stderr and falls back to `.leftRight`, rather than silently producing what looks like a valid measurement of the wrong thing. `Container.defaultConcurrency` reads and writes the same process-wide default in code, and `container.concurrency` reports what a given container ended up with.

### What the trade actually is

On a 16-core M-series machine, cached resolves of a value-typed service:

| threads | `.recursiveLock` | `.unfairLock` | `.leftRight` |
| ------: | ---------------: | ------------: | -----------: |
|       1 |        52.7 M/s  |    142.7 M/s  |   128.2 M/s  |
|       4 |        16.8 M/s  |     34.0 M/s  |   497.5 M/s  |
|      16 |        25.7 M/s  |     56.6 M/s  |  1606.7 M/s  |

Writes and construction pay for it, in nanoseconds per operation:

| operation     | `.recursiveLock` | `.unfairLock` | `.leftRight` |
| ------------- | ---------------: | ------------: | -----------: |
| `register`    |            258   |         246   |         338  |
| construction  |             79   |          55   |        1088  |
| first resolve |            820   |         796   |        1933  |

Left-Right's container construction is 20x the cost of a mutex's, because each container allocates its own 16 KiB of reader-slot storage.

Put together, a whole composition root — 17 registrations plus a first resolve of each — costs about **12.9 µs under `.unfairLock` and 19.2 µs under `.leftRight`**. If your application builds one container at launch and then resolves from it, that 6.3 µs is the entire price, and you would need 159 launches to accumulate a millisecond. If it builds thousands of short-lived containers, the same 6.3 µs is the dominant term and `.leftRight` is the wrong choice.

Run `swift run -c release ZinjectBench` to reproduce all of this on your own hardware — but the numbers that should decide anything are the ones from your application, not from this file.

### What a cached resolve actually does

One probe of a flat, open-addressed table keyed by type metadata, then a typed load of the cached instance out of storage that holds a `Service`, not an `Any`. Neither step hashes anything or casts anything: `Dictionary` cost about 13 ns per lookup in `Hasher`, and recovering a value from an `Any` cost about another 7 ns in `swift_dynamicCast`.

`resolve` is `@inlinable`, which matters more than either: a generic that cannot specialize asks the runtime for type metadata on every call, and that alone cost more than the rest of a resolve put together. Inlining lets each call site specialize for its own service type, and a cached resolve settles at about **4 ns of work** — the rest of the numbers above are what that leaves.

### Two caveats worth knowing

**Shared singletons and reference counting.** The numbers above resolve a value type, or a class type that each thread owns. If instead **every core resolves the same class-typed singleton back to back**, `.leftRight` is worse than either mutex — around 8.7 M/s against 34.2 M/s at 16 threads.

That is not the container's synchronization. `resolve` hands back a strong reference, so every caller retains and releases the same object, and uncoordinated reference counting on one object degrades sharply under contention. The benchmark measures this directly with no container involved at all: bare `retain`/`release` of a single shared object runs at 258 M/s on one core but collapses to a fraction of that across 16, while funnelling the identical traffic through a mutex holds at 30 M/s. A lock had been serializing that contention as a side effect; a wait-free reader no longer does.

In practice this is what dependency injection already advises: resolve a service once and hold the reference, rather than resolving it inside a hot loop. Resolve-and-hold pays this cost once. Where that is genuinely not an option, [`withResolvedRequired`](#borrowing-instead-of-resolving) lends the instance instead of handing back a reference, and does not pay it at all.

**The reader-slot ceiling.** `.leftRight` has a fixed number of wait-free reader slots — `ZinjectDiagnostics.readerSlotCapacity`, currently 64 — recycled only when a thread exits. A process with more live resolving threads than that gives the overflow threads no slot, and their reads fall back to taking the writer lock: the same serialization a mutex imposes, plus Left-Right's much more expensive writes. Such a process is strictly worse off than it would be under `.unfairLock`, and nothing about that is visible from the outside.

So it is counted:

```swift
ZinjectDiagnostics.slotlessReads      // reads that took the writer-lock fallback
ZinjectDiagnostics.threadsWithoutSlot // threads that never got a slot (counted once each)
ZinjectDiagnostics.reset()            // to scope a measurement to one phase
```

A non-zero `slotlessReads` in your application is a direct instruction to switch strategy. Both counters live on paths that were already slow, so a reader holding a slot never touches them.

### Measuring your own resolve volume

Whether any of the above matters depends on how much an application actually resolves — usually far less than a benchmark loop. Build with `-DZINJECT_METRICS` to find out:

```
swift build -Xswiftc -DZINJECT_METRICS
```

```swift
let m = container.metrics
print(m.cachedResolves, m.factoryRuns, m.writes, m.unregisteredLookups)
```

Opt-in rather than always-on because collecting these puts an atomic increment on the resolve fast path — small, but comparable to the read it is measuring. Use it to learn *how much* you resolve; turn it off to measure *how fast*.

## License

Public domain, via [the Unlicense](https://unlicense.org). See [LICENSE](LICENSE).
