#!/usr/bin/env bash
# green-v6 一键安装脚本 (sh)
#
# 从 greenpng/green-v7 下载签名发布资产 (x86_64 / aarch64), 校验 sha256 +
# ed25519 模块签名, 落地 /opt/green-v6, 生成 systemd 服务。
# 旧版本兜底: greenpng/gv6-releases (v6.0.28 及更早发布仍在旧仓库)。
#
# 数据库/缓存连接信息按"管理面 / 业务面 / 缓存"分组填写:
#   - 业务面(探测/分析): GV6_DATABASE_URL  GV6_BIZ_DATABASE_URL  GV6_ASSOCIATION_DATABASE_URL
#   - 管理面(面板/审计):  GV6_ADMIN_DATABASE_URL
#   - 缓存(可选):         GV5_REDIS_URL (留空 = 本地文件 soft store)
#   - 管理面板登录:        OAuth 跳转官网域名 (GV6_OFFICIAL_URL + GV6_OAUTH_ADMIN_EMAILS)
#
# 用法:
#   bash install.sh [--version 6.0.28] [--arch auto|x86_64|aarch64]
#                   [--prefix /opt/green-v6] [--env-file path]
#                   [--with-docker] [--no-systemd] [--yes]
#
# 环境变量: GV6_RELEASE_REPO (默认 greenpng/gv6-releases), GV6_RAW_BASE
#           (默认 raw.githubusercontent.com/greenpng/install/main), SUDO_PASS (免交互 sudo)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_REPO="${GV6_RELEASE_REPO:-greenpng/green-v7}"
LEGACY_REPO="${GV6_LEGACY_RELEASE_REPO:-greenpng/gv6-releases}"
RAW_BASE="${GV6_RAW_BASE:-https://raw.githubusercontent.com/greenpng/install/main}"
PREFIX="${GV6_PREFIX:-/opt/green-v6}"
VERSION=""
ARCH="auto"
ENV_FILE=""
WITH_DOCKER=0
NO_SYSTEMD=0
YES=0

# ---------- 参数 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --arch) ARCH="${2:-auto}"; shift 2 ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --env-file) ENV_FILE="${2:-}"; shift 2 ;;
    --with-docker) WITH_DOCKER=1; shift ;;
    --no-systemd) NO_SYSTEMD=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '1,20p' "$0"; exit 0 ;;
    *) echo "[install] unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ---------- 环境探测 ----------
host_arch="$(uname -m)"
case "$host_arch" in
  x86_64|amd64) host_arch=x86_64 ;;
  aarch64|arm64) host_arch=aarch64 ;;
esac
[[ "$ARCH" == "auto" ]] && ARCH="$host_arch"
TRIPLE="${ARCH}-linux-gnu"

for c in curl openssl tar; do
  command -v "$c" >/dev/null 2>&1 || { echo "[install] missing required: $c" >&2; exit 1; }
done
PY3=0; command -v python3 >/dev/null 2>&1 && PY3=1

say() { printf '[install] %s\n' "$*"; }
die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }
have_sudo() { id -u 2>/dev/null | grep -q '^0$' || sudo -n true 2>/dev/null; }

ask() { # ask <var> <prompt> <default> <secret=0|1>
  local var="$1" prompt="$2" dflt="${3:-}" secret="${4:-0}" ans
  if [[ "$YES" == "1" || -n "$ENV_FILE" ]]; then
    if [[ -z "${!var:-}" ]]; then printf '%s' "$dflt" > /dev/null; fi
    eval "$var=\"${!var:-$dflt}\""
    return 0
  fi
  while :; do
    if [[ "$secret" == "1" ]]; then
      read -r -p "? $prompt ${dflt:+[默认保密]} : " -s ans; echo
    else
      read -r -p "? $prompt ${dflt:+[$dflt]} : " ans
    fi
    ans="${ans:-$dflt}"
    [[ -n "$ans" ]] && break
  done
  eval "$var=\"$ans\""
}

# ---------- 版本解析 ----------
if [[ -z "$VERSION" ]]; then
  if [[ "$PY3" == "1" ]]; then
    VERSION="$(curl -fsSL "https://api.github.com/repos/${RELEASE_REPO}/releases/latest" 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("tag_name","").lstrip("v"))' 2>/dev/null || true)"
    if [[ -z "$VERSION" && "$LEGACY_REPO" != "$RELEASE_REPO" ]]; then
      VERSION="$(curl -fsSL "https://api.github.com/repos/${LEGACY_REPO}/releases/latest" 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin).get("tag_name","").lstrip("v"))' 2>/dev/null || true)"
    fi
  fi
  [[ -z "$VERSION" ]] && die "cannot resolve latest version; pass --version"
fi
say "version=$VERSION arch=$ARCH triple=$TRIPLE prefix=$PREFIX"
BASE="https://github.com/${RELEASE_REPO}/releases/download/v${VERSION}"
LEGACY_BASE="https://github.com/${LEGACY_REPO}/releases/download/v${VERSION}"

# ---------- (可选) Docker 数据服务: PG(4 库) + Redis ----------
POSTGRES_PASSWORD=""; REDIS_PASSWORD=""
pg_dsn() { echo "postgres://gv6:${POSTGRES_PASSWORD}@127.0.0.1:5432/$1"; }
if [[ "$WITH_DOCKER" == "1" ]]; then
  command -v docker >/dev/null 2>&1 || die "--with-docker requires docker"
  DDIR="$SCRIPT_DIR/docker"
  D_ENV="$DDIR/.env"
  if [[ -f "$D_ENV" ]]; then
    set -a; # shellcheck disable=SC1091
    source "$D_ENV"; set +a
  else
    POSTGRES_PASSWORD="$(openssl rand -hex 16)"
    REDIS_PASSWORD="$(openssl rand -hex 16)"
    cat >"$D_ENV" <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
EOF
    chmod 600 "$D_ENV"
  fi
  say "docker: starting postgres(4 db)+redis on 127.0.0.1"
  (cd "$DDIR" && docker compose up -d --wait 2>/dev/null || docker compose up -d)
  for i in $(seq 1 30); do
    if docker compose -f "$DDIR/docker-compose.yml" exec -T postgres pg_isready -U gv6 >/dev/null 2>&1; then break; fi
    sleep 1
  done
  docker compose -f "$DDIR/docker-compose.yml" exec -T postgres pg_isready -U gv6 >/dev/null 2>&1 \
    || die "postgres not ready"
  say "docker: data services ready (dsn prefix postgres://gv6:****@127.0.0.1:5432)"
fi

# ---------- 连接信息(分组向导 / ENV_FILE) ----------
if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || die "--env-file not found: $ENV_FILE"
  set -a; # shellcheck disable=SC1091
  source "$ENV_FILE"; set +a
fi

echo; echo "=============================================="
echo " green-v6 连接信息配置 (管理面 / 业务面 / 缓存)"
echo "=============================================="
[[ "$WITH_DOCKER" == "1" ]] || echo " (可用 --with-docker 自动在本机起 PG+Redis 数据服务)"
echo; echo "--- [A] 业务面 PostgreSQL (会话/探针冷存储/分析队列) ---"
ask GV6_DATABASE_URL "GV6_DATABASE_URL" "$(pg_dsn greenv6 2>/dev/null || true)"
ask GV6_BIZ_DATABASE_URL "GV6_BIZ_DATABASE_URL" "$(pg_dsn gv6_biz 2>/dev/null || true)"
ask GV6_ASSOCIATION_DATABASE_URL "GV6_ASSOCIATION_DATABASE_URL" "$(pg_dsn gv6_assoc 2>/dev/null || true)"
echo; echo "--- [B] 管理面 PostgreSQL (面板/审计/集群 OTA) ---"
ask GV6_ADMIN_DATABASE_URL "GV6_ADMIN_DATABASE_URL" "$(pg_dsn gv6_admin 2>/dev/null || true)"
echo; echo "--- [C] 缓存 Redis (可选; 留空 = 本地文件) ---"
ask GV5_REDIS_URL "GV5_REDIS_URL" "${REDIS_PASSWORD:+redis://:${REDIS_PASSWORD}@127.0.0.1:6379/0}"
echo; echo "--- [D] 管理面板登录 (官网 OAuth) ---"
ask GV6_OFFICIAL_URL "官网域名 GV6_OFFICIAL_URL (如 https://www.example.com)" "https://example.com"
ask GV6_OAUTH_ADMIN_EMAILS "管理员邮箱 GV6_OAUTH_ADMIN_EMAILS (逗号分隔)" "admin@example.com"
ask GV6_OAUTH_LOCAL_USER "本地管理员账号 GV6_OAUTH_LOCAL_USER" "admin"
ask GV6_OAUTH_REDIRECT_URI "回调 GV6_OAUTH_REDIRECT_URI" "http://127.0.0.1:28680/oauth/callback"
echo; echo "--- [E] 运行参数 (回车默认) ---"
ask GV6_ANALYZE_WORKERS "分析 worker 数 GV6_ANALYZE_WORKERS" "2"

GV6_CLUSTER_KEY="${GV6_CLUSTER_KEY:-$(openssl rand -hex 32)}"
GV6_RESULT_TOKEN="${GV6_RESULT_TOKEN:-$(openssl rand -hex 16)}"
GV6_OPS_TOKEN="${GV6_OPS_TOKEN:-$(openssl rand -hex 16)}"

if [[ "$YES" != "1" ]]; then
  echo; echo "---- 配置汇总 ----"
  for v in GV6_DATABASE_URL GV6_BIZ_DATABASE_URL GV6_ASSOCIATION_DATABASE_URL GV6_ADMIN_DATABASE_URL GV5_REDIS_URL GV6_OFFICIAL_URL GV6_OAUTH_ADMIN_EMAILS; do
    echo "  $v=${!v}"
  done
  printf '继续安装? [y/N] '; read -r ok; [[ "$ok" == "y" || "$ok" == "Y" ]] || exit 0
fi

# ---------- 下载 + 校验 (参考 update_runtime_from_github.sh) ----------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$PREFIX/bin" "$PREFIX/modules" "$PREFIX/data" "$PREFIX/dist/release-$VERSION"

resolve_manifest() {
  # 先在当前 base 解析; 失败且还有 legacy 仓库时翻转 BASE 重试 (旧版本兜底)
  local base="$BASE" ok=0
  if curl -fsSL -o "$TMP/manifest-index.json" "$base/manifest-index.json" 2>/dev/null; then
    if [[ "$PY3" == "1" ]]; then
      man_name=$(python3 - <<PY
import json
idx=json.load(open("$TMP/manifest-index.json"))
e=(idx.get("architectures") or {}).get("$ARCH") or {}
print(e.get("manifest") or "")
PY
)
      if [[ -n "$man_name" && "$man_name" != *"/"* && "$man_name" != *".."* ]] \
        && curl -fsSL -o "$TMP/manifest.json" "$base/$man_name"; then
        say "manifest from index: $man_name"
        ok=1
      fi
    fi
  fi
  if [[ "$ok" != "1" ]]; then
    for m in "manifest-${TRIPLE}.json" "manifest.json"; do
      if curl -fsSL -o "$TMP/manifest.json" "$base/$m" 2>/dev/null; then
        say "manifest: $m"; ok=1; break
      fi
    done
  fi
  if [[ "$ok" == "1" ]]; then
    BASE="$base"   # 钉住已解析源, 后续资产下载与 manifest 同源
    return 0
  fi
  if [[ "$base" != "$LEGACY_BASE" && -n "$LEGACY_BASE" ]]; then
    say "release not found on $base — retrying legacy $LEGACY_BASE"
    BASE="$LEGACY_BASE"
    resolve_manifest
    return $?
  fi
  return 1
}
resolve_manifest || die "cannot resolve manifest for $VERSION/$TRIPLE"

manifest_val() { # manifest_val <json-path>
  [[ "$PY3" == "1" ]] && python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print(m$1 or '')" "$TMP/manifest.json" 2>/dev/null || true
}

SVC_ASSET="$(manifest_val '["runtime"]["asset"]')"
[[ -n "$SVC_ASSET" ]] || die "manifest runtime.asset missing"
say "fetching $SVC_ASSET"
curl -fsSL -o "$TMP/gv6-service" "$BASE/$SVC_ASSET"
curl -fsSL -o "$TMP/gv6" "$BASE/gv6-${VERSION}-${TRIPLE}" 2>/dev/null || true
chmod +x "$TMP/gv6-service" "$TMP/gv6" 2>/dev/null || true

# sha256 校验 (R-01)
EXPECT_SHA="$(manifest_val '["runtime"]["sha256"]')"
[[ -n "$EXPECT_SHA" ]] || die "runtime sha256 missing from manifest"
GOT_SHA="$(sha256sum "$TMP/gv6-service" | awk '{print $1}')"
[[ "$GOT_SHA" == "$EXPECT_SHA" ]] || die "runtime sha256 mismatch: got $GOT_SHA expect $EXPECT_SHA"
say "runtime sha256 verified"

# ELF 检查
file "$TMP/gv6-service" 2>/dev/null | grep -qi ELF || die "downloaded asset is not an ELF binary"

# FE / admin-spa / 公钥
( curl -fsSL -o "$TMP/fe.tgz" "$BASE/fe-${VERSION}.tgz" 2>/dev/null \
  && curl -fsSL -o "$TMP/admin-spa.tgz" "$BASE/admin-spa.tgz" 2>/dev/null ) || true
curl -fsSL -o "$TMP/ota_ed25519.pk" "$RAW_BASE/ota_ed25519.pk" 2>/dev/null \
  || curl -fsSL -o "$TMP/ota_ed25519.pk" "$BASE/ota_ed25519.pk" 2>/dev/null \
  || die "cannot fetch ota_ed25519.pk"

# ---------- 安装 ----------
install -m 0755 "$TMP/gv6-service" "$PREFIX/bin/gv6-service"
[[ -f "$TMP/gv6" ]] && install -m 0755 "$TMP/gv6" "$PREFIX/bin/gv6" 2>/dev/null || true
install -m 0644 "$TMP/ota_ed25519.pk" "$PREFIX/ota_ed25519.pk"
echo "$VERSION" > "$PREFIX/VERSION"
cp -f "$TMP/manifest.json" "$PREFIX/dist/release-$VERSION/manifest.json"

# FE + admin-spa 安全解包 (R-05: 拒路径逃逸/符号链接)
safe_extract_tar_gz() {
  local tgz="$1" dest="$2"
  local listing vlist
  listing="$(tar -tzf "$tgz")"
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    # 仅拒绝真正的路径逃逸: 绝对路径 / ../ 目录段 (注意 fe 包含 [[...path]] 模板名, 不能误伤)
    if [[ "$path" == /* ]] || [[ "$path" == ../* ]] || [[ "$path" == *"/../"* ]] || [[ "$path" == *"/.." ]]; then
      die "tar entry rejected (path escape): $path"
    fi
  done <<<"$listing"
  if vlist="$(tar -tvzf "$tgz" 2>/dev/null)"; then
    while IFS= read -r line; do
      local t="${line#"${line%%[![:space:]]*}"}"
      if [[ "$t" == l* ]] || [[ "$line" == *" -> "* ]]; then
        die "tar entry rejected (symlink): $line"
      fi
    done <<<"$vlist"
  fi
  mkdir -p "$dest"
  tar -xzf "$tgz" -C "$dest"
}
if [[ -f "$TMP/fe.tgz" ]]; then
  FE_SHA="$(manifest_val '["fe"]["sha256"]')"
  if [[ -n "$FE_SHA" ]]; then
    [[ "$(sha256sum "$TMP/fe.tgz" | awk '{print $1}')" == "$FE_SHA" ]] || die "FE sha256 mismatch"
  fi
  safe_extract_tar_gz "$TMP/fe.tgz" "$TMP"
  [[ -d "$TMP/fe" ]] && mv -f "$TMP/fe" "$PREFIX/fe"
fi
if [[ -f "$TMP/admin-spa.tgz" ]]; then
  safe_extract_tar_gz "$TMP/admin-spa.tgz" "$TMP"
  [[ -d "$TMP/admin-spa" ]] && mv -f "$TMP/admin-spa" "$PREFIX/admin-spa"
fi

# .env (chmod 600)
cat > "$PREFIX/.env" <<EOF
# green-v6 v${VERSION}  — 管理面/业务面/缓存 连接配置
# 业务面 (探测/分析)
GV6_DATABASE_URL=${GV6_DATABASE_URL}
GV6_BIZ_DATABASE_URL=${GV6_BIZ_DATABASE_URL}
GV6_ASSOCIATION_DATABASE_URL=${GV6_ASSOCIATION_DATABASE_URL}
# 管理面 (面板/审计/集群 OTA)
GV6_ADMIN_DATABASE_URL=${GV6_ADMIN_DATABASE_URL}
# 缓存 (可选)
GV5_REDIS_URL=${GV5_REDIS_URL}
# 面板登录 (官网 OAuth)
GV6_OFFICIAL_URL=${GV6_OFFICIAL_URL}
GV6_OAUTH_ADMIN_EMAILS=${GV6_OAUTH_ADMIN_EMAILS}
GV6_OAUTH_LOCAL_USER=${GV6_OAUTH_LOCAL_USER}
GV6_OAUTH_REDIRECT_URI=${GV6_OAUTH_REDIRECT_URI}
# 运行参数 (默认仅本机回环监听)
GV6_BIND=127.0.0.1:28680
GV6_PROBE_BIND=127.0.0.1:28765
GV6_GATEWAY_BIND=127.0.0.1:28766
GV6_ANALYZE_WORKERS=${GV6_ANALYZE_WORKERS}
GV6_CLUSTER_KEY=${GV6_CLUSTER_KEY}
GV6_RESULT_TOKEN=${GV6_RESULT_TOKEN}
GV6_OPS_TOKEN=${GV6_OPS_TOKEN}
GV6_PUBKEY_PATH=${PREFIX}/ota_ed25519.pk
GV6_DATA_DIR=${PREFIX}/data
GV6_MODULES_DIR=${PREFIX}/modules
GV6_ADMIN_SPA=${PREFIX}/admin-spa
GV6_STATIC_DIR=${PREFIX}/fe
EOF
chmod 600 "$PREFIX/.env"

# ---------- gv6 install: data dir + console 引导 (需先载入 .env 的 DSN) ----------
say "initializing data dir..."
( set -a; # shellcheck disable=SC1091
  source "$PREFIX/.env"; set +a
  "$PREFIX/bin/gv6" install --data-dir "$PREFIX/data" ) | tee "$TMP/gv6-install.out"
CONSOLE="$(grep -oE 'console_path=/?[A-Za-z0-9_/-]+' "$TMP/gv6-install.out" | head -1 | cut -d= -f2-)"
[[ -n "$CONSOLE" ]] || CONSOLE="<console from gv6 install output>"

# ---------- 模块 stage(验签) + activate ----------
if [[ -x "$PREFIX/bin/gv6" ]]; then
  for name in identity brain analyze ingest edge probe_assets; do
    mkdir -p "$PREFIX/dist/release-$VERSION"
    ASSET="${name}.artifact.json"
    curl -fsSL -o "$PREFIX/dist/release-$VERSION/$ASSET" "$BASE/$ASSET" 2>/dev/null || true
    # artifact json 内 asset 字段 = 实际 so 文件名
    SO_NAME=""
    if [[ -f "$PREFIX/dist/release-$VERSION/$ASSET" && "$PY3" == "1" ]]; then
      SO_NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("asset",""))' "$PREFIX/dist/release-$VERSION/$ASSET" 2>/dev/null || true)"
    fi
    if [[ -z "$SO_NAME" ]]; then
      SO_NAME="libgv6_${name}-${VERSION}-${TRIPLE}.so"
    fi
    curl -fsSL -o "$PREFIX/dist/release-$VERSION/$SO_NAME" "$BASE/$SO_NAME" 2>/dev/null || true
    if [[ -f "$PREFIX/dist/release-$VERSION/$SO_NAME" && -f "$PREFIX/dist/release-$VERSION/$ASSET" ]]; then
      say "staging module $name (signature verify)..."
      "$PREFIX/bin/gv6" stage --modules-dir "$PREFIX/modules" \
        --pubkey "$PREFIX/ota_ed25519.pk" \
        --artifact-json "$PREFIX/dist/release-$VERSION/$ASSET" \
        --so "$PREFIX/dist/release-$VERSION/$SO_NAME" \
        --runtime-version "$VERSION" \
        && "$PREFIX/bin/gv6" activate --modules-dir "$PREFIX/modules" --name "$name" --version "$VERSION" \
        || say "WARN: module $name stage/activate failed (installed runtime only)"
    else
      say "WARN: module $name artifact missing on release — skip"
    fi
  done
fi

# 必填连接校验 (业务面/管理面至少主库齐备, 否则启动必失败)
for v in GV6_DATABASE_URL GV6_BIZ_DATABASE_URL GV6_ASSOCIATION_DATABASE_URL GV6_ADMIN_DATABASE_URL; do
  [[ -n "${!v:-}" ]] || die "$v 未填写 — 数据库连接信息必填 (业务面: GV6_DATABASE_URL/GV6_BIZ_DATABASE_URL/GV6_ASSOCIATION_DATABASE_URL, 管理面: GV6_ADMIN_DATABASE_URL)"
done

# ---------- systemd (配置全部走 $PREFIX/.env, 见 EnvironmentFile) ----------
if [[ "$NO_SYSTEMD" != "1" ]] && have_sudo; then
  sed "s|{PREFIX}|$PREFIX|g" "$SCRIPT_DIR/systemd/green-v6.service" > "$TMP/green-v6.service"
  if [[ -n "${SUDO_PASS:-}" ]]; then
    printf '%s\n' "$SUDO_PASS" | sudo -S sh -c "install -m 0644 \"$TMP/green-v6.service\" /etc/systemd/system/green-v6.service && systemctl daemon-reload && systemctl enable green-v6 && systemctl restart green-v6" >/dev/null
  else
    sudo sh -c "install -m 0644 \"$TMP/green-v6.service\" /etc/systemd/system/green-v6.service && systemctl daemon-reload && systemctl enable green-v6 && systemctl restart green-v6"
  fi
  say "systemd service green-v6 enabled"
else
  # 无 systemd (runner / 容器 / 无 sudo): 后台拉起并记录 PID/日志
  say "no systemd — starting gv6-service in background (pid + log under $PREFIX/log)"
  mkdir -p "$PREFIX/log"
  ( set -a; # shellcheck disable=SC1091
    source "$PREFIX/.env"; set +a
    nohup "$PREFIX/bin/gv6-service" >"$PREFIX/log/gv6-service.log" 2>&1 &
    echo $! > "$PREFIX/log/gv6-service.pid" )
fi

# ---------- 健康门 (端口取 .env GV6_BIND, 默认 127.0.0.1:28680) ----------
ENV_BIND="$(grep -E '^GV6_BIND=' "$PREFIX/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)"
HEALTH="http://${ENV_BIND:-127.0.0.1:28680}/v1/health"
ok=0
for i in $(seq 1 30); do
  if curl -fsS --max-time 3 "$HEALTH" >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
[[ "$ok" == "1" ]] || die "health check failed on $HEALTH — check $PREFIX/.env DSNs and service log"

cat > "$PREFIX/install-state.env" <<EOF
VERSION=${VERSION}
ARCH=${ARCH}
TRIPLE=${TRIPLE}
CONSOLE=${CONSOLE}
HEALTH=${HEALTH}
PREFIX=${PREFIX}
EOF

echo
echo "=============================================="
echo " green-v6 v${VERSION} 安装完成"
echo "  安装目录 : $PREFIX"
echo "  console  : http://127.0.0.1:28680${CONSOLE}"
echo "  管理面登录: 浏览器打开上述地址 → 跳转官网 OAuth (${GV6_OFFICIAL_URL})"
echo "  探针引导凭据: cat $PREFIX/data/admin/admin_bootstrap_once.txt"
echo "  连接信息 : $PREFIX/.env (管理面: GV6_ADMIN_DATABASE_URL / 业务面: GV6_DATABASE_URL, GV6_BIZ_DATABASE_URL, GV6_ASSOCIATION_DATABASE_URL / 缓存: GV5_REDIS_URL)"
echo "  升级     : VERSION=x.y.z bash ${SCRIPT_DIR}/release/update_runtime_from_github.sh"
echo "=============================================="
