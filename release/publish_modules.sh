#!/usr/bin/env bash
# Incremental module publish: build+sign+upload ONLY the named modules.
# Usage:
#   bash release/publish_modules.sh analyze
#   bash release/publish_modules.sh analyze ingest
# Then on node (PRIMARY): panel POST ota/install for each name.
#
# Hardened flow (07-HARDENING.md): modules are double-signed (root `sig` +
# per-release key `sig2`), the manifest binds build_id/release_pubkey/release_cert
# and is re-signed after the module merge. Re-running for the same VERSION keeps
# the existing per-release key + build_id, so nodes that already bound the key
# keep accepting the new signatures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

# Reuse the release's build_id + obf salt so the rebuilt module embeds the same
# identity as the rest of the release (only when the release tree provides them).
if [[ -f "$OUT/build_id" ]]; then
  export GV6_BUILD_ID="$(tr -d '[:space:]' < "$OUT/build_id")"
fi
# Per-release signing key: reuse when the release tree has one, else generate.
RELKEY_DIR="$OUT/keys-release"
RELEASE_SK="$RELKEY_DIR/ota_ed25519.sk"
if [[ ! -f "$RELEASE_SK" ]]; then
  mkdir -p "$RELKEY_DIR"
  cargo run -q -p gv6-cli -- keygen --out-dir "$RELKEY_DIR" >/dev/null
fi
RELEASE_PK_HEX="$(python3 -c "import pathlib; print(pathlib.Path(r'$RELKEY_DIR/ota_ed25519.pk').read_bytes().hex())")"

# Read existing manifest release fields (new-format); empty when legacy.
OLD_MAN=""
if [[ -f "$OUT/manifest.json" ]]; then
  OLD_MAN="$(cat "$OUT/manifest.json")"
fi
OLD_BUILD_ID="$(printf '%s' "$OLD_MAN" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('build_id') or '')" 2>/dev/null || true)"
OLD_PK="$(printf '%s' "$OLD_MAN" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('release_pubkey') or '')" 2>/dev/null || true)"
OLD_CERT="$(printf '%s' "$OLD_MAN" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('release_cert') or '')" 2>/dev/null || true)"
# If the manifest already binds a release key, we MUST sign with that same key.
if [[ -n "$OLD_PK" && "$OLD_PK" != "$RELEASE_PK_HEX" ]]; then
  echo "[publish-modules] existing manifest release_pubkey != $RELKEY_DIR key" >&2
  echo "[publish-modules] refusing to mix keys — restore $RELKEY_DIR from the release machine" >&2
  exit 1
fi

export GV6_RELEASE_VERSION="$VERSION"
export GV6_MODULE_VERSION="$VERSION"
ARCH="$(uname -m)"
TRIPLE="${ARCH}-linux-gnu"
REPO="${GV6_RELEASE_REPO:-greenpng/install}"

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
  # P0-2: double-sign — root sig + per-release sig2 (new runtimes require sig2
  # when the manifest binds a release key).
  art=$(cargo run -q -p gv6-cli -- sign-module --name "$name" --version "$VERSION" \
    --so "$OUT/$asset" --secret-key keys/ota_ed25519.sk --domain "$name" \
    --release-key "$RELEASE_SK")
  echo "$art" > "$OUT/${name}.artifact.json"
  ASSETS+=("$OUT/$asset")
  echo "[publish-modules] staged $asset (double-signed)"
done

# Merge into existing manifest, PRESERVING build_id / release_pubkey /
# release_cert / arch fields; then re-sign with the same release binding.
MANIFEST="$OUT/manifest.json"
python3 - <<PY
import json, pathlib
out = pathlib.Path("$OUT")
mods = []
for p in sorted(out.glob("*.artifact.json")):
    mods.append(json.loads(p.read_text()))
old_path = out / "manifest.json"
doc = {}
if old_path.is_file():
    try:
        doc = json.loads(old_path.read_text())
    except Exception:
        doc = {}
    by = {m["name"]: m for m in doc.get("modules", [])}
    for m in mods:
        by[m["name"]] = m
    mods = list(by.values())
doc.update({
    "product": doc.get("product") or "green-v6",
    "channel": doc.get("channel") or "stable",
    "runtime": doc.get("runtime") or {"version": "$VERSION", "abi": 1},
    "modules": mods,
})
doc.pop("sig", None)  # re-signed below
old_path.write_text(json.dumps(doc, indent=2) + "\n")
print("[publish-modules] manifest modules:", [m["name"] for m in mods])
PY

RELEASE_ARGS=()
if [[ -n "$OLD_PK" && -n "$OLD_CERT" && -n "$OLD_BUILD_ID" ]]; then
  # New-format manifest: keep the ORIGINAL binding (same version, same cert).
  RELEASE_ARGS=(--build-id "$OLD_BUILD_ID" --release-pubkey "$OLD_PK" --release-cert "$OLD_CERT")
else
  # First hardened publish for this tree: certify the current per-release key.
  cert="$(cargo run -q -p gv6-cli -- sign-cert --secret-key keys/ota_ed25519.sk \
    --version "$VERSION" --build-id "${GV6_BUILD_ID:-dev}" --release-pubkey "$RELEASE_PK_HEX")"
  RELEASE_ARGS=(--build-id "${GV6_BUILD_ID:-dev}" --release-pubkey "$RELEASE_PK_HEX" --release-cert "$cert")
  echo -n "$cert" > "$OUT/release_cert.sig"
  echo -n "$RELEASE_PK_HEX" > "$OUT/release_pubkey.hex"
fi
cargo run -q -p gv6-cli -- sign-manifest --manifest "$MANIFEST" \
  --secret-key keys/ota_ed25519.sk "${RELEASE_ARGS[@]}"
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
