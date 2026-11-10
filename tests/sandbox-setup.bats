#!/usr/bin/env bats
# sandbox-setup.sh applies the defaults the wrappers pass in.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.claude" "$BATS_TEST_TMPDIR/bin"
    # Stand-in for `claude update`.
    printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/claude"
    chmod +x "$BATS_TEST_TMPDIR/bin/claude"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    echo '{"model":"keep-me","effortLevel":"high","permissions":{"defaultMode":"bypassPermissions"}}' > "$HOME/.claude/settings.json"
}

setting() { jq -r "$1" "$HOME/.claude/settings.json"; }

@test "sets model, effort and permission mode" {
    bash "$REPO_ROOT/sandbox-setup.sh" sonnet low plan 2>/dev/null
    [ "$(setting .model)" = sonnet ]
    [ "$(setting .effortLevel)" = low ]
    [ "$(setting .permissions.defaultMode)" = plan ]
}

@test "empty or 'unset' leaves a setting as the sandbox has it" {
    bash "$REPO_ROOT/sandbox-setup.sh" unset "" unset 2>/dev/null
    [ "$(setting .model)" = keep-me ]
    [ "$(setting .effortLevel)" = high ]
    [ "$(setting .permissions.defaultMode)" = bypassPermissions ]
}

@test "'default' is a real permission mode, not 'leave as is'" {
    bash "$REPO_ROOT/sandbox-setup.sh" unset unset default 2>/dev/null
    [ "$(setting .permissions.defaultMode)" = default ]
}

@test "drops the image's second copy of the shell-completions warning" {
    cat > "$HOME/.claude/CLAUDE.md" <<'MD'
<!-- sbx:guidance start -->
## Critical: Shell Completions Must NOT Be in the Persistent Environment File
first copy
## Environment Persistence
kept
### Shell Completions Must NOT Be in CLAUDE_ENV_FILE
second copy
#### WRONG - Will Break Bash
```bash
# DO NOT ADD THESE
```
dropped too
<!-- sbx:guidance end -->
MD
    bash "$REPO_ROOT/sandbox-setup.sh" unset unset unset 2>/dev/null
    run cat "$HOME/.claude/CLAUDE.md"
    [[ "$output" == *"first copy"* ]]
    [[ "$output" == *"kept"* ]]
    [[ "$output" != *"second copy"* ]]
    [[ "$output" != *"dropped too"* ]]
    [[ "$output" == *"<!-- sbx:guidance end -->"* ]]
}

@test "keeps the CLAUDE_ENV_FILE warning when it's the only copy" {
    printf '%s\n' '### Shell Completions Must NOT Be in CLAUDE_ENV_FILE' 'only copy' > "$HOME/.claude/CLAUDE.md"
    bash "$REPO_ROOT/sandbox-setup.sh" unset unset unset 2>/dev/null
    grep -q 'only copy' "$HOME/.claude/CLAUDE.md"
}
