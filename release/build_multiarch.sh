#!/usr/bin/env bash
# Build signed release artifacts for x86_64 + aarch64 on ONE dev machine.
#
# Recommended local workflow (no GitHub Actions minutes):
#   1. Install: Docker + `cargo install cross --locked`
#   2. bash scripts/release/build_multiarch.sh SKIP_PUBLISH=1
#   3. gh release upload …   # hosting only; build stays on your box
#
# Env:
#   HOST_ONLY=1       — current arch only → build_and_publish.sh
#   TARGETS="x86_64 aarch64"
#   USE_CROSS=0       — skip foreign arch (default: auto ON if docker+cross exist)
#   SKIP_PUBLISH=1    — do not gh upload
set -euo pipefail
SRC_ROOT="${GV6_SRC:-$(cd "$(dirname "$0")/../../.." && pwd)}"
ROOT="$SRC_ROOT"
cd "$ROOT"
VERSION="$(tr -d '[:space:]' < VERSION)"
TARGETS="${TARGETS:-x86_64 aarch64}"
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64|amd64) HOST_ARCH=x86_64 ;;
  aarch64|arm64) HOST_ARCH=aarch64 ;;
esac

if [[ "${HOST_ONLY:-0}" == "1" ]]; then
  exec bash "$(dirname "$0")/build_and_publish.sh"
fi

need_cross=0
for a in $TARGETS; do
  [[ "$a" != "$HOST_ARCH" ]] && need_cross=1
done

if [[ "$need_cross" == 1 && "${USE_CROSS:-auto}" == "auto" ]]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    USE_CROSS=1
  else
    USE_CROSS=0
  fi
fi

if [[ "$need_cross" == 1 && "${USE_CROSS:-0}" != "1" ]]; then
  echo "[multiarch] foreign arch requested but USE_CROSS!=1 and docker/cross unavailable"
  echo "[multiarch] install: cargo install cross --locked  (needs Docker running)"
  exit 1
fi

if [[ "$need_cross" == 1 ]] && ! command -v cross >/dev/null 2>&1; then
  echo "[multiarch] installing cross CLI…"
  cargo install cross --locked
fi

# Asset / manifest naming — matches build_and_publish.sh + panel OTA (`{arch}-linux-gnu`).
triple_for() {
  case "$1" in
    x86_64) echo "x86_64-linux-gnu" ;;
    aarch64) echo "aarch64-linux-gnu" ;;
    *) echo "unknown"; return 1 ;;
  esac
}

# rustc / cross target triple
rust_target_for() {
  case "$1" in
    x86_64) echo "x86_64-unknown-linux-gnu" ;;
    aarch64) echo "aarch64-unknown-linux-gnu" ;;
    *) echo "unknown"; return 1 ;;
  esac
}

ensure_keys() {
  mkdir -p "$ROOT/keys"
  if [[ -f "$ROOT/keys/ota_ed25519.sk" ]]; then
    return 0
  fi
  if [[ -n "${GV6_OTA_SIGNING_KEY:-}" ]]; then
    printf '%s' "$GV6_OTA_SIGNING_KEY" > "$ROOT/keys/ota_ed25519.sk"
    chmod 600 "$ROOT/keys/ota_ed25519.sk"
    return 0
  fi
  if [[ "${GV6_ALLOW_KEYGEN:-0}" == "1" ]]; then
    cargo run -q -p gv6-cli -- keygen --out-dir "$ROOT/keys"
    return 0
  fi
  echo "[multiarch] missing keys/ota_ed25519.sk — set GV6_OTA_SIGNING_KEY or GV6_ALLOW_KEYGEN=1" >&2
  exit 1
}

ensure_fe() {
  echo -n "$VERSION" > "$ROOT/fe/VERSION"
  if [[ -x "$ROOT/scripts/fe/rebuild_bundles.sh" ]]; then
    bash "$ROOT/scripts/fe/rebuild_bundles.sh"
  fi
}

stage_artifacts() {
  local arch="$1"
  local triple="$2"
  local out="$3"
  local target_dir="$4"

  mkdir -p "$out"
  # 公钥随产物分发 (installer 从 release 资产读取公钥验签)
  if [[ -f "$ROOT/keys/ota_ed25519.pk" ]]; then
    cp -f "$ROOT/keys/ota_ed25519.pk" "$out/ota_ed25519.pk"
  elif [[ -f "$ROOT/keys/ota_ed25519.pub" ]]; then
    cp -f "$ROOT/keys/ota_ed25519.pub" "$out/ota_ed25519.pk"
  fi
  cp -f "$target_dir/gv6-service" "$out/gv6-service-${VERSION}-${triple}"
  cp -f "$target_dir/gv6" "$out/gv6-${VERSION}-${triple}" 2>/dev/null || true
  chmod +x "$out/gv6-service-${VERSION}-${triple}"
  [[ -f "$out/gv6-${VERSION}-${triple}" ]] && chmod +x "$out/gv6-${VERSION}-${triple}"

  local mods_json="[]"
  for pair in identity:gv6_module_identity brain:gv6_module_brain analyze:gv6_module_analyze ingest:gv6_module_ingest edge:gv6_module_edge probe_assets:gv6_module_probe_assets; do
    local name crate so asset art
    name="${pair%%:*}"
    crate="${pair##*:}"
    so="$(find "$target_dir" -maxdepth 1 -name "lib${crate//-/_}.so" | head -1 || true)"
    if [[ -z "$so" || ! -f "$so" ]]; then
      so="$(find "$target_dir" -maxdepth 1 -name "libgv6_module_${name}*.so" | head -1 || true)"
    fi
    if [[ -z "$so" || ! -f "$so" ]]; then
      so="$(find "$target_dir" -maxdepth 1 -name "libgv6_${name}*.so" | head -1 || true)"
    fi
    if [[ -z "$so" || ! -f "$so" ]]; then
      echo "[multiarch] WARN missing module so: $name ($arch)"
      continue
    fi
    asset="libgv6_${name}-${VERSION}-${triple}.so"
    cp -f "$so" "$out/$asset"
    art=$(cargo run -q -p gv6-cli -- sign-module \
      --name "$name" --version "$VERSION" --so "$out/$asset" \
      --secret-key "$ROOT/keys/ota_ed25519.sk" --domain "$name")
    echo "$art" > "$out/${name}.artifact.json"
    mods_json=$(python3 - <<PY
import json
mods = json.loads('''$mods_json''')
mods.append(json.loads('''$art'''))
print(json.dumps(mods))
PY
)
  done

  # FE/admin-spa 与架构无关: 若其他 arch 目录已打包同版本, 复制字节 (sha 一致),
  # 否则本 arch 首次打包。gzip 含时间戳, 重复打包会产生不同 sha → 各 arch manifest 不一致。
  fe_master="$(find "$ROOT/dist" -maxdepth 2 -name "fe-${VERSION}.tgz" ! -path "$out/*" | head -1 || true)"
  if [[ -n "$fe_master" && "$fe_master" != "$out/fe-${VERSION}.tgz" ]]; then
    cp -f "$fe_master" "$out/fe-${VERSION}.tgz"
  elif [[ ! -f "$out/fe-${VERSION}.tgz" ]]; then
    tar -C "$ROOT" -czhf "$out/fe-${VERSION}.tgz" fe
  fi
  admin_master="$(find "$ROOT/dist" -maxdepth 2 -name "admin-spa.tgz" ! -path "$out/*" | head -1 || true)"
  if [[ -n "$admin_master" && "$admin_master" != "$out/admin-spa.tgz" ]]; then
    cp -f "$admin_master" "$out/admin-spa.tgz"
  elif [[ -d "$ROOT/admin-spa" && ! -f "$out/admin-spa.tgz" ]]; then
    tar -C "$ROOT" -czf "$out/admin-spa.tgz" admin-spa
  fi

  python3 - <<PY
import hashlib, json, pathlib
out = pathlib.Path(r"""$out""")
version = """$VERSION"""
triple = """$triple"""
arch = """$arch"""
mods = json.loads(r'''$mods_json''')
svc = out / f"gv6-service-{version}-{triple}"
fe = out / f"fe-{version}.tgz"
man = {
    "product": "green-v6",
    "channel": "stable",
    "arch": arch,
    "triple": triple,
    "runtime": {
        "version": version,
        "abi": 1,
        "asset": svc.name,
        "sha256": hashlib.sha256(svc.read_bytes()).hexdigest(),
    },
    "fe": {
        "asset": fe.name,
        "sha256": hashlib.sha256(fe.read_bytes()).hexdigest(),
    } if fe.is_file() else None,
    "modules": mods,
}
(out / f"manifest-{triple}.json").write_text(json.dumps(man, indent=2) + "\n")
print("[multiarch] manifest", out / f"manifest-{triple}.json", "modules", len(mods))
PY
}

build_native() {
  local arch="$1"
  local triple rust_target out target_dir
  triple="$(triple_for "$arch")"
  rust_target="$(rust_target_for "$arch")"
  out="$ROOT/dist/release-$VERSION-$arch"
  target_dir="$ROOT/target/release"

  echo "[multiarch] native build $arch ($rust_target)"
  cargo build --release -p gv6-service -p gv6-cli -p gv6-harden
  for p in gv6-module-identity gv6-module-brain gv6-module-analyze gv6-module-ingest gv6-module-edge gv6-module-probe-assets; do
    cargo build --release -p "$p" --features plugin
  done
  stage_artifacts "$arch" "$triple" "$out" "$target_dir"
  file "$out/gv6-service-${VERSION}-${triple}"
}

build_cross() {
  local arch="$1"
  local triple rust_target out cross_dir target_dir
  triple="$(triple_for "$arch")"
  rust_target="$(rust_target_for "$arch")"
  out="$ROOT/dist/release-$VERSION-$arch"
  cross_dir="/tmp/gv6-cross-${VERSION}-${arch}"
  target_dir="$cross_dir/${rust_target}/release"

  echo "[multiarch] cross build $arch ($rust_target) target-dir=$cross_dir"
  rustup target add "$rust_target" >/dev/null 2>&1 || true
  rm -rf "$cross_dir"

  cross build --release --target "$rust_target" \
    --target-dir "$cross_dir" \
    -p gv6-service -p gv6-cli -p gv6-harden
  for p in gv6-module-identity gv6-module-brain gv6-module-analyze gv6-module-ingest gv6-module-edge gv6-module-probe-assets; do
    cross build --release --target "$rust_target" \
      --target-dir "$cross_dir" \
      -p "$p" --features plugin
  done

  stage_artifacts "$arch" "$triple" "$out" "$target_dir"
  file "$out/gv6-service-${VERSION}-${triple}"
}

ensure_keys
ensure_fe

for a in $TARGETS; do
  if [[ "$a" == "$HOST_ARCH" ]]; then
    build_native "$a"
  else
    build_cross "$a"
  fi
done

MERGE="$ROOT/dist/release-$VERSION"
mkdir -p "$MERGE"
for a in $TARGETS; do
  src="$ROOT/dist/release-$VERSION-$a"
  [[ -d "$src" ]] || continue
  cp -an "$src"/* "$MERGE/" 2>/dev/null || cp -a "$src"/. "$MERGE/"
done

python3 - <<PY
import json, pathlib
merge = pathlib.Path(r"""$MERGE""")
version = """$VERSION"""
index = {
  "product": "green-v6",
  "version": version,
  "architectures": {},
  "build_host": "$(uname -m)",
  "note": "Built locally; GitHub Releases is asset hosting only.",
}
for p in sorted(merge.glob("manifest-*-linux-gnu.json")):
    if p.name == "manifest-index.json":
        continue
    man = json.loads(p.read_text())
    arch = man.get("arch") or "unknown"
    index["architectures"][arch] = {"manifest": p.name, "triple": man.get("triple")}
(merge / "manifest-index.json").write_text(json.dumps(index, indent=2) + "\n")
print(json.dumps(index, indent=2))
PY

for mf in "$MERGE"/manifest-*-linux-gnu.json; do
  [[ -f "$mf" ]] || continue
  cargo run -q -p gv6-cli -- sign-manifest --manifest "$mf" --secret-key "$ROOT/keys/ota_ed25519.sk"
done

# Back-compat: host arch also as manifest.json for single-arch OTA scripts
host_triple="$(triple_for "$HOST_ARCH")"
if [[ -f "$MERGE/manifest-${host_triple}.json" ]]; then
  cp -f "$MERGE/manifest-${host_triple}.json" "$MERGE/manifest.json"
fi

echo "[multiarch] merged → $MERGE"
ls -la "$MERGE" | head -30

if [[ "${SKIP_PUBLISH:-0}" == "1" ]]; then
  echo "[multiarch] SKIP_PUBLISH=1 done"
  exit 0
fi

REPO="${GV6_RELEASE_REPO:-greenpng/gv6-releases}"
if command -v gh >/dev/null 2>&1; then
  mapfile -t ASSETS < <(find "$MERGE" -maxdepth 1 -type f ! -name '*.sk' | sort)
  if gh release view "v${VERSION}" --repo "$REPO" >/dev/null 2>&1; then
    echo "[multiarch] release v${VERSION} exists — uploading new assets only (no clobber)"
    gh release upload "v${VERSION}" "${ASSETS[@]}" --repo "$REPO"
  else
    gh release create "v${VERSION}" "${ASSETS[@]}" --repo "$REPO" \
      --title "green-v6 ${VERSION}" \
      --notes "Local multi-arch build (x86_64 + aarch64). See manifest-index.json."
  fi
else
  echo "[multiarch] gh not installed — artifacts ready at $MERGE"
fi
