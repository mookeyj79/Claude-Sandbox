---
name: clean-docs
description: Strip AI scaffolding (decision narration, rationale, prompt leftovers) out of human-facing docs and move what's worth keeping to the agent-side record. Use when the user asks to de-AI, clean up or humanize docs, or says a README or guide reads like an agent's notes.
argument-hint: "[files or folders to clean, default every human doc in the repo]"
---

Human docs are for the people who use the project. Agents writing them leave **scaffolding** behind: material about how the doc or the code got built rather than about using the product. Take the scaffolding down. What a future maintainer or agent still needs moves to the **agent-side record**; everything else is deleted. The reader's doc ends up reading as if a person wrote it for them on purpose.

## What counts as scaffolding

Ask of each passage: **does the reader need this to use, run, configure or decide something?** If yes, it's content, even when it says "why" ("keep these files together: the wrapper looks for the others next to itself" is content). If it only explains the builder's thinking, it's scaffolding:

- **Narration:** first person from the agent ("I added", "I chose"), "as requested", "per your instructions", "Note: this section was updated to…", summaries of what the edit changed.
- **Decision records:** "Decision:", "Why we chose X", options considered and rejected, trade-off tables, "Alternatives" sections, ADR-shaped blocks inside a guide.
- **Prompt leftovers:** echoed instructions, task lists for the agent, "TODO for Claude", placeholders the agent meant to fill, meta-commentary on the doc's own structure ("This guide is organized as follows so that…").
- **Process hedging:** "I couldn't verify", "assuming the user wants", confidence notes. A real gap the reader should know about stays, rewritten as a plain fact about the product ("Not tested on macOS").
- **Agent-facing rules:** conventions and gotchas written for whoever edits the code ("When changing X, also update Y"), sitting in a user doc.

## Scope

**Human docs:** the README, user guides, `docs/` pages for users, CHANGELOGs, help text and other Markdown or text the product's users read. Limit to the paths in the arguments if given.

**The agent-side record**, never cleaned by this skill: `CLAUDE.md`, `AGENTS.md`, `docs/agents/`, `docs/adr/`, `GLOSSARY.md`, `CODING_STANDARDS.md`, skill files (`**/SKILL.md`) and anything a `CLAUDE.md` or `AGENTS.md` names as agent reading.

## 1. Survey

List the human docs in scope (`git ls-files '*.md' '*.txt' '*.rst'` and the paths in the arguments, minus the agent-side record). Read the agent-side record too: you need to know what's already recorded before moving anything there.

Read each human doc in full and mark every scaffolding passage, down to single sentences and clauses.

Done when every human doc in scope has been read top to bottom and every scaffolding passage is marked.

## 2. Route each passage

Send every marked passage to exactly one place:

- **Decision with lasting value** (a choice and the reason someone could later want to reverse it): `docs/adr/`. Extend the ADR that already covers it, or write a new one with the next number, in the format of the existing ADRs (or the `domain-modeling` skill's ADR format, if installed). Create `docs/adr/` only when the repo has none and a decision is worth keeping.
- **Convention or gotcha for whoever edits the code:** the agent doc it belongs in: `CLAUDE.md`, a file under `docs/agents/`, or `CODING_STANDARDS.md`. One line, in that file's style.
- **Term the project defines:** `GLOSSARY.md`, if the repo has one.
- **Already recorded, or no lasting value** (narration, prompt leftovers, hedging, rejected options nobody will revisit): delete.

Keep each meaning in one place: when the agent-side record already says it, delete the copy rather than recording it twice.

Done when every marked passage has a destination.

## 3. Rewrite the human docs

Remove each scaffolding passage, then repair the prose around it so the doc reads straight through: fix sentences that lost a clause, merge paragraphs left thin, drop headings left empty, and update tables of contents and `#anchor` links that pointed at removed sections. Where a reader-facing fact was tangled with the reasoning ("We use X because Y, so run Z"), keep the fact and the instruction ("Run Z").

Write in the doc's own voice: second person or neutral, present tense, about the product. Leave content you didn't mark untouched.

## 4. Write the agent-side record

Apply the routes from step 2. Agents find this record through `CLAUDE.md` and `docs/agents/`, so the human docs don't link to it.

## 5. Check

- Search the cleaned docs for leftovers: `grep -niE '\b(I|I.ve|I.ll|we decided|as requested|per your|decision:|alternatives considered|rationale|TODO)\b'` over the files you touched, and read each hit.
- Every relative link and `#anchor` in the touched docs resolves.
- Every passage routed to the agent-side record is there.
- Run the repo's check or lint command (from `CLAUDE.md`, the README or the manifests) if it covers docs.

Done when every check passes.

## 6. Report

Don't commit. Tell the user in a few lines: the docs you cleaned, what moved where (ADRs written or extended, lines added to agent docs), what you deleted by kind, and any passage you weren't sure was scaffolding, left in place for them to decide. If the repo's `CLAUDE.md` doesn't say where agents should record decisions, suggest a line for it so the scaffolding stops reappearing.
