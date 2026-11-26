#!/usr/bin/env bats
# Image cleanup: _claude_sandbox_prune_images

load helpers

setup() {
    setup_fake_sbx
    # Rows as `sbx df --verbose` shows them: one image can be listed tagged and untagged.
    cat > "$FAKE_SBX_DIR/images" <<'ROWS'
docker.io/library/sandbox-kit-assembled 3344a263200166f7 55dabccee96c 0
docker.io/sbx/claude <none> 55dabccee96c 0
docker.io/library/sandbox-kit-assembled 8c076eb8c89a6a0d 6925fc818508 1
docker.io/sbx/claude <none> 6925fc818508 1
docker.io/sbx/claude <none> 01b847e74f7a 0
docker.io/sbx/claude <none> fa91ca160b08 2
ROWS
}

removals() { sbx_calls | grep '^template rm' || true; }

@test "removes each image no sandbox uses, once, and keeps the ones in use" {
    run _claude_sandbox_prune_images
    [ "$status" -eq 0 ]
    [[ "$output" == *"removing 2 unused sandbox images"* ]]
    [ "$(removals)" = $'template rm --force --no-input 55dabccee96c\ntemplate rm --force --no-input 01b847e74f7a' ]
}

@test "runs at most once a day" {
    _claude_sandbox_prune_images 2>/dev/null
    : > "$FAKE_SBX_DIR/calls"
    run _claude_sandbox_prune_images
    [ "$output" = "" ]
    [ "$(sbx_calls)" = "" ]

    touch -t 202001010000 "$HOME/.claude-sandbox-images-pruned"
    _claude_sandbox_prune_images 2>/dev/null
    [ -n "$(removals)" ]
}

@test "says nothing when every image is in use" {
    printf '%s\n' 'docker.io/sbx/claude <none> 6925fc818508 1' > "$FAKE_SBX_DIR/images"
    run _claude_sandbox_prune_images
    [ "$output" = "" ]
    [ "$(removals)" = "" ]
}

@test "a failed removal is reported with the command, and the rest still go" {
    echo fail > "$FAKE_SBX_DIR/image-55dabccee96c"
    run _claude_sandbox_prune_images
    [ "$status" -eq 0 ]
    [[ "$output" == *"couldn't remove image 55dabccee96c. To try now: sbx template rm 55dabccee96c"* ]]
    [[ "$(removals)" == *"01b847e74f7a" ]]
}
