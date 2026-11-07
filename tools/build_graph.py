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
    lane_ids = ["mario", "kaloy", "perlita"]
    lane_x = {lane: 30 + i * 430 for i, lane in enumerate(lane_ids)}
    row_by_lane = {lane: 0 for lane in lane_ids}
    lanes = [{"id": lane, "x": lane_x[lane], "title_key": f"UI-LANE-{lane.upper()}"} for lane in lane_ids]
    for chapter in chapters:
        protagonist = chapter.get("protagonist", "")
        if protagonist not in lane_x:
            raise ValueError(f"chapter {chapter.get('id')} has unknown protagonist lane {protagonist!r}")
        x = lane_x[protagonist]
        for node in chapter.get("nodes", []):
            node_id = node["id"]
            row = row_by_lane[protagonist]
            nodes.append({"id": node_id, "type": node["type"], "chapter": chapter["id"], "protagonist": protagonist, "flowchart_lock": node.get("flowchart_lock")})
            positions[node_id] = [x, 145 + row * 135]
            row_by_lane[protagonist] += 1
            if node.get("type") == "decision":
                for option_index, option in enumerate(node.get("options", [])):
                    option_node = f"{node_id}/{option['id']}"
                    nodes.append({"id": option_node, "type": "option", "chapter": chapter["id"], "protagonist": protagonist, "decision_id": node_id, "option_id": option["id"], "label_key": option.get("label_key", ""), "locked_hint_key": option.get("locked_hint_key", ""), "requires": option.get("requires", {"always": True})})
                    positions[option_node] = [x + 220, 145 + row * 135 + option_index * 72]
                    edges.append({"from": node_id, "to": option_node, "option_id": option["id"]})
                    if option.get("next"):
                        edges.append({"from": option_node, "to": option["next"], "option_id": ""})
                    for branch in option.get("next_if", []):
                        if branch.get("next"):
                            edges.append({"from": option_node, "to": branch["next"], "option_id": ""})
            elif node.get("next"):
                edges.append({"from": node_id, "to": node["next"], "option_id": ""})
    out = {"entry_node": index["entry_node"], "nodes": nodes, "edges": edges, "positions": positions, "lanes": lanes}
    (STORY / "graph.json").write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")

if __name__ == "__main__":
    main()
