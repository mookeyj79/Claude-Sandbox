# The install knows about Nowhere; Nowhere doesn't know about Claude-Sandbox

On a machine set up with [Nowhere](https://github.com/mookeyj79/Nowhere), `install.sh` / `install.ps1` load the wrapper from Nowhere's local override (`~/.config/nowhere/local.zsh` or `local.ps1`), not from `~/.zshrc` or `$PROFILE`. Nowhere's bootstrap rewrites those two files as its stub, so a line appended there is lost on the next bootstrap, while the local override is never overwritten. The install also adds a `goto cs` bookmark there. Nowhere is optional: without it, the install writes to the shell's own profile, and it never installs or bootstraps Nowhere. Nothing in Nowhere names Claude-Sandbox.

Nowhere counts as present only when it has been bootstrapped (its local override exists), found through `NOWHERE_ROLE`, `NOWHERE_DIR` or a clone at `~/Nowhere`. Every file the install doesn't own gets one block between `# >>> claude-sandbox >>>` and `# <<< claude-sandbox <<<`, appended at the end and replaced on a re-run. The bookmark adds to `NowhereGotoBookmarks` rather than resetting it.

## Considered Options

- **A dev-layer conf.d file in Nowhere that loads the wrapper when it finds a clone.** Works with no install step, but makes Nowhere depend on Claude-Sandbox's layout, and it would load only on a DevBox.
- **sbx and gh in Nowhere's `shared/tools.json`.** Would let Nowhere's `update` keep them current, but the install would still need its own route for machines without Nowhere, so there would be two install paths for the same tools. Still possible later, on Nowhere's side.
