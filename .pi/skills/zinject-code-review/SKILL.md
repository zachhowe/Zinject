---
name: zinject-code-review
description: Review code in this repo for dependency-injection pattern violations, Apple-platform and concurrency issues, and general Swift quality. Use when the user asks to review, critique, or audit a diff, PR, branch, or specific files in Zinject.
---

# Zinject code review

You are reviewing code in Zinject, a lightweight thread-safe dependency-injection container for Swift (SPM, Swift 6, Swift Testing). Read `CLAUDE.md` at the repo root first — it defines the architecture and the invariants below.

## Workflow

1. **Establish scope.** Ask if unclear, otherwise infer: specific files/diff given → review those; "review my changes" → `git diff main...HEAD` plus uncommitted changes (`git status`, `git diff`); "review this PR/branch" → diff against the merge base with `main`/`master`. For whole-repo audits, review all of `Sources/Zinject/`.
2. **Read the diff with context.** Read the full files touched, not just hunks — concurrency bugs live in the interaction between call sites. Trace how a change affects `Container.resolve`, the `ConstructionToken` path, and cached-instance handling.
3. **Build and test as ground truth.** Run `swift build` and `swift test`. Failures found by the compiler are findings too, but never report tests/build as your only review — the checklists below catch things they cannot.
4. **Review against the three checklists** in order: DI patterns, Apple platforms, general Swift.
5. **Report findings** in the format at the end. Confirm severity before claiming a bug: re-read the guarding code path before calling something a race or deadlock.

## Checklist 1 — Dependency-injection patterns

These are the repo's documented invariants. A change that weakens any of them is a blocker:

- **Lock discipline.** The container lock (`NSRecursiveLock`) must never be held while user code runs — factories and `initCompleted` callbacks. Flag any new code path that locks around a factory call, callback invocation, or other re-entrant user code.
- **Exactly-once construction.** A `.container`-scoped service must construct exactly once under concurrent first resolve, serialized per `ServiceKey` via `ConstructionToken` — not by the container lock. A slow factory for one type must never block resolving another type. Check that new resolve paths install, honor, and clean up tokens correctly (including on trap/throw/early-exit paths).
- **Cycle detection.** A thread that finds its *own* `ConstructionToken` has re-entered its own construction — that is a cycle, not a race — and must fall through so `pushResolutionStack` traps with the rendered chain. It must never wait on its own token (that deadlocks). New dependency traversal must keep the per-thread resolution stack accurate.
- **Transient is not serialized.** `.transient` resolves deliberately run the factory every time with no token gating. Do not "fix" races here; per-resolve construction is the contract.
- **Mid-construction replacement.** If a registration is replaced while its factory runs, the instance goes to its own caller but is never cached — it cannot outlive the registration. Verify identity comparison against the live registration stays intact (this is why `ServiceFactory` is `AnyObject`-constrained).
- **Main-actor factories.** `registerMainActor` runs inline on the main thread and traps off it on a cold resolve. `resolveAsync(_:)` is the only supported off-main path: it hops only when the registration needs one and nothing is cached yet. Do not reintroduce synchronous hops (`DispatchQueue.main.sync` deadlocked here historically). A warm off-main `resolve` handing a main-actor service to a background thread is the caller's responsibility — document, don't guard.
- **Caching and teardown semantics.** Re-registering a type evicts its cached instance; `unregister`/`removeAll` clear both factories and instances. `initCompleted` callbacks accumulate in registration order and run after the instance is cached, so a callback may resolve its own type without recursing. Preserve both.
- **API misuse in reviewed code (including tests and examples):** force-unwrapping `resolve(_:)` instead of using `resolveRequired(_:)`; registering concrete types where a protocol would give testability; capturing the container inside factories in a way that creates cycles; resolving inside `initCompleted` for types not yet registered; assuming resolve order across registrations.

## Checklist 2 — Apple platforms and concurrency

- **Deployment targets:** macOS 10.15, iOS 13, tvOS 13, watchOS 6 (`Package.swift`). Any API newer than those must be gated with `if #available` / `@available` with a working fallback, or the PR must explicitly justify raising a target.
- **Swift 6 strict concurrency.** The package builds under Swift 6 language mode. Check: `Sendable` conformance claims are real (flag unjustified `@unchecked Sendable` — `Container` has one, justified by full lock coverage; new ones need the same scrutiny); mutable shared state is lock- or actor-protected; closures crossing isolation boundaries are correctly annotated (`@Sendable`, `@MainActor`); no `nonisolated(unsafe)` without a written invariant.
- **Thread vs. task identity.** Code identifies the constructing thread via `ObjectIdentifier(Thread.current)`. New code comparing `Thread.current` must account for tasks hopping threads under structured concurrency — identity-by-thread breaks under an executor hop; prefer token/ownership objects where possible.
- **Main-actor correctness.** UI-adjacent work isolated correctly; no `MainActor.assumeIsolated` on paths that can genuinely run off-main; `await` hops only where needed (needless hops on hot resolve paths are worth flagging).
- **Foundation primitives.** `NSCondition` usage must lock before `wait()` and re-check the predicate in a `while` loop (spurious wakeups); `NSRecursiveLock` must be balanced; prefer `os_unfair_lock`/`NSLock` over `@synchronized`-style patterns; no busy-waiting.
- **Platform neutrality.** Sources must not import UIKit/AppKit/WatchKit; Foundation only. Watch for `DispatchQueue` misuse (sync on the current queue, priority inversion via sync hops).
- **Memory management.** Retain cycles in factories/callbacks capturing the container or resolver; cached `Any` instances keeping heavy graphs alive after `removeAll()`; delegates `weak` where ownership is inverted.

## Checklist 3 — General code and Swift review

- **Public API surface.** New `public` symbols need a reason, a doc comment, and naming consistent with existing style (`register`, `resolve`, `resolveRequired`, `resolveAsync`, `Scope`, `ServiceEntry`). Prefer internal until needed. Breaking changes to existing public signatures must be called out.
- **Doc comments.** Public API gets `///` docs; behavioral contracts (traps, caching, threading) are documented on the declaration, matching the existing voice — precise, no fluff.
- **Trapping behavior.** `preconditionFailure`/`fatalError` messages follow the `Zinject: ...` convention and describe what the caller did wrong and what to do instead. Traps are appropriate here for programmer errors, but each new trap must be documented.
- **Idiomatic Swift.** No force-unwraps (`!`) outside tests; `guard let` over `if let`-pyramids for early exit; value types where reference semantics aren't needed; `final` on non-subclassable classes; access control explicit; no `Any`/`AnyObject` where generics work.
- **Tests.** New behavior ships with tests using Swift Testing (`import Testing`, `@Test`). Concurrency changes need tests that actually exercise the race (many threads racing first resolve, e.g. via `TaskGroup` or `Thread`), not just single-threaded happy paths. Tests should assert the trap paths where feasible. Test classes A/B/C demonstrate chains and scoping — follow that style.
- **Comments.** Comments explain *why*, not *what*. Stale comments contradicting new behavior are findings.
- **No drive-by churn.** Formatting-only diffs, reordering, or unrelated refactors mixed into a functional change should be flagged as noise.

## Report format

Group findings by severity, most severe first:

- **Blocker** — breaks a documented invariant (lock discipline, exactly-once, cycle detection, mid-construction replacement), introduces a data race/deadlock, breaks a deployment target, or fails build/tests.
- **Should fix** — correctness risk, API-design problem, missing test for new concurrency behavior, undocumented trap or public symbol.
- **Nit** — naming, style, comment quality, minor idiom.

Each finding: `path/to/file.swift:LINE` — what's wrong, why it matters in this codebase, and a concrete suggested fix. Cite the invariant or checklist item being violated. End with the `swift build` / `swift test` results and a one-paragraph overall assessment. If something looks wrong but you can't confirm the guard against it, say so explicitly instead of asserting it.
