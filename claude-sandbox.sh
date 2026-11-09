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
# Defaults (export to override; set to "" to keep the sandbox's own default):
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

_claude_sandbox_store_root() {
    if _claude_sandbox_is_windows; then
        printf '%s/claude-sandbox/history' "$(cygpath -u "$LOCALAPPDATA")"
    else
        printf '%s/claude-sandbox/history' "${XDG_DATA_HOME:-$HOME/.local/share}"
    fi
}

_claude_sandbox_name() {
    local norm hash leaf
    if _claude_sandbox_is_windows; then
        # Match the PowerShell wrapper: Windows path, backslashes, lowercase.
        norm="$(pwd -W | tr '/' '\\' | tr '[:upper:]' '[:lower:]')"
        norm="${norm%\\}"
    else
        norm="$PWD"
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

# Copy a sandbox's session history into the host store for its project.
# Returns non-zero if anything went wrong, in which case the sandbox must not be deleted.
_claude_sandbox_save() {
    local sandbox="$1" base="$2" store tmp failed=0
    store="$(_claude_sandbox_store_root)/$base"
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

_claude_sandbox_warn_kept() {
    echo "claude-sandbox: WARNING: couldn't save history from $1, so the sandbox was kept. The next claude run will retry. To give up on it and delete it: sbx rm --force $1" >&2
}

# Sandboxes left behind (window closed, crash): save their history, then delete them.
# A sandbox whose save fails stays stopped, so the next run retries it.
# Only *stopped* ones are touched; a running one may belong to another open window.
_claude_sandbox_sweep() {
    local name
    sbx ls 2>/dev/null | awk 'NR > 1 && $4 == "stopped" { print $1 }' | while read -r name; do
        if printf '%s' "$name" | grep -Eq '^claude-.+-[0-9a-f]{8}(-[a-z0-9]{4})?$'; then
            echo "claude-sandbox: cleaning up leftover sandbox $name" >&2
            if _claude_sandbox_save "$name" "$(printf '%s' "$name" | sed -E 's/^(claude-.+-[0-9a-f]{8})(-[a-z0-9]{4})?$/\1/')"; then
                sbx rm --force "$name" >/dev/null 2>&1
            else
                _claude_sandbox_warn_kept "$name"
            fi
        fi
    done
}

_claude_sandbox_main() {
    export MSYS_NO_PATHCONV=1   # Git Bash: don't rewrite "name:/tmp/..." arguments

    # Install this repo's skills (skills/) that aren't installed yet, so a skill added to the
    # repo is picked up after `git pull`. The marker lists the installed skills, one per line.
    # `sbx skills update` won't do this: it only refreshes skills that are already installed.
    # Retried on the next run if it fails.
    local added="$HOME/.claude-sandbox-skills-added"
    local missing=() skill
    for skill in "$_CLAUDE_SANDBOX_DIR"/skills/*/; do
        skill=$(basename "$skill")
        [ "$skill" = "*" ] && continue
        grep -qxF "$skill" "$added" 2>/dev/null || missing+=("$skill")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "claude-sandbox: installing skills from mookeyj79/Claude-Sandbox: ${missing[*]}" >&2
        # A time limit, so a stuck install can't keep Claude from starting.
        local limit=""
        command -v timeout >/dev/null 2>&1 && limit="timeout 120"
        local out
        # One skill per call. If the skill is already installed (say, by an earlier manual
        # `sbx skills add`), sbx asks "Overwrite?" and, with no terminal to answer, fails with
        # "stdin is not a terminal". With a single named skill that question is the only one it
        # can ask, so the skill is there and counts as installed.
        for skill in "${missing[@]}"; do
            if out=$($limit sbx skills add mookeyj79/Claude-Sandbox --skill "$skill" </dev/null 2>&1) ||
               [[ "$out" == *"not a terminal"* ]]; then
                echo "$skill" >> "$added"
            else
                [ -n "$out" ] && echo "$out" >&2
                echo "claude-sandbox: couldn't install skill $skill, will retry next run. To try now: sbx skills add mookeyj79/Claude-Sandbox --skill $skill" >&2
            fi
        done
    fi

    # Refresh skills added with `sbx skills add` at most once a day, in the background.
    local stamp="$HOME/.claude-sandbox-skills-updated"
    if [ -z "$(find "$stamp" -mmin -1440 2>/dev/null)" ]; then
        date > "$stamp"
        (sbx skills update </dev/null >/dev/null 2>&1 &)
    fi

    _claude_sandbox_sweep

    local base name store out
    base="$(_claude_sandbox_name)"
    name="$base-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 4)"
    store="$(_claude_sandbox_store_root)/$base"
    mkdir -p "$store"

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

    trap '
        echo "claude-sandbox: saving history and removing '"$name"'" >&2
        if _claude_sandbox_save "'"$name"'" "'"$base"'"; then
            sbx rm --force "'"$name"'" >/dev/null 2>&1
        else
            # Stopped, not left running: the sweep only retries stopped sandboxes.
            sbx stop "'"$name"'" >/dev/null 2>&1
            _claude_sandbox_warn_kept "'"$name"'"
        fi
    ' EXIT
    trap 'exit 130' INT TERM HUP

    sbx cp "$(_claude_sandbox_hostpath "$store")" "$name:/tmp/claude-hist" >/dev/null 2>&1
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
