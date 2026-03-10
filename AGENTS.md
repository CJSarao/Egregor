## Spec Sync Policy

`specs.md` is the source of truth for product behavior, intended UX, and operational assumptions.
`tasks.md` is a derived execution plan.

When implementation, tasks, README text, tests, or UI copy introduce behavior that is not reflected in `specs.md`, the agent must update `specs.md` in the same change or explicitly call out the mismatch as a blocker.

Agents must not leave durable spec drift behind.
If a task adds, removes, or materially changes user-visible behavior, acceptance criteria, or operational assumptions, reconcile:
- `specs.md`
- `tasks.md`
- relevant README or UI copy
- tests covering the changed behavior

Tests are proof of the spec, not proof of whatever the code currently does.
If tests, implementation, and `specs.md` disagree, resolve the disagreement instead of silently preserving drift.

If the intended behavior is unclear, stop and surface the ambiguity rather than inventing a new spec implicitly.
