#!/usr/bin/env bash
# 개인 배포 키 "상태" 확인: 출처 + 형식 + 앞 12자 프리뷰만 출력. 키 전체 값은 절대 출력 금지.
#
# 사용: key-status.sh
# 출력(stdout): 한 줄. 첫 토큰이 결과 코드.
#   NO_KEY                          아직 키 없음(파일·환경변수 둘 다 없음)
#   KEY_FILE  <앞12자> <YES|NO>      ~/.fursys/proxy-key 파일에 있음
#   KEY_ENV   <앞12자> <YES|NO>      환경변수 FURSYS_PROXY_KEY 에 있음
#   KEY_BOTH  <앞12자> <YES|NO>      둘 다 있음(환경변수가 우선 적용됨)
# (프리뷰는 board 의 key_prefix = 평문[:12] 규약과 동일 — 표시/식별용으로 안전)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

ENV_KEY="${FURSYS_PROXY_KEY:-}"
FILE_KEY=""
if [ -f "$HOME/.fursys/proxy-key" ]; then
  FILE_KEY="$(cat "$HOME/.fursys/proxy-key" 2>/dev/null || true)"
fi

# 실제 적용되는 키: 환경변수 우선(fdh_load_key 의 우선순위와 동일)
EFFECTIVE="$ENV_KEY"
[ -z "$EFFECTIVE" ] && EFFECTIVE="$FILE_KEY"

if [ -z "$EFFECTIVE" ]; then
  echo NO_KEY
  exit 0
fi

# 형식 검사: fdh_live_ + base62 40자 = 총 49자
VALID=NO
if printf '%s' "$EFFECTIVE" | grep -Eq '^fdh_live_[A-Za-z0-9]{40}$'; then
  VALID=YES
fi
PREVIEW="$(printf '%s' "$EFFECTIVE" | cut -c1-12)"

if [ -n "$ENV_KEY" ] && [ -n "$FILE_KEY" ]; then
  CODE=KEY_BOTH
elif [ -n "$ENV_KEY" ]; then
  CODE=KEY_ENV
else
  CODE=KEY_FILE
fi

printf '%s %s %s\n' "$CODE" "$PREVIEW" "$VALID"
