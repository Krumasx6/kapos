#!/usr/bin/env python3
"""Validate active story data and exercise Chapter 1 golden paths and bots."""
import csv
import json
import random
import sys
from itertools import product
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STORY = ROOT / "story"
DERIVED_NAMES = {"m_status", "k_stance", "knows_lockbox", "caca_takes_run", "evidence_score", "civic_outcome", "death_toll"}

def load(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"{path.relative_to(ROOT)}: {error}") from error

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

def csv_table() -> dict[str, list[str]]:
    with (STORY / "text" / "en_tl.csv").open(encoding="utf-8-sig", newline="") as source:
        rows = list(csv.reader(source))
    table: dict[str, list[str]] = {}
    for row in rows[1:]:
        if len(row) >= 2 and row[0]:
            table.setdefault(row[0], []).append(row[1])
    return table

def matches(condition, state, derived=None) -> bool:
    derived = derived or {}
    if not isinstance(condition, dict) or len(condition) != 1:
        return False
    if "always" in condition: return bool(condition["always"])
    if "flag" in condition: return bool(state.get(condition["flag"], derived.get(condition["flag"])))
    if "eq" in condition:
        name, expected = condition["eq"]
        return state.get(name, derived.get(name)) == expected
    if "in" in condition:
        name, values = condition["in"]
        return state.get(name, derived.get(name)) in values
    if "gte" in condition:
        name, expected = condition["gte"]
        return state.get(name, derived.get(name, 0)) >= expected
    if "lte" in condition:
        name, expected = condition["lte"]
        return state.get(name, derived.get(name, 0)) <= expected
    if "all" in condition: return all(matches(item, state, derived) for item in condition["all"])
    if "any" in condition: return any(matches(item, state, derived) for item in condition["any"])
    if "not" in condition: return not matches(condition["not"], state, derived)
    return False

def apply_effects(effects, state, definitions) -> None:
    for effect in effects:
        if "set" in effect:
            state[effect["set"]] = effect["to"]
        elif "add" in effect:
            name = effect["add"]
            value = state.get(name, definitions[name].get("default", 0)) + effect.get("by", 0)
            state[name] = max(definitions[name].get("min", value), min(definitions[name].get("max", value), value))
        elif "clamp" in effect:
            name = effect["clamp"]
            value = state.get(name, definitions[name].get("default", 0))
            state[name] = max(effect.get("min", definitions[name].get("min", value)), min(effect.get("max", definitions[name].get("max", value)), value))

def option_map(nodes):
    return {node["id"]: {option["id"]: option for option in node.get("options", [])} for node in nodes.values() if node.get("type") == "decision"}

def run_route(nodes, definitions, route):
    state = {name: definition.get("default") for name, definition in definitions.items()}
    selected = {"C1-D1": route[0], "C1-D2": route[1], "C1-D3": route[-1]}
    if route[1] == "C": selected["C1-D2b"] = route[2]
    current = "C1-S01"
    options = option_map(nodes)
    while current in nodes:
        node = nodes[current]
        if node.get("type") == "flowchart": break
        if node.get("type") == "decision":
            choice = selected.get(current)
            option = options[current].get(choice)
            if option is None or not matches(option.get("requires", {"always": True}), state):
                raise AssertionError(f"route has no unlocked choice at {current}/{choice}")
            apply_effects(option.get("effects", []), state, definitions)
            current = option["next"]
            for conditional in option.get("next_if", []):
                if matches(conditional.get("when", {}), state):
                    apply_effects(conditional.get("effects", []), state, definitions)
                    current = conditional.get("next", current)
                    break
        elif node.get("type") == "hub":
            if not any(matches(v.get("when", {"always": True}), state) for v in node.get("variants", [])):
                raise AssertionError("C1-S08 has no matching variant")
            current = node.get("next", "")
        else:
            current = node.get("next", "")
    if current != "FLOW-C1": raise AssertionError(f"route ended at {current!r}")
    return state

def expected_state(route):
    d1, d2, d3 = route[0], route[1], route[-1]
    expected = {"meds_choice": {"A":"anna_fee_lost","B":"half_dose","C":"loan_5_6"}[d1], "m_debt":1 if d1=="C" else 0, "m_trust":-1 if d1=="A" else 0, "saw_envelope":d2=="C", "ramil_offer":None, "m_tulay":0, "mk_met":False, "caca_phone":{"A":"confronted","B":"calm","C":"ignored"}[d3]}
    if d2 == "A": expected.update(ramil_offer="took",m_tulay=1,mk_met=True)
    elif d2 == "B": expected["ramil_offer"]="declined"
    else:
        outcome=route[2]
        expected["ramil_offer"]={"A":"peeked_took","B":"peeked_declined"}[outcome]
        if outcome=="A": expected.update(m_tulay=1,mk_met=True)
    expected["m_trust"] += -1 if d3=="A" else (1 if d3=="B" else 0)
    return expected

def golden_tests(nodes, definitions):
    failures=[]
    single_count=0
    expected_options={
        ("C1-D1","A"): {"meds_choice":"anna_fee_lost","m_trust":-1},
        ("C1-D1","B"): {"meds_choice":"half_dose"},
        ("C1-D1","C"): {"meds_choice":"loan_5_6","m_debt":1},
        ("C1-D2","A"): {"ramil_offer":"took","m_tulay":1,"mk_met":True},
        ("C1-D2","B"): {"ramil_offer":"declined"},
        ("C1-D2","C"): {"saw_envelope":True},
        ("C1-D2b","A"): {"ramil_offer":"peeked_took","m_tulay":1,"mk_met":True},
        ("C1-D2b","B"): {"ramil_offer":"peeked_declined"},
        ("C1-D3","A"): {"caca_phone":"confronted","m_trust":-1},
        ("C1-D3","B"): {"caca_phone":"calm","m_trust":1},
        ("C1-D3","C"): {"caca_phone":"ignored"},
    }
    for node_id, options in option_map(nodes).items():
        for option_id, option in options.items():
            state={name:definition.get("default") for name,definition in definitions.items()}
            apply_effects(option.get("effects",[]),state,definitions)
            for name,value in expected_options[(node_id,option_id)].items():
                if state.get(name)!=value: failures.append(f"option test {node_id}/{option_id}: {name} expected {value!r}, got {state.get(name)!r}")
            single_count+=1
    routes=[]
    delivery_paths=[("A",),("B",),("C","A"),("C","B")]
    for d1, delivery, d3 in product("ABC",delivery_paths,"ABC"):
        route=(d1,*delivery,d3)
        routes.append(route)
        actual=run_route(nodes,definitions,route)
        for name,value in expected_state(route).items():
            if actual.get(name)!=value: failures.append(f"golden path {route}: {name} expected {value!r}, got {actual.get(name)!r}")
    row_routes=[("C","A","A"), ("B","A","A"), ("C","B","A"), ("B","B","A")]
    expected_rows=[0,1,2,3]
    hub=nodes["C1-S08"].get("variants",[])
    for route,expected_index in zip(row_routes,expected_rows):
        state=run_route(nodes,definitions,route)
        idx=next((i for i,v in enumerate(hub) if matches(v.get("when",{"always":True}),state)),None)
        if idx!=expected_index: failures.append(f"hub route {route} selected row {idx}, expected {expected_index}")
    return failures,single_count,len(routes),len(row_routes)

def random_walks(nodes, definitions, entry, run_count=10000):
    rng=random.Random(20261106)
    chosen={}
    hits=set()
    stalls=[]
    for run_index in range(run_count):
        state={name:definition.get("default") for name,definition in definitions.items()}
        current=entry
        steps=0
        while current in nodes and steps<=len(nodes)+2:
            node=nodes[current]; steps+=1
            if node.get("type")=="flowchart": break
            if node.get("type")=="decision":
                hits.add(current)
                options=[o for o in node.get("options",[]) if matches(o.get("requires",{"always":True}),state)]
                if not options:
                    stalls.append(f"run {run_index}: no unlocked option at {current}"); break
                selected=rng.choice(options); key=(current,selected["id"]); chosen[key]=chosen.get(key,0)+1
                apply_effects(selected.get("effects",[]),state,definitions); current=selected.get("next","")
                for branch in selected.get("next_if",[]):
                    if matches(branch.get("when",{}),state):
                        apply_effects(branch.get("effects",[]),state,definitions); current=branch.get("next",current); break
            elif node.get("type")=="hub":
                if not any(matches(v.get("when",{"always":True}),state) for v in node.get("variants",[])):
                    stalls.append(f"run {run_index}: no matching hub variant at {current}"); break
                current=node.get("next","")
            else: current=node.get("next","")
            if not current:
                stalls.append(f"run {run_index}: missing next node"); break
        else: stalls.append(f"run {run_index}: traversal limit")
    return hits,chosen,stalls

def validate():
    errors=[]
    index=load(STORY/"index.json")
    if index.get("entry_node")!="C1-S01": errors.append("active entry_node must be C1-S01 for Stage 2")
    declared=load(STORY/"flags.json")
    definitions=dict(declared.get("flags",{})); definitions.update(declared.get("test_fixture_flags",{}))
    chapters=[]
    for relative in index.get("chapter_files",[]): chapters.append(load(STORY/relative))
    if [chapter.get("id") for chapter in chapters] != ["C1"]: errors.append("Stage 2 active chapter_files must contain Chapter 1 only")
    nodes={}
    for chapter in chapters:
        for node in chapter.get("nodes",[]):
            if not node.get("id") or node["id"] in nodes: errors.append(f"empty or duplicate node ID: {node.get('id')!r}")
            else: nodes[node["id"]]=node
    for name,definition in definitions.items():
        kind=definition.get("type"); default=definition.get("default")
        if kind not in {"bool","int","float","enum"}: errors.append(f"flag {name!r} has unsupported type {kind!r}")
        if "default" not in definition: errors.append(f"flag {name!r} has no declared default")
        if kind=="enum" and (not definition.get("values") or (default is not None and default not in definition["values"])): errors.append(f"enum flag {name!r} has invalid values or default")
        if kind in {"int","float"} and definition.get("min",float("-inf"))>definition.get("max",float("inf")): errors.append(f"flag {name!r} has inverted bounds")
    table=csv_table(); manifest=load(ROOT/"assets"/"manifest.json"); characters=load(STORY/"characters.json").get("characters",{})
    for cid,character in characters.items():
        if character.get("name_key") not in table: errors.append(f"character {cid}: missing localized name")
        if character.get("portrait_id") not in manifest.get("portraits",{}): errors.append(f"character {cid}: undeclared portrait")
    adjacency={node_id:[] for node_id in nodes}; writes=set(); reads=set()
    for node_id,node in nodes.items():
        kind=node.get("type")
        if kind not in {"dialogue","decision","hub","flowchart"}: errors.append(f"{node_id}: unsupported type {kind!r}")
        if node.get("type") in {"dialogue","decision","hub"} and node.get("stage") and node["stage"] not in manifest.get("stages",{}): errors.append(f"{node_id}: unknown stage {node['stage']!r}")
        if node.get("next"):
            adjacency[node_id].append(node["next"])
            if node["next"] not in nodes: errors.append(f"{node_id}: next target does not exist: {node['next']}")
        if kind=="decision":
            options=node.get("options",[])
            if not options: errors.append(f"{node_id}: no options")
            ids=[o.get("id") for o in options]
            if len(ids)!=len(set(ids)): errors.append(f"{node_id}: duplicate option IDs")
            for option in options:
                if not option.get("next"): errors.append(f"{node_id}/{option.get('id')}: option has no next")
                elif option["next"] not in nodes: errors.append(f"{node_id}/{option.get('id')}: target does not exist: {option['next']}")
                else: adjacency[node_id].append(option["next"])
                if option.get("label_key") not in table: errors.append(f"{node_id}/{option.get('id')}: missing label text key")
                if option.get("locked_hint_key") and option["locked_hint_key"] not in table: errors.append(f"{node_id}/{option.get('id')}: missing locked hint")
                if not matches(option.get("requires",{"always":True}),{n:d.get("default") for n,d in definitions.items()}):
                    # A gated choice may be locked at its default; this is expected.
                    pass
                for branch in option.get("next_if",[]):
                    if not branch.get("next"): errors.append(f"{node_id}/{option.get('id')}: next_if has no next")
                    elif branch["next"] not in nodes: errors.append(f"{node_id}/{option.get('id')}: next_if target missing: {branch['next']}")
                    else: adjacency[node_id].append(branch["next"])
            if node.get("timer_seconds",0)>0 and node.get("default_option") not in ids: errors.append(f"{node_id}: invalid timed default_option")
        for variant in node.get("variants",[]):
            for line in variant.get("lines",[]):
                if line.get("text_key") not in table: errors.append(f"{node_id}: missing text key {line.get('text_key')!r}")
                if line.get("speaker") not in characters: errors.append(f"{node_id}: unknown speaker {line.get('speaker')!r}")
        for line in node.get("lines",[]):
            if line.get("text_key") not in table: errors.append(f"{node_id}: missing text key {line.get('text_key')!r}")
            if line.get("speaker") not in characters: errors.append(f"{node_id}: unknown speaker {line.get('speaker')!r}")
        for part in walk(node):
            for key,value in part.items():
                if key.endswith("_key") and value not in table: errors.append(f"{node_id}: missing localization key {value!r}")
        for part in walk(node):
            for op in ("flag","eq","in","gte","lte"):
                ref=part.get(op)
                name=ref if op=="flag" else (ref[0] if isinstance(ref,list) and ref else None)
                if name:
                    reads.add(name)
                    if name not in definitions and name not in DERIVED_NAMES: errors.append(f"{node_id}: reads undeclared flag {name!r}")
                    elif name in definitions and op in {"eq","in"} and definitions[name].get("type")=="enum":
                        values=[ref[1]] if op=="eq" else ref[1]
                        if isinstance(values,list):
                            for value in values:
                                if value is not None and value not in definitions[name].get("values",[]): errors.append(f"{node_id}: invalid enum value {value!r} for {name}")
            for op in ("set","add","clamp"):
                if op in part:
                    name=part[op]
                    if name not in definitions: errors.append(f"{node_id}: writes undeclared flag {name!r}")
                    else:
                        writes.add(name)
                        if op=="set" and definitions[name].get("type")=="enum" and part.get("to") not in definitions[name].get("values",[]): errors.append(f"{node_id}: invalid enum value {part.get('to')!r} for {name}")
    for name in reads:
        if name in definitions and name not in writes and "default" not in definitions[name]: errors.append(f"flag {name!r} is read but never written and has no default")
    for source,targets in adjacency.items():
        for target in targets:
            if target not in nodes: errors.append(f"{source}: target does not exist: {target}")
    reachable=set(); pending=[index.get("entry_node","")]
    while pending:
        current=pending.pop()
        if current in reachable or current not in nodes: continue
        reachable.add(current); pending.extend(adjacency[current])
    for node_id in nodes.keys()-reachable: errors.append(f"unreachable C1 node from C1-S01: {node_id}")
    graph=load(STORY/"graph.json")
    if graph.get("entry_node")!=index.get("entry_node"): errors.append("graph.json entry_node does not match story/index.json")
    graph_ids={n.get("id") for n in graph.get("nodes",[])}
    for edge in graph.get("edges",[]):
        if edge.get("from") not in graph_ids or edge.get("to") not in graph_ids: errors.append(f"graph.json has unknown edge {edge}")
    return errors,nodes,definitions,index.get("entry_node","C1-S01")

def main():
    try: errors,nodes,definitions,entry=validate()
    except (ValueError,KeyError,TypeError) as error:
        print(f"ERROR: {error}",file=sys.stderr); return 2
    if errors:
        print("Story validation failed:"); print("\n".join(f"- {problem}" for problem in errors)); return 1
    print(f"Structure passed: {len(nodes)} C1 nodes reachable from {entry}; every option has a valid next.")
    golden_errors,single_count,path_count,hub_count=golden_tests(nodes,definitions)
    if golden_errors:
        print("Golden-path failures:"); print("\n".join(f"- {problem}" for problem in golden_errors)); return 1
    print(f"Golden tests passed: {single_count} decision options; {path_count} complete decision combinations; {hub_count} C1-S08 rows.")
    hits,choices,stalls=random_walks(nodes,definitions,entry)
    if stalls:
        print(f"Random-walk failure: {stalls[0]}"); return 1
    decisions={node_id for node_id,node in nodes.items() if node.get("type")=="decision"}
    print(f"Random walks: 10,000 runs, no stalls; decisions hit {len(hits)}/{len(decisions)}.")
    missed=[f"{node_id}/{option['id']}" for node_id,node in nodes.items() if node.get("type")=="decision" for option in node.get("options",[]) if choices.get((node_id,option["id"]),0)==0]
    print("Coverage report: " + ("all C1 options reached" if not missed else "never reached: " + ", ".join(missed)))
    return 1 if hits!=decisions or missed else 0

if __name__=="__main__": raise SystemExit(main())
