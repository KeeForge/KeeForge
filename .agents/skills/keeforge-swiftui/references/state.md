# State, navigation, and concurrency

- Identify the source of truth before changing wrappers. Use `@State` for view-owned state and `@Bindable` or environment access for observable state supplied by an owner. Avoid a second state copy merely to simplify a binding.
- Custom `Binding(get:set:)` can enforce validation, adapt types, route intents, or perform dismissal cleanup. Trace the setter before suggesting a projected binding or `onChange`: rejecting a write synchronously and reacting after mutation are different contracts.
- Keep business rules in testable view models/services and local presentation state in the view. Preserve the existing session, draft, save, and lock owners. Do not reorganize unrelated code to fit a generic architecture preference.
- Check `@Observable` UI state for appropriate main-actor isolation, and check shared mutable state for isolation or synchronization. Do not add `@MainActor` mechanically to domain or worker types, or move crypto/parsing onto it to quiet diagnostics.
- Prefer structured async work and view-scoped `task` when cancellation should follow disappearance. Inspect whether work must outlive a view before replacing a task. `Task {}` can inherit main-actor isolation; it does not by itself move expensive work off-main.
- Evaluate detached tasks and dispatch calls against their actual executor, cancellation, ordering, and lifetime requirements. Preserve deliberate off-main work and platform callback deferral unless an equivalent replacement is established. Check stale async completions against session/lock changes.
- Use the existing navigation model for the relevant shell. Check destination registration and state identity; do not convert every `NavigationLink(destination:)` without examining its hierarchy.
- Prefer item-driven presentation when the item is the source of truth. Preserve dismissal side effects, unsaved-edit handling, and single presentation-host constraints when changing sheet or alert bindings.
- Presentation modifiers must belong to a host that remains mounted and can present on that platform. Trace a row-triggered alert or confirmation through its container; do not relocate it solely for an animation preference.

SwiftData and CloudKit guidance is not part of this skill: KeeForge's persistence and interoperability contracts come from its own model/service documentation.
