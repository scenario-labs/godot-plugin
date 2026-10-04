#!/usr/bin/env python3
"""FREE live contract check (0 CU): is Scenario still answering the way the
plugin expects?

Usage:
  SCENARIO_API_KEY=... SCENARIO_API_SECRET=... python3 tools/contract_check.py

Loads the schema of every model listed in addons/scenario/core/lanes.gd, prices
each one (estimates are free), asks for recommendations, and checks that
Generate is refused with SCENARIO_NO_SPEND=1, which this script always sets.
Run it after a Scenario MCP release or before a plugin release.
"""
import os, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(pathlib.Path.home() / ".claude/skills/godot-expert/scripts"))
import gd_run  # noqa: E402


def main() -> int:
    if not (os.environ.get("SCENARIO_API_KEY") and os.environ.get("SCENARIO_API_SECRET")):
        print("Set SCENARIO_API_KEY and SCENARIO_API_SECRET.")
        return 2
    env = {k: os.environ[k] for k in ("SCENARIO_API_KEY", "SCENARIO_API_SECRET")}
    env["SCENARIO_NO_SPEND"] = "1"
    r = gd_run.run_script(str(ROOT), "res://tests/live/contract_check_job.gd", editor=True, timeout=900, env=env)
    res = r.get("result") or {}
    for m in res.get("models", []):
        cu = f"{m['cu']:g} CU" if m.get("cu") is not None else ""
        print(f"  {m['lane']:9s} {m['model']:45s} fields={m['fields']:<3} {m['state']:8s} {cu:8s} {m.get('note', '')[:70]}")
    for rec in res.get("recommendations", []):
        print(f"  recommend {rec['lane']:9s} {rec['count']} models, first {rec['first']}")
    print("no-spend refusal:", res.get("no_spend_refused"))
    print("ok:", bool(r.get("ok")) and bool(res.get("ok")), "error:", r.get("error") or res.get("error", ""))
    return 0 if r.get("ok") and res.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
