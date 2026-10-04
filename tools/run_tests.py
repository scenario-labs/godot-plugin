#!/usr/bin/env python3
"""Run the plugin's GUT suites headless and print a one-line verdict.

Usage: python3 tools/run_tests.py [unit|editor|all]
Uses the godot-expert toolkit (gd_run) so the log is scanned for parse and
script errors as well as the GUT totals. Exit code 0 only when every suite passes.
"""
import os, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, os.environ.get("GODOT_EXPERT_SCRIPTS", str(pathlib.Path.home() / ".claude/skills/godot-expert/scripts")))
import gd_run  # noqa: E402

SUITES = {"unit": "res://tests/unit", "editor": "res://tests/editor"}
EDITOR_JOBS = ["res://tests/editor/editor_flow_job.gd"]


def main() -> int:
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    names = list(SUITES) if which == "all" else [which]
    imp = gd_run.import_project(str(ROOT))
    if not imp.get("ok"):
        print("IMPORT FAILED:", imp.get("error"), imp.get("parse_errors"))
        return 10
    failed = False
    for name in names:
        if not (ROOT / SUITES[name].replace("res://", "")).exists():
            continue
        if name == "editor":
            for job in EDITOR_JOBS:
                r = gd_run.run_script(str(ROOT), job, editor=True, timeout=300)
                res = r.get("result") or {}
                ok = bool(r.get("ok")) and bool(res.get("ok"))
                failed |= not ok
                print(f"editor {job.split('/')[-1]}: {'PASS' if ok else 'FAIL'} checks={res.get('checks')} "
                      f"failures={res.get('failures')} paid_calls={res.get('paid_calls')} log={r.get('log_path')}")
                if not ok:
                    print("  error:", r.get("error"), (r.get("script_errors") or r.get("parse_errors") or r.get("engine_errors") or [])[:6])
            continue
        r = gd_run.run_tests(str(ROOT), framework="gut", dirs=(SUITES[name],))
        s = r.get("summary") or {}
        bad = r.get("parse_errors") or r.get("script_errors")
        ok = bool(r.get("ok")) and not bad
        failed |= not ok
        print(f"{name}: {'PASS' if ok else 'FAIL'} tests={s.get('tests')} passing={s.get('passing_tests')} "
              f"failing={s.get('failing_tests')} asserts={s.get('asserts')} time={s.get('time')} log={r.get('log_path')}")
        if bad:
            print("  errors:", bad[:10])
    return 11 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
