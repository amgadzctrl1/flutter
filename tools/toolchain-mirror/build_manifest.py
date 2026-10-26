#!/usr/bin/env python3
"""Turn a path-preserving download tree into flat GitHub release assets.

Input:  <download-dir>/flutter_infra_release/.../<file>
Output: <assets-dir>/flutter_infra_release__...__<file>
        <output-json>  (the CLI's mirror manifest)

Assets are moved, not copied, so the runner does not need 2x disk space.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("download_dir", type=Path)
    parser.add_argument("assets_dir", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--flutter-commit", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()

    if not args.download_dir.is_dir():
        print(f"download directory does not exist: {args.download_dir}", file=sys.stderr)
        return 1

    args.assets_dir.mkdir(parents=True, exist_ok=True)
    files = sorted(
        path for path in args.download_dir.rglob("*") if path.is_file()
    )
    if not files:
        print("no downloaded artifacts found", file=sys.stderr)
        return 1

    entries = []
    seen = set()
    total = 0
    for source in files:
        relative = source.relative_to(args.download_dir).as_posix()
        asset = relative.replace("/", "__")
        if asset in seen:
            print(f"duplicate flat asset name: {asset}", file=sys.stderr)
            return 1
        seen.add(asset)

        destination = args.assets_dir / asset
        if destination.exists():
            destination.unlink()
        shutil.move(str(source), str(destination))

        size = destination.stat().st_size
        total += size
        entries.append(
            {
                "path": relative,
                "asset": asset,
                "bytes": size,
                "sha256": sha256_of(destination),
            }
        )

    manifest = {
        "schema": 1,
        "engine_revision": args.revision,
        "flutter_commit": args.flutter_commit,
        "repository": args.repository,
        "tag": args.tag,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "entries": entries,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"mirrored {len(entries)} artifacts, {total} bytes")
    for entry in entries:
        print(f"  {entry['bytes']:>12}  {entry['path']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
