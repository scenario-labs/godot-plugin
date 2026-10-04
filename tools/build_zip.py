#!/usr/bin/env python3
"""Build the release zip: addons/scenario only (no tests, GUT or AgentKit).

Usage: python3 tools/build_zip.py [--verify]

Writes dist/scenario-godot-plugin-<version>.zip with paths starting at
addons/scenario/, the layout Godot's asset installer and a manual unzip into a
project both expect. --verify installs the zip into a blank Godot project in a
temporary folder, enables the plugin and checks in a headless editor that it
loads with zero errors and that its dock and controller exist.
"""
import argparse, configparser, pathlib, sys, tempfile, zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON = ROOT / "addons/scenario"
SKIP_NAMES = {".DS_Store"}

VERIFY_JOB = '''extends "res://addons/agentkit/agent_job.gd"
func run() -> Dictionary:
	await wait_frames(3)
	var controller := root.find_child("ScenarioController", true, false)
	var dock := root.find_child("Scenario", true, false)
	return {"ok": controller != null and dock != null, "controller": controller != null, "dock": dock != null}
'''


def version() -> str:
    cfg = configparser.ConfigParser()
    cfg.read(ADDON / "plugin.cfg")
    return cfg["plugin"]["version"].strip('"')


def build() -> pathlib.Path:
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    out = dist / f"scenario-godot-plugin-{version()}.zip"
    files = sorted(p for p in ADDON.rglob("*") if p.is_file() and p.name not in SKIP_NAMES)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for path in files:
            z.write(path, path.relative_to(ROOT).as_posix())
    print(f"{out} ({out.stat().st_size} bytes, {len(files)} files)")
    return out


def verify(zip_path: pathlib.Path) -> bool:
    sys.path.insert(0, str(pathlib.Path.home() / ".claude/skills/godot-expert/scripts"))
    import gd_env, gd_run  # noqa: E402

    project = pathlib.Path(tempfile.mkdtemp(prefix="scenario-godot-install-")) / "Blank"
    gd_env.new_project(str(project), template="3d", name="Blank", do_import=False, isolate_user=True)
    gd_env.install_agentkit(str(project))
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
        bad = [n for n in names if not n.startswith("addons/scenario/")]
        if bad:
            print("unexpected paths in the zip:", bad[:5])
            return False
        z.extractall(project)
    text = (project / "project.godot").read_text()
    text += '\n[editor_plugins]\n\nenabled=PackedStringArray("res://addons/scenario/plugin.cfg")\n'
    (project / "project.godot").write_text(text)
    (project / "verify_job.gd").write_text(VERIFY_JOB)

    imp = gd_run.import_project(str(project))
    checked = gd_run.check_all(str(project), root="res://addons/scenario", exclude=())
    r = gd_run.run_script(str(project), "res://verify_job.gd", editor=True, timeout=120)
    res = r.get("result") or {}
    # Godot 4.7.2 prints "N resources still in use at exit" after every editor run.
    engine = [e for e in r.get("engine_errors") or [] if "still in use at exit" not in str(e.get("message", ""))]
    errors = (r.get("parse_errors") or []) + (r.get("script_errors") or []) + engine
    ok = bool(imp.get("ok")) and not checked.get("failed_files") and bool(r.get("ok")) and bool(res.get("ok")) and not errors
    print(f"install check in {project}: {'PASS' if ok else 'FAIL'} import={imp.get('ok')} "
          f"failed_files={checked.get('failed_files')} result={res} errors={errors[:5]}")
    return ok


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    out = build()
    if args.verify and not verify(out):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
