#!/usr/bin/env python3
"""Recover a release draft only by rerunning its original release workflow commit.

Used by .github/workflows/release-please.yml (ported from scenario-labs/blender-plugin).
Reads GH_REPO, GITHUB_SHA and GITHUB_OUTPUT; writes found=, tag_name=, sha=, release_id=.
"""
import json, os, re, subprocess, sys
from pathlib import Path

PREFIX = "godot-plugin-v"
RELEASE_APP = "gh-actions-token-retriever-public[bot]"
SHA_RE = re.compile(r"[0-9a-fA-F]{40}")
TAG_RE = re.compile(r"godot-plugin-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def gh_json(endpoint, *, paginate=False):
    command = ["gh", "api", endpoint]
    if paginate:
        command.extend(["--paginate", "--slurp"])
    result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=60)
    return json.loads(result.stdout)


def find_draft(repo, current_sha, request=gh_json):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("GH_REPO must identify an owner/repository")
    if not SHA_RE.fullmatch(current_sha):
        raise ValueError("GITHUB_SHA must be a full commit SHA")
    pages = request(f"repos/{repo}/releases?per_page=100", paginate=True)
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise ValueError("GitHub returned an invalid paginated release list")
    drafts = []
    for page in pages:
        for release in page:
            if not isinstance(release, dict):
                raise ValueError("GitHub returned an invalid release")
            tag = release.get("tag_name", "")
            if release.get("draft") is True and isinstance(tag, str) and tag.startswith(PREFIX):
                drafts.append(release)
    if len(drafts) > 1:
        raise ValueError("Multiple Godot plugin release drafts exist; select and resolve them before retrying")
    if not drafts:
        return {"found": "false"}
    draft = drafts[0]
    tag = draft["tag_name"]
    if not TAG_RE.fullmatch(tag) or draft.get("prerelease") is not False:
        raise ValueError("The pending draft must have a stable godot-plugin-vX.Y.Z tag")
    if (draft.get("author") or {}).get("login") != RELEASE_APP:
        raise ValueError("The pending draft was not created by the release GitHub App")
    sha = draft.get("target_commitish", "")
    if not isinstance(sha, str) or not SHA_RE.fullmatch(sha):
        raise ValueError("The pending draft must target a full commit SHA, not a branch")
    release_id = draft.get("id")
    if type(release_id) is not int or release_id <= 0:
        raise ValueError("The pending draft has no valid release ID")
    sha = sha.lower()
    if sha != current_sha.lower():
        raise ValueError(f"Rerun the original release workflow for {sha}; newer pushes must not rebuild this draft")
    return {"found": "true", "tag_name": tag, "sha": sha, "release_id": str(release_id)}


def main(environ=None, request=gh_json):
    environ = os.environ if environ is None else environ
    try:
        outputs = find_draft(environ["GH_REPO"], environ["GITHUB_SHA"], request)
        with Path(environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
            output.write("".join(f"{key}={value}\n" for key, value in outputs.items()))
    except (KeyError, ValueError, OSError, subprocess.SubprocessError) as error:
        # Do not echo API responses or subprocess output, which may contain private data.
        message = str(error) if isinstance(error, ValueError) else type(error).__name__
        print(f"::error::Cannot recover a release draft: {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
