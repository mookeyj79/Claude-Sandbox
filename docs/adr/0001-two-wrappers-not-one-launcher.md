# Two wrappers, kept in step by shared tests, not one launcher

The bash and PowerShell wrappers implement the same launch behaviour twice, in two languages. We keep it that way instead of moving it into one launcher both shells call, because the only thing every user is guaranteed to have is their own shell: a shared launcher would mean shipping a compiled binary or requiring bash, Python or Node on Windows, which PowerShell users don't otherwise need. Drift between the two is caught instead by testing both wrappers against the same fake `sbx` and the same project-key cases (`tests/project-keys.tsv`).

## Considered Options

- **One launcher (binary or script) with two thin wrappers.** Removes the duplication, but adds a build and release step, or a runtime dependency, to a project that is currently "clone and source one file".
- **PowerShell wrapper calls the bash one through Git Bash.** Git Bash isn't guaranteed on Windows, and a WSL `bash.exe` can shadow it.

## Consequences

Every behaviour change is made in both wrappers, with a test on each side. Each wrapper keeps the same modules under the same roles (skill sync, history store, close, sweep), so a change in one has an obvious counterpart in the other. Revisit if the wrappers gain a dependency on a runtime anyway, or if keeping them in step starts costing more than a release step would.
