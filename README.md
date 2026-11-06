# KAPOS narrative pipeline

The active data set contains Chapter 1 (`C1`) only. The verified `TEST` fixture remains isolated in `story/chapters/test.json` with its flag under `test_fixture_flags`; it is not listed in the active `story/index.json` chapter files. Chapter 1 text is localized through stable keys in `story/text/en_tl.csv`, and placeholder stages and portraits are declared in `assets/manifest.json`.

## Run the game

Open this folder in the Godot version already recorded in `project.godot`, then run the project (F5). The runner opens `C1-S01`, follows Chapter 1 choices, and shows the `FLOW-C1` decision flowchart after the C1-S08 hub. The flowchart preview is available from the toolbar. Save and load buttons expose three manual slots; autosaves are stored under `user://`.

## Build and validate story data

Requires Python 3 on `PATH`. From the project root in PowerShell:

```powershell
python tools/build_graph.py
python tools/validate_story.py
```

The validator checks active Chapter 1 node structure, option targets, flag references, enum values, localization keys, manifest IDs, and reachability from `C1-S01`. It runs one expected-value test for each decision option, all 36 combinations of C1-D1 × (C1-D2 or C1-D2b) × C1-D3, and four C1-S08 variant-priority cases. It also runs 10,000 deterministic random walks and prints option coverage.

The `TEST` fixture and its flag are kept separately for deletion when no longer needed. Only chapter files listed in `story/index.json` are loaded by the game.
