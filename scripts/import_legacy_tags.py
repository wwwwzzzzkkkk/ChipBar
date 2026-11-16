#!/usr/bin/env python3
"""Preserve legacy ChipBar tags using GitHub Git refs API without workflow-scope push.

An old Git commit is used directly whenever accessible in the standalone repo.
When not accessible, create an *explicit archive pointer* orphan commit with a
link to the real original tag. Never substitute the current v4 source.
"""
import re
import sys
from import_legacy_releases import SOURCE, TARGET, TAG_RE, api


def old_tag_refs():
    refs = []
    page = 1
    while True:
        part = api(f"repos/{SOURCE}/git/refs/tags?per_page=100&page={page}")
        if not isinstance(part, list):
            raise RuntimeError("Unexpected GitHub tag listing")
        refs.extend(part)
        if len(part) < 100:
            break
        page += 1
    pairs = []
    for item in refs:
        name = item["ref"].removeprefix("refs/tags/")
        if TAG_RE.fullmatch(name):
            pairs.append((name, item["object"]["sha"], item["object"]["type"]))
    if len(pairs) < 64:
        raise RuntimeError(f"Expected >=64 ChipBar historical tags, got {len(pairs)}")
    return sorted(pairs)


def archive_readme(tag, sha):
    return (
        f"# ChipBar {tag.removeprefix('chipbar-v')} — historical archive pointer\n\n"
        "**This Git revision is an archive pointer, NOT the historical source code.**\n\n"
        "GitHub did not allow this automation to import the original commit "
        "with its old workflow files. The real source is preserved unchanged "
        f"at [the original Git tag](https://github.com/{SOURCE}/tree/{tag}).\n\n"
        f"Original Git commit or tag object: \x60{sha}\x60.\n\n"
        f"The untouched original binary ZIP and SHA256 file are available at "
        f"[the archived Release](https://github.com/{TARGET}/releases/tag/{tag}).\n\n"
        "Do not build this pointer revision as if it were the historical source.\n"
    )


def make_archive_pointer(tag, sha):
    tree = api(f"repos/{TARGET}/git/trees", method="POST", payload={
        "tree": [{
            "path": "README.md", "mode": "100644", "type": "blob",
            "content": archive_readme(tag, sha),
        }]
    })
    commit = api(f"repos/{TARGET}/git/commits", method="POST", payload={
        "message": f"Archive reference for {tag} — original source linked in README",
        "tree": tree["sha"],
        "parents": [],
    })
    return commit["sha"]


def create_tag(tag, sha):
    return api(f"repos/{TARGET}/git/refs", method="POST", payload={
        "ref": f"refs/tags/{tag}", "sha": sha,
    })


def peel_to_commit(original_sha, kind):
    """Annotated tags point to a Git *tag object*, not directly to a commit."""
    for _ in range(5):
        if kind == "commit":
            return original_sha
        if kind != "tag":
            raise RuntimeError(f"Unexpected source tag object type: {kind}")
        annotation = api(f"repos/{SOURCE}/git/tags/{original_sha}")
        kind = annotation["object"]["type"]
        original_sha = annotation["object"]["sha"]
    raise RuntimeError("Historical tag is nested too deeply")


def import_tags():
    direct = pointers = existing = 0
    for tag, ref_sha, kind in old_tag_refs():
        original_sha = peel_to_commit(ref_sha, kind)
        found = api(f"repos/{TARGET}/git/ref/tags/{tag}", missing_ok=True)
        if found is not None:
            # Idempotent: never change a pre-existing version tag.
            print(f"EXISTS {tag} -> {found['object']['sha']}", flush=True)
            existing += 1
            continue
        original = api(f"repos/{TARGET}/git/commits/{original_sha}",
                       missing_ok=True)
        if original:
            try:
                create_tag(tag, original_sha)
                print(f"DIRECT {tag} -> {original_sha}", flush=True)
                direct += 1
                continue
            except RuntimeError as error:
                if not any(word in str(error).lower()
                           for word in ("workflow", "422", "unprocessable")):
                    raise
                print(f"Workflow permission prevents {tag} original tag; "
                      "using a clearly marked archive pointer", flush=True)
        pointer_sha = make_archive_pointer(tag, original_sha)
        create_tag(tag, pointer_sha)
        print(f"POINTER {tag} -> {pointer_sha}; original {original_sha}", flush=True)
        pointers += 1
    print(f"HISTORICAL TAGS: original source={direct}, "
          f"explicit archive pointers={pointers}, existing={existing}", flush=True)


if __name__ == "__main__":
    try:
        import_tags()
    except RuntimeError as err:
        sys.exit(str(err))
