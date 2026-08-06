#!/usr/bin/env bash
# (pgpublish) 배포가 **정상 기동한 뒤** Playground 반영: POST /apps/<app_id>/publish.
#
# 왜 기동 뒤인가: 예전엔 POST /apps 응답에서 바로 승인했는데, 그때는 빌드가 시작도 안 한
# 시점이라 **첫 빌드가 실패한 앱까지 "승인·보안 검토 통과" 로 카탈로그에 올라갔다.**
# 그래서 ⑦-1 종결 폴링에서 RUNNING 을 확인한 뒤 이 스크립트를 부른다.
# **서버가 스스로 다시 확인한다** — 이 스크립트가 "떴어요" 라고 말해서 승인되는 게 아니라,
# proxy 가 Coolify status 를 직접 보고 running 이 아니면 거부한다(NOT_RUNNING).
#
# 사용: publish.sh <app_id> <repo>
#   <app_id>: CREATED/REDEPLOYED 에서 받은 app_id
#   <repo>  : org/repo 또는 repo 이름 (Playground 신청은 repo 로 매칭된다)
#
# 출력(stdout): 첫 줄 결과 코드, 이후 줄에 응답 본문(JSON).
#   PUBLISHED approved <url>      승인+주소+배지 완료(최초). url 은 있을 때만.
#   PUBLISHED url_updated <url>   이미 승인된 앱의 주소·배지 갱신.
#   PUBLISHED skipped             관리자가 반려·차단해 둔 앱이거나 Playground 신청 없음 — 미변경.
#   NOT_RUNNING                   아직 기동 전 — 배포는 성공했을 수 있다. **막지 말 것.**
#   PUBLISH_UNAVAILABLE <code>    404/502/네트워크 등. **배포 성패와 무관 — 막지 말 것.**
#   ※ exit code 는 항상 0. 판정은 첫 줄로만 한다.
#
# **fail-open(중요):** 이 단계는 배포가 이미 끝난 뒤의 부가 작업이다. 실패해도 배포는 성공이며
# 관리자가 화면에서 손으로 승인하는 기존 절차가 그대로 폴백이다. 호출측은 실패를 사용자에게
# "문제"로 알리지 않는다.
# 무인증(배포 키 제거) — 인증 헤더 없이 호출한다.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"
# common.sh 가 errexit 를 켜므로 이 스크립트의 선언 모드로 되돌린다(registration.sh 와 동일).
# 실패를 허용하는 줄(curl·grep 의 '|| true')이 파이프 중간 실패로 조기 종료되지 않게 한다.
set +e

APP_ID="${1:-}"
REPO="${2:-}"
if [ -z "$APP_ID" ] || [ -z "$REPO" ]; then
  echo "USAGE publish.sh <app_id> <repo>" >&2
  exit 2
fi

fdh_resolve_url || true

BODY="$(printf '{"repo":"%s"}' "$REPO")"
RESP="$(curl -sS -w $'\n%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  --data-binary "$BODY" \
  "$PROXY_URL/apps/$APP_ID/publish" 2>/dev/null || true)"
HTTP="$(printf '%s' "$RESP" | tail -n1)"
JSON="$(printf '%s' "$RESP" | sed '$d')"

extract() { printf '%s' "$JSON" | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/"; }

case "$HTTP" in
  200)
    ACTION="$(extract playground)"
    URL="$(extract playground_url)"
    [ -z "$ACTION" ] && ACTION="skipped"
    if [ -n "$URL" ]; then printf 'PUBLISHED %s %s\n' "$ACTION" "$URL"
    else printf 'PUBLISHED %s\n' "$ACTION"; fi
    ;;
  409)
    # not_running(아직 기동 전) / no_domain — 어느 쪽이든 배포를 막지 않는다.
    ERR="$(extract error)"
    if [ "$ERR" = "not_running" ]; then echo "NOT_RUNNING"; else echo "PUBLISH_UNAVAILABLE 409"; fi
    ;;
  *) echo "PUBLISH_UNAVAILABLE ${HTTP:-000}" ;;
esac
printf '%s\n' "$JSON"
exit 0
