#!/usr/bin/env python3
"""Build the plugin's website: docs/USER_GUIDE.md as one page, plus the latest release zip.

Usage: uv run --no-project --with markdown==3.10.3 python tools/build_site.py --output DIR
[--release DIR] [--guide DIR --ref REF] (make site). --release is a folder holding a
release zip and its SHA256SUMS, already checked by the caller (.github/workflows/pages.yml
verifies both and the build provenance). Without it the page links to the GitHub releases
instead. --guide is a checkout of the released commit: the guide, its images and
plugin.cfg come from there, so the page describes what users can download, while the
template, styles and search come from this checkout. --ref is the git ref the guide's
links to repository files point at (default main).

The page has the look of the Blender plugin's site: docs/site/template.html with
docs/site/site.css and the guide search docs/site/handbook-search.js inlined.

Writes index.html, images/ and, with a release, download/<zip>,
download/SHA256SUMS and download/latest.json.
"""
import argparse, configparser, hashlib, html, json, pathlib, re, shutil, sys

import markdown

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO = "https://github.com/scenario-labs/godot-plugin"
SITE = ROOT / "docs/site"
TEMPLATE = SITE / "template.html"
ZIP_RE = re.compile(r"scenario-godot-plugin-(\d+\.\d+\.\d+)\.zip")
LINK_RE = re.compile(r"\]\((?!https?://|#|mailto:)([^)\s]+)\)")


def inline(name: str, element: str) -> str:
    """A file of docs/site/ placed inside its own <style> or <script> element."""
    text = (SITE / name).read_text()
    if f"</{element}" in text.casefold():
        raise SystemExit(f"docs/site/{name} must not close its <{element}> element")
    return text


def plugin_cfg(guide: pathlib.Path) -> configparser.SectionProxy:
    cfg = configparser.ConfigParser()
    cfg.read(guide / "addons/scenario/plugin.cfg")
    return cfg["plugin"]


def repo_links(text: str, guide: pathlib.Path, ref: str) -> str:
    """Links from the guide to other repository files point at GitHub; images stay local."""
    def target(match: re.Match) -> str:
        path = (guide / "docs" / match.group(1)).resolve().relative_to(guide.resolve()).as_posix()
        if path.startswith("docs/images/"):
            return f"]({path.removeprefix('docs/')})"
        return f"]({REPO}/blob/{ref}/{path})"
    return LINK_RE.sub(target, text)


def release_files(folder: pathlib.Path) -> dict:
    zips = [p for p in folder.iterdir() if ZIP_RE.fullmatch(p.name)]
    if len(zips) != 1:
        raise SystemExit(f"--release must hold exactly one scenario-godot-plugin-X.Y.Z.zip, found {len(zips)}")
    zip_path = zips[0]
    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    sums = (folder / "SHA256SUMS").read_text()
    if f"{digest}  {zip_path.name}" not in sums.splitlines():
        raise SystemExit(f"SHA256SUMS does not list {zip_path.name} with its checksum")
    return {"version": ZIP_RE.fullmatch(zip_path.name).group(1), "file": zip_path.name, "sha256": digest,
            "path": zip_path, "sums": folder / "SHA256SUMS"}


def no_symlinks(guide_root: pathlib.Path) -> None:
    """The guide's files are published as they are, so none may point outside the checkout."""
    paths = [guide_root / "docs/USER_GUIDE.md", guide_root / "addons/scenario/plugin.cfg",
             guide_root / "docs/images", *(guide_root / "docs/images").rglob("*")]
    links = [p.relative_to(guide_root).as_posix() for p in paths if p.is_symlink()]
    if links:
        raise SystemExit(f"symbolic links are not published: {', '.join(links)}")


def build(output: pathlib.Path, release: pathlib.Path | None, guide_root: pathlib.Path = ROOT, ref: str = "main") -> None:
    no_symlinks(guide_root)
    if output.exists() and any(output.iterdir()):
        raise SystemExit(f"{output} is not empty")
    output.mkdir(parents=True, exist_ok=True)
    md = markdown.Markdown(extensions=["toc", "tables", "fenced_code", "sane_lists"],
                           extension_configs={"toc": {"toc_depth": "2"}})
    guide = (guide_root / "docs/USER_GUIDE.md").read_text()
    # The page has its own title and version line; the guide's first two lines repeat them.
    body = re.sub(r"\A# [^\n]*\n+(Version [^\n]*\n+)?", "", guide)
    content = md.convert(repo_links(body, guide_root, ref))
    plugin = plugin_cfg(guide_root)

    if release:
        found = release_files(release)
        (output / "download").mkdir()
        shutil.copy2(found["path"], output / "download" / found["file"])
        shutil.copy2(found["sums"], output / "download/SHA256SUMS")
        latest = {key: found[key] for key in ("version", "file", "sha256")}
        latest["release"] = f"{REPO}/releases/tag/godot-plugin-v{found['version']}"
        (output / "download/latest.json").write_text(json.dumps(latest, indent=2) + "\n")
        version, download = found["version"], f"download/{found['file']}"
        checksum = (f'<code>{found["sha256"]}</code>'
                    f'<button class="button quiet" type="button" data-copy="{found["sha256"]}">Copy</button>')
    else:
        version, download = plugin["version"].strip('"'), f"{REPO}/releases/latest"
        checksum = f'In the <a href="{download}">GitHub release</a>'

    docks = sorted((guide_root / "docs/images").glob("dock-*.png"), key=lambda p: [int(n) for n in re.findall(r"\d+", p.stem)])
    shutil.copytree(guide_root / "docs/images", output / "images")
    slots = {
        "description": html.escape(plugin["description"].strip('"')),
        "version": html.escape(version),
        "download": html.escape(download),
        "checksum": checksum,
        "dock": f"images/{docks[-1].name}" if docks else "",
        # List items after the template's own Install entry; the names come escaped.
        "toc": "\n".join(f'<li><a href="#{t["id"]}">{t["name"]}</a></li>' for t in md.toc_tokens),
        "content": content,
        "repo": REPO,
        "ref": html.escape(ref),
        "style": inline("site.css", "style"),
        "search": inline("handbook-search.js", "script"),
    }
    page = re.sub(r"{{\s*(\w+)\s*}}", lambda m: slots[m.group(1)], TEMPLATE.read_text())
    (output / "index.html").write_text(page)
    (output / ".nojekyll").write_text("")
    print(f"site {version} in {output}" + (" with the release zip" if release else " (no release zip)"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--release", type=pathlib.Path)
    parser.add_argument("--guide", type=pathlib.Path, default=ROOT)
    parser.add_argument("--ref", default="main")
    args = parser.parse_args()
    build(args.output, args.release, args.guide, args.ref)
    return 0


if __name__ == "__main__":
    sys.exit(main())
