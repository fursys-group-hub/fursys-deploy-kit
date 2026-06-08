#!/usr/bin/env bash
# 내 정보 + 생성 가능 공간 + 내가 만든 앱 조회: GET /me.
#
# 사용: my-apps.sh
# 출력(stdout): 첫 줄 결과 코드, 이후 줄에 응답 본문(JSON: user_id/name/creatable_teams/my_apps).
#   결과 코드:
#     ME_OK              200 (본문 JSON 이어서 출력)
#     NO_KEY             개인 배포 키 없음(키 등록 전)
#     UNAUTHORIZED       401
#     PROXY_ERROR <code> 기타
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

fdh_resolve_url || true
if ! fdh_load_key; then
  echo "NO_KEY"
  exit 0
fi

RESP="$(curl -sS -w $'\n%{http_code}' "$PROXY_URL/me" \
  -H "X-Proxy-Key: $KEY" 2>/dev/null || true)"
HTTP="$(printf '%s' "$RESP" | tail -n1)"
JSON="$(printf '%s' "$RESP" | sed '$d')"

case "$HTTP" in
  200) echo "ME_OK"; printf '%s\n' "$JSON" ;;
  401) echo "UNAUTHORIZED" ;;
  *) echo "PROXY_ERROR $HTTP" ;;
esac
