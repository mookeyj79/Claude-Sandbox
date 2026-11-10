#!/usr/bin/env bats
# Skill sync: _claude_sandbox_sync_skills <repo-dir>

load helpers

setup() {
    setup_fake_sbx
    repo="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$repo/skills/alpha" "$repo/skills/beta"
    # Most tests aren't about the daily refresh: make it look recent.
    date > "$HOME/.claude-sandbox-skills-updated"
}

installed() { cat "$HOME/.claude-sandbox-skills-added" 2>/dev/null; }

@test "installs every repo skill and records it" {
    run _claude_sandbox_sync_skills "$repo"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(installed)" = $'alpha\nbeta\nmattpocock/skills' ]
    [ "$(sbx_calls)" = $'skills add mookeyj79/Claude-Sandbox --skill alpha --no-input\nskills add mookeyj79/Claude-Sandbox --skill beta --no-input\nskills add mattpocock/skills --no-input' ]
}

@test "skips skills already recorded" {
    printf '%s\n' alpha mattpocock/skills > "$HOME/.claude-sandbox-skills-added"
    _claude_sandbox_sync_skills "$repo"
    [ "$(sbx_calls)" = "skills add mookeyj79/Claude-Sandbox --skill beta --no-input" ]
    [ "$(installed)" = $'alpha\nmattpocock/skills\nbeta' ]
}

@test "a skill that's already installed counts as installed" {
    echo exists > "$FAKE_SBX_DIR/skill-alpha"
    run _claude_sandbox_sync_skills "$repo"
    [ "$output" = "" ]
    [ "$(installed)" = $'alpha\nbeta\nmattpocock/skills' ]
}

@test "a failed install is reported, not recorded, and retried next run" {
    echo fail > "$FAKE_SBX_DIR/skill-alpha"
    run _claude_sandbox_sync_skills "$repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"network error"* ]]
    [[ "$output" == *"couldn't install skill alpha, will retry next run"* ]]
    [ "$(installed)" = $'beta\nmattpocock/skills' ]

    rm "$FAKE_SBX_DIR/skill-alpha"
    _claude_sandbox_sync_skills "$repo"
    [ "$(installed)" = $'beta\nmattpocock/skills\nalpha' ]
}

@test "a stuck install is cut off by the time limit, even without timeout(1)" {
    echo hang > "$FAKE_SBX_DIR/skill-alpha"
    export _CLAUDE_SANDBOX_SKILL_TIMEOUT=1
    # Hide GNU timeout, as on stock macOS.
    timeout() { return 127; }
    SECONDS=0
    run _claude_sandbox_sync_skills "$repo"
    [ "$SECONDS" -lt 10 ]
    [[ "$output" == *"installing skill alpha took over 1s, skipped."* ]]
    [[ "$output" == *"couldn't install skill alpha"* ]]
    [ "$(installed)" = $'beta\nmattpocock/skills' ]
}

@test "no repo skills: only the skill repos are installed" {
    rm -r "$repo/skills"/*
    run _claude_sandbox_sync_skills "$repo"
    [ "$output" = "" ]
    [ "$(sbx_calls)" = "skills add mattpocock/skills --no-input" ]
}

@test "installs mattpocock/skills once, whole" {
    printf '%s\n' alpha beta > "$HOME/.claude-sandbox-skills-added"
    _claude_sandbox_sync_skills "$repo"
    [ "$(sbx_calls)" = "skills add mattpocock/skills --no-input" ]
    _claude_sandbox_sync_skills "$repo"
    [ "$(sbx_calls)" = "skills add mattpocock/skills --no-input" ]
}

@test "mattpocock/skills already added by hand counts as installed" {
    printf '%s\n' alpha beta > "$HOME/.claude-sandbox-skills-added"
    echo exists > "$FAKE_SBX_DIR/skill-mattpocock__skills"
    run _claude_sandbox_sync_skills "$repo"
    [ "$output" = "" ]
    [ "$(installed)" = $'alpha\nbeta\nmattpocock/skills' ]
}

@test "a failed mattpocock/skills install is reported with the retry command" {
    printf '%s\n' alpha beta > "$HOME/.claude-sandbox-skills-added"
    echo fail > "$FAKE_SBX_DIR/skill-mattpocock__skills"
    run _claude_sandbox_sync_skills "$repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"couldn't install skill mattpocock/skills, will retry next run. To try now: sbx skills add mattpocock/skills"* ]]
    [ "$(installed)" = $'alpha\nbeta' ]
}

@test "refreshes installed skills when the last refresh is over a day old" {
    printf '%s\n' alpha beta mattpocock/skills > "$HOME/.claude-sandbox-skills-added"
    touch -t 202001010000 "$HOME/.claude-sandbox-skills-updated"
    _claude_sandbox_sync_skills "$repo"
    # The refresh runs in the background.
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(sbx_calls)" ] && break; sleep 0.2; done
    [ "$(sbx_calls)" = "skills update" ]
    [ -n "$(find "$HOME/.claude-sandbox-skills-updated" -mmin -1)" ]
}

@test "doesn't refresh twice in a day" {
    printf '%s\n' alpha beta mattpocock/skills > "$HOME/.claude-sandbox-skills-added"
    _claude_sandbox_sync_skills "$repo"
    sleep 0.5
    [ "$(sbx_calls)" = "" ]
}
