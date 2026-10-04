#!/usr/bin/env python3
"""Render the dock in three states (fake backend, 0 CU) to docs/images/.

Usage: python3 tools/capture_dock.py
Opens a small editor window for a few seconds (headless draws nothing).
"""
import os, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, os.environ.get("GODOT_EXPERT_SCRIPTS", str(pathlib.Path.home() / ".claude/skills/godot-expert/scripts")))
import gd_run, gd_review  # noqa: E402


def main() -> int:
    sys.path.insert(0, str(ROOT / "tools"))
    from build_zip import version
    out = ROOT / f"docs/images/dock-{version()}.png"
    r = gd_run.run_script(str(ROOT), "res://tests/editor/dock_capture_job.gd", {"out": str(out)},
                          editor=True, headless=False, timeout=180)
    res = r.get("result") or {}
    # A windowed editor logs "current_window is null" from its own import
    # progress dialog while it starts; anything else counts.
    other = [e for e in res.get("captured_errors", []) if e.get("file") != "editor/gui/progress_dialog.cpp"]
    errors = (r.get("parse_errors") or []) + (r.get("script_errors") or []) + other
    # AgentKit sets res["ok"] false on any logged error, so judge the image itself.
    ok = out.exists() and bool(res.get("size")) and not errors
    print("ok:", ok, "errors:", errors[:3], "size:", res.get("size"), "scale:", res.get("scale"))
    print("states:", res.get("states"))
    if out.exists():
        print("image:", out, gd_review.image_checks(str(out)).get("flags"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
