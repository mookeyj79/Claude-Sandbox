# Shared setup for the bash wrapper tests: a fake sbx on PATH, and a throwaway HOME.
# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

setup_fake_sbx() {
    export FAKE_SBX_DIR="$BATS_TEST_TMPDIR/sbx"
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_DATA_HOME="$HOME/.local/share"
    mkdir -p "$FAKE_SBX_DIR" "$HOME"
    : > "$FAKE_SBX_DIR/calls"
    PATH="$REPO_ROOT/tests/fake-sbx:$PATH"
    # shellcheck source=claude-sandbox.sh  # paths are from the repo root, where CI runs
    source "$REPO_ROOT/claude-sandbox.sh"
}

# The sbx calls made so far, one per line, arguments joined by spaces.
sbx_calls() {
    python3 -c 'import json,sys
for line in open(sys.argv[1]): print(" ".join(json.loads(line)))' "$FAKE_SBX_DIR/calls"
}

# A sandbox in the fake, with a status and optional files: make_sandbox <name> <status>
make_sandbox() {
    mkdir -p "$FAKE_SBX_DIR/sandboxes/$1/fs"
    printf '%s' "$2" > "$FAKE_SBX_DIR/sandboxes/$1/status"
}

# Write a file inside a fake sandbox: sandbox_file <name> <path> <content>
sandbox_file() {
    local f="$FAKE_SBX_DIR/sandboxes/$1/fs/${2#/}"
    mkdir -p "$(dirname "$f")"
    printf '%s' "$3" > "$f"
}
