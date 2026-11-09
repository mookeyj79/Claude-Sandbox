# shellcheck shell=bash
# Runs `claude` inside a throwaway Docker Sandbox (sbx) instead of directly on the host.
# Works in Linux/macOS bash or zsh, and Git Bash on Windows.
#
# Install: add this line to ~/.bashrc (or ~/.zshrc):
#     source /path/to/claude-sandbox.sh
#
# Usage is unchanged: cd into a project and run `claude`, `claude --resume`, `claude "fix the bug"`, ...
#   - Every run gets a fresh sandbox that is deleted when Claude exits.
#   - Session history is saved on the host and restored into the next sandbox, so --resume works.
#   - Several windows (same or different folders) each get their own sandbox.
#   - On Windows, Git Bash and PowerShell share the same history store.
#
# Defaults (export to override; set to "" or "unset" to keep the sandbox's own default):
#   CLAUDE_SANDBOX_MODEL=opus  CLAUDE_SANDBOX_EFFORT=medium  CLAUDE_SANDBOX_PERMISSION_MODE=auto
#
# Earlier sessions from every project are mounted read-only so Claude can look things up in them.
#   CLAUDE_SANDBOX_SHARE_HISTORY=0   keep them out (this folder's own sessions are still restored)
#
# Escape hatches:
#   command claude ...        run the real Claude Code on the host
#   CLAUDE_NO_SANDBOX=1       make `claude` use the host
#
# Git Bash note: run it inside Windows Terminal (the old mintty window has no real console).

_CLAUDE_SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

_claude_sandbox_is_windows() {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac
}

# Host path in the form sbx expects (Windows: C:/Users/...).
_claude_sandbox_hostpath() {
    if _claude_sandbox_is_windows; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# ---- History store ------------------------------------------------------------------------
# Session history lives on the host, one folder per project, so --resume works across
# throwaway sandboxes. Callers only need: project_key, new_name, push_history, close.
# The sandbox name carries the project key, so a leftover sandbox can be traced to its folder.

_claude_sandbox_store_root() {
    if _claude_sandbox_is_windows; then
        printf '%s/claude-sandbox/history' "$(cygpath -u "$LOCALAPPDATA")"
    else
        printf '%s/claude-sandbox/history' "${XDG_DATA_HOME:-$HOME/.local/share}"
    fi
}

# Project key for a folder: claude-<leaf>-<hash>. On Windows, pass the Windows form of the path
# (`pwd -W`); it is normalized like the PowerShell wrapper does, so both share a history folder.
_claude_sandbox_project_key() {
    local norm="$1" hash leaf
    if _claude_sandbox_is_windows; then
        # shellcheck disable=SC1003  # '\\' is a literal backslash for tr, not an escaped quote
        # A-Z only (C locale), whatever tr would do with other capitals: the PowerShell wrapper matches.
        norm="$(printf '%s' "$norm" | tr '/' '\\' | LC_ALL=C tr '[:upper:]' '[:lower:]')"
        norm="${norm%\\}"
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        hash="$(printf '%s' "$norm" | sha256sum | cut -c1-8)"
    else
        hash="$(printf '%s' "$norm" | shasum -a 256 | cut -c1-8)"
    fi
    leaf="${norm##*[\\/]}"
    leaf="$(printf '%s' "$leaf" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//' | cut -c1-24 | sed -E 's/-+$//')"
    [ -n "$leaf" ] || leaf=root
    printf 'claude-%s-%s' "$leaf" "$hash"
}

# A fresh sandbox name for a project: <key>-<4 random chars>, so several windows can share a folder.
_claude_sandbox_new_name() {
    printf '%s-%s' "$1" "$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 4)"
}

# The project key a sandbox belongs to; fails if the sandbox isn't one of ours.
# (Names without the random part come from older versions of the wrappers.)
_claude_sandbox_project_of() {
    printf '%s' "$1" | grep -Eq '^claude-.+-[0-9a-f]{8}(-[a-z0-9]{4})?$' || return 1
    printf '%s' "$1" | sed -E 's/^(claude-.+-[0-9a-f]{8})(-[a-z0-9]{4})?$/\1/'
}

# Copy the project's saved history into a new sandbox, where sandbox-setup.sh restores it.
_claude_sandbox_push_history() {
    local store
    store="$(_claude_sandbox_store_root)/$(_claude_sandbox_project_of "$1")"
    mkdir -p "$store"
    sbx cp "$(_claude_sandbox_hostpath "$store")" "$1:/tmp/claude-hist" >/dev/null 2>&1
}

# Copy a sandbox's session history into the store for its project.
# Fails if anything went wrong. A missing projects/ folder counts as a failure: sandbox-setup.sh
# always creates it, so missing means the copy didn't work.
_claude_sandbox_save_history() {
    local sandbox="$1" store tmp failed=0
    store="$(_claude_sandbox_store_root)/$(_claude_sandbox_project_of "$sandbox")" || return 1
    tmp="$(mktemp -d)" || return 1
    mkdir -p "$store/projects"
    sbx cp "$sandbox:/home/agent/.claude/projects" "$(_claude_sandbox_hostpath "$tmp")/projects" >/dev/null 2>&1 || failed=1
    # Not checked: history.jsonl doesn't exist until the first prompt is typed.
    sbx cp "$sandbox:/home/agent/.claude/history.jsonl" "$(_claude_sandbox_hostpath "$tmp")/history.jsonl" >/dev/null 2>&1
    rm -rf "$tmp/projects/lost+found"
    if [ -d "$tmp/projects" ]; then
        cp -r "$tmp/projects/." "$store/projects/" || failed=1
    else
        failed=1
    fi
    if [ -f "$tmp/history.jsonl" ]; then
        cp "$tmp/history.jsonl" "$store/history.jsonl" || failed=1
    fi
    rm -rf "$tmp"
    return "$failed"
}

# Close a sandbox: save its history, then delete it. If the save fails the sandbox is kept,
# stopped, so the next run's sweep retries it; nothing is lost.
_claude_sandbox_close() {
    if _claude_sandbox_save_history "$1"; then
        sbx rm --force "$1" >/dev/null 2>&1
    else
        sbx stop "$1" >/dev/null 2>&1
        echo "claude-sandbox: WARNING: couldn't save history from $1, so the sandbox was kept. The next claude run will retry. To give up on it and delete it: sbx rm --force $1" >&2
        return 1
    fi
}

# Sweep: close sandboxes left behind (window closed, crash).
# Only *stopped* ones are touched; a running one may belong to another open window.
_claude_sandbox_sweep() {
    local name
    # `sbx ls` prints a table: SANDBOX AGENT STATUS PORTS WORKSPACE CREATED, where STATUS may
    # carry a dot first ("● running"). Name and status never contain spaces; the workspace can,
    # but it comes later. So the status is the 3rd or 4th word. (No --json here: that needs jq,
    # which isn't on stock macOS or Git Bash.)
    sbx ls 2>/dev/null | awk '$3 == "stopped" || $4 == "stopped" { print $1 }' | while read -r name; do
        _claude_sandbox_project_of "$name" >/dev/null || continue
        echo "claude-sandbox: cleaning up leftover sandbox $name" >&2
        _claude_sandbox_close "$name" || :   # kept and reported; retried next run
    done
}

# Run a command with a time limit in seconds, killing it if it overruns. Exit status is the
# command's (or the signal's, if killed). Portable: stock macOS has no `timeout`.
_claude_sandbox_with_limit() {
    local secs="$1" pid watcher rc
    shift
    "$@" &
    pid=$!
    # The watcher takes its sleep down with it, so nothing lingers once the command is done.
    # shellcheck disable=SC2016  # $s expands in the subshell, when the trap runs
    (
        trap 'kill "$s" 2>/dev/null; exit 0' TERM
        sleep "$secs" & s=$!
        wait "$s" && kill "$pid"
    ) >/dev/null 2>&1 &
    watcher=$!
    wait "$pid"
    rc=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    return "$rc"
}

# Skill sync: make sure every skill in this repo's skills/ is installed in sbx, and refresh
# installed skills at most once a day. Never stops Claude from starting: a failed or stuck
# install prints how to retry, and the next run tries again.
#   $1  folder holding skills/ (this repo)
# State in $HOME: .claude-sandbox-skills-added (installed skills, one per line) and
# .claude-sandbox-skills-updated (time of the last refresh).
_claude_sandbox_sync_skills() {
    local repo="$1" added="$HOME/.claude-sandbox-skills-added" stamp="$HOME/.claude-sandbox-skills-updated"
    local limit="${_CLAUDE_SANDBOX_SKILL_TIMEOUT:-120}" skill out rc

    # `sbx skills update` won't install new skills, only refresh installed ones, so a skill
    # added to the repo by `git pull` is installed here.
    for skill in "$repo"/skills/*/; do
        skill=$(basename "$skill")
        [ "$skill" = "*" ] && continue
        grep -qxF "$skill" "$added" 2>/dev/null && continue
        # One skill per call. If the skill is already installed (say, by an earlier manual
        # `sbx skills add`), sbx asks "Overwrite?" and, with no terminal to answer, fails with
        # "stdin is not a terminal". With a single named skill that question is the only one it
        # can ask, so the skill is there and counts as installed.
        out=$(_claude_sandbox_with_limit "$limit" sbx skills add mookeyj79/Claude-Sandbox --skill "$skill" </dev/null 2>&1)
        rc=$?
        if [ "$rc" -eq 0 ] || [[ "$out" == *"not a terminal"* ]]; then
            echo "$skill" >> "$added"
        else
            [ "$rc" -eq 143 ] && echo "claude-sandbox: installing skill $skill took over ${limit}s, skipped." >&2
            [ -n "$out" ] && echo "$out" >&2
            echo "claude-sandbox: couldn't install skill $skill, will retry next run. To try now: sbx skills add mookeyj79/Claude-Sandbox --skill $skill" >&2
        fi
    done

    if [ -z "$(find "$stamp" -mmin -1440 2>/dev/null)" ]; then
        date > "$stamp"
        (sbx skills update </dev/null >/dev/null 2>&1 &)
    fi
}

_claude_sandbox_main() {
    export MSYS_NO_PATHCONV=1   # Git Bash: don't rewrite "name:/tmp/..." arguments

    _claude_sandbox_sync_skills "$_CLAUDE_SANDBOX_DIR"
    _claude_sandbox_sweep

    local here name out
    if _claude_sandbox_is_windows; then here="$(pwd -W)"; else here="$PWD"; fi
    name="$(_claude_sandbox_new_name "$(_claude_sandbox_project_key "$here")")"

    # Read-only views of earlier sessions. sandbox-setup.sh tells Claude where they are.
    local mounts=()
    if [ "${CLAUDE_SANDBOX_SHARE_HISTORY:-1}" != "0" ]; then
        mounts+=("$(_claude_sandbox_hostpath "$(_claude_sandbox_store_root)"):/claude-history-sandbox:ro")
        [ -d "$HOME/.claude/projects" ] &&
            mounts+=("$(_claude_sandbox_hostpath "$HOME/.claude/projects"):/claude-history-host:ro")
    fi

    echo "claude-sandbox: starting $name" >&2
    if ! out="$(sbx create --name "$name" claude "$(_claude_sandbox_hostpath "$PWD")" "${mounts[@]}" 2>&1)"; then
        # Earlier sessions are a convenience: a bad mount shouldn't stop Claude from starting.
        [ "${#mounts[@]}" -gt 0 ] || { echo "$out" >&2; return 1; }
        echo "claude-sandbox: couldn't mount earlier sessions, starting without them: $out" >&2
        echo "claude-sandbox: these mounts need sbx 0.51.0 or newer. Check with: sbx version" >&2
        sbx rm --force "$name" >/dev/null 2>&1
        if ! out="$(sbx create --name "$name" claude "$(_claude_sandbox_hostpath "$PWD")" 2>&1)"; then
            echo "$out" >&2
            return 1
        fi
    fi

    # shellcheck disable=SC2064  # expand $name now: it's local and gone by the time the trap runs
    trap "echo 'claude-sandbox: saving history and removing $name' >&2; _claude_sandbox_close '$name'" EXIT
    trap 'exit 130' INT TERM HUP

    _claude_sandbox_push_history "$name"
    sbx cp "$(_claude_sandbox_hostpath "$_CLAUDE_SANDBOX_DIR/sandbox-setup.sh")" "$name:/tmp/claude-sandbox-setup.sh" >/dev/null 2>&1
    sbx cp "$(_claude_sandbox_hostpath "$_CLAUDE_SANDBOX_DIR/statusline.sh")" "$name:/tmp/claude-statusline.sh" >/dev/null 2>&1
    sbx exec "$name" bash /tmp/claude-sandbox-setup.sh \
        "${CLAUDE_SANDBOX_MODEL-opus}" "${CLAUDE_SANDBOX_EFFORT-medium}" "${CLAUDE_SANDBOX_PERMISSION_MODE-auto}"

    # `sbx exec`, not `sbx run`: run always adds --dangerously-skip-permissions, which overrides
    # the permission mode set in settings.json. exec runs exactly the command we give it.
    local tty=-i
    [ -t 0 ] && [ -t 1 ] && tty=-it
    sbx exec "$tty" "$name" claude "$@"
}

claude() {
    if [ "${CLAUDE_NO_SANDBOX:-}" = "1" ]; then
        command claude "$@"
        return
    fi
    if ! command -v sbx >/dev/null 2>&1; then
        echo "claude-sandbox: 'sbx' not found. See https://docs.docker.com/ai/sandboxes/install/ (or use: command claude)" >&2
        return 127
    fi
    # Subshell so the cleanup trap fires on exit / Ctrl+C without touching your shell.
    ( _claude_sandbox_main "$@" )
}
