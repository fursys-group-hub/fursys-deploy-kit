#!/usr/bin/env bash
# 공통 헬퍼 — 개인 배포 키 읽기 + 전송 대상 URL 가드 (security-review 스킬용).
# verdict-upload.sh 가 `source` 한다. 비밀값(키)은 절대 echo 하지 않는다.
set -euo pipefail

# 개인 배포 키 → 전역 KEY. (출력 금지) 없으면 KEY="" + stdout 에 NO_KEY.
fdh_load_key() {
  KEY="${FURSYS_PROXY_KEY:-}"
  if [ -z "$KEY" ] && [ -f "$HOME/.fursys/proxy-key" ]; then
    KEY="$(cat "$HOME/.fursys/proxy-key" 2>/dev/null || true)"
  fi
  if [ -z "$KEY" ]; then
    echo NO_KEY
    return 1
  fi
  return 0
}

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
