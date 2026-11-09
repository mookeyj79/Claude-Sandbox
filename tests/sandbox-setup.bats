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
