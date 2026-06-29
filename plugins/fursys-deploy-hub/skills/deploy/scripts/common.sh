#!/usr/bin/env bash
# 공통 헬퍼 — 전송 대상 URL 가드.
# deploy.sh / status.sh / logs.sh 가 `source` 한다.
# 무인증(배포 키 제거) — 더 이상 개인 키를 읽지 않는다.
set -euo pipefail

# 스크립트 자기 위치 기준 절대경로(T4 폴백의 단일 출처).
# $CLAUDE_PLUGIN_ROOT 가 안 잡혀도 다른 스크립트(verdict-upload 등) 경로를 이 기준으로 산출한다.
#   FDH_SCRIPT_DIR : 이 common.sh(= scripts/) 가 있는 절대경로
#   FDH_PLUGIN_ROOT: 플러그인 루트. $CLAUDE_PLUGIN_ROOT 우선, 없으면 scripts/ 에서 2단계 상위로 폴백.
FDH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  FDH_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
  # scripts/ → skills/deploy/ → skills/ → <plugin-root> (3단계 상위)
  FDH_PLUGIN_ROOT="$(cd "$FDH_SCRIPT_DIR/../../.." && pwd)"
fi
export FDH_SCRIPT_DIR FDH_PLUGIN_ROOT

# 같은 deploy 스크립트군(deploy.sh/status.sh/logs.sh/gen-secret.sh)의 절대경로를 돌려준다.
# 호출부가 $CLAUDE_PLUGIN_ROOT 유무와 무관하게 동작하도록 표준화한 헬퍼.
fdh_script() { printf '%s/%s' "$FDH_SCRIPT_DIR" "$1"; }

# Windows(git-bash/MSYS2) 경로 자동변환 끄기.
# MSYS 는 '/' 로 시작하는 인자(예: URL 경로 '/me', '/apps/...')를 Windows 경로
# (예: 'C:/Program Files/Git/me')로 자동 변환해 curl.exe 요청을 깨뜨릴 수 있다.
# 이 스크립트군은 사내 URL/경로만 다루므로 변환을 전면 비활성화한다(비Windows 에선 무해).
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# 전송 대상 URL 을 정해 전역 PROXY_URL 에 담는다(보안 핵심).
#   기본값: https://deploy-proxy.hub.fursys.com
#   FURSYS_PROXY_URL 로 덮어쓸 수 있으나, 호스트가 *.hub.fursys.com 일 때만 허용.
#   그 외 주소면 무시하고 기본값을 쓰며 EXTERNAL_BLOCKED 를 stdout 에 찍는다.
fdh_resolve_url() {
  local default="https://deploy-proxy.hub.fursys.com"
  PROXY_URL="$default"
  local override="${FURSYS_PROXY_URL:-}"
  if [ -n "$override" ]; then
    # 호스트 추출: scheme 제거 → 첫 '/' 앞까지
    local host="${override#*://}"
    host="${host%%/*}"
    host="${host%%:*}"
    case "$host" in
      *.hub.fursys.com)
        PROXY_URL="$override"
        ;;
      *)
        echo EXTERNAL_BLOCKED
        ;;
    esac
  fi
  return 0
}
