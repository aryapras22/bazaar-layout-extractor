"""Check the metre truth files (data/planN/truth.json) against the tracing rules.

Usage: python3 scripts/check_metre_truth.py [plan numbers, default 1 2 3 5 6]
Reads each file from disk, checks the key order and shapes, then runs the Pass 7 checks from metre_truth.py:
positive extents, the wall and doors, gates and exitPt inside the lobby, booths inside the hall and not overlapping,
no booth on a wall, pillar, stage or fixture, and a walkable route (0.4 m wide passages) from the entrance gate to
every booth and to exitPt. Booths that lie in the lobby are reported as notes, not problems.
"""
import json
import sys

sys.path.insert(0, "scripts")
import metre_truth as mt

plans = [int(a) for a in sys.argv[1:]] or [1, 2, 3, 5, 6]
failed = False
for number in plans:
    truth = json.load(open(f"data/plan{number}/truth.json"))
    if list(truth) != mt.KEY_ORDER:
        print(f"plan{number}: PROBLEM keys are {list(truth)}")
        failed = True
    problems, notes = mt.check(truth)
    kinds, n_tables, n_walls = mt.counts(truth)
    print(f"plan{number}: {kinds}; {n_tables} tables; {n_walls} walls; {len(truth['pilasters'])} pilasters; "
          f"{len(truth['fixtures'])} fixtures; {len(truth['columns'])} columns; {len(truth['doors'])} doors")
    for note in notes:
        print("  note:", note)
    for problem in problems:
        print("  PROBLEM:", problem)
        failed = True
sys.exit(1 if failed else 0)
