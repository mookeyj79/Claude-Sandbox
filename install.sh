#!/usr/bin/env bash
# =============================================================================
#  install.sh: the install for Debian 13+ and Ubuntu 24.04+ (see GLOSSARY.md).
#
#    curl -fsSL https://raw.githubusercontent.com/mookeyj79/Claude-Sandbox/main/install.sh | bash
#
#  or from a clone: bash install.sh
#
#    1. KVM: /dev/kvm must exist; adds you to the kvm group when you aren't in it
#    2. tools with apt: git, curl, gh (from GitHub's repository; the distro's is
#       too old), sbx (Docker's repository on Ubuntu, the release .deb on Debian)
#    3. the clone: the one this script runs from, else CLAUDE_SANDBOX_DIR
#       (default ~/Claude-Sandbox), cloned when absent, fast-forwarded when not
#    4. sign-ins: gh auth login and sbx login, each only when not signed in
#    5. sandbox settings: sbx policy init balanced when there is no global
#       policy yet, and the github secret as the command 'gh auth token'
#    6. the wrapper in new shells: a marked block in Nowhere's local override
#       (~/.config/nowhere/local.zsh, with a 'goto cs' bookmark) when Nowhere is
#       bootstrapped, else in ~/.zshrc or ~/.bashrc, for your login shell
#       (docs/adr/0003-install-is-nowhere-aware-not-nowhere-dependent.md)
#
#  Safe to re-run: a step that is already done is skipped, and the block is
#  rewritten in place. Steps 4 and 5 never stop the install: what they couldn't
#  do is listed at the end, with the commands to run.
#
#  CLAUDE_SANDBOX_REPO points it at another remote. The tests move the system
#  paths it reads with CLAUDE_SANDBOX_OS_RELEASE (/etc/os-release),
#  CLAUDE_SANDBOX_KVM (/dev/kvm), CLAUDE_SANDBOX_APT_DIR (/etc/apt) and
#  CLAUDE_SANDBOX_TTY (/dev/tty).
# =============================================================================
set -euo pipefail

TAG="claude-sandbox install"
REPO=${CLAUDE_SANDBOX_REPO:-https://github.com/mookeyj79/Claude-Sandbox.git}
OS_RELEASE=${CLAUDE_SANDBOX_OS_RELEASE:-/etc/os-release}
KVM=${CLAUDE_SANDBOX_KVM:-/dev/kvm}
APT_DIR=${CLAUDE_SANDBOX_APT_DIR:-/etc/apt}
TTY=${CLAUDE_SANDBOX_TTY:-/dev/tty}
BEGIN_MARK="# >>> claude-sandbox >>>"
END_MARK="# <<< claude-sandbox <<<"
SBX_MIN=0.51.0

step() { echo "==> $*"; }
warn() { echo "$TAG: $*" >&2; }
die() { warn "$*"; exit 1; }

case "${1:-}" in
    "") ;;
    -h | --help) echo "usage: install.sh   (no arguments; the header of install.sh lists its steps)"; exit 0 ;;
    *) echo "usage: install.sh   (no arguments)" >&2; exit 2 ;;
esac

LEFT=()   # commands the install couldn't run for you, printed at the end
left() { LEFT+=("$1"); }

as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

# version_ge A B: A is B or newer
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- Platform -------------------------------------------------------------------------
unsupported="the install supports Debian 13+ and Ubuntu 24.04+; on other systems follow the README's Setup by hand"
command -v apt-get >/dev/null 2>&1 || die "apt-get not found: $unsupported"
[ -r "$OS_RELEASE" ] || die "can't read $OS_RELEASE: $unsupported"
# shellcheck disable=SC1090  # os-release is the system's, read in a subshell
DISTRO=$(. "$OS_RELEASE" && printf '%s' "${ID:-}")
# shellcheck disable=SC1090
DISTRO_VERSION=$(. "$OS_RELEASE" && printf '%s' "${VERSION_ID:-0}")
case "$DISTRO" in
    debian) version_ge "$DISTRO_VERSION" 13 || die "Debian $DISTRO_VERSION: $unsupported" ;;
    ubuntu) version_ge "$DISTRO_VERSION" 24.04 || die "Ubuntu $DISTRO_VERSION: $unsupported" ;;
    *) die "${DISTRO:-this distro}: $unsupported" ;;
esac
ARCH=$(dpkg --print-architecture)
case "$ARCH" in amd64 | arm64) ;; *) die "sbx has no build for $ARCH" ;; esac

# --- 1. KVM ---------------------------------------------------------------------------
step "checking KVM"
[ -e "$KVM" ] || die "$KVM is missing, and sbx runs each sandbox as a KVM microVM. Turn on virtualization (Intel VT-x / AMD-V) in the BIOS/UEFI, or nested virtualization if this machine is a VM, then re-run."
RELOGIN=""
ME=$(id -un)
in_kvm() { id -nG "$@" | tr ' ' '\n' | grep -qx kvm; }
if [ "$(id -u)" -ne 0 ]; then
    if ! in_kvm "$ME"; then
        step "adding $ME to the kvm group"
        as_root usermod -aG kvm "$ME" || die "couldn't add you to the kvm group; run: sudo usermod -aG kvm $ME, then re-run"
        RELOGIN=1
    elif ! in_kvm; then
        RELOGIN=1   # added earlier, but this login session predates it
    fi
fi

# --- 2. Tools -------------------------------------------------------------------------
APT_UPDATED=""
apt_install() {
    local pkg missing=()
    for pkg in "$@"; do dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg"); done
    [ ${#missing[@]} -gt 0 ] || return 0
    if [ -z "$APT_UPDATED" ]; then
        step "apt-get update"
        as_root apt-get update || die "apt-get update failed; fix the error above and re-run"
        APT_UPDATED=1
    fi
    step "installing ${missing[*]}"
    as_root apt-get install -y "${missing[@]}" || die "apt-get couldn't install ${missing[*]}; fix the error above and re-run"
}
apt_install git curl ca-certificates

# gh: GitHub's own repository. The distro's gh (2.45/2.46) no longer works with GitHub's API,
# so a gh from dpkg without that repository is replaced; a gh installed some other way is kept.
GH_LIST=$APT_DIR/sources.list.d/github-cli.list
GH_KEY=$APT_DIR/keyrings/githubcli-archive-keyring.gpg
if command -v gh >/dev/null 2>&1 && ! dpkg -s gh >/dev/null 2>&1; then
    step "gh: installed outside apt; keeping it"
elif [ -f "$GH_LIST" ]; then
    apt_install gh
else
    step "adding GitHub's apt repository for gh"
    as_root mkdir -p -m 755 "$APT_DIR/keyrings" "$APT_DIR/sources.list.d"
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | as_root tee "$GH_KEY" >/dev/null ||
        die "couldn't download GitHub's apt key; check the network and re-run"
    as_root chmod go+r "$GH_KEY"
    echo "deb [arch=$ARCH signed-by=$GH_KEY] https://cli.github.com/packages stable main" | as_root tee "$GH_LIST" >/dev/null
    APT_UPDATED=""
    if dpkg -s gh >/dev/null 2>&1; then
        step "replacing the distro's gh"
        as_root apt-get remove -y gh || die "apt-get couldn't remove the distro's gh; fix the error above and re-run"
    fi
    apt_install gh
fi

if ! command -v sbx >/dev/null 2>&1; then
    if [ "$DISTRO" = ubuntu ]; then
        # Docker's apt repository, so apt upgrade keeps sbx current
        step "adding Docker's apt repository"
        curl -fsSL -o "$TMP/get-docker.sh" https://get.docker.com || die "couldn't download https://get.docker.com; check the network and re-run"
        as_root env REPO_ONLY=1 sh "$TMP/get-docker.sh" || die "Docker's repository script failed; fix the error above and re-run"
        APT_UPDATED=""
        apt_install docker-sbx
    else
        # Docker's repository has no sbx for Debian: the release package instead
        deb=DockerSandboxes-linux-$ARCH-ubuntu2404.deb
        step "downloading $deb"
        curl -fsSL -o "$TMP/$deb" "https://github.com/docker/sbx-releases/releases/latest/download/$deb" ||
            die "couldn't download $deb; check the network and re-run"
        as_root apt-get install -y "$TMP/$deb" || die "apt-get couldn't install $deb; fix the error above and re-run"
    fi
    command -v sbx >/dev/null 2>&1 || die "sbx installed, but it isn't on PATH; open a new terminal and re-run"
fi
SBX_VERSION=$(sbx version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
if [ -n "$SBX_VERSION" ] && ! version_ge "$SBX_VERSION" "$SBX_MIN"; then
    warn "sbx $SBX_VERSION is older than $SBX_MIN, which the wrappers need; update it (README: Updating)"
fi

# --- 3. The clone ---------------------------------------------------------------------
SELF=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    [ -f "$SELF/claude-sandbox.sh" ] || SELF=""
fi
if [ -n "$SELF" ]; then
    DIR=$SELF
    step "using the clone at $DIR"
else
    DIR=${CLAUDE_SANDBOX_DIR:-$HOME/Claude-Sandbox}
    if [ -d "$DIR/.git" ]; then
        step "updating $DIR"
        git -C "$DIR" pull --ff-only || die "couldn't fast-forward $DIR; sort it out by hand, then re-run"
    elif [ -e "$DIR" ]; then
        die "$DIR exists and isn't a git clone; move it or set CLAUDE_SANDBOX_DIR, then re-run"
    else
        step "cloning Claude-Sandbox into $DIR"
        git clone "$REPO" "$DIR" || die "git clone failed; fix the error above and re-run"
    fi
    DIR=$(cd "$DIR" && pwd)
fi
case "$DIR" in *"'"*) die "the clone's path must not contain a single quote: $DIR" ;; esac
[ -f "$DIR/claude-sandbox.sh" ] || die "$DIR has no claude-sandbox.sh; is it a Claude-Sandbox clone?"

# --- 4. Sign-ins ----------------------------------------------------------------------
# Under curl | bash, stdin is the script, so the sign-ins read the terminal itself.
have_tty() { { : <"$TTY"; } 2>/dev/null; }

if gh auth status >/dev/null 2>&1; then
    step "GitHub: signed in"
elif have_tty; then
    step "signing in to GitHub (gh auth login)"
    gh auth login <"$TTY" || warn "gh auth login didn't finish"
fi
GH_OK=""
if gh auth status >/dev/null 2>&1; then GH_OK=1; else left "gh auth login"; fi

# sbx has no status command; sbx diagnose reports both the sign-in and the global policy.
DIAG=""
diagnose() { DIAG=$(sbx diagnose 2>&1 || true); }
sbx_signed_in() { grep -Eq 'Authentication[[:space:]]+[^[:space:]]+[[:space:]]+authenticated[[:space:]]*$' <<<"$DIAG"; }
sbx_policy_set() { grep -Eq 'Global network policy[[:space:]]+[^[:space:]]+[[:space:]]+initialized[[:space:]]*$' <<<"$DIAG"; }

step "checking sbx (sbx diagnose)"
diagnose
if sbx_signed_in; then
    step "Docker: signed in"
elif have_tty; then
    step "signing in to Docker (sbx login)"
    if sbx login <"$TTY"; then diagnose; else warn "sbx login didn't finish"; fi
fi

# --- 5. Sandbox settings --------------------------------------------------------------
SECRET_CMD="sbx secret set github --command 'gh auth token' -f"
if ! sbx_signed_in; then
    left "sbx login"
    left "sbx policy init balanced   # skip it if sbx diagnose says the global network policy is initialized"
    left "$SECRET_CMD"
else
    if sbx_policy_set; then
        step "network policy: already set"
    else
        step "setting the network policy (sbx policy init balanced)"
        sbx policy init balanced --no-input || { warn "sbx policy init failed"; left "sbx policy init balanced"; }
    fi
    if [ -n "$GH_OK" ]; then
        # Stored as a command, so sbx reads the current token itself and a new token needs nothing.
        step "giving sandboxes GitHub access (the github secret, as 'gh auth token')"
        sbx secret set github --command 'gh auth token' -f --no-input ||
            { warn "couldn't store the github secret"; left "$SECRET_CMD"; }
    else
        left "$SECRET_CMD   # after gh auth login"
    fi
fi

# --- 6. The wrapper in new shells -----------------------------------------------------
NOWHERE_LOCAL=$HOME/.config/nowhere/local.zsh
nowhere_present() {
    [ -f "$NOWHERE_LOCAL" ] || return 1
    [ -n "${NOWHERE_ROLE:-}" ] && return 0
    [ -n "${NOWHERE_DIR:-}" ] && [ -f "$NOWHERE_DIR/bootstrap/bootstrap.sh" ] && return 0
    [ -f "$HOME/Nowhere/bootstrap/bootstrap.sh" ]
}
NOWHERE=""
FILES=()
if nowhere_present; then
    NOWHERE=1
    TARGET=$NOWHERE_LOCAL
    FILES=("$TARGET" "$HOME/.zshrc")   # ~/.zshrc is Nowhere's stub, which bootstrap rewrites
    step "Nowhere found: loading the wrapper from its local override"
else
    case "$(basename "${SHELL:-bash}")" in
        zsh) TARGET=$HOME/.zshrc ;;
        *) TARGET=$HOME/.bashrc ;;
    esac
    FILES=("$TARGET")
fi

# Lines outside our block that already source claude-sandbox.sh, as "<line number><tab><path>"
hand_loads() {
    [ -f "$1" ] || return 0
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        $0 == b { skip = 1; next }
        skip && $0 == e { skip = 0; next }
        skip { next }
        /^[[:space:]]*(source|\.)[[:space:]]+/ && /claude-sandbox\.sh/ {
            p = $0
            sub(/^[[:space:]]*(source|\.)[[:space:]]+/, "", p)
            sub(/[[:space:]]+#.*$/, "", p)
            sub(/[[:space:]]+$/, "", p)
            gsub(/["\047]/, "", p)
            print FNR "\t" p
        }' "$1"
}
same_clone() {
    local p=$1 d
    # shellcheck disable=SC2088,SC2016  # a literal ~ or $HOME, as a hand-written line has them
    case "$p" in
        "~/"*) p=$HOME/${p#"~/"} ;;
        '$HOME/'*) p=$HOME/${p#'$HOME/'} ;;
        '${HOME}/'*) p=$HOME/${p#'${HOME}/'} ;;
    esac
    d=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || return 1
    [ "$d" = "$(cd "$DIR" && pwd -P)" ]
}
LOADED=""
for f in "${FILES[@]}"; do
    while IFS=$'\t' read -r line path; do
        [ -n "$line" ] || continue
        if ! same_clone "$path"; then
            die "$f already loads a wrapper from another clone ($path, line $line). Remove that line, or re-run with CLAUDE_SANDBOX_DIR set to that clone."
        fi
        if [ "$f" = "$TARGET" ]; then
            LOADED=1
        else
            warn "$f also loads the wrapper (line $line). Nowhere's bootstrap rewrites that file, so the line will be lost then; the local override loads it now, so remove that line."
        fi
    done < <(hand_loads "$f")
done

BLOCK=""
add() { BLOCK="$BLOCK$1"$'\n'; }
if [ -n "$LOADED" ]; then
    step "$TARGET already loads the wrapper; leaving that line as it is"
else
    add "source '$DIR/claude-sandbox.sh'"
fi
[ -z "$NOWHERE" ] || add "typeset -gA NowhereGotoBookmarks; NowhereGotoBookmarks[cs]='$DIR'"
if [ -n "$BLOCK" ]; then
    BLOCK="$BEGIN_MARK"$'\n'"# Written by Claude-Sandbox's install.sh; re-running it rewrites this block."$'\n'"$BLOCK$END_MARK"
fi

# Replace our block in $1 with $BLOCK (or drop it when $BLOCK is empty). The rest of the file
# is kept as it is, and so are its permissions (the local override is owner-only).
write_block() {
    local file=$1 new=$TMP/block
    mkdir -p "$(dirname "$file")"
    [ -e "$file" ] || : >"$file"
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        $0 == b { skip = 1; next }
        skip && $0 == e { skip = 0; next }
        !skip' "$file" >"$new"
    if [ -n "$BLOCK" ]; then
        local sep=""   # end the last line, then one blank line before the block
        if [ -s "$new" ]; then
            [ -z "$(tail -c 1 "$new")" ] || sep=$'\n'
            [ -z "$(tail -n 1 "$new")" ] || sep="$sep"$'\n'
        fi
        printf '%s%s\n' "$sep" "$BLOCK" >>"$new"
    fi
    if cmp -s "$new" "$file"; then
        step "$file: already up to date"
    else
        cat "$new" >"$file"
        step "$file: wrapper block written"
    fi
}
write_block "$TARGET"

# --- Done -----------------------------------------------------------------------------
echo
step "Claude-Sandbox installed in $DIR"
if [ ${#LEFT[@]} -gt 0 ]; then
    echo "Still to do, in a terminal:"
    printf '    %s\n' "${LEFT[@]}"
fi
if [ -n "$RELOGIN" ]; then
    echo "Log out and back in (or reboot) so the kvm group applies, then cd into a project and run claude."
else
    echo "Open a new terminal, cd into a project and run claude. Inside Claude, run /login once."
fi
