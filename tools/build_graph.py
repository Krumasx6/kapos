#!/usr/bin/env python3
"""Generate the static graph layout consumed by the flowchart screen."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STORY = ROOT / "story"

def main() -> None:
    index = json.loads((STORY / "index.json").read_text(encoding="utf-8"))
    nodes, edges, positions = [], [], {}
    chapters = [json.loads((STORY / name).read_text(encoding="utf-8")) for name in index["chapter_files"]]
    row = 0
    for chapter in chapters:
        for node in chapter.get("nodes", []):
            node_id = node["id"]
            nodes.append({"id": node_id, "type": node["type"], "chapter": chapter["id"], "flowchart_lock": node.get("flowchart_lock")})
            positions[node_id] = [80, 130 + row * 110]
            row += 1
            if node.get("type") == "decision":
                for option_index, option in enumerate(node.get("options", [])):
                    option_node = f"{node_id}/{option['id']}"
                    nodes.append({"id": option_node, "type": "option", "chapter": chapter["id"], "decision_id": node_id, "option_id": option["id"]})
                    positions[option_node] = [420, 130 + (row - 1) * 110 + option_index * 62]
                    edges.append({"from": node_id, "to": option_node, "option_id": option["id"]})
                    if option.get("next"):
                        edges.append({"from": option_node, "to": option["next"], "option_id": ""})
                    for branch in option.get("next_if", []):
                        if branch.get("next"):
                            edges.append({"from": option_node, "to": branch["next"], "option_id": ""})
            elif node.get("next"):
                edges.append({"from": node_id, "to": node["next"], "option_id": ""})
    out = {"entry_node": index["entry_node"], "nodes": nodes, "edges": edges, "positions": positions}
    (STORY / "graph.json").write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")

if __name__ == "__main__":
    main()
