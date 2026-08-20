#!/usr/bin/env bash
# Pull green-v6 **runtime binary** from GitHub releases and restart service.
# Module .so updates should use admin panel OTA (hot); this path is for rare
# runtime / in-tree plane changes that require process restart.
#
# Usage on the server (or via SSH):
#   VERSION=6.0.2 bash release/update_runtime_from_github.sh
# Env:
#   VERSION          default: from /opt/green-v6/VERSION or required
#   INSTALL_ROOT     default: /opt/green-v6
#   RELEASE_REPO     default: greenpng/gv6-releases
#   ARCH_TRIPLE      default: auto from uname -m → {arch}-linux-gnu
#   REQUIRE_SHA      default: 1 — fail if manifest lacks runtime.sha256
#   HEALTH_URL       default: http://127.0.0.1:28680/v1/health
set -euo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-/opt/green-v6}"
RELEASE_REPO="${RELEASE_REPO:-greenpng/gv6-releases}"
REQUIRE_SHA="${REQUIRE_SHA:-1}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:28680/v1/health}"
VERSION="${VERSION:-}"
host_arch="$(uname -m)"
case "$host_arch" in
  x86_64|amd64) host_arch=x86_64 ;;
  aarch64|arm64) host_arch=aarch64 ;;
esac
ARCH_TRIPLE="${ARCH_TRIPLE:-${host_arch}-linux-gnu}"
if [[ -z "$VERSION" && -f "$INSTALL_ROOT/VERSION" ]]; then
  # if caller wants "latest" they must set VERSION explicitly
  :
fi
if [[ -z "$VERSION" ]]; then
  echo "USAGE: VERSION=x.y.z $0" >&2
  exit 2
fi

BASE="https://github.com/${RELEASE_REPO}/releases/download/v${VERSION}"
ASSET_SVC="gv6-service-${VERSION}-${ARCH_TRIPLE}"
ASSET_CLI="gv6-${VERSION}-${ARCH_TRIPLE}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Prefer multi-arch index → per-arch manifest; fall back to manifest.json
resolve_manifest() {
  local man_name=""
  if curl -fsSL -o "$TMP/manifest-index.json" "$BASE/manifest-index.json" 2>/dev/null; then
    man_name=$(python3 - <<PY
import json
idx=json.load(open("$TMP/manifest-index.json"))
arch="$host_arch"
entry=(idx.get("architectures") or {}).get(arch) or {}
print(entry.get("manifest") or "")
PY
)
    if [[ -n "$man_name" && "$man_name" != *"/"* && "$man_name" != *".."* ]]; then
      if curl -fsSL -o "$TMP/manifest.json" "$BASE/$man_name"; then
        echo "[runtime-ota] manifest from index: $man_name (arch=$host_arch)"
        return 0
      fi
    fi
  fi
  if curl -fsSL -o "$TMP/manifest.json" "$BASE/manifest-${ARCH_TRIPLE}.json" 2>/dev/null; then
    echo "[runtime-ota] using manifest-${ARCH_TRIPLE}.json"
    return 0
  fi
  if curl -fsSL -o "$TMP/manifest.json" "$BASE/manifest.json" 2>/dev/null; then
    echo "[runtime-ota] using legacy manifest.json"
    return 0
  fi
  return 1
}

# R-05: list + reject path escapes / symlinks before extract
safe_extract_tar_gz() {
  local tgz="$1"
  local dest="$2"
  local listing
  listing="$(tar -tzf "$tgz")"
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    # 仅拒绝真正的路径逃逸 (fe 包含 [[...path]] 模板目录名, 不能误伤 "..")
    if [[ "$path" == /* ]] || [[ "$path" == ../* ]] || [[ "$path" == *"/../"* ]] || [[ "$path" == *"/.." ]]; then
      echo "tar entry rejected (path escape): $path" >&2
      return 1
    fi
  done <<<"$listing"
  local vlist
  if vlist="$(tar -tvzf "$tgz" 2>/dev/null)"; then
    while IFS= read -r line; do
      local t="${line#"${line%%[![:space:]]*}"}"
      if [[ "$t" == l* ]] || [[ "$line" == *" -> "* ]]; then
        echo "tar entry rejected (symlink): $line" >&2
        return 1
      fi
    done <<<"$vlist"
  fi
  mkdir -p "$dest"
  tar -xzf "$tgz" -C "$dest"
}

echo "[runtime-ota] arch=$ARCH_TRIPLE base=$BASE"
resolve_manifest || true
if [[ -f "$TMP/manifest.json" ]]; then
  MAN_ASSET=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print((m.get("runtime") or {}).get("asset") or "")' "$TMP/manifest.json" 2>/dev/null || true)
  if [[ -n "$MAN_ASSET" ]]; then
    ASSET_SVC="$MAN_ASSET"
  fi
fi

echo "[runtime-ota] fetch $BASE/$ASSET_SVC"
curl -fsSL -o "$TMP/gv6-service" "$BASE/$ASSET_SVC"
chmod +x "$TMP/gv6-service"
# optional CLI
if curl -fsSL -o "$TMP/gv6" "$BASE/$ASSET_CLI" 2>/dev/null; then
  chmod +x "$TMP/gv6"
fi
# optional FE tarball (product_version SSOT)
FE_TGZ="fe-${VERSION}.tgz"
if curl -fsSL -o "$TMP/fe.tgz" "$BASE/$FE_TGZ" 2>/dev/null; then
  echo "[runtime-ota] fetched $FE_TGZ"
else
  echo "[runtime-ota] no $FE_TGZ on release (FE not updated this run)"
fi

# sanity: ELF
file "$TMP/gv6-service" | grep -qi ELF || {
  echo "downloaded asset is not ELF binary" >&2
  head -c 200 "$TMP/gv6-service" >&2 || true
  exit 1
}

# R-01: verify runtime/FE sha256 from manifest when present; REQUIRE_SHA=1 fails if missing.
if [[ -f "$TMP/manifest.json" ]]; then
  EXPECT_SHA=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print((m.get("runtime") or {}).get("sha256") or "")' "$TMP/manifest.json" 2>/dev/null || true)
  if [[ -n "${EXPECT_SHA}" ]]; then
    GOT_SHA=$(sha256sum "$TMP/gv6-service" | awk '{print $1}')
    if [[ "$GOT_SHA" != "$EXPECT_SHA" ]]; then
      echo "runtime sha256 mismatch: got $GOT_SHA expect $EXPECT_SHA" >&2
      exit 1
    fi
    echo "[runtime-ota] runtime sha256 verified"
  elif [[ "$REQUIRE_SHA" == "1" ]]; then
    echo "runtime sha256 missing from manifest (set REQUIRE_SHA=0 only for lab)" >&2
    exit 1
  fi
  if [[ -f "$TMP/fe.tgz" ]]; then
    FE_SHA=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print((m.get("fe") or {}).get("sha256") or "")' "$TMP/manifest.json" 2>/dev/null || true)
    if [[ -n "${FE_SHA}" ]]; then
      GOT_FE=$(sha256sum "$TMP/fe.tgz" | awk '{print $1}')
      if [[ "$GOT_FE" != "$FE_SHA" ]]; then
        echo "FE sha256 mismatch: got $GOT_FE expect $FE_SHA" >&2
        exit 1
      fi
      echo "[runtime-ota] FE sha256 verified"
    elif [[ "$REQUIRE_SHA" == "1" ]]; then
      echo "FE sha256 missing from manifest (set REQUIRE_SHA=0 only for lab)" >&2
      exit 1
    fi
  fi
elif [[ "$REQUIRE_SHA" == "1" ]]; then
  echo "manifest.json missing; cannot verify sha256 (set REQUIRE_SHA=0 only for lab)" >&2
  exit 1
fi

echo "[runtime-ota] install into $INSTALL_ROOT/bin (backup previous)"
mkdir -p "$INSTALL_ROOT/bin" "$INSTALL_ROOT/bin/releases/${VERSION}" "$INSTALL_ROOT/dist/release-${VERSION}"
BAK=""
if [[ -x "$INSTALL_ROOT/bin/gv6-service" ]]; then
  BAK="$INSTALL_ROOT/bin/gv6-service.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -a "$INSTALL_ROOT/bin/gv6-service" "$BAK" || true
fi
# versioned slot then install
install -m 0755 "$TMP/gv6-service" "$INSTALL_ROOT/bin/releases/${VERSION}/gv6-service"
install -m 0755 "$TMP/gv6-service" "$INSTALL_ROOT/bin/gv6-service"
if [[ -f "$TMP/gv6" ]]; then
  install -m 0755 "$TMP/gv6" "$INSTALL_ROOT/bin/gv6"
fi
if [[ -f "$TMP/manifest.json" ]]; then
  cp -f "$TMP/manifest.json" "$INSTALL_ROOT/dist/release-${VERSION}/manifest.json"
fi
echo "$VERSION" > "$INSTALL_ROOT/VERSION"
# Sync FE product_version so cool tickets + asset ?v= use v6 SSOT
if [[ -f "$TMP/fe.tgz" ]]; then
  echo "[runtime-ota] install FE assets (safe extract)"
  STAGE="$TMP/fe-extract"
  safe_extract_tar_gz "$TMP/fe.tgz" "$STAGE"
  if [[ -d "$INSTALL_ROOT/fe" ]]; then
    FE_BAK="$INSTALL_ROOT/fe.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$INSTALL_ROOT/fe" "$FE_BAK" || true
  fi
  if [[ -d "$STAGE/fe" ]]; then
    mkdir -p "$INSTALL_ROOT"
    mv "$STAGE/fe" "$INSTALL_ROOT/fe"
  else
    mkdir -p "$INSTALL_ROOT/fe"
    # copy contents if tarball is flat under STAGE
    cp -a "$STAGE"/. "$INSTALL_ROOT/fe/"
  fi
  echo "$VERSION" > "$INSTALL_ROOT/fe/VERSION"
fi
echo "$VERSION" > "$INSTALL_ROOT/fe/VERSION" 2>/dev/null || true

# Point OTA module channel at this tag (panel still installs so separately)
ENVF="$INSTALL_ROOT/.env"
if [[ -f "$ENVF" ]]; then
  if grep -q '^GV6_RELEASE_URL=' "$ENVF"; then
    sed -i "s|^GV6_RELEASE_URL=.*|GV6_RELEASE_URL=${BASE}|" "$ENVF"
  else
    echo "GV6_RELEASE_URL=${BASE}" >> "$ENVF"
  fi
fi

echo "[runtime-ota] restart green-v6 + health gate"
if systemctl is-enabled green-v6 >/dev/null 2>&1 || systemctl cat green-v6 >/dev/null 2>&1; then
  systemctl restart green-v6
  ok=0
  for i in 1 2 3 4 5 6 7 8; do
    sleep 2
    if curl -fsS "$HEALTH_URL" >/tmp/gv6-runtime-ota-health.json 2>/dev/null; then
      ok=1
      break
    fi
  done
  if [[ "$ok" != "1" ]]; then
    echo "[runtime-ota] HEALTH_FAIL — rolling back binary" >&2
    if [[ -n "$BAK" && -x "$BAK" ]]; then
      install -m 0755 "$BAK" "$INSTALL_ROOT/bin/gv6-service"
      systemctl restart green-v6 || true
      sleep 3
      if curl -fsS "$HEALTH_URL" >/tmp/gv6-runtime-ota-health-rollback.json 2>/dev/null; then
        echo "[runtime-ota] ROLLBACK_HEALTH_OK" >&2
      else
        echo "[runtime-ota] ROLLBACK_HEALTH_FAIL" >&2
      fi
    fi
    exit 1
  fi
  systemctl is-active green-v6
  echo "[runtime-ota] HEALTH_OK"
else
  echo "WARN: green-v6 unit not found; binary installed, restart manually" >&2
fi

echo "[runtime-ota] done VERSION=$VERSION"
