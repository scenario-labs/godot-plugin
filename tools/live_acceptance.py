#!/usr/bin/env python3
"""PAID live acceptance. Spends Creative Units on the project of the API key.

Usage:
  SCENARIO_API_KEY=... SCENARIO_API_SECRET=... python3 tools/live_acceptance.py [--budget 200]

Runs tests/live/live_acceptance_job.gd in a headless editor with the real HTTP
transport, captures the resulting scene in a window, and appends one row per
run to tests/live/LEDGER.md (quoted vs charged CU). Exit 0 only when every run
succeeded, was placed, and was charged exactly its quote.
"""
import argparse, datetime, os, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, os.environ.get("GODOT_EXPERT_SCRIPTS", str(pathlib.Path.home() / ".claude/skills/godot-expert/scripts")))
import gd_run, gd_review  # noqa: E402

LEDGER = ROOT / "tests/live/LEDGER.md"
CAP_CU = 1500.0  # total budget for this plugin's live tests (spec, section 6)


def spent_so_far() -> float:
    if not LEDGER.exists():
        return 0.0
    total = 0.0
    for line in LEDGER.read_text().splitlines():
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) >= 5 and cells[0][:4].isdigit():
            try:
                total += float(cells[4])
            except ValueError:
                pass
    return total


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--budget", type=float, default=200.0)
    parser.add_argument("--lanes", default="", help="comma-separated lanes, e.g. model3d,sound (default: all)")
    args = parser.parse_args()
    if not (os.environ.get("SCENARIO_API_KEY") and os.environ.get("SCENARIO_API_SECRET")):
        print("Set SCENARIO_API_KEY and SCENARIO_API_SECRET.")
        return 2
    already = spent_so_far()
    budget = min(args.budget, CAP_CU - already)
    if budget <= 0:
        print(f"Live test cap reached ({already} of {CAP_CU} CU).")
        return 3
    print(f"Spent so far {already} CU; this run may spend up to {budget} CU.")
    r = gd_run.run_script(str(ROOT), "res://tests/live/live_acceptance_job.gd", {"budget_cu": budget, "lanes": args.lanes},
                          editor=True, timeout=1800, env={k: os.environ[k] for k in ("SCENARIO_API_KEY", "SCENARIO_API_SECRET")})
    res = r.get("result") or {}
    runs = res.get("runs", [])
    today = datetime.date.today().isoformat()
    if not LEDGER.exists():
        LEDGER.write_text("# Live acceptance ledger\n\nPaid runs of tests/live/live_acceptance_job.gd. Cap: "
                          f"{CAP_CU:.0f} CU.\n\n| Date | Lane | Model | Quoted CU | Charged CU | Placed | Job | Note |\n"
                          "|---|---|---|---|---|---|---|---|\n")
    with LEDGER.open("a") as f:
        for run in runs:
            note = " ".join(str(run.get("note", "")).split()).replace("|", "/")
            f.write(f"| {today} | {run['lane']} | {run['model'].removeprefix('model_')} | {run.get('quoted')} | "
                    f"{run.get('charged') if run.get('charged') is not None else 0} | {'yes' if run.get('placed') else 'no'} | "
                    f"{run.get('job_id', '')} | {note} |\n")
    for run in runs:
        match = "=" if run.get("quoted") == run.get("charged") else "MISMATCH"
        print(f"  {run['lane']:9s} {run['model']:45s} quoted={run.get('quoted')} charged={run.get('charged')} {match} "
              f"placed={run.get('placed')} {run.get('note', '')[:120]}")
    print("spent:", res.get("spent_cu"), "ok:", res.get("ok"), "error:", r.get("error"))
    if res.get("scene_path"):
        cap = gd_run.capture_scene(str(ROOT), scene=res["scene_path"], out="captures/live.png", size=(1280, 720), frames=16)
        shot = ROOT / ".agent_out/captures/live.png"
        if cap.get("ok") and shot.exists():
            print("capture:", shot, gd_review.image_checks(str(shot)).get("flags"))
    return 0 if r.get("ok") and res.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
