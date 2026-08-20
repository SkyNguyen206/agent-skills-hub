# Note Templates

Two shapes: a regular note, and an index note. Use the frontmatter fields
to carry metadata that folders would normally carry — the vault is flat,
so `type`/`status`/`tags` are how notes get organized/queried instead.

`status` follows an evergreen-note lifecycle: a note doesn't need to be
complete to exist — it grows.

- `seed` — just captured, may be a fragment or a raw idea
- `growing` — actively being expanded/corrected across sessions
- `evergreen` — settled, stable, safe to link into other notes as a dependency

---

## Regular note

```markdown
---
title: {Title}
type: concept        # concept | reference | project | log
status: seed          # seed | growing | evergreen
tags: []
created: {YYYY-MM-DD}
updated: {YYYY-MM-DD}
---

# {Title}

## Summary
1-2 sentences — the core idea. Reading only this should convey the point.

## Details
...

## Related
- [[Note A]]
- [[Note B]]
```

- `type` picks the closest fit: `concept` (an idea/topic), `reference`
  (a fact sheet / cheatsheet), `project` (an active piece of work),
  `log` (a dated entry, e.g. a debugging session or decision record).
- On every edit, bump `updated` and reconsider `status` — most edits
  should move a note forward (`seed` → `growing` → `evergreen`), not
  reset it backward.

## Index note

```markdown
---
title: {Topic} Index
type: index
tags: [index]
created: {YYYY-MM-DD}
updated: {YYYY-MM-DD}
---

# {Topic} Index

- [[Note 1]]
- [[Note 2]]
```

- Index notes stay pure lists of `[[wikilinks]]` — no prose, no summary.
  If a note needs explaining, that explanation belongs in the note itself.
