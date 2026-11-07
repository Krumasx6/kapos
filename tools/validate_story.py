#!/usr/bin/env python3
"""Validate active KAPOS chapters C1-C6 and run deterministic playthrough checks."""
import csv
import json
import random
import sys
from itertools import product
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STORY = ROOT / "story"
DERIVED = {}

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

def csv_table():
    with (STORY / "text" / "en_tl.csv").open(encoding="utf-8-sig", newline="") as source:
        rows = list(csv.reader(source))
    table = {}
    duplicates = set()
    for row in rows[1:]:
        if len(row) >= 2 and row[0]:
            if row[0] in table: duplicates.add(row[0])
            table[row[0]] = row[1]
    return table, duplicates

def value(name, state):
    if name in state: return state[name]
    definition = DERIVED.get(name, {})
    for rule in definition.get("rules", []):
        if "when" not in rule or matches(rule["when"], state): return rule.get("value")
    return definition.get("default")

def matches(condition, state):
    if not isinstance(condition, dict) or len(condition) != 1: return False
    if "always" in condition: return bool(condition["always"])
    if "flag" in condition: return bool(value(condition["flag"], state))
    if "eq" in condition:
        name, expected = condition["eq"]
        return value(name, state) == expected
    if "in" in condition:
        name, values = condition["in"]
        return value(name, state) in values
    if "gte" in condition:
        name, expected = condition["gte"]
        return value(name, state) >= expected
    if "lte" in condition:
        name, expected = condition["lte"]
        return value(name, state) <= expected
    if "all" in condition: return all(matches(item, state) for item in condition["all"])
    if "any" in condition: return any(matches(item, state) for item in condition["any"])
    if "not" in condition: return not matches(condition["not"], state)
    return False

def apply_effects(effects, state, definitions):
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

def options_by_decision(nodes):
    return {node_id: {option["id"]: option for option in node.get("options", [])} for node_id, node in nodes.items() if node.get("type") == "decision"}

def matching_variants(node, state):
    matches_found = [i for i, variant in enumerate(node.get("variants", [])) if matches(variant.get("when", {"always": True}), state)]
    return matches_found if node.get("variant_mode") == "all_matching" else matches_found[:1]

def simulate(nodes, definitions, entry, selections, initial_state=None, follow_chapter_flows=False, stop_at=""):
    state = {name: definition.get("default") for name, definition in definitions.items()}
    if initial_state is not None: state.update(initial_state)
    choices = options_by_decision(nodes)
    current = entry
    variants = {}
    visited = set()
    while current in nodes:
        if current in visited: raise AssertionError(f"cycle encountered at {current}")
        visited.add(current)
        if current == stop_at: return state, current, variants
        node = nodes[current]
        kind = node.get("type")
        if kind == "flowchart":
            next_node = node.get("next", "")
            for branch in node.get("next_if", []):
                if matches(branch.get("when", {}), state):
                    apply_effects(branch.get("effects", []), state, definitions)
                    next_node = branch.get("next", next_node)
                    break
            if not follow_chapter_flows or not next_node: return state, current, variants
            current = next_node
            continue
        if kind == "decision":
            option_id = selections.get(current)
            option = choices[current].get(option_id)
            if option is None: raise AssertionError(f"missing golden selection for {current}")
            if not matches(option.get("requires", {"always": True}), state): raise AssertionError(f"locked golden option {current}/{option_id}")
            apply_effects(option.get("effects", []), state, definitions)
            current = option["next"]
            for branch in option.get("next_if", []):
                if matches(branch.get("when", {}), state):
                    apply_effects(branch.get("effects", []), state, definitions)
                    current = branch.get("next", current)
                    break
            continue
        if kind == "hub":
            chosen = matching_variants(node, state)
            if not chosen: raise AssertionError(f"no hub variant matched at {current}")
            variants[current] = chosen if node.get("variant_mode") == "all_matching" else chosen[0]
            for index in chosen:
                apply_effects(node["variants"][index].get("effects", []), state, definitions)
        else:
            for index in matching_variants(node, state):
                apply_effects(node.get("variants", [])[index].get("effects", []), state, definitions)
        current = node.get("next", "")
        if not current: raise AssertionError(f"node {node.get('id')} has no next")
    raise AssertionError(f"route reached unknown node {current!r}")

def clamped(value, definition):
    return max(definition["min"], min(definition["max"], value))

def c1_expected(route, definitions):
    d1, d2, d3 = route[0], route[1], route[-1]
    expected = {
        "meds_choice":{"A":"anna_fee_lost","B":"half_dose","C":"loan_5_6"}[d1],
        "m_debt":1 if d1 == "C" else 0,
        "m_trust":-1 if d1 == "A" else 0,
        "saw_envelope":d2 == "C",
        "ramil_offer":None,"m_tulay":0,"mk_met":False,
        "caca_phone":{"A":"confronted","B":"calm","C":"ignored"}[d3],
        "dado_notice":0,
    }
    if d2 == "A": expected.update(ramil_offer="took",m_tulay=1,mk_met=True)
    elif d2 == "B": expected["ramil_offer"]="declined"
    else:
        outcome=route[2]
        expected["ramil_offer"]={"A":"peeked_took","B":"peeked_declined"}[outcome]
        if outcome == "A": expected.update(m_tulay=1,mk_met=True)
    expected["m_trust"] = clamped(expected["m_trust"] + (-1 if d3 == "A" else (1 if d3 == "B" else 0)), definitions["m_trust"])
    return expected

def assert_expected(errors, label, actual, expected):
    for name, value in expected.items():
        if actual.get(name) != value:
            errors.append(f"{label}: {name} expected {value!r}, got {actual.get(name)!r}")

def single_option_tests(nodes, definitions):
    errors=[]; count=0
    expected={
        "C1-D1/A":{"meds_choice":"anna_fee_lost","m_trust":-1},"C1-D1/B":{"meds_choice":"half_dose"},"C1-D1/C":{"meds_choice":"loan_5_6","m_debt":1},
        "C1-D2/A":{"ramil_offer":"took","m_tulay":1,"mk_met":True},"C1-D2/B":{"ramil_offer":"declined"},"C1-D2/C":{"saw_envelope":True},
        "C1-D2b/A":{"ramil_offer":"peeked_took","m_tulay":1,"mk_met":True},"C1-D2b/B":{"ramil_offer":"peeked_declined"},
        "C1-D3/A":{"caca_phone":"confronted","m_trust":-1},"C1-D3/B":{"caca_phone":"calm","m_trust":1},"C1-D3/C":{"caca_phone":"ignored"},
        "C2-D1/A":{"k_father_morning":"appeased","k_safety":0},"C2-D1/B":{"k_father_morning":"confronted","k_safety":-1},"C2-D1/C":{"k_father_morning":"shielded","k_safety":1},
        "C2-D2/A":{"k_wage":"joined","k_solidarity":1,"dado_notice":1},"C2-D2/B":{"k_wage":"silent"},"C2-D2/C":{"k_wage":"asked_ot","dado_notice":1},
        "C2-D3/A":{"k_box":"photographed","k_photo_evidence":True},"C2-D3/B":{"k_box":"ignored"},"C2-D3/C":{"k_box":"asked_tito","tito_story":True,"k_solidarity":1},
        "C3-D1/A":{"p_bea":"insisted","bond_bea":-1,"bond_jessa":-1},"C3-D1/B":{"p_bea":"gentle","bond_bea":1,"bond_jessa":1},"C3-D1/C":{"p_bea":"deferred","bond_jessa":1},
        "C3-D2/A":{"p_notebook":"took_over","bond_jessa":-2},"C3-D2/B":{"p_notebook":"jessa_stays","bond_jessa":1},"C3-D2/C":{"p_notebook":"apologized","bond_jessa":2},
        "C3-D3/A":{"p_paolo":"promised","bond_paolo":1},"C3-D3/B":{"p_paolo":"honest","bond_paolo":1},"C3-D3/C":{"p_paolo":"pulled_rank","bond_paolo":-2},
        "C4-D1/A":{"money_fix":"ramil_advance","m_tulay":1,"m_debt":0,"mk_met":True},"C4-D1/B":{"money_fix":"maniquis_patronage","owes_maniquis":True,"m_debt":0},"C4-D1/C":{"money_fix":"sold_bike","m_no_bike":True,"m_debt":0},
        "C4-D2/A":{"pharmacy":"lent","mk_bond":1},"C4-D2/B":{"pharmacy":"kept"},"C4-D2/C":{"pharmacy":"asked_kaloy","mk_bond":1},
        "C4-D3/A":{"caca_arrest":"paid_settlement","m_debt":1},"C4-D3/B":{"caca_arrest":"diversion","m_trust":1},"C4-D3/C":{"caca_arrest":"tulay_favor","m_tulay":1,"mk_met":True},
        "C5-D1/A":{"k_night_job":"accepted","k_corruption":1,"dado_notice":1},"C5-D1/B":{"k_night_job":"declined"},"C5-D1/C":{"k_night_job":"accepted_recording","k_corruption":1},
        "C5-D2/A":{"k_union":"committed","k_solidarity":1},"C5-D2/B":{"k_union":"regularized","k_corruption":1},"C5-D2/C":{"k_union":"neutral"},
        "C5-D3/A":{"k_project":"toned_down"},"C5-D3/B":{"k_project":"supported","project_public":True,"k_solidarity":1,"dado_notice":1},"C5-D3/C":{"k_project":"asked_alma","alma_contacted":True},
        "C5-D4/A":{"k_violence":"struck","k_safety":-1},"C5-D4/B":{"k_violence":"vaw_desk","k_safety":1},"C5-D4/C":{"k_violence":"relocated","k_safety":2},
        "C6-D1/A":{"p_ruben":"let_in","ruben_info":True,"bond_paolo":-1,"bond_jessa":-1},"C6-D1/B":{"p_ruben":"outside"},"C6-D1/C":{"p_ruben":"refused","bond_paolo":1,"bond_jessa":1},
        "C6-D2/A":{"p_work":"recruiter","p_income":0,"bond_paolo":-2},"C6-D2/B":{"p_work":"valdez","p_income":2,"bond_family":-1},"C6-D2/C":{"p_work":"local","p_income":1,"bond_family":1},
        "C6-D3/A":{"p_jessa_abroad":"forbid","jessa_status":"stays_resentful"},"C6-D3/B":{"p_jessa_abroad":"licensed","jessa_status":"leaving_licensed","bond_jessa":1},"C6-D3/C":{"p_jessa_abroad":"compromise","jessa_status":"stays_studying","bond_jessa":2},
    }
    initial={"C4-D2/C":{"mk_met":True,"k_photo_evidence":True},"C4-D3/A":{"money_fix":"maniquis_patronage"},"C6-D2/A":{"p_paolo":"promised"},"C6-D3/A":{"bond_jessa":1},"C6-D3/C":{"p_income":1}}
    for node_id, options in options_by_decision(nodes).items():
        for option_id, option in options.items():
            key=f"{node_id}/{option_id}"
            state={name:definition.get("default") for name,definition in definitions.items()}
            state.update(initial.get(key,{}))
            apply_effects(option.get("effects",[]),state,definitions)
            for branch in option.get("next_if",[]):
                if matches(branch.get("when",{}),state): apply_effects(branch.get("effects",[]),state,definitions); break
            if key not in expected: errors.append(f"missing explicit option assertion for {key}")
            else: assert_expected(errors,f"option {key}",state,expected[key])
            count+=1
    return errors,count

def c1_golden_tests(nodes, definitions):
    errors=[]; count=0
    routes=[]
    delivery=[("A",),("B",),("C","A"),("C","B")]
    for d1, middle, d3 in product("ABC",delivery,"ABC"):
        route=(d1,*middle,d3)
        selected={"C1-D1":d1,"C1-D2":d1 if False else middle[0],"C1-D3":d3}
        if middle[0]=="C": selected["C1-D2b"]=middle[1]
        actual,flow,variants=simulate(nodes,definitions,"C1-S01",selected)
        if flow!="FLOW-C1": errors.append(f"C1 path {route} ended at {flow}")
        assert_expected(errors,f"C1 path {route}",actual,c1_expected(route,definitions))
        count+=1
    hub_cases=[(("C","A","A"),0),(("B","A","A"),1),(("C","B","A"),2),(("B","B","A"),3)]
    for route,row in hub_cases:
        d1,d2,d3=route
        selected={"C1-D1":d1,"C1-D2":d2,"C1-D3":d3}
        if d2=="C": selected["C1-D2b"]=d3
        actual,flow,variants=simulate(nodes,definitions,"C1-S01",selected)
        if variants.get("C1-S08")!=row: errors.append(f"C1-S08 case {route} chose row {variants.get('C1-S08')}, expected {row}")
    return errors,count,4

def c2_expected(route, definitions):
    d1,d2,d3=route
    expected={
     "k_father_morning":{"A":"appeased","B":"confronted","C":"shielded"}[d1],
     "k_safety":{"A":0,"B":-1,"C":1}[d1],
     "k_wage":{"A":"joined","B":"silent","C":"asked_ot"}[d2],
     "dado_notice":1 if d2 in {"A","C"} else 0,
     "k_solidarity":(1 if d2=="A" else 0)+(1 if d3=="C" else 0),
     "k_box":{"A":"photographed","B":"ignored","C":"asked_tito"}[d3],
     "k_photo_evidence":d3=="A","tito_story":d3=="C",
    }
    expected["k_safety"]=clamped(expected["k_safety"],definitions["k_safety"])
    expected["k_solidarity"]=clamped(expected["k_solidarity"],definitions["k_solidarity"])
    expected["dado_notice"]=clamped(expected["dado_notice"],definitions["dado_notice"])
    return expected

def c3_expected(route, definitions):
    d1,d2,d3=route
    bj={"A":-1,"B":1,"C":1}[d1]
    bj += {"A":-2,"B":1,"C":2}[d2]
    expected={
     "p_bea":{"A":"insisted","B":"gentle","C":"deferred"}[d1],
     "p_notebook":{"A":"took_over","B":"jessa_stays","C":"apologized"}[d2],
     "p_paolo":{"A":"promised","B":"honest","C":"pulled_rank"}[d3],
     "bond_bea":{"A":-1,"B":1,"C":0}[d1],
     "bond_jessa":clamped(bj,definitions["bond_jessa"]),
     "bond_paolo":{"A":1,"B":1,"C":-2}[d3],
     "bond_family":0,
    }
    return expected

def chapter_golden_tests(nodes, definitions):
    errors=[]; c2_count=0; c3_count=0
    for d1,d2,d3 in product("ABC",repeat=3):
        route=(d1,d2,d3)
        state,flow,variants=simulate(nodes,definitions,"C2-S01",{"C2-D1":d1,"C2-D2":d2,"C2-D3":d3})
        if flow!="FLOW-C2": errors.append(f"C2 path {route} ended at {flow}")
        assert_expected(errors,f"C2 path {route}",state,c2_expected(route,definitions))
        if variants.get("C2-S07") != {"A":0,"B":1,"C":2}[d1]: errors.append(f"C2 hub path {route} selected the wrong home variant")
        c2_count+=1
        state,flow,variants=simulate(nodes,definitions,"C3-S01",{"C3-D1":d1,"C3-D2":d2,"C3-D3":d3})
        if flow!="FLOW-C3": errors.append(f"C3 path {route} ended at {flow}")
        assert_expected(errors,f"C3 path {route}",state,c3_expected(route,definitions))
        if variants.get("C3-S07") != {"A":0,"B":1,"C":2}[d1]: errors.append(f"C3 hub path {route} selected the wrong drawing variant")
        is_open=matches(nodes["C3-S05C"].get("conversation_open_when",{}),state)
        if is_open != (c3_expected(route,definitions)["bond_jessa"]>=2): errors.append(f"C3 path {route} conversation condition disagrees with bond_jessa")
        c3_count+=1
    return errors,c2_count,c3_count

def test_c4_c6(nodes, definitions):
    errors=[]
    c4=nodes["C4-S06"]
    for mask in product((False,True),repeat=4):
        state={name:definition.get("default") for name,definition in definitions.items()}
        state.update({"m_tulay":1 if mask[0] else 0,"owes_maniquis":mask[1],"m_no_bike":mask[2],"caca_arrest":"diversion" if mask[3] else "paid_settlement"})
        actual=matching_variants(c4,state)
        expected=[i for i,enabled in enumerate(mask) if enabled]
        if actual!=expected: errors.append(f"C4-S06 additive rows {mask}: got {actual}, expected {expected}")
        for index in actual: apply_effects(c4["variants"][index].get("effects",[]),state,definitions)
        if state["luz_suspects"]!=mask[0]: errors.append(f"C4-S06 luz_suspects mismatch for {mask}")
    for value,expected in [("accepted",0),("declined",1),("accepted_recording",2)]:
        state={name:definition.get("default") for name,definition in definitions.items()}; state["k_night_job"]=value
        if matching_variants(nodes["C5-S08"],state)!=[expected]: errors.append(f"C5-S08 {value} selected wrong row")
    for value,expected in [("stays_studying",0),("leaving_licensed",1),("stays_resentful",2),("left_illegal",3)]:
        state={name:definition.get("default") for name,definition in definitions.items()}; state["jessa_status"]=value
        if matching_variants(nodes["C6-S07"],state)!=[expected]: errors.append(f"C6-S07 {value} selected wrong row")
    c4d2=next(option for option in nodes["C4-D2"]["options"] if option["id"]=="C")
    for met,expected in [(False,False),(True,True)]:
        state={name:definition.get("default") for name,definition in definitions.items()}; state["mk_met"]=met
        if matches(c4d2.get("requires",{}),state)!=expected: errors.append(f"X2 lock state mk_met={met} is incorrect")
    state={name:definition.get("default") for name,definition in definitions.items()}; state.update({"mk_met":True,"money_fix":"ramil_advance"})
    apply_effects(c4d2.get("effects",[]),state,definitions)
    if state["mk_bond"]!=0: errors.append("X2 C4-D2 C granted mk_bond without evidence")
    for evidence in ("k_photo_evidence","tito_story"):
        state={name:definition.get("default") for name,definition in definitions.items()}; state.update({"mk_met":True,evidence:True})
        apply_effects(c4d2.get("effects",[]),state,definitions)
        for branch in c4d2.get("next_if",[]):
            if matches(branch.get("when",{}),state): apply_effects(branch.get("effects",[]),state,definitions); break
        if state["mk_bond"]!=1: errors.append(f"X2 C4-D2 C did not grant bond for {evidence}")
    c6d3=nodes["C6-D3"]
    for bond,income,option_id in product(range(-2,4),range(0,3),"ABC"):
        state={name:definition.get("default") for name,definition in definitions.items()}; state.update({"bond_jessa":bond,"p_income":income})
        option=next(item for item in c6d3["options"] if item["id"]==option_id)
        apply_effects(option.get("effects",[]),state,definitions)
        for branch in option.get("next_if",[]):
            if matches(branch.get("when",{}),state): apply_effects(branch.get("effects",[]),state,definitions); break
        if option_id=="A": expected_status="stays_resentful" if bond>=1 else "left_illegal"; expected_bond=bond
        elif option_id=="B": expected_status="leaving_licensed"; expected_bond=clamped(bond+1,definitions["bond_jessa"])
        else: expected_status="stays_studying" if income>=1 else "stays_resentful"; expected_bond=clamped(bond+(2 if income>=1 else 0),definitions["bond_jessa"])
        if state["jessa_status"]!=expected_status or state["bond_jessa"]!=expected_bond:
            errors.append(f"C6-D3 rule bond_jessa={bond}, p_income={income}, option={option_id}: {state['jessa_status']}/{state['bond_jessa']}")
    return errors

def route_selections(index):
    abc="ABC"
    d1=abc[index%3]; d2=abc[(index//2)%3]; d2b=abc[index%2]
    select={"C1-D1":d1,"C1-D2":d2,"C1-D3":abc[(index//3)%3]}
    if d2=="C": select["C1-D2b"]=d2b
    for prefix,shift in [("C2",index//3),("C3",index//5)]:
        for n in (1,2,3): select[f"{prefix}-D{n}"]=abc[(shift+n+index)%3]
    select["C4-D1"]=abc[(index//2)%3]
    mk_met=d2=="A" or (d2=="C" and d2b=="A") or select["C4-D1"]=="A"
    select["C4-D2"]="C" if mk_met and index%3==0 else abc[(index//3)%2]
    select["C4-D3"]=abc[(index//4)%3]
    for n in (1,2,3,4): select[f"C5-D{n}"]=abc[(index//(n+1)+n)%3]
    for n in (1,2,3): select[f"C6-D{n}"]=abc[(index//(n+2)+n)%3]
    return select

def expected_full_chain(select, definitions):
    d1,d2,d3=select["C1-D1"],select["C1-D2"],select["C1-D3"]
    middle=(d2,select["C1-D2b"]) if d2=="C" else (d2,)
    state={name:definition.get("default") for name,definition in definitions.items()}
    state.update(c1_expected((d1,*middle,d3),definitions))
    state.update(c2_expected(tuple(select[f"C2-D{i}"] for i in (1,2,3)),definitions))
    state.update(c3_expected(tuple(select[f"C3-D{i}"] for i in (1,2,3)),definitions))
    d=select["C4-D1"]
    if d=="A": state.update(money_fix="ramil_advance",m_tulay=clamped(state["m_tulay"]+1,definitions["m_tulay"]),m_debt=clamped(state["m_debt"]-1,definitions["m_debt"]),mk_met=True)
    elif d=="B": state.update(money_fix="maniquis_patronage",owes_maniquis=True,m_debt=clamped(state["m_debt"]-1,definitions["m_debt"]))
    else: state.update(money_fix="sold_bike",m_no_bike=True,m_debt=clamped(state["m_debt"]-1,definitions["m_debt"]))
    d=select["C4-D2"]
    if d=="A": state.update(pharmacy="lent",mk_bond=1)
    elif d=="B": state["pharmacy"]="kept"
    else:
        state["pharmacy"]="asked_kaloy"
        if state["k_photo_evidence"] or state["tito_story"]: state["mk_bond"]=1
    d=select["C4-D3"]
    if d=="A": state["caca_arrest"]="paid_settlement"; state["m_debt"]=clamped(state["m_debt"]+int(state["money_fix"]=="maniquis_patronage"),definitions["m_debt"])
    elif d=="B": state["caca_arrest"]="diversion"; state["m_trust"]=clamped(state["m_trust"]+1,definitions["m_trust"])
    else: state.update(caca_arrest="tulay_favor",m_tulay=clamped(state["m_tulay"]+1,definitions["m_tulay"]),mk_met=True)
    state["luz_suspects"]=state["m_tulay"]>=1
    d=select["C5-D1"]
    if d=="A": state["k_night_job"]="accepted"; state["k_corruption"]=clamped(state["k_corruption"]+1,definitions["k_corruption"]); state["dado_notice"]=clamped(state["dado_notice"]+1,definitions["dado_notice"])
    elif d=="B": state["k_night_job"]="declined"
    else: state["k_night_job"]="accepted_recording"; state["k_corruption"]=clamped(state["k_corruption"]+1,definitions["k_corruption"])
    d=select["C5-D2"]
    if d=="A": state["k_union"]="committed"; state["k_solidarity"]=clamped(state["k_solidarity"]+1,definitions["k_solidarity"])
    elif d=="B": state["k_union"]="regularized"; state["k_corruption"]=clamped(state["k_corruption"]+1,definitions["k_corruption"])
    else: state["k_union"]="neutral"
    d=select["C5-D3"]
    if d=="A": state["k_project"]="toned_down"
    elif d=="B": state.update(k_project="supported",project_public=True,k_solidarity=clamped(state["k_solidarity"]+1,definitions["k_solidarity"]),dado_notice=clamped(state["dado_notice"]+1,definitions["dado_notice"]))
    else: state.update(k_project="asked_alma",alma_contacted=True)
    d=select["C5-D4"]
    state["k_violence"]={"A":"struck","B":"vaw_desk","C":"relocated"}[d]
    state["k_safety"]=clamped(state["k_safety"]+{"A":-1,"B":1,"C":2}[d],definitions["k_safety"])
    d=select["C6-D1"]
    if d=="A": state.update(p_ruben="let_in",ruben_info=True,bond_paolo=clamped(state["bond_paolo"]-1,definitions["bond_paolo"]),bond_jessa=clamped(state["bond_jessa"]-1,definitions["bond_jessa"]))
    elif d=="B": state["p_ruben"]="outside"
    else: state.update(p_ruben="refused",bond_jessa=clamped(state["bond_jessa"]+1,definitions["bond_jessa"]),bond_paolo=clamped(state["bond_paolo"]+1,definitions["bond_paolo"]))
    d=select["C6-D2"]
    if d=="A": state.update(p_work="recruiter",p_income=0)
    elif d=="B": state.update(p_work="valdez",p_income=2,bond_family=clamped(state["bond_family"]-1,definitions["bond_family"]),p_inside=True)
    else: state.update(p_work="local",p_income=1,bond_family=clamped(state["bond_family"]+1,definitions["bond_family"]))
    if d=="A" and state["p_paolo"]=="promised": state["bond_paolo"]=clamped(state["bond_paolo"]-3,definitions["bond_paolo"])
    d=select["C6-D3"]
    if d=="A": state.update(p_jessa_abroad="forbid",jessa_status="stays_resentful" if state["bond_jessa"]>=1 else "left_illegal")
    elif d=="B": state.update(p_jessa_abroad="licensed",jessa_status="leaving_licensed",bond_jessa=clamped(state["bond_jessa"]+1,definitions["bond_jessa"]))
    else: state.update(p_jessa_abroad="compromise",jessa_status="stays_studying" if state["p_income"]>=1 else "stays_resentful",bond_jessa=clamped(state["bond_jessa"]+(2 if state["p_income"]>=1 else 0),definitions["bond_jessa"]))
    return state

def curated_full_chain_tests(nodes, definitions):
    errors=[]; count=0
    for index in range(20):
        select=route_selections(index)
        actual,flow,_=simulate(nodes,definitions,"C1-S01",select,follow_chapter_flows=True)
        if flow!="FLOW-C6": errors.append(f"curated route {index+1} ended at {flow}")
        expected=expected_full_chain(select,definitions)
        keys=["meds_choice","ramil_offer","m_tulay","m_debt","m_trust","money_fix","pharmacy","mk_bond","caca_arrest","luz_suspects","k_night_job","k_union","k_project","k_corruption","dado_notice","k_safety","k_solidarity","k_violence","p_ruben","ruben_info","p_work","p_inside","p_income","p_jessa_abroad","jessa_status","bond_jessa","bond_paolo","bond_family"]
        assert_expected(errors,f"curated route {index+1}",actual,{key:expected[key] for key in keys})
        for name in DERIVED:
            if value(name,actual)!=value(name,expected): errors.append(f"curated route {index+1}: derived {name} did not match")
        count+=1
    return errors,count

def derived_tests(definitions):
    errors=[]
    for tulay,owes in product(range(4),(False,True)):
        state={name:definition.get("default") for name,definition in definitions.items()}; state.update({"m_tulay":tulay,"owes_maniquis":owes})
        expected="ENTANGLED" if tulay>=2 else ("TOUCHED" if tulay==1 or owes else "CLEAN")
        if value("m_status",state)!=expected: errors.append(f"m_status incorrect for m_tulay={tulay}, owes_maniquis={owes}")
    for job,union in product([None,"accepted","declined","accepted_recording"],[None,"committed","regularized","neutral"]):
        state={name:definition.get("default") for name,definition in definitions.items()}; state.update({"k_night_job":job,"k_union":union})
        expected="dado_man" if job=="accepted" or union=="regularized" else ("ally" if union=="committed" or job=="accepted_recording" else "neutral")
        if value("k_stance",state)!=expected: errors.append(f"k_stance incorrect for {job}/{union}")
        expected_lock=job in {"accepted","accepted_recording"}
        if value("knows_lockbox",state)!=expected_lock: errors.append(f"knows_lockbox incorrect for {job}")
        if any(name in state for name in DERIVED): errors.append("derived values were materialized in state")
    return errors

def test_x1(nodes, definitions):
    node=nodes["C2-S06"]
    variants=node.get("variants",[])
    errors=[]
    for value,expected_portrait in [("took","c1_mario_portrait"),("peeked_took","c1_mario_portrait"),("declined","c2_dindo_portrait"),("peeked_declined","c2_dindo_portrait")]:
        state={name:definition.get("default") for name,definition in definitions.items()}
        state["ramil_offer"]=value
        index=next((i for i,variant in enumerate(variants) if matches(variant.get("when",{"always":True}),state)),None)
        if index is None or variants[index].get("portrait_id")!=expected_portrait: errors.append(f"X1 {value}: expected {expected_portrait}, got variant {index}")
        if value in {"declined","peeked_declined"} and state.get("mk_met") is not False: errors.append(f"X1 {value}: mk_met must remain false")
    return errors

def test_c1_save_c2(nodes, definitions):
    errors=[]
    selection={"C1-D1":"C","C1-D2":"C","C1-D2b":"A","C1-D3":"B","C2-D1":"A","C2-D2":"B","C2-D3":"C","C3-D1":"B","C3-D2":"C","C3-D3":"A"}
    state,flow,_=simulate(nodes,definitions,"C1-S01",selection,follow_chapter_flows=True,stop_at="FLOW-C3")
    if flow!="FLOW-C3": errors.append("C1-C3 save test did not stop at FLOW-C3")
    payload={"version":3,"story_data_version":4,"node":"C4-S01C","flags":state,"branch_log":[{"decision_id":"C1-D1","option_id":"C"}],"seen_nodes":["C1-S01","C1-D1","C1-S08","C2-S01","C3-S01"],"chapter_snapshots":{"C1":{"flags":state},"C2":{"flags":state},"C3":{"flags":state}}}
    restored=json.loads(json.dumps(payload))["flags"]
    c4_state,flow,_=simulate(nodes,definitions,"C4-S01C",{"C4-D1":"C","C4-D2":"A","C4-D3":"B"},initial_state=restored)
    if flow!="FLOW-C4": errors.append("C1-C3 save test did not reach C4 flowchart")
    c1_flags=["meds_choice","ramil_offer","saw_envelope","caca_phone","mk_met","m_tulay","m_debt","m_trust"]
    for name in c1_flags:
        if restored.get(name)!=state.get(name): errors.append(f"C1-C3 flag {name} did not survive save/load into C4")
    return errors

def random_walks(nodes, definitions, entry, run_count=10000):
    rng=random.Random(20261107); hits=set(); choice_hits={}; stalls=[]
    for run_index in range(run_count):
        state={name:definition.get("default") for name,definition in definitions.items()}
        current=entry; steps=0
        while current in nodes and steps<=len(nodes)*2:
            node=nodes[current]; steps+=1; kind=node.get("type")
            if kind=="flowchart":
                current=node.get("next","")
                for branch in node.get("next_if",[]):
                    if matches(branch.get("when",{}),state):
                        apply_effects(branch.get("effects",[]),state,definitions); current=branch.get("next",current); break
                if not current: break
            elif kind=="decision":
                hits.add(current)
                available=[option for option in node.get("options",[]) if matches(option.get("requires",{"always":True}),state)]
                if not available:
                    stalls.append(f"run {run_index}: no unlocked option at {current}"); break
                option=rng.choice(available); key=(current,option["id"]); choice_hits[key]=choice_hits.get(key,0)+1
                apply_effects(option.get("effects",[]),state,definitions); current=option.get("next","")
                for branch in option.get("next_if",[]):
                    if matches(branch.get("when",{}),state):
                        apply_effects(branch.get("effects",[]),state,definitions); current=branch.get("next",current); break
            elif kind=="hub":
                matched=matching_variants(node,state)
                if not matched:
                    stalls.append(f"run {run_index}: no hub variant at {current}"); break
                for index in matched: apply_effects(node.get("variants",[])[index].get("effects",[]),state,definitions)
                current=node.get("next","")
            else:
                for index in matching_variants(node,state): apply_effects(node.get("variants",[])[index].get("effects",[]),state,definitions)
                current=node.get("next","")
            if not current:
                stalls.append(f"run {run_index}: missing next at {node.get('id')}"); break
        else: stalls.append(f"run {run_index}: traversal limit")
    return hits,choice_hits,stalls

def validate():
    global DERIVED
    errors=[]
    index=load(STORY/"index.json")
    if index.get("entry_node")!="C1-S01": errors.append("entry_node must remain C1-S01")
    chapter_files=index.get("chapter_files",[])
    chapters=[load(STORY/path) for path in chapter_files]
    chapter_ids=[chapter.get("id") for chapter in chapters]
    if chapter_ids != ["C1","C2","C3","C4","C5","C6"]: errors.append(f"only C1 through C6 may be active, got {chapter_ids}")
    if index.get("chapter_map") != {chapter["id"]:path for chapter,path in zip(chapters,chapter_files)}: errors.append("chapter_map must map C1-C6 to their listed files")
    declared=load(STORY/"flags.json")
    definitions=dict(declared.get("flags",{})); definitions.update(declared.get("test_fixture_flags",{}))
    DERIVED=declared.get("derived",{})
    nodes={}; chapter_for_node={}
    for chapter in chapters:
        chapter_id=chapter.get("id")
        if chapter.get("title_key") not in csv_table()[0]: errors.append(f"{chapter_id}: missing title localization")
        for node in chapter.get("nodes",[]):
            node_id=node.get("id")
            if not node_id or node_id in nodes: errors.append(f"empty or duplicate node ID {node_id!r}"); continue
            nodes[node_id]=node; chapter_for_node[node_id]=chapter_id
    for name,definition in definitions.items():
        kind=definition.get("type"); default=definition.get("default")
        if kind not in {"bool","int","float","enum"}: errors.append(f"flag {name}: unsupported type {kind!r}")
        if "default" not in definition: errors.append(f"flag {name}: missing default")
        if kind=="enum" and (not definition.get("values") or (default is not None and default not in definition["values"])): errors.append(f"flag {name}: invalid enum values/default")
        if kind in {"int","float"} and definition.get("min",float("-inf"))>definition.get("max",float("inf")): errors.append(f"flag {name}: inverted range")
    table,duplicates=csv_table()
    for key in sorted(duplicates): errors.append(f"duplicate localization key {key}")
    manifest=load(ROOT/"assets"/"manifest.json")
    characters=load(STORY/"characters.json").get("characters",{})
    for cid,character in characters.items():
        if character.get("name_key") not in table: errors.append(f"character {cid}: missing name key")
        if character.get("portrait_id") not in manifest.get("portraits",{}): errors.append(f"character {cid}: unknown portrait ID")
    writes=set(); reads=set(); adjacency={node_id:[] for node_id in nodes}
    for node_id,node in nodes.items():
        kind=node.get("type")
        if kind not in {"dialogue","decision","hub","cutscene","flowchart"}: errors.append(f"{node_id}: unsupported type {kind!r}")
        if node.get("stage") and node["stage"] not in manifest.get("stages",{}): errors.append(f"{node_id}: unknown stage {node['stage']!r}")
        if node.get("next"):
            adjacency[node_id].append(node["next"])
            if node["next"] not in nodes: errors.append(f"{node_id}: next target missing: {node['next']}")
        for branch in node.get("next_if",[]):
            target=branch.get("next")
            if not target: errors.append(f"{node_id}: next_if missing next")
            elif target not in nodes: errors.append(f"{node_id}: next_if target missing: {target}")
            else: adjacency[node_id].append(target)
        if kind=="decision":
            options=node.get("options",[]); ids=[option.get("id") for option in options]
            if not options: errors.append(f"{node_id}: decision has no options")
            if len(ids)!=len(set(ids)): errors.append(f"{node_id}: duplicate option IDs")
            if node.get("timer_seconds",0)>0 and node.get("default_option") not in ids: errors.append(f"{node_id}: timed decision default is invalid")
            for option in options:
                if not option.get("next"): errors.append(f"{node_id}/{option.get('id')}: missing next")
                elif option["next"] not in nodes: errors.append(f"{node_id}/{option.get('id')}: next missing: {option['next']}")
                else: adjacency[node_id].append(option["next"])
                if option.get("label_key") not in table: errors.append(f"{node_id}/{option.get('id')}: missing label text")
                if option.get("locked_hint_key") and option["locked_hint_key"] not in table: errors.append(f"{node_id}/{option.get('id')}: missing locked hint")
                for branch in option.get("next_if",[]):
                    target=branch.get("next")
                    if not target: errors.append(f"{node_id}/{option.get('id')}: next_if missing next")
                    elif target not in nodes: errors.append(f"{node_id}/{option.get('id')}: next_if missing target {target}")
                    else: adjacency[node_id].append(target)
        if kind=="cutscene" and (node_id!="C3-S01" or node.get("options") or node.get("non_interactive") is not True): errors.append(f"{node_id}: flashback must be a non-interactive cutscene without choices")
        if kind=="hub" and not node.get("variants"): errors.append(f"{node_id}: hub has no variants")
        if node.get("variant_mode","first_match") not in {"first_match","all_matching"}: errors.append(f"{node_id}: unknown variant_mode")
        if node.get("variant_mode")=="all_matching" and node_id!="C4-S06": errors.append(f"{node_id}: additive variants are reserved for C4-S06")
        for line in node.get("lines",[]):
            if line.get("text_key") not in table: errors.append(f"{node_id}: missing text key {line.get('text_key')!r}")
            if line.get("speaker") not in characters: errors.append(f"{node_id}: unknown speaker {line.get('speaker')!r}")
        for variant in node.get("variants",[]):
            if not isinstance(variant.get("when"),dict): errors.append(f"{node_id}: malformed variant condition")
            if variant.get("portrait_id") and variant["portrait_id"] not in manifest.get("portraits",{}): errors.append(f"{node_id}: unknown variant portrait {variant['portrait_id']}")
            for line in variant.get("lines",[]):
                if line.get("text_key") not in table: errors.append(f"{node_id}: missing variant text key {line.get('text_key')!r}")
                if line.get("speaker") not in characters: errors.append(f"{node_id}: unknown variant speaker {line.get('speaker')!r}")
        for part in walk(node):
            for key,value in part.items():
                if key.endswith("_key") and value not in table: errors.append(f"{node_id}: missing localization key {value!r}")
            for operator in ("flag","eq","in","gte","lte"):
                ref=part.get(operator)
                name=ref if operator=="flag" else (ref[0] if isinstance(ref,list) and ref else None)
                if name:
                    reads.add(name)
                    if name not in definitions: errors.append(f"{node_id}: reads undeclared flag {name!r}")
                    elif operator in {"eq","in"} and definitions[name].get("type")=="enum":
                        values=[ref[1]] if operator=="eq" else ref[1]
                        if isinstance(values,list):
                            for value in values:
                                if value is not None and value not in definitions[name].get("values",[]): errors.append(f"{node_id}: invalid enum comparison {value!r} for {name}")
            for operator in ("set","add","clamp"):
                if operator in part:
                    name=part[operator]
                    if name not in definitions: errors.append(f"{node_id}: writes undeclared or derived flag {name!r}")
                    else:
                        writes.add(name)
                        if operator=="set" and definitions[name].get("type")=="enum" and part.get("to") not in definitions[name].get("values",[]): errors.append(f"{node_id}: invalid enum value {part.get('to')!r} for {name}")
    for name in reads:
        if name not in definitions and name not in DERIVED: errors.append(f"read flag {name!r} is undeclared")
        elif name in definitions and name not in writes and "default" not in definitions[name]: errors.append(f"read flag {name!r} is neither written nor declared with a default")
    reachable=set(); pending=[index.get("entry_node","")]
    while pending:
        current=pending.pop()
        if current in reachable or current not in nodes: continue
        reachable.add(current); pending.extend(adjacency[current])
    for node_id in nodes.keys()-reachable: errors.append(f"unreachable node from C1-S01: {node_id}")
    graph=load(STORY/"graph.json")
    if graph.get("entry_node")!=index.get("entry_node"): errors.append("graph entry does not match story index")
    graph_nodes=graph.get("nodes",[]); graph_ids={node.get("id") for node in graph_nodes}
    for node_id in nodes:
        if node_id not in graph_ids: errors.append(f"graph omits story node {node_id}")
    for edge in graph.get("edges",[]):
        if edge.get("from") not in graph_ids or edge.get("to") not in graph_ids: errors.append(f"graph edge has missing endpoint: {edge}")
    lanes={lane.get("id") for lane in graph.get("lanes",[])}
    if lanes!={"mario","kaloy","perlita"}: errors.append(f"flowchart lanes are incomplete: {lanes}")
    if nodes.get("C1-D1",{}).get("default_option")!="B": errors.append("C1-D1 default must remain B")
    if nodes.get("C1-D3",{}).get("default_option")!="C": errors.append("C1-D3 default must be C")
    if nodes.get("C2-D1",{}).get("default_option")!="A": errors.append("C2-D1 must default to passive option A")
    if nodes.get("C3-D1",{}).get("default_option")!="C": errors.append("C3-D1 must default to passive/deferred option C")
    if nodes.get("C3-D3",{}).get("default_option")!="B": errors.append("C3-D3 must default to low-conflict option B")
    if nodes.get("C5-D4",{}).get("default_option")!="B": errors.append("C5-D4 must default to passive option B")
    for name, bounds in {"m_tulay":(0,3),"m_debt":(0,3),"m_trust":(-3,3),"mk_bond":(0,2),"k_safety":(-2,2),"k_solidarity":(0,3),"k_corruption":(0,3),"dado_notice":(0,3),"p_income":(0,2),"bond_jessa":(-2,3),"bond_paolo":(-2,3),"bond_bea":(-2,3),"bond_family":(-2,3)}.items():
        if name not in definitions or (definitions[name].get("min"),definitions[name].get("max"))!=bounds: errors.append(f"flag {name} must have range {bounds[0]}..{bounds[1]}")
    if set(DERIVED)!={"m_status","k_stance","knows_lockbox"}: errors.append("derived flags must be exactly m_status, k_stance, knows_lockbox")
    return errors,nodes,definitions

def main():
    try: errors,nodes,definitions=validate()
    except (ValueError,KeyError,TypeError) as error:
        print(f"ERROR: {error}",file=sys.stderr); return 2
    if errors:
        print("Story validation failed:"); print("\n".join(f"- {problem}" for problem in errors)); return 1
    print(f"Structure passed: {len(nodes)} C1-C6 nodes reachable from C1-S01; every next target exists.")
    option_errors,option_count=single_option_tests(nodes,definitions)
    c1_errors,c1_paths,c1_hubs=c1_golden_tests(nodes,definitions)
    chapter_errors,c2_paths,c3_paths=chapter_golden_tests(nodes,definitions)
    c4_c6_errors=test_c4_c6(nodes,definitions)
    chain_errors,chain_paths=curated_full_chain_tests(nodes,definitions)
    derived_errors=derived_tests(definitions)
    x1_errors=test_x1(nodes,definitions)
    save_errors=test_c1_save_c2(nodes,definitions)
    failures=option_errors+c1_errors+chapter_errors+c4_c6_errors+chain_errors+derived_errors+x1_errors+save_errors
    if failures:
        print("Golden-path failures:"); print("\n".join(f"- {problem}" for problem in failures)); return 1
    print(f"Golden tests passed: {option_count} individual decision options; {c1_paths} C1 routes; {c1_hubs} C1-S08 rows; C2 {c2_paths}/27; C3 {c3_paths}/27; {chain_paths} curated C1-C6 routes.")
    print("Hub rows passed: C4-S06 additive combinations, C5-S08, and C6-S07.")
    print("X1 and X2 hooks passed; C6-D3 rules passed for all bond_jessa/p_income combinations.")
    print("Derived values passed: m_status, k_stance, and knows_lockbox are computed on demand.")
    print("Save/load passed: C1-C3 flags survived JSON round-trip into C4.")
    hits,choices,stalls=random_walks(nodes,definitions,"C1-S01")
    if stalls:
        print(f"Random-walk failure: {stalls[0]}"); return 1
    decisions={node_id for node_id,node in nodes.items() if node.get("type")=="decision"}
    print(f"Random walks: 10,000 C1-C6 runs, no stalls; decisions hit {len(hits)}/{len(decisions)}.")
    missed=[f"{node_id}/{option['id']}" for node_id,node in nodes.items() if node.get("type")=="decision" for option in node.get("options",[]) if choices.get((node_id,option["id"]),0)==0]
    print("Coverage report: " + ("all C1-C6 options reached" if not missed else "never reached: " + ", ".join(missed)))
    return 1 if hits!=decisions or missed else 0

if __name__=="__main__": raise SystemExit(main())
