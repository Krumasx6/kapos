# KAPOS project rules

- The KAPOS blueprint PDF is the source of truth for story, IDs, flags, and rules.
- Never change scene IDs, decision IDs, flag names, or enum values.
- Copy dialogue and narration word for word, including Taglish. Never rewrite, shorten, or “fix” it. List suspected errors for the owner instead.
- If the blueprint is ambiguous or contradicts itself, stop and ask. Do not guess.
- Story lives in data (`story/*.json` and the text CSV). No story logic in GDScript.
- Load one chapter at a time. Do not load a later chapter early.
- All art goes through `assets/manifest.json` IDs. Never hard-code art paths.
- Run `tools/build_graph.py` and `tools/validate_story.py` after every story change.
- Do not claim anything works unless you ran it. Report what you ran and what you did not.
- Keep the `TEST` fixture in its own section so it can be deleted.
