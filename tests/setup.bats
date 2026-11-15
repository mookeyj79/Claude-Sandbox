#!/usr/bin/env bats
# sandbox/setup.sh, run as the wrappers run it: from a staged copy of sandbox/, with the
# project's history in history/ beside it.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home"
    # Earlier-session mounts appear under here; none unless a test makes them.
    export CLAUDE_SANDBOX_MOUNT_ROOT="$BATS_TEST_TMPDIR/mounts"
    stage="$BATS_TEST_TMPDIR/stage"
    cp -r "$REPO_ROOT/sandbox" "$stage"
    mkdir -p "$HOME/.claude" "$BATS_TEST_TMPDIR/bin" "$stage/history"
    # sbx cp leaves the staging folder owned by root: setup mustn't need to write there.
    chmod a-w "$stage"
    # Stand-in for `claude update`.
    printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/claude"
    chmod +x "$BATS_TEST_TMPDIR/bin/claude"
    # Chromium and PowerShell already present, so the background install is skipped.
    for t in chromium pwsh; do printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/$t"; chmod +x "$BATS_TEST_TMPDIR/bin/$t"; done
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    echo '{"model":"keep-me","effortLevel":"high","permissions":{"defaultMode":"bypassPermissions"}}' > "$HOME/.claude/settings.json"
}

teardown() { chmod -R u+w "$stage"; }

setting() { jq -r "$1" "$HOME/.claude/settings.json"; }
run_setup() { bash "$stage/setup.sh" "$@"; }

@test "sets model, effort and permission mode" {
    run_setup =sonnet =low =plan 2>/dev/null
    [ "$(setting .model)" = sonnet ]
    [ "$(setting .effortLevel)" = low ]
    [ "$(setting .permissions.defaultMode)" = plan ]
}

@test "set-but-empty or 'unset' leaves a setting as the sandbox has it" {
    run_setup =unset = =unset 2>/dev/null
    [ "$(setting .model)" = keep-me ]
    [ "$(setting .effortLevel)" = high ]
    [ "$(setting .permissions.defaultMode)" = bypassPermissions ]
}

@test "'default' is a real permission mode, not 'leave as is'" {
    run_setup = = =default 2>/dev/null
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
    run_setup = = = 2>/dev/null
    run cat "$HOME/.claude/CLAUDE.md"
    [[ "$output" == *"first copy"* ]]
    [[ "$output" == *"kept"* ]]
    [[ "$output" != *"second copy"* ]]
    [[ "$output" != *"dropped too"* ]]
    [[ "$output" == *"<!-- sbx:guidance end -->"* ]]
}

@test "keeps the CLAUDE_ENV_FILE warning when it's the only copy" {
    printf '%s\n' '### Shell Completions Must NOT Be in CLAUDE_ENV_FILE' 'only copy' > "$HOME/.claude/CLAUDE.md"
    run_setup = = = 2>/dev/null
    grep -q 'only copy' "$HOME/.claude/CLAUDE.md"
}

# Stands in for sudo (logging each command), apt-cache and curl; $1 is the step that fails, if any:
# chromium (the apt install) or powershell (the release download).
stub_installer() {
    # setup.sh runs only inside the (Linux) sandbox.
    [ "$(uname -s)" = Linux ] || skip "Linux only"
    rm "$BATS_TEST_TMPDIR/bin/chromium" "$BATS_TEST_TMPDIR/bin/pwsh"
    # A PATH holding only what the script needs, so a real chromium or pwsh on this machine is hidden.
    local sys="$BATS_TEST_TMPDIR/sys" cmd
    mkdir -p "$sys"
    for cmd in bash sh awk cat chmod cp dirname env grep jq mkdir mv rm sed seq sleep sort tail tee timeout uname; do
        ln -s "$(command -v "$cmd")" "$sys/$cmd"
    done
    PATH="$BATS_TEST_TMPDIR/bin:$sys"
    local fail="${1:-none}"
    cat > "$BATS_TEST_TMPDIR/bin/sudo" <<SH
#!/bin/sh
echo "\$*" >> "$BATS_TEST_TMPDIR/sudo.log"
case "\$*" in *"apt-get install"*" $fail"*) exit 1 ;; esac
exit 0
SH
    printf '#!/bin/sh\nprintf "libicu-dev\\nlibicu74\\nlibicu76\\n"\n' > "$BATS_TEST_TMPDIR/bin/apt-cache"
    cat > "$BATS_TEST_TMPDIR/bin/curl" <<SH
#!/bin/sh
echo "\$*" >> "$BATS_TEST_TMPDIR/curl.log"
case "\$*" in
    *-fsSI*) echo "location: https://github.com/PowerShell/PowerShell/releases/tag/v7.7.0" ;;
    *) [ "$fail" != powershell ] ;;
esac
SH
    chmod +x "$BATS_TEST_TMPDIR/bin/sudo" "$BATS_TEST_TMPDIR/bin/apt-cache" "$BATS_TEST_TMPDIR/bin/curl"
}

tools_result() { tail -n 1 "$HOME/.cache/claude-sandbox/tools.log"; }

@test "installs Chromium and PowerShell before returning" {
    stub_installer
    run run_setup = = =
    [ "$(tools_result)" = "exit status 0" ]
    [[ "$output" != *WARNING* ]]
    grep -q '^apt-get update$' "$BATS_TEST_TMPDIR/sudo.log"
    grep -q 'install -y --no-install-recommends -o DPkg::Lock::Timeout=300 chromium libicu76$' "$BATS_TEST_TMPDIR/sudo.log"
    grep -q 'releases/download/v7.7.0/powershell-7.7.0-linux-' "$BATS_TEST_TMPDIR/curl.log"
    grep -q '^ln -sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh$' "$BATS_TEST_TMPDIR/sudo.log"
}

@test "a failed PowerShell download still installs Chromium and warns how to retry" {
    stub_installer powershell
    run run_setup = = =
    [[ "$output" == *"WARNING: failed to install: powershell"*"To retry: bash $stage/setup.sh --install-tools"* ]]
    grep -q 'chromium libicu76$' "$BATS_TEST_TMPDIR/sudo.log"
}

@test "a failed Chromium install still installs PowerShell and warns" {
    stub_installer chromium
    run run_setup = = =
    [[ "$output" == *"WARNING: failed to install: chromium"* ]]
    grep -q '/usr/bin/pwsh$' "$BATS_TEST_TMPDIR/sudo.log"
}

@test "retries apt-get update while another apt holds the lock" {
    stub_installer
    # The first two updates fail, as when the sandbox's own startup apt-get holds the lock.
    printf '#!/bin/sh\nn=$(cat "%s/n" 2>/dev/null || echo 0); echo $((n+1)) > "%s/n"; [ "$n" -ge 2 ]\n' \
        "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/apt-get-real"
    sed -i 's|^exit 0$|case "$*" in "apt-get update") exec sh '"$BATS_TEST_TMPDIR"'/apt-get-real ;; esac; exit 0|' "$BATS_TEST_TMPDIR/bin/sudo"
    printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/sleep"; chmod +x "$BATS_TEST_TMPDIR/bin/sleep"
    run run_setup = = =
    [ "$(tools_result)" = "exit status 0" ]
    [ "$(grep -c '^apt-get update$' "$BATS_TEST_TMPDIR/sudo.log")" = 3 ]
}

@test "skips the install when both are already there" {
    run_setup = = = 2>/dev/null
    [ ! -e "$HOME/.cache/claude-sandbox/tools.log" ]
}

@test "not set: the defaults, opus, medium and auto" {
    run_setup - - - 2>/dev/null
    [ "$(setting .model)" = opus ]
    [ "$(setting .effortLevel)" = medium ]
    [ "$(setting .permissions.defaultMode)" = auto ]
}

@test "a setting in an unknown form fails setup instead of being guessed at" {
    run run_setup sonnet - -
    [ "$status" -ne 0 ]
    [[ "$output" == *"bad setting 'sonnet'"* ]]
    [ "$(setting .model)" = keep-me ]
}

@test "restores the project's sessions and prompt history" {
    mkdir -p "$stage/history/projects/p"
    echo s1 > "$stage/history/projects/p/s1.jsonl"
    echo '{"display":"hi"}' > "$stage/history/history.jsonl"
    run_setup = = = 2>/dev/null
    [ "$(cat "$HOME/.claude/projects/p/s1.jsonl")" = s1 ]
    [ "$(cat "$HOME/.claude/history.jsonl")" = '{"display":"hi"}' ]
}

@test "always creates projects/, even with no history yet" {
    chmod u+w "$stage"; rm -rf "$stage/history"; chmod a-w "$stage"
    run_setup = = = 2>/dev/null
    [ -d "$HOME/.claude/projects" ]
}

@test "fails if the history can't be restored" {
    mkdir -p "$stage/history/projects"
    echo s > "$stage/history/projects/s.jsonl"
    chmod 000 "$stage/history/projects/s.jsonl"
    [ "$(id -u)" != 0 ] || skip "root can read anything"
    run run_setup = = =
    chmod 644 "$stage/history/projects/s.jsonl"
    [ "$status" -ne 0 ]
    [[ "$output" == *"couldn't restore session history"* ]]
}

@test "installs the status line and points settings at it" {
    run_setup = = = 2>/dev/null
    cmp "$REPO_ROOT/sandbox/statusline.sh" "$HOME/.claude/statusline.sh"
    [ "$(setting .statusLine.command)" = "bash $HOME/.claude/statusline.sh" ]
}

@test "tells Claude about whichever earlier-session mounts exist" {
    mkdir -p "$CLAUDE_SANDBOX_MOUNT_ROOT/claude-history-sandbox"
    run_setup = = = 2>/dev/null
    grep -q '^# Earlier Claude sessions$' "$HOME/.claude/CLAUDE.md"
    grep -q "$CLAUDE_SANDBOX_MOUNT_ROOT/claude-history-sandbox/<project>" "$HOME/.claude/CLAUDE.md"
    ! grep -q 'claude-history-host' "$HOME/.claude/CLAUDE.md"
}

@test "no earlier-session mounts: no note" {
    run_setup = = = 2>/dev/null
    ! grep -qs 'Earlier Claude sessions' "$HOME/.claude/CLAUDE.md"
}
