#!/usr/bin/env bash
# Incremental module publish: build+sign+upload ONLY the named modules.
# Usage:
#   bash scripts/release/publish_modules.sh analyze
#   bash scripts/release/publish_modules.sh analyze ingest
# Then on node (PRIMARY): panel POST ota/install for each name.
set -euo pipefail
SRC_ROOT="${GV6_SRC:-$(cd "$(dirname "$0")/../../.." && pwd)}"
ROOT="$SRC_ROOT"
cd "$ROOT"
VERSION="$(tr -d '[:space:]' < VERSION)"
OUT="$ROOT/dist/release-$VERSION"
mkdir -p "$OUT" keys
if [[ ! -f keys/ota_ed25519.sk ]]; then
  if [[ -n "${GV6_OTA_SIGNING_KEY:-}" ]]; then
    printf '%s' "$GV6_OTA_SIGNING_KEY" > keys/ota_ed25519.sk
    chmod 600 keys/ota_ed25519.sk
  elif [[ "${GV6_ALLOW_KEYGEN:-0}" == "1" ]]; then
    cargo run -q -p gv6-cli -- keygen --out-dir keys
  else
    echo "[release] missing keys/ota_ed25519.sk (set GV6_OTA_SIGNING_KEY or GV6_ALLOW_KEYGEN=1)" >&2
    exit 1
  fi
fi
export GV6_RELEASE_VERSION="$VERSION"
export GV6_MODULE_VERSION="$VERSION"
ARCH="$(uname -m)"
TRIPLE="${ARCH}-linux-gnu"
REPO="${GV6_RELEASE_REPO:-greenpng/gv6-releases}"

if [[ $# -lt 1 ]]; then
  echo "USAGE: $0 <module> [module...]" >&2
  echo "  modules: identity brain analyze ingest edge probe_assets" >&2
  exit 2
fi

crate_for() {
  case "$1" in
    identity) echo gv6-module-identity ;;
    brain) echo gv6-module-brain ;;
    analyze) echo gv6-module-analyze ;;
    ingest) echo gv6-module-ingest ;;
    edge) echo gv6-module-edge ;;
    probe_assets) echo gv6-module-probe-assets ;;
    *) echo "unknown module: $1" >&2; exit 2 ;;
  esac
}

ASSETS=()
for name in "$@"; do
  crate="$(crate_for "$name")"
  echo "[publish-modules] build $crate (plugin)"
  cargo build --release -p "$crate" --features plugin
  so="$(find target/release -maxdepth 1 -name "libgv6_module_${name}*.so" -o -name "lib${crate//-/_}.so" 2>/dev/null | head -1)"
  if [[ -z "${so:-}" || ! -f "$so" ]]; then
    so="$(ls -1 target/release/libgv6_module_${name}*.so 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "${so:-}" || ! -f "$so" ]]; then
    # rustc often names libgv6_module_analyze.so
    so="$(ls -1 target/release/libgv6_module_${name//_/-}.so target/release/libgv6_${name}.so 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "${so:-}" || ! -f "$so" ]]; then
    so="$(find target/release -maxdepth 1 -name "*.so" | rg -i "module.?${name}|gv6.?${name}" | head -1 || true)"
  fi
  if [[ -z "${so:-}" || ! -f "$so" ]]; then
    echo "[publish-modules] cannot find .so for $name after build" >&2
    ls target/release/*.so 2>/dev/null | head -20 >&2 || true
    exit 1
  fi
  asset="libgv6_${name}-${VERSION}-${TRIPLE}.so"
  cp -f "$so" "$OUT/$asset"
  art=$(cargo run -q -p gv6-cli -- sign-module --name "$name" --version "$VERSION" --so "$OUT/$asset" --secret-key keys/ota_ed25519.sk --domain "$name")
  echo "$art" > "$OUT/${name}.artifact.json"
  ASSETS+=("$OUT/$asset")
  echo "[publish-modules] staged $asset"
done

# Merge into existing manifest if present, else minimal
MANIFEST="$OUT/manifest.json"
python3 - <<PY
import json, pathlib, glob
out = pathlib.Path("$OUT")
ver = "$VERSION"
mods = []
# prefer newly written artifact json for requested modules
for p in sorted(out.glob("*.artifact.json")):
    mods.append(json.loads(p.read_text()))
# if old full manifest exists, keep non-overwritten modules
old_path = out / "manifest.json"
if old_path.is_file():
    try:
        old = json.loads(old_path.read_text())
        by = {m["name"]: m for m in old.get("modules", [])}
        for m in mods:
            by[m["name"]] = m
        mods = list(by.values())
    except Exception:
        pass
doc = {
    "product": "green-v6",
    "channel": "stable",
    "runtime": {"version": ver, "abi": 1},
    "modules": mods,
}
old_path.write_text(json.dumps(doc, indent=2) + "\n")
print("[publish-modules] manifest modules:", [m["name"] for m in mods])
PY
ASSETS+=("$MANIFEST")

if command -v gh >/dev/null 2>&1; then
  if gh release view "v${VERSION}" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "v${VERSION}" "${ASSETS[@]}" --repo "$REPO"
  else
    gh release create "v${VERSION}" "${ASSETS[@]}" --repo "$REPO" \
      --title "green-v6 ${VERSION}" \
      --notes "Incremental module assets. Panel: ota/install per module."
  fi
  echo "[publish-modules] uploaded to v${VERSION}"
  echo "[next] panel: set-release-url …/v${VERSION} then ota/install each: $*"
else
  echo "[publish-modules] gh missing; local only: $OUT"
fi
