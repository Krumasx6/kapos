# KAPOS narrative pipeline

The active data set contains Chapters 1–6 (`C1` → `C6`). Chapters are loaded sequentially as play advances, and flags persist in `StoryState` and saves. The `TEST` fixture remains isolated in `story/chapters/test.json` with its flag under `test_fixture_flags`; it is not listed in the active `story/index.json` chapter files. Text uses stable keys in `story/text/en_tl.csv`, and placeholder stages and portraits are declared in `assets/manifest.json`.

## Run the game

Open this folder in the Godot version already recorded in `project.godot`, then run the project (F5). The runner opens `C1-S01`, follows choices through Chapter 6, and shows each chapter's decision flowchart before continuing. C5-D4 defaults to B after 15 seconds, the VAW desk response. Save and load buttons expose three manual slots; autosaves are stored under `user://`.

## Build and validate story data

Requires Python 3 on `PATH`. From the project root in PowerShell:

```powershell
python tools/build_graph.py
python tools/validate_story.py
```

The validator checks active Chapters 1–6 node structure, option targets, flag references, enum values, localization keys, manifest IDs, and reachability from `C1-S01`. It covers every decision option, 36 Chapter 1 routes, 27 each in Chapters 2 and 3, 20 curated C1–C6 routes, the C4-S06 additive hub rows, C5-S08 and C6-S07 variants, X1/X2, C6-D3 bond rules, derived values, and save/load persistence. It also runs 10,000 deterministic random walks and reports option coverage.

The `TEST` fixture and its flag are kept separately for deletion when no longer needed. Only chapter files listed in `story/index.json` are loaded by the game.
