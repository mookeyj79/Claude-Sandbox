# Work that can run inside the sandbox lives in sandbox/, not in both wrappers

When a launch step could run either on the host (in both wrappers) or inside the sandbox, it goes in `sandbox/setup.sh`. The wrappers prepare a sandbox in one step: copy `sandbox/` and the project's history into the staging folder (`/tmp/claude-sandbox`), run setup, and stop if anything failed. That staging path is the only thing the two sides share. Setup finds everything else relative to itself and owns the policy: the default model, effort and permission mode, and the tooling to install. ADR 0001 keeps two wrappers, so every step in them is written twice; a step in `sandbox/` is written once, in bash, and tested once in `tests/setup.bats`.

## Considered Options

- **Separate `sbx cp` per file, each with its own path in the sandbox.** What we had: five paths known to both wrappers, setup and the fake `sbx`, and no check that setup ran. Two broken tooling installs went unnoticed until checked by hand.

## Consequences

The wrappers pass the user's settings through unchanged: `-` for not set, `=value` for set (`=` for set but empty). Steps that must happen on the host stay in the wrappers: creating the sandbox and its mounts, and copying history out on close (its `lost+found` cleanup applies to the host copy).
