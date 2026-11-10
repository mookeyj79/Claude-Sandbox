# Coding standards

Read during review. Mechanical rules (ShellCheck, PSScriptAnalyzer, ASCII-only `.ps1`) are enforced by `tests/check.sh` and CI, so they're not repeated here.

## Wrapper parity

A behaviour change to one wrapper lands in the other in the same change, with a matching test on each side: bats in `tests/*.bats`, Pester in `tests/*.Tests.ps1`. A change to only one wrapper is a finding, unless the behaviour is platform-specific and the diff says why. See `docs/adr/0001-two-wrappers-not-one-launcher.md`.

## Real `sbx`, not guessed `sbx`

A new `sbx` call, flag, or parsed piece of `sbx` output must match `docs/sbx-cli.md`. If the doc doesn't cover it, the change adds the real output to the doc, from the user running it on the host, and teaches `tests/fake-sbx/sbx` the same behaviour. Calls that run with no terminal pass `--no-input` where `sbx` accepts it, so a prompt fails fast instead of hanging.

## Messages users paste back

Warnings and errors start with the tag that carries the wrapper's commit (`$_CLAUDE_SANDBOX_TAG` / `$script:ClaudeSandboxTag`), and say how to retry or undo by hand.
