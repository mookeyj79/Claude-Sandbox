#!/usr/bin/env bats
# The whole `claude` function, end to end against the fake sbx.

load helpers

setup() {
    setup_fake_sbx
    # Skill sync is covered in skill-sync.bats; keep it quiet here.
    { for s in "$REPO_ROOT"/skills/*/; do basename "$s"; done
      printf '%s\n' "${_CLAUDE_SANDBOX_SKILL_REPOS[@]}"; } > "$HOME/.claude-sandbox-skills-added"
    date > "$HOME/.claude-sandbox-skills-updated"
    project="$BATS_TEST_TMPDIR/My Project"
    mkdir -p "$project"
    cd "$project"
    key=$(_claude_sandbox_project_key "$project")
    store="$XDG_DATA_HOME/claude-sandbox/history/$key"
}

calls_matching() { sbx_calls | grep -E "$1" || true; }

@test "runs claude in a new sandbox, then saves history and deletes it" {
    mkdir -p "$store/projects/p"; echo s0 > "$store/projects/p/s0.jsonl"
    run claude --resume
    [ "$status" -eq 0 ]
    [[ "$(calls_matching '^create ')" == "create --name $key-"*" claude $project "* ]]
    [[ "$(calls_matching '^exec ')" == *"bash /tmp/claude-sandbox-setup.sh opus medium auto"* ]]
    [[ "$(calls_matching '^exec ')" == *" claude --resume" ]]
    [ -n "$(calls_matching "^cp .*/$key $key-[a-z0-9]{4}:/tmp/claude-hist\$")" ]
    [ -n "$(calls_matching "^rm --force $key-")" ]
    [ -z "$(ls "$FAKE_SBX_DIR/sandboxes")" ]
}

@test "model, effort and permission mode come from the environment" {
    CLAUDE_SANDBOX_MODEL=sonnet CLAUDE_SANDBOX_EFFORT= CLAUDE_SANDBOX_PERMISSION_MODE=bypassPermissions run claude
    [[ "$(calls_matching '^exec ')" == *"setup.sh sonnet  bypassPermissions"* ]]
}

@test "earlier sessions are mounted read-only unless turned off" {
    mkdir -p "$HOME/.claude/projects"
    run claude
    [[ "$(calls_matching '^create ')" == *":/claude-history-sandbox:ro "*":/claude-history-host:ro" ]]
    : > "$FAKE_SBX_DIR/calls"
    CLAUDE_SANDBOX_SHARE_HISTORY=0 run claude
    [[ "$(calls_matching '^create ')" != *"claude-history"* ]]
}

@test "starts without the mounts if sbx rejects them" {
    touch "$FAKE_SBX_DIR/create-fails-with-mounts"
    run claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"couldn't mount earlier sessions, starting without them"* ]]
    [ "$(calls_matching '^create ' | wc -l)" -eq 2 ]
    [ -n "$(calls_matching ' claude$')" ]
}

@test "keeps the sandbox when its history can't be saved" {
    # No setup run means no ~/.claude/projects in the sandbox, so the save fails.
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/sbx" <<EOF
#!/bin/sh
case "\$1 \$3" in "exec bash") exit 0 ;; esac
exec "$REPO_ROOT/tests/fake-sbx/sbx" "\$@"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/sbx"
    run claude
    [[ "$output" == *"so the sandbox was kept"* ]]
    name=$(ls "$FAKE_SBX_DIR/sandboxes")
    [ "$(cat "$FAKE_SBX_DIR/sandboxes/$name/status")" = stopped ]
}

@test "cleans up a leftover sandbox from an earlier window before starting" {
    make_sandbox "$key-old1" stopped
    sandbox_file "$key-old1" /home/agent/.claude/projects/p/s1.jsonl s
    run claude
    [[ "$output" == *"cleaning up leftover sandbox $key-old1"* ]]
    [ -f "$store/projects/p/s1.jsonl" ]
}

@test "CLAUDE_NO_SANDBOX runs the host claude" {
    mkdir -p "$BATS_TEST_TMPDIR/hostbin"
    printf '#!/bin/sh\necho "host claude $*"\n' > "$BATS_TEST_TMPDIR/hostbin/claude"
    chmod +x "$BATS_TEST_TMPDIR/hostbin/claude"
    PATH="$BATS_TEST_TMPDIR/hostbin:$PATH" CLAUDE_NO_SANDBOX=1 run claude -p hi
    [ "$output" = "host claude -p hi" ]
    [ -z "$(sbx_calls)" ]
}

@test "says which commit of the wrapper is running" {
    run claude
    [[ "$output" == *"claude-sandbox ($(git -C "$REPO_ROOT" rev-parse --short HEAD)): starting $key-"* ]]
}
