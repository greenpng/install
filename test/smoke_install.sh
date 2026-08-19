#!/usr/bin/env bash
# green-v6 安装后冒烟测试 (sh / docker 安装共用)
#
# 断言:
#   1. 控制面健康  /v1/health                          → 200
#   2. 管理面板未认证 {console}/api/me                 → 401
#   3. 探测面健康  :probe/v1/health                    → 200
#   4. 业务面会话  POST /v1/session/open (唯一 vt)     → ok/business_state
#
# 用法: bash test/smoke_install.sh [--prefix /opt/green-v6] [--admin-port 28680] [--probe-port 28765]
set -euo pipefail
PREFIX="${1:-/opt/green-v6}"
ADMIN_PORT=28680
PROBE_PORT=28765
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --admin-port) ADMIN_PORT="${2:-}"; shift 2 ;;
    --probe-port) PROBE_PORT="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

ADMIN="http://127.0.0.1:${ADMIN_PORT}"
PROBE="http://127.0.0.1:${PROBE_PORT}"
[[ -f "$PREFIX/install-state.env" ]] && { set -a; # shellcheck disable=SC1091
  source "$PREFIX/install-state.env"; set +a; }
CONSOLE="${CONSOLE:-}"
# 规范化 console 路径: 忽略首尾斜杠, 避免 //api/me 404
CONSOLE="$(printf '%s' "$CONSOLE" | sed 's#^/*##; s#/*$##')"

pass=0; fail=0
check() { # check <name> <expected_rc/status> <actual>
  local name="$1" exp="$2" got="$3"
  if [[ "$got" == "$exp" ]]; then echo "PASS  $name"; pass=$((pass+1));
  else echo "FAIL  $name (expected $exp got $got)"; fail=$((fail+1)); fi
}

GOT=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$ADMIN/v1/health")
check "control-plane health ($ADMIN/v1/health)" "200" "$GOT"

GOT=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$PROBE/v1/health")
check "probe-plane health ($PROBE/v1/health)" "200" "$GOT"

if [[ -n "$CONSOLE" ]]; then
  GOT=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$ADMIN${CONSOLE}/api/me")
  check "admin console unauth -> 401 (console=$CONSOLE)" "401" "$GOT"
else
  echo "WARN  console path unknown (install-state.env missing CONSOLE) — skip admin auth check"
fi

VT="smoke_$(date +%s)_$$"
BODY=$(curl -s --max-time 15 -X POST "$PROBE/v1/session/open" \
  -H 'content-type: application/json' \
  -d "{\"site_id\":\"smoke\",\"visitor_terminal_id\":\"$VT\",\"meta\":{\"fe\":\"smoke\"}}")
if echo "$BODY" | grep -q 'business_state' || echo "$BODY" | grep -q '"ok":true'; then
  echo "PASS  business session open (vt=$VT)"
  pass=$((pass+1))
else
  echo "FAIL  business session open -> $BODY"; fail=$((fail+1))
fi

echo "SMOKE pass=$pass fail=$fail"
[[ "$fail" == "0" ]]
