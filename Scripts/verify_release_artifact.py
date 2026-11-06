#!/usr/bin/env python3
"""Fail closed unless a downloaded DMG matches its verified build.

The expected digest comes from the verification job's output, independently of
the downloaded artifact. This check deliberately does not rely on the artifact
action's digest-mismatch warning being fatal.
"""

import argparse
import hashlib
from pathlib import Path
import re
import sys


def verify(directory: Path, *, commit: str, version: str, sha256: str) -> Path:
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected commit must be a full Git SHA.")
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise ValueError("The verification job did not supply a valid DMG digest.")
    if not version or any(c in version for c in "\r\n/\\"):
        raise ValueError("Release version must be a nonempty, single filename component.")

    source = (directory / "source-commit.txt").read_text(encoding="utf-8").strip()
    packaged_version = (directory / "package-version.txt").read_text(encoding="utf-8").strip()
    if source != commit:
        raise ValueError("Package source commit differs from this release's commit.")
    if packaged_version != version:
        raise ValueError("Package version differs from this release's tag.")

    dmg = directory / "Markdown2.dmg"
    digest = hashlib.sha256()
    with dmg.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != sha256:
        raise ValueError("Downloaded DMG differs from the package that passed verification.")
    return dmg


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--sha256", required=True)
    args = parser.parse_args()
    try:
        verify(args.directory, commit=args.commit, version=args.version, sha256=args.sha256)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Release artifact rejected: {error}", file=sys.stderr)
        return 1
    print(f"Verified release package for {args.version} at {args.commit}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
