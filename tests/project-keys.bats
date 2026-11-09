#!/usr/bin/env bats
# The bash wrapper (as under Git Bash) gives the project keys in project-keys.tsv.
# tests/project-keys.Tests.ps1 checks the PowerShell wrapper against the same file.

load helpers

setup() {
    setup_fake_sbx
    _claude_sandbox_is_windows() { return 0; }
}

@test "project keys match the shared table" {
    local path want got bad=0
    while IFS=$'\t' read -r path want; do
        case "$path" in '#'*|'') continue ;; esac
        got=$(_claude_sandbox_project_key "$path")
        [ "$got" = "$want" ] || { echo "$path: got $got, want $want"; bad=1; }
    done < "$REPO_ROOT/tests/project-keys.tsv"
    [ "$bad" -eq 0 ]
}
