#!/usr/bin/env bats
# sandbox-setup.sh applies the defaults the wrappers pass in.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.claude" "$BATS_TEST_TMPDIR/bin"
    # Stand-in for `claude update`.
    printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/claude"
    chmod +x "$BATS_TEST_TMPDIR/bin/claude"
    # Chromium and PowerShell already present, so the background install is skipped.
    for t in chromium pwsh; do printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/$t"; chmod +x "$BATS_TEST_TMPDIR/bin/$t"; done
    export CLAUDE_SANDBOX_TOOLS_DIR="$BATS_TEST_TMPDIR/tools"
    mkdir -p "$CLAUDE_SANDBOX_TOOLS_DIR"
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

# Stands in for sudo (logging each command), apt-cache and curl; $1 is the step that fails, if any:
# chromium (the apt install) or powershell (the release download).
stub_installer() {
    # sandbox-setup.sh runs only inside the (Linux) sandbox; macOS has neither of these.
    command -v flock >/dev/null && command -v setsid >/dev/null || skip "needs flock and setsid (Linux)"
    rm "$BATS_TEST_TMPDIR/bin/chromium" "$BATS_TEST_TMPDIR/bin/pwsh"
    # A PATH holding only what the script needs, so a real chromium or pwsh on this machine is hidden.
    local sys="$BATS_TEST_TMPDIR/sys" cmd
    mkdir -p "$sys"
    for cmd in bash sh awk cat chmod cp env flock grep jq mkdir mv nohup rm sed setsid sleep sort tail timeout uname; do
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

wait_for_tools() { flock "$CLAUDE_SANDBOX_TOOLS_DIR/claude-sandbox-tools.lock" cat "$CLAUDE_SANDBOX_TOOLS_DIR/claude-sandbox-tools.done"; }

@test "installs Chromium and PowerShell in the background and tells Claude how to wait" {
    stub_installer
    bash "$REPO_ROOT/sandbox-setup.sh" unset unset unset 2>/dev/null
    grep -q "flock $CLAUDE_SANDBOX_TOOLS_DIR/claude-sandbox-tools.lock" "$HOME/.claude/CLAUDE.md"
    [ "$(wait_for_tools)" = "exit status 0" ]
    grep -q '^apt-get update$' "$BATS_TEST_TMPDIR/sudo.log"
    grep -q 'install -y --no-install-recommends chromium libicu76$' "$BATS_TEST_TMPDIR/sudo.log"
    grep -q 'releases/download/v7.7.0/powershell-7.7.0-linux-' "$BATS_TEST_TMPDIR/curl.log"
    grep -q '^ln -sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh$' "$BATS_TEST_TMPDIR/sudo.log"
}

@test "a failed PowerShell download still installs Chromium and reports the failure" {
    stub_installer powershell
    bash "$REPO_ROOT/sandbox-setup.sh" unset unset unset 2>/dev/null
    [ "$(wait_for_tools)" = "exit status 1: failed to install: powershell" ]
    grep -q 'install -y --no-install-recommends chromium' "$BATS_TEST_TMPDIR/sudo.log"
}

@test "a failed Chromium install still installs PowerShell and reports the failure" {
    stub_installer chromium
    bash "$REPO_ROOT/sandbox-setup.sh" unset unset unset 2>/dev/null
    [ "$(wait_for_tools)" = "exit status 1: failed to install: chromium" ]
    grep -q '/usr/bin/pwsh$' "$BATS_TEST_TMPDIR/sudo.log"
}

@test "skips the install when both are already there" {
    bash "$REPO_ROOT/sandbox-setup.sh" unset unset unset 2>/dev/null
    [ ! -e "$CLAUDE_SANDBOX_TOOLS_DIR/claude-sandbox-tools.lock" ]
    ! grep -qs 'Chromium and PowerShell' "$HOME/.claude/CLAUDE.md"
}
