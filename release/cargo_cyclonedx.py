#!/usr/bin/env python3
"""Emit a CycloneDX 1.5 SBOM from `cargo metadata` (no extra crates)."""
from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timezone


def main() -> int:
    raw = subprocess.check_output(
        ["cargo", "metadata", "--format-version", "1", "--locked"],
        stderr=subprocess.DEVNULL,
    )
    meta = json.loads(raw)
    components = []
    seen = set()
    for pkg in meta.get("packages", []):
        name = pkg.get("name") or ""
        ver = pkg.get("version") or ""
        key = (name, ver)
        if key in seen:
            continue
        seen.add(key)
        purl = f"pkg:cargo/{name}@{ver}"
        comp = {
            "type": "library",
            "name": name,
            "version": ver,
            "purl": purl,
            "bom-ref": purl,
        }
        lic = []
        for lic_ent in pkg.get("license") and [{"license": {"id": pkg["license"]}}] or []:
            lic.append(lic_ent)
        if pkg.get("license"):
            comp["licenses"] = [{"license": {"name": pkg["license"]}}]
        components.append(comp)
    bom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "tools": [{"name": "scripts/release/cargo_cyclonedx.py", "version": "1"}],
        },
        "components": components,
    }
    json.dump(bom, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
