#!/usr/bin/env bash
# 공통 헬퍼 — 개인 배포 키 읽기 + 전송 대상 URL 가드.
# deploy.sh / logs.sh / my-apps.sh 가 `source` 한다.
# 비밀값(키)은 절대 echo/print 하지 않는다. 함수는 변수에만 담는다.
set -euo pipefail

# Windows(git-bash/MSYS2) 경로 자동변환 끄기.
# MSYS 는 '/' 로 시작하는 인자(예: URL 경로 '/me', '/apps/...')를 Windows 경로
# (예: 'C:/Program Files/Git/me')로 자동 변환해 curl.exe 요청을 깨뜨릴 수 있다.
# 이 스크립트군은 사내 URL/경로만 다루므로 변환을 전면 비활성화한다(비Windows 에선 무해).
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# 개인 배포 키를 읽어 전역 KEY 에 담는다(화면 출력 금지).
#   1) 환경변수 FURSYS_PROXY_KEY  2) ~/.fursys/proxy-key
# 둘 다 없으면 KEY="" 로 두고 NO_KEY 를 stdout 에 찍는다(키 값 자체는 절대 안 찍음).
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
