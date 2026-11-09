---
name: update-readme
description: Write or refresh the project's README so it is a complete, accurate front page on GitHub or GitLab. Use when the user asks to create, update, rewrite or improve the README.
argument-hint: "[path to project or README] [focus, e.g. 'installation only']"
---

Bring the README of the current project (or the path in the arguments) up to date: a complete front page for someone landing on the repo on GitHub or GitLab, with every fact checked against the code. If the arguments name a focus, limit the changes to that and leave the rest alone.

## 1. Survey the project

Read before writing. Gather, from the files rather than from memory:

- **What it is:** the existing README, package manifests (`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `*.csproj`, `pom.xml`, ...), entry points, and any `docs/`, `GLOSSARY.md`, ADRs or `CLAUDE.md`.
- **How to run it:** declared scripts and tasks (`scripts`, `Makefile`, `justfile`, `Taskfile`), Dockerfiles and compose files, required runtimes and their versions, environment variables (`.env.example`, config loaders, `process.env` / `os.environ` reads).
- **How it is built and tested:** CI files (`.github/workflows/`, `.gitlab-ci.yml`), test and lint commands, release tooling.
- **Where it lives:** `git remote -v` gives the host (GitHub or GitLab) and `owner/repo` for links and badges; `git branch --show-current` / the default branch; `LICENSE`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CHANGELOG.md`.
- **Visuals:** screenshots, logos or GIFs already in the repo.

Done when you can say in one sentence what the project does, who it is for, and the exact commands to install, run and test it.

## 2. Plan the sections

Use the sections below in this order, **including only those the project gives you real content for**. A small script needs a title, description, usage and license; a library or app needs most of the list. Never invent features, commands, versions, URLs or screenshots.

1. **Title and tagline:** project name as `# H1`, then one sentence on what it does and for whom.
2. **Badges:** only ones that resolve: CI status, license, package version, coverage. Use the host's URL format (GitHub Actions: `https://github.com/<owner>/<repo>/actions/workflows/<file>/badge.svg`; GitLab: `https://gitlab.com/<ns>/<project>/badges/<branch>/pipeline.svg`).
3. **Overview / features:** a short paragraph and a bulleted list of what it does. Add an existing screenshot or demo GIF here.
4. **Table of contents:** only when the README runs past about five sections. Write it by hand with anchor links; don't use GitLab's `[[_TOC_]]`, which shows as plain text on GitHub.
5. **Requirements:** runtimes, tools and versions, supported OSes.
6. **Installation:** copy-pasteable commands, per platform if they differ.
7. **Quick start / usage:** the shortest path to something working, then common examples. Show real CLI flags, API calls or screenshots.
8. **Configuration:** environment variables and config files as a table (name, default, meaning).
9. **Project structure:** a brief tree or table of the top-level folders, when the layout isn't obvious.
10. **Development:** build, test, lint and run-locally commands; how CI runs.
11. **Deployment / release:** only if the repo has it.
12. **Contributing:** link `CONTRIBUTING.md` if it exists, otherwise a few lines on issues and PRs.
13. **License:** name it and link `LICENSE`. If there is no license file, say so to the user instead of writing one in.
14. **Acknowledgements / links:** related projects, docs sites, credits.

## 3. Write it

- **Keep what's good.** Update an existing README in place: keep hand-written prose, section anchors other pages may link to, and the file's name and casing (`README.md`, `Readme.md`, ...). Fix stale facts, fill gaps, reorder only when it clearly helps. Create `README.md` at the project root only when none exists.
- **Portable Markdown.** Stick to what renders the same on GitHub and GitLab: fenced code blocks with a language tag, tables, relative links to repo files, `<details>` for long optional content, Mermaid for diagrams, and alerts (`> [!NOTE]`, `> [!WARNING]`) sparingly.
- **Readers first.** Lead with what the project does, not how it was built. Short paragraphs, imperative steps, one idea per bullet. Every command must be copy-pasteable as written, with placeholders marked as `<like-this>`.
- **No secrets.** Don't copy real tokens, internal hostnames or personal details from config files; use placeholders.

## 4. Verify

- Every command and script you mention exists in the repo (or is a standard tool), with the flags you show.
- Every relative link points at a file that exists, and every `#anchor` matches a heading.
- Versions, env var names and defaults match the code.
- Badges point at real workflows/branches for this repo.

Done when every check above passes; fix anything that doesn't before reporting.

## 5. Report

Don't commit. Tell the user in a few lines: sections added, sections changed, facts you corrected, and anything you couldn't confirm from the repo (such as a missing license or an undocumented env var) for them to fill in.
