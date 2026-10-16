#!/usr/bin/env python3
"""The scenario-godot-expert toolkit (gd_run, gd_env) the other tools drive Godot with.

Usage: python3 tools/toolkit.py [fetch|check|sync]
  fetch  the pinned toolkit into .toolkit/ (what CI runs; Godot never imports a hidden folder)
  check  addons/agentkit equals the pinned toolkit's AgentKit, which the tests run on
  sync   copy the pinned toolkit's AgentKit into addons/agentkit (after bumping REF)

The other tools look for the toolkit in $GODOT_EXPERT_SCRIPTS, then the pinned copy,
then the skill installed for an agent (`npx skills add scenario-labs/skills`).
"""
import os, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO = "https://github.com/scenario-labs/skills"
# The scenario-labs/skills commit the tests run against. After a bump: make toolkit, sync, test.
REF = "49dd26e47371163ae0020c7f5627d0993626bfc2"
SUBDIR = "skills/game-engines/godot/scenario-godot-expert/scripts"
CLONE = ROOT / ".toolkit/skills"
PINNED = CLONE / SUBDIR


def scripts_dir() -> pathlib.Path:
    env = os.environ.get("GODOT_EXPERT_SCRIPTS")
    home = pathlib.Path.home()
    candidates = [pathlib.Path(env)] if env else [
        PINNED,
        home / ".claude/skills/scenario-godot-expert/scripts",
        home / ".agents/skills/scenario-godot-expert/scripts",
        home / ".claude/skills/godot-expert/scripts",  # the skill's name before it was published
    ]
    for path in candidates:
        if (path / "gd_run.py").is_file():
            return path
    sys.exit("scenario-godot-expert toolkit not found: run `make toolkit`, or set GODOT_EXPERT_SCRIPTS "
             "to its scripts/ folder. Looked in: " + ", ".join(str(p) for p in candidates))


def use() -> pathlib.Path:
    """Put the toolkit on sys.path, so `import gd_run` works after it."""
    path = scripts_dir()
    sys.path.insert(0, str(path))
    return path


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(CLONE), *args], check=True, capture_output=True, text=True).stdout.strip()


def fetch() -> int:
    if not (CLONE / ".git").is_dir():
        CLONE.mkdir(parents=True, exist_ok=True)
        git("init", "-q")
        git("config", "core.autocrlf", "false")  # the toolkit as committed, on Windows too
        git("remote", "add", "origin", REPO)
        git("sparse-checkout", "set", SUBDIR)
    if (PINNED / "gd_run.py").is_file() and git("rev-parse", "HEAD") == REF:
        print(f"toolkit {REF[:12]} already in {PINNED}")
        return 0
    git("fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", REF)
    git("checkout", "-q", "--detach", REF)
    print(f"toolkit {REF[:12]} in {PINNED}")
    return 0


def same_text(a: pathlib.Path, b: pathlib.Path) -> bool:
    return a.read_bytes().replace(b"\r\n", b"\n") == b.read_bytes().replace(b"\r\n", b"\n")


def install_agentkit(project: pathlib.Path) -> pathlib.Path:
    """What the pinned toolkit installs as <project>/addons/agentkit (scripts and VERSION)."""
    sys.path.insert(0, str(PINNED))
    import gd_env  # noqa: E402

    return pathlib.Path(gd_env.install_agentkit(str(project)))


def agentkit_diff() -> list[str]:
    """Files that differ between addons/agentkit and a fresh install of the pinned AgentKit.

    Every file counts except the .uid files Godot generates for each project.
    """
    def files(folder: pathlib.Path) -> set[str]:
        return {p.relative_to(folder).as_posix() for p in folder.rglob("*") if p.is_file() and p.suffix != ".uid"}

    ours = ROOT / "addons/agentkit"
    with tempfile.TemporaryDirectory() as tmp:
        kit = install_agentkit(pathlib.Path(tmp))
        theirs, mine = files(kit), files(ours)
        return sorted((theirs ^ mine) | {n for n in theirs & mine if not same_text(kit / n, ours / n)})


def main() -> int:
    which = sys.argv[1] if len(sys.argv) > 1 else "fetch"
    if which == "fetch":
        return fetch()
    if not (PINNED / "gd_run.py").is_file():
        print("No pinned toolkit: run `make toolkit` first.")
        return 2
    if which == "check":
        diff = agentkit_diff()
        if diff:
            print(f"addons/agentkit differs from the toolkit at {REF[:12]}: {', '.join(diff)}. "
                  "Run `python3 tools/toolkit.py sync`.")
            return 1
        print(f"addons/agentkit matches the toolkit at {REF[:12]}")
        return 0
    if which == "sync":
        install_agentkit(ROOT)
        left = agentkit_diff()
        print(f"addons/agentkit synced from the toolkit at {REF[:12]}"
              + (f"; no longer in the toolkit, delete them: {', '.join(left)}" if left else ""))
        return 1 if left else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
