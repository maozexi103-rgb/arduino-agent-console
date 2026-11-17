"""Audit intended electrical nets, including both common four-leg switch layouts."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAN = json.loads((ROOT / "hardware/wiring.json").read_text())

def node(hole):
    if hole.startswith("MCU:"):
        return hole
    column, row = hole[0], int(hole[1:])
    assert column in "abcdefghij" and 1 <= row <= 30
    return ("L" if column in "abcde" else "R") + str(row)

def audit(switch_layout, pressed=None):
    parent = {}
    def find(x):
        x = node(x)
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    def union(a,b):
        a,b = find(a),find(b)
        parent[a] = b
    def same(a,b):
        return find(a) == find(b)
    occupied = {}
    def use(hole, label):
        assert hole not in occupied, f"Two leads share physical hole {hole}: {occupied.get(hole)}, {label}"
        occupied[hole] = label
    def wire(a,b,label):
        for hole in (a,b):
            if not hole.startswith(("MCU:",)):
                use(hole,label)
        union(a,b)

    wire("MCU:GND", PLAN["ground"]["feed"], "ground root")
    wire(*PLAN["ground"]["bridge"], "ground bridge")
    for b in PLAN["buttons"]:
        r1,r2=b["rows"]
        pins=[f"e{r1}",f"e{r2}",f"f{r1}",f"f{r2}"]
        for hole in pins: use(hole,b["id"])
        pairs=((0,1),(2,3)) if switch_layout=="same_bank" else ((0,2),(1,3))
        for a,c in pairs: union(pins[a],pins[c])
        wire(f'MCU:D{b["pin"]}',b["signal_hole"],b["id"]+" input")
        wire(b["ground_hole"],b["ground_to"],b["id"]+" ground")
        assert same(b["ground_hole"],"MCU:GND")
        if pressed == b["id"]: union(pins[0],pins[3])
    for led in PLAN["leds"]:
        wire(f'MCU:D{led["pin"]}',led["feed"],led["id"]+" drive")
        for hole in led["resistor"]: use(hole,led["id"]+" resistor")
        use(led["anode"],led["id"]+" anode")
        use(led["cathode"],led["id"]+" cathode")
        wire(led["ground_hole"],led["ground_to"],led["id"]+" ground")
        assert same(led["feed"],led["resistor"][0])
        assert same(led["anode"],led["resistor"][1])
        assert same(led["cathode"],"MCU:GND")
        assert not same(led["anode"],"MCU:GND"), "LED anode shorted to ground"
        assert not same(led["feed"],led["anode"]), "LED resistor bypassed"
    sources=[f"MCU:D{x}" for x in (2,3,4)]
    for i,a in enumerate(sources):
        assert not same(a,"MCU:GND"), f"Output {a} directly grounded"
        for other in sources[i+1:]: assert not same(a,other), "Two outputs tied"
    for b in PLAN["buttons"]:
        sig=f'MCU:D{b["pin"]}'
        assert same(sig,"MCU:GND") == (pressed == b["id"]), "Button input/ground mapping invalid"
        for source in sources: assert not same(sig,source), "Input shorted to output"
    return len(occupied)

import unittest

class WiringTests(unittest.TestCase):
    def test_all_switch_pairings_and_single_presses(self):
        for layout in ("same_bank", "same_row"):
            for pressed in (None, "B1", "B2", "B3", "B4"):
                with self.subTest(layout=layout, pressed=pressed):
                    self.assertGreater(audit(layout, pressed), 0)

if __name__ == "__main__":
    unittest.main()
