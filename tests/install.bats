#!/usr/bin/env bats
# install.sh end to end, against fakes of apt-get, dpkg, sudo, curl, gh, usermod and id
# (tests/fake-tools) and sbx (tests/fake-sbx), in a throwaway HOME. PATH holds only those and the
# system tools the install needs, so a real gh or sbx on this machine stays out of it.
# The PowerShell side is tests/install.Tests.ps1.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
    [ "$(uname -s)" = Linux ] || skip "install.sh is for Debian and Ubuntu"
    local t sys=$BATS_TEST_TMPDIR/sys
    mkdir -p "$sys"
    ZSH_BIN=$(command -v zsh || true)   # before PATH is narrowed
    for t in bash sh env cat mkdir mktemp rm cp mv ln dirname basename chmod tee tail head cut tr \
        grep awk sed sort cmp git python3 uname touch ls stat; do
        ln -s "$(command -v "$t")" "$sys/$t"
    done
    export HOME=$BATS_TEST_TMPDIR/home
    export FAKE_TOOLS_DIR=$BATS_TEST_TMPDIR/tools FAKE_SBX_DIR=$BATS_TEST_TMPDIR/sbx
    export FAKE_TOOLS_SRC=$REPO_ROOT/tests/fake-tools FAKE_TOOLS_SBX=$REPO_ROOT/tests/fake-sbx/sbx
    mkdir -p "$HOME" "$FAKE_TOOLS_DIR/bin" "$FAKE_SBX_DIR"
    : >"$FAKE_TOOLS_DIR/calls"; : >"$FAKE_TOOLS_DIR/packages"; : >"$FAKE_SBX_DIR/calls"
    for t in apt-get dpkg sudo curl usermod id; do ln -s "$FAKE_TOOLS_SRC/$t" "$FAKE_TOOLS_DIR/bin/$t"; done

    # The remote: a repo with the wrapper in it
    origin=$BATS_TEST_TMPDIR/origin
    mkdir -p "$origin"
    echo '# wrapper' >"$origin/claude-sandbox.sh"
    git -C "$origin" init -q
    git -C "$origin" add claude-sandbox.sh
    git -C "$origin" -c user.name=t -c user.email=t@example.com commit -qm init

    export PATH="$FAKE_TOOLS_DIR/bin:$sys"
    export SHELL=/bin/bash
    export CLAUDE_SANDBOX_REPO=$origin
    export CLAUDE_SANDBOX_OS_RELEASE=$BATS_TEST_TMPDIR/os-release
    export CLAUDE_SANDBOX_KVM=$BATS_TEST_TMPDIR/kvm
    export CLAUDE_SANDBOX_APT_DIR=$BATS_TEST_TMPDIR/apt
    export CLAUDE_SANDBOX_TTY=$BATS_TEST_TMPDIR/tty
    unset CLAUDE_SANDBOX_DIR NOWHERE_ROLE NOWHERE_DIR
    os debian 13
    touch "$CLAUDE_SANDBOX_KVM" "$CLAUDE_SANDBOX_TTY"
    clone=$HOME/Claude-Sandbox
}

os() { printf 'ID=%s\nVERSION_ID="%s"\n' "$1" "$2" >"$CLAUDE_SANDBOX_OS_RELEASE"; }

# The one-liner: the script arrives on stdin, as with curl | bash
# (its output is printed too, so bats shows it when a test fails)
install() { run bash -c 'bash <"$1"' _ "$REPO_ROOT/install.sh"; echo "$output"; }

tool_calls() { grep -E "$1" "$FAKE_TOOLS_DIR/calls" || true; }
sbx_calls() {
    python3 -c 'import json,sys
for line in open(sys.argv[1]): print(" ".join(json.loads(line)))' "$FAKE_SBX_DIR/calls" | grep -E "$1" || true
}
blocks() { grep -c '^# >>> claude-sandbox >>>$' "$1" || true; }

# A machine where everything is already done
ready() {
    for p in git curl ca-certificates gh docker-sbx; do echo "$p" >>"$FAKE_TOOLS_DIR/packages"; done
    ln -s "$FAKE_TOOLS_SRC/gh" "$FAKE_TOOLS_DIR/bin/gh"
    ln -s "$FAKE_TOOLS_SBX" "$FAKE_TOOLS_DIR/bin/sbx"
    mkdir -p "$CLAUDE_SANDBOX_APT_DIR/sources.list.d"
    touch "$CLAUDE_SANDBOX_APT_DIR/sources.list.d/github-cli.list"
    echo kvm >"$FAKE_TOOLS_DIR/account-groups"; echo kvm >"$FAKE_TOOLS_DIR/session-groups"
    touch "$FAKE_TOOLS_DIR/gh-signed-in" "$FAKE_SBX_DIR/signed-in" "$FAKE_SBX_DIR/policy-set"
}

# A bootstrapped Nowhere: its clone, its stub at ~/.zshrc and its local override
nowhere() {
    mkdir -p "$HOME/Nowhere/bootstrap" "$HOME/.config/nowhere"
    touch "$HOME/Nowhere/bootstrap/bootstrap.sh"
    printf 'export NOWHERE_ROLE=devbox\nsource %s/Nowhere/zsh/profile.zsh\n' "$HOME" >"$HOME/.zshrc"
    printf '# my settings\ntypeset -A NowhereGotoBookmarks=(src /src)\nexport GITHUB_TOKEN=x\n' >"$HOME/.config/nowhere/local.zsh"
    chmod 600 "$HOME/.config/nowhere/local.zsh"
}

@test "fresh Debian machine: installs the tools, signs in, sets up sbx and loads the wrapper" {
    install
    [ "$status" -eq 0 ]
    for p in git curl ca-certificates gh docker-sbx; do grep -qx "$p" "$FAKE_TOOLS_DIR/packages"; done
    [ -n "$(tool_calls '^usermod -aG kvm tester$')" ]
    [ -n "$(tool_calls 'sbx-releases/releases/latest/download/DockerSandboxes-linux-amd64-ubuntu2404\.deb')" ]
    grep -q 'https://cli.github.com/packages stable main' "$CLAUDE_SANDBOX_APT_DIR/sources.list.d/github-cli.list"
    [ -f "$clone/claude-sandbox.sh" ]
    [ -n "$(tool_calls '^gh auth login$')" ]
    [ -n "$(sbx_calls '^login$')" ]
    [ -n "$(sbx_calls '^policy init balanced --no-input$')" ]
    [ -n "$(sbx_calls '^secret set github --command gh auth token -f --no-input$')" ]
    [ "$(cat "$FAKE_SBX_DIR/secret-github")" = "gh auth token" ]
    grep -qx "source '$clone/claude-sandbox.sh'" "$HOME/.bashrc"
    [ "$(blocks "$HOME/.bashrc")" -eq 1 ]
    ! grep -q NowhereGotoBookmarks "$HOME/.bashrc"
    [[ "$output" == *"Log out and back in"* ]]
    [[ "$output" != *"Still to do"* ]]
}

@test "Ubuntu: sbx comes from Docker's apt repository" {
    os ubuntu 24.04
    install
    [ "$status" -eq 0 ]
    [ -n "$(tool_calls '^get-docker REPO_ONLY=1$')" ]
    grep -qx docker-sbx "$FAKE_TOOLS_DIR/packages"
    [ -z "$(tool_calls 'sbx-releases')" ]
}

@test "a re-run changes nothing" {
    install
    [ "$status" -eq 0 ]
    cp "$HOME/.bashrc" "$BATS_TEST_TMPDIR/bashrc.first"
    : >"$FAKE_TOOLS_DIR/calls"; : >"$FAKE_SBX_DIR/calls"
    install
    [ "$status" -eq 0 ]
    [ -z "$(tool_calls '^(apt-get|usermod|curl|gh auth login)')" ]
    [ -z "$(sbx_calls '^(login|policy)')" ]
    cmp "$HOME/.bashrc" "$BATS_TEST_TMPDIR/bashrc.first"
    [[ "$output" == *"already up to date"* ]]
    # The kvm group still needs a new login session
    [[ "$output" == *"Log out and back in"* ]]
}

@test "keeps an existing network policy and sign-ins" {
    ready
    install
    [ "$status" -eq 0 ]
    [ -z "$(sbx_calls '^(login|policy)')" ]
    [ -z "$(tool_calls '^(gh auth login|usermod|apt-get)')" ]
    [[ "$output" == *"network policy: already set"* ]]
    [[ "$output" == *"Open a new terminal"* ]]
}

@test "a zsh login shell gets the block in ~/.zshrc" {
    ready
    SHELL=/usr/bin/zsh install
    [ "$status" -eq 0 ]
    [ "$(blocks "$HOME/.zshrc")" -eq 1 ]
    [ ! -e "$HOME/.bashrc" ]
}

@test "keeps the rest of the file and appends the block after a blank line" {
    ready
    printf 'alias ll="ls -l"' >"$HOME/.bashrc"   # no newline at the end
    install
    [ "$status" -eq 0 ]
    [ "$(sed -n 1p "$HOME/.bashrc")" = 'alias ll="ls -l"' ]
    [ -z "$(sed -n 2p "$HOME/.bashrc")" ]
    [ "$(sed -n 3p "$HOME/.bashrc")" = '# >>> claude-sandbox >>>' ]
}

@test "a clone that moved: the block is rewritten, not added again" {
    ready
    CLAUDE_SANDBOX_DIR=$BATS_TEST_TMPDIR/a install
    [ "$status" -eq 0 ]
    CLAUDE_SANDBOX_DIR=$BATS_TEST_TMPDIR/b install
    [ "$status" -eq 0 ]
    [ "$(blocks "$HOME/.bashrc")" -eq 1 ]
    grep -qx "source '$BATS_TEST_TMPDIR/b/claude-sandbox.sh'" "$HOME/.bashrc"
    ! grep -q "$BATS_TEST_TMPDIR/a/" "$HOME/.bashrc"
}

@test "Nowhere: the block goes in its local override, with a goto bookmark" {
    ready
    nowhere
    cp "$HOME/.zshrc" "$BATS_TEST_TMPDIR/stub"
    install
    [ "$status" -eq 0 ]
    local o=$HOME/.config/nowhere/local.zsh
    [ "$(sed -n 1,3p "$o")" = "$(printf '# my settings\ntypeset -A NowhereGotoBookmarks=(src /src)\nexport GITHUB_TOKEN=x')" ]
    grep -qx "source '$clone/claude-sandbox.sh'" "$o"
    grep -qx "typeset -gA NowhereGotoBookmarks; NowhereGotoBookmarks\[cs\]='$clone'" "$o"
    [ "$(stat -c %a "$o" 2>/dev/null || stat -f %Lp "$o")" = 600 ]
    cmp "$HOME/.zshrc" "$BATS_TEST_TMPDIR/stub"
    [ ! -e "$HOME/.bashrc" ]
}

@test "Nowhere: the bookmark adds to the ones already set" {
    [ -n "$ZSH_BIN" ] || skip "zsh isn't installed"
    ready
    nowhere
    install
    [ "$status" -eq 0 ]
    run "$ZSH_BIN" -fc 'source ~/.config/nowhere/local.zsh; print -r -- ${(t)NowhereGotoBookmarks} $NowhereGotoBookmarks[src] $NowhereGotoBookmarks[cs]'
    [ "$output" = "association /src $clone" ]
}

@test "Nowhere: found through NOWHERE_DIR too" {
    ready
    nowhere
    mv "$HOME/Nowhere" "$BATS_TEST_TMPDIR/nw"
    NOWHERE_DIR=$BATS_TEST_TMPDIR/nw install
    [ "$status" -eq 0 ]
    [ "$(blocks "$HOME/.config/nowhere/local.zsh")" -eq 1 ]
}

@test "a Nowhere clone that was never bootstrapped doesn't count" {
    ready
    mkdir -p "$HOME/Nowhere/bootstrap"
    touch "$HOME/Nowhere/bootstrap/bootstrap.sh"
    install
    [ "$status" -eq 0 ]
    [ "$(blocks "$HOME/.bashrc")" -eq 1 ]
    [ ! -e "$HOME/.config/nowhere/local.zsh" ]
}

@test "a wrapper already loaded by hand from the same clone is left alone" {
    ready
    git clone -q "$origin" "$clone"
    echo "source $clone/claude-sandbox.sh" >"$HOME/.bashrc"
    cp "$HOME/.bashrc" "$BATS_TEST_TMPDIR/bashrc"
    install
    [ "$status" -eq 0 ]
    cmp "$HOME/.bashrc" "$BATS_TEST_TMPDIR/bashrc"
    [[ "$output" == *"already loads the wrapper"* ]]
}

@test "Nowhere: a hand-added line in its stub gets a warning, and the block goes in the override" {
    ready
    nowhere
    git clone -q "$origin" "$clone"
    echo "source ~/Claude-Sandbox/claude-sandbox.sh" >>"$HOME/.zshrc"
    install
    [ "$status" -eq 0 ]
    [[ "$output" == *"$HOME/.zshrc also loads the wrapper (line 3)"*"remove that line"* ]]
    grep -qx "source '$clone/claude-sandbox.sh'" "$HOME/.config/nowhere/local.zsh"
}

@test "a wrapper loaded from another clone stops the install" {
    ready
    git clone -q "$origin" "$BATS_TEST_TMPDIR/other"
    echo ". '$BATS_TEST_TMPDIR/other/claude-sandbox.sh'" >"$HOME/.bashrc"
    cp "$HOME/.bashrc" "$BATS_TEST_TMPDIR/bashrc"
    install
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-sandbox install: $HOME/.bashrc already loads a wrapper from another clone"*"CLAUDE_SANDBOX_DIR"* ]]
    cmp "$HOME/.bashrc" "$BATS_TEST_TMPDIR/bashrc"
}

@test "no terminal: skips the sign-ins and lists them at the end" {
    CLAUDE_SANDBOX_TTY=$BATS_TEST_TMPDIR/no-tty install
    [ "$status" -eq 0 ]
    [ -z "$(tool_calls '^gh auth login')" ]
    [ -z "$(sbx_calls '^(login|policy|secret)')" ]
    [[ "$output" == *"Still to do, in a terminal:"*"gh auth login"*"sbx login"*"sbx policy init balanced"*"sbx secret set github --command 'gh auth token' -f"* ]]
    [ "$(blocks "$HOME/.bashrc")" -eq 1 ]
}

@test "a failed secret doesn't stop the install" {
    ready
    touch "$FAKE_SBX_DIR/secret-fails"
    install
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude-sandbox install: couldn't store the github secret"* ]]
    [[ "$output" == *"Still to do"*"sbx secret set github --command 'gh auth token' -f"* ]]
    [ "$(blocks "$HOME/.bashrc")" -eq 1 ]
}

@test "the distro's gh is replaced by GitHub's" {
    ready
    rm "$CLAUDE_SANDBOX_APT_DIR/sources.list.d/github-cli.list"
    install
    [ "$status" -eq 0 ]
    [ -n "$(tool_calls '^apt-get remove -y gh$')" ]
    [ -n "$(tool_calls '^apt-get install -y gh$')" ]
}

@test "a gh installed some other way is kept" {
    ready
    rm "$CLAUDE_SANDBOX_APT_DIR/sources.list.d/github-cli.list"
    grep -vx gh "$FAKE_TOOLS_DIR/packages" >"$BATS_TEST_TMPDIR/p"; mv "$BATS_TEST_TMPDIR/p" "$FAKE_TOOLS_DIR/packages"
    install
    [ "$status" -eq 0 ]
    [ -z "$(tool_calls '^apt-get')" ]
    [ ! -e "$CLAUDE_SANDBOX_APT_DIR/sources.list.d/github-cli.list" ]
}

@test "run from a clone, it uses that clone" {
    ready
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"using the clone at $REPO_ROOT"* ]]
    [ ! -e "$clone" ]
    grep -qx "source '$REPO_ROOT/claude-sandbox.sh'" "$HOME/.bashrc"
}

@test "a folder in the clone's place that isn't a clone stops the install" {
    ready
    mkdir -p "$clone"
    install
    [ "$status" -eq 1 ]
    [[ "$output" == *"$clone exists and isn't a git clone"* ]]
}

@test "an unsupported release stops before installing anything" {
    os debian 12
    install
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-sandbox install: Debian 12: the install supports Debian 13+ and Ubuntu 24.04+"* ]]
    [ -z "$(tool_calls '^(apt-get|usermod)')" ]
}

@test "no /dev/kvm stops before installing anything" {
    rm "$CLAUDE_SANDBOX_KVM"
    install
    [ "$status" -eq 1 ]
    [[ "$output" == *"is missing, and sbx runs each sandbox as a KVM microVM"* ]]
    [ -z "$(tool_calls '^(apt-get|usermod)')" ]
}

@test "an sbx older than 0.51.0 gets a warning" {
    ready
    echo "v0.50.2 abc" >"$FAKE_SBX_DIR/version"
    install
    [ "$status" -eq 0 ]
    [[ "$output" == *"sbx 0.50.2 is older than 0.51.0"* ]]
}
