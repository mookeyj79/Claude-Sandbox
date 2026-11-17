## Agent skills

The docs below are shared from the AI-Environment Home Repo, one folder up (github.com/mookeyj79/AI-Environment).

### Issue tracker

Issues and specs live in this repo's GitHub Issues, managed with the `gh` CLI. See `../docs/agents/issue-tracker.md`.

### Triage labels

Uses the default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `../docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root, created only when needed. See `../docs/agents/domain.md`.

## Working on the wrappers

`claude-sandbox.sh` and `claude-sandbox.ps1` implement the same behaviour twice (`docs/adr/0001-two-wrappers-not-one-launcher.md`). Run `tests/check.sh` before committing; PowerShell is tested only in CI. `sbx` isn't available in the sandbox: its real behaviour is in `docs/sbx-cli.md`, and the tests use `tests/fake-sbx`.

## Skills

Skills live in `skills/<name>/SKILL.md`. A skill that tidies one kind of repo artifact is named `clean-<thing>` (`clean-git`, `clean-repo`, `clean-docs`).
