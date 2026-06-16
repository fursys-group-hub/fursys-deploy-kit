#!/usr/bin/env bash
# 개인 배포 키 저장(등록/교체): 인자로 받은 키를 형식 검증 후 ~/.fursys/proxy-key 에 0600 으로 저장.
# 키 값은 절대 출력하지 않는다(저장 후에도 앞 12자 프리뷰만).
#
# 사용: key-set.sh "<new-key>"
# 출력(stdout): 한 줄. 첫 토큰이 결과 코드.
#   SAVED        <앞12자>   저장 완료
#   ENV_OVERRIDE <앞12자>   저장은 했으나 환경변수 FURSYS_PROXY_KEY 가 설정돼 있어 그게 우선됨(주의)
#   BAD_FORMAT              형식이 fdh_live_ + 40자(총 49자) 규약과 다름 — 저장 안 함
#   NO_INPUT               키 인자가 비어 있음
set -uo pipefail

NEW="${1:-}"
if [ -z "$NEW" ]; then
  echo NO_INPUT
  exit 0
fi

# 형식 검사: fdh_live_ + base62 40자 = 총 49자
if ! printf '%s' "$NEW" | grep -Eq '^fdh_live_[A-Za-z0-9]{40}$'; then
  echo BAD_FORMAT
  exit 0
fi

mkdir -p "$HOME/.fursys"
# 소유자만 읽기(0600). 서브셸로 umask 를 격리해 호출 환경에 영향 주지 않는다.
( umask 177; printf '%s' "$NEW" > "$HOME/.fursys/proxy-key" )

PREVIEW="$(printf '%s' "$NEW" | cut -c1-12)"
if [ -n "${FURSYS_PROXY_KEY:-}" ]; then
  printf 'ENV_OVERRIDE %s\n' "$PREVIEW"
else
  printf 'SAVED %s\n' "$PREVIEW"
fi
