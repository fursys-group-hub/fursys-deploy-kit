#!/usr/bin/env bash
# 공통 헬퍼 — 전송 대상 URL 가드 (deploy-check 스킬용).
# verdict-upload.sh 가 `source` 한다. 무인증(배포 키 제거) — 더 이상 키를 읽지 않는다.
set -euo pipefail

# 스크립트 자기 위치 기준 절대경로(T4 폴백의 단일 출처).
# $CLAUDE_PLUGIN_ROOT 가 안 잡혀도 같은 스킬의 다른 스크립트(verdict-upload 등) 경로를 이 기준으로 산출한다.
FDH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  FDH_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
  # scripts/ → deploy-check/ → skills/ → <plugin-root> (3단계 상위)
  FDH_PLUGIN_ROOT="$(cd "$FDH_SCRIPT_DIR/../../.." && pwd)"
fi
export FDH_SCRIPT_DIR FDH_PLUGIN_ROOT

# 같은 deploy-check scripts/ 폴더의 다른 스크립트 절대경로를 돌려준다.
fdh_script() { printf '%s/%s' "$FDH_SCRIPT_DIR" "$1"; }

# 전송 대상 URL → 전역 PROXY_URL. *.hub.fursys.com 외 override 는 무시(EXTERNAL_BLOCKED).
fdh_resolve_url() {
  local default="https://deploy-proxy.hub.fursys.com"
  PROXY_URL="$default"
  local override="${FURSYS_PROXY_URL:-}"
  if [ -n "$override" ]; then
    local host="${override#*://}"
    host="${host%%/*}"
    host="${host%%:*}"
    case "$host" in
      *.hub.fursys.com) PROXY_URL="$override" ;;
      *) echo EXTERNAL_BLOCKED ;;
    esac
  fi
  return 0
}
