#!/usr/bin/env bash
# Build + sign business modules for a release version (default 6.0.1).
# Does not rebuild full gv6-service (keeps machine load low).
set -euo pipefail
SRC_ROOT="${GV6_SRC:-$(cd "$(dirname "$0")/../../.." && pwd)}"
ROOT="$SRC_ROOT"
cd "$ROOT"
VERSION="${1:-6.0.1}"
OUT="$ROOT/dist/release-$VERSION"
JOBS="${CARGO_BUILD_JOBS:-2}"
TRIPLE="$(uname -m)-linux-gnu"
mkdir -p "$OUT" keys

if [[ ! -f keys/ota_ed25519.sk ]]; then
  if [[ -n "${GV6_OTA_SIGNING_KEY:-}" ]]; then
    printf '%s' "$GV6_OTA_SIGNING_KEY" > keys/ota_ed25519.sk
    chmod 600 keys/ota_ed25519.sk
  elif [[ "${GV6_ALLOW_KEYGEN:-0}" == "1" ]]; then
    cargo run -q -p gv6-cli --jobs "$JOBS" -- keygen --out-dir keys
  else
    echo "[release] missing keys/ota_ed25519.sk (set GV6_OTA_SIGNING_KEY or GV6_ALLOW_KEYGEN=1)" >&2
    exit 1
  fi
fi
cp -f keys/ota_ed25519.pk "$OUT/ota_ed25519.pk"

echo "[release] build plugin .so (jobs=$JOBS) version=$VERSION"
export GV6_RELEASE_VERSION="$VERSION"
export GV6_MODULE_VERSION="$VERSION"
for p in gv6-module-identity gv6-module-brain gv6-module-analyze gv6-module-ingest gv6-module-edge gv6-module-probe-assets; do
  cargo build --release -p "$p" --features plugin --jobs "$JOBS"
done

# map name -> so pattern
mods=(
  "identity:libgv6_module_identity.so"
  "brain:libgv6_module_brain.so"
  "analyze:libgv6_module_analyze.so"
  "ingest:libgv6_module_ingest.so"
  "edge:libgv6_module_edge.so"
  "probe_assets:libgv6_module_probe_assets.so"
)

MANIFEST_MODULES='[]'
for pair in "${mods[@]}"; do
  name="${pair%%:*}"
  so_name="${pair##*:}"
  src=$(find target/release -maxdepth 1 -name "$so_name" | head -1 || true)
  if [[ -z "$src" || ! -f "$src" ]]; then
    echo "[release] WARN missing $so_name"
    continue
  fi
  asset="libgv6_${name}-${VERSION}-${TRIPLE}.so"
  cp -f "$src" "$OUT/$asset"
  art=$(cargo run -q -p gv6-cli --jobs "$JOBS" -- sign-module \
    --name "$name" --version "$VERSION" --so "$OUT/$asset" \
    --secret-key keys/ota_ed25519.sk --domain "$name")
  echo "$art" >"$OUT/${name}.artifact.json"
  MANIFEST_MODULES=$(python3 -c "import json; m=json.loads('''$MANIFEST_MODULES'''); m.append(json.loads('''$art''')); print(json.dumps(m))")
  echo "[release] signed $asset"
done

python3 - <<PY >"$OUT/manifest.json"
import json
mods=json.loads('''$MANIFEST_MODULES''')
print(json.dumps({
  "product": "green-v6",
  "channel": "stable",
  "runtime": {"version": "$VERSION", "abi": 1},
  "modules": mods
}, indent=2))
PY

# ship admin spa snapshot
mkdir -p "$OUT/admin-spa"
cp -a admin-spa/. "$OUT/admin-spa/" 2>/dev/null || true

echo "[release] artifacts in $OUT"
ls -la "$OUT" | head -40

REPO="${GV6_RELEASE_REPO:-greenpng/gv6-releases}"
if [[ "${PUBLISH:-1}" == "1" ]] && command -v gh >/dev/null; then
  if gh release view "v${VERSION}" --repo "$REPO" >/dev/null 2>&1; then
    echo "[release] upload to existing v${VERSION}"
    gh release upload "v${VERSION}" "$OUT"/* --repo "$REPO"
  else
    echo "[release] create v${VERSION}"
    gh release create "v${VERSION}" "$OUT"/* \
      --repo "$REPO" \
      --title "green-v6 ${VERSION}" \
      --notes "Signed business modules for green-v6. Verify ed25519 (ota_ed25519.pk) + sha256 before activate. Runtime ABI 1."
  fi
  echo "[release] published https://github.com/${REPO}/releases/tag/v${VERSION}"
else
  echo "[release] local only (PUBLISH=0 or no gh)"
fi
