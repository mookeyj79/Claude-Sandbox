#!/usr/bin/env bash
# The repo's checks, the same ones CI runs. From the repo root:
#   tests/check.sh          lint, then tests
#   tests/check.sh lint     ShellCheck, plus .ps1 files must be ASCII
#   tests/check.sh test     bats
# PowerShell (Pester, PSScriptAnalyzer) runs only in CI, on Windows.
set -u
cd "$(dirname "$0")/.." || exit 1
what="${1:-all}"

need() {
    command -v "$1" >/dev/null 2>&1 && return 0
    if command -v apt-get >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        echo "check: installing $1" >&2
        { sudo apt-get install -y "$1" || { sudo apt-get update && sudo apt-get install -y "$1"; }; } >/dev/null 2>&1
    fi
    command -v "$1" >/dev/null 2>&1 || { echo "check: $1 is missing; install it first" >&2; exit 1; }
}

lint() {
    need shellcheck
    shellcheck -x claude-sandbox.sh sandbox-setup.sh statusline.sh tests/helpers.bash tests/check.sh .githooks/pre-commit || return 1
    # Windows PowerShell 5.1 reads a .ps1 without a BOM as ANSI, so any non-ASCII byte is garbled.
    if LC_ALL=C grep -n "$(printf '[\200-\377]')" ./*.ps1 tests/*.ps1; then
        echo "check: the lines above have non-ASCII characters; .ps1 files must be ASCII" >&2
        return 1
    fi
}

tests() {
    need bats
    bats tests/
}

case "$what" in
    lint) lint ;;
    test) tests ;;
    all)  lint && tests ;;
    *)    echo "usage: tests/check.sh [lint|test]" >&2; exit 2 ;;
esac
