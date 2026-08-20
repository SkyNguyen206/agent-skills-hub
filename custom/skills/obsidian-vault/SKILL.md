---
name: obsidian-vault
description: Search, create, link, and organize notes in Sky's Obsidian vault at /home/skynguyen/Documents/Obsidian Vault/ using wikilinks, index notes, and an ACE-style evolving playbook of conventions. Use whenever the user wants to find, create, or restructure a note, mentions "second brain", "vault", "Obsidian", or asks Claude to remember a convention for note-taking. Also use when the user wants to review, prune, or update the playbook of vault conventions itself.
---

# Obsidian Vault (ACE-managed)

This skill is split into two layers, mirroring ACE's separation of *execution* from *learned strategy*:

1. **This file (SKILL.md)** — the Generator's operating manual: where the vault lives, how to search it, how to create/link notes. Stable, rarely changes.
2. **`references/playbook.md`** — the Curator's output: a growing list of ID'd, counted bullets capturing conventions Sky has actually adopted (naming, tagging, structural rules). This is expected to change over time. **Always read it before any create/restructure action** — it may have grown since this SKILL.md was written.

Do not fold playbook content into this file. Keep the split — it's what lets the playbook grow via incremental delta-updates instead of triggering a full rewrite (context collapse) every time a convention changes.

## Vault location

`/home/skynguyen/Documents/Obsidian Vault/`

> Assumption: this is your Ubuntu vault path as you specified. If `load-skills.sh` expects skills at a specific directory (e.g. `~/.claude/skills/`), drop this whole folder there so it auto-loads — let me know the exact path if it differs and I'll adjust the packaging.

## Workflow: Search (Generator retrieves context)

```bash
VAULT="/home/skynguyen/Documents/Obsidian Vault/"

# By filename
find "$VAULT" -name "*.md" | grep -i "keyword"

# By content
grep -rl "keyword" "$VAULT" --include="*.md"
```

Prefer Grep/Glob tools directly on `$VAULT` if available in the environment.

## Workflow: Create a note (Curator applies a structured update)

1. **Check `references/playbook.md` first** — naming/structure rules may have changed.
2. **Duplicate check before writing** (mutating op — don't silently overwrite):
   ```bash
   find "$VAULT" -iname "<Title>.md"
   ```
3. Apply current naming/structure convention from the playbook (as of writing: Title Case filename, flat — no folders).
4. **Use `references/templates.md`** for the actual file shape — frontmatter (`type`, `status`, `tags`, `created`/`updated`) plus body sections. Pick the "Regular note" or "Index note" template depending on what's being created; pick the closest `type` rather than inventing a new one.
5. Write content as a self-contained unit of learning; start `status: seed` unless the content is clearly already settled.
6. Add `[[wikilinks]]` to related/dependency notes at the bottom (regular notes) or as the entire body (index notes).
7. If part of a numbered sequence, use the hierarchical numbering scheme from the playbook.
8. **Verify** the file was actually created:
   ```bash
   test -f "$VAULT/<Title>.md" && echo OK
   ```

## Workflow: Edit an existing note

- Bump `updated` in frontmatter on any content change.
- Move `status` forward (`seed` → `growing` → `evergreen`) as the note matures — don't reset it backward without a clear reason (e.g. the note was proven wrong and is being substantially reworked).

## Workflow: Find backlinks

```bash
grep -rl "\[\[Note Title\]\]" "$VAULT"
```

## Workflow: Find index notes

```bash
find "$VAULT" -iname "*Index*"
```

## Workflow: Update the playbook (Reflector → Curator loop)

Trigger this whenever, mid-session, Sky corrects a convention, states a new rule ("từ giờ dùng snake_case cho tag"), or you notice a repeated pattern across notes that isn't yet captured.

1. Open `references/playbook.md`.
2. **New convention** → append a new bullet with the next sequential ID, `helpful:0 harmful:0`.
3. **Existing convention worked** → increment its `helpful` count.
4. **Existing convention caused friction / was overridden by Sky** → increment `harmful`, but do not auto-delete. Flag it to Sky in your response and let them decide whether to prune — a bullet Sky disagrees with once may still be right most of the time.
5. Never rewrite the whole playbook file to "clean it up." Edit only the touched bullet(s). This is the core ACE discipline: incremental deltas, not summarization.
