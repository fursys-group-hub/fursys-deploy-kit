#!/usr/bin/env bash
# 본인 소유 앱 삭제(deregister): DELETE /apps/{app_id}.
# 공유 리소스(같은 Coolify 리소스를 다른 app_id 가 가리키는 별칭/유령)면 board 기록만 삭제되고
# Coolify 리소스는 보존된다(공유 중인 실앱 보호). 단독 소유면 Coolify 리소스까지 삭제된다.
# 본인 소유 검증은 서버(board)가 한다 — 타인/미등록 앱은 거부된다.
#
# 사용: delete-app.sh <app_id>
# 출력(stdout): 첫 줄 결과 코드, 이후 응답 본문(JSON).
#   DELETED <app_id>        삭제 완료(coolify_deleted=true: Coolify 리소스까지 삭제됨)
#   DEREGISTERED <app_id>   기록만 삭제됨(shared=true 공유 리소스 보존, 또는 Coolify 삭제 부분실패)
#   NOT_FOUND               미등록이거나 본인 소유가 아님(404)
#   UNAUTHORIZED            401
#   NO_KEY                  개인 배포 키 없음
#   PROXY_ERROR <code>      기타
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

APP_ID="${1:-}"
if [ -z "$APP_ID" ]; then
  echo "USAGE delete-app.sh <app_id>" >&2
  exit 2
fi

fdh_resolve_url || true
if ! fdh_load_key; then
  echo "NO_KEY"
  exit 0
fi

RESP="$(curl -sS -w $'\n%{http_code}' -X DELETE "$PROXY_URL/apps/$APP_ID" \
  -H "X-Proxy-Key: $KEY" 2>/dev/null || true)"
HTTP="$(printf '%s' "$RESP" | tail -n1)"
JSON="$(printf '%s' "$RESP" | sed '$d')"

case "$HTTP" in
  200)
    if printf '%s' "$JSON" | grep -qE '"coolify_deleted"[[:space:]]*:[[:space:]]*true'; then
      echo "DELETED $APP_ID"
    else
      echo "DEREGISTERED $APP_ID"   # shared=true → 공유 리소스 보존, 기록만 삭제
    fi
    printf '%s\n' "$JSON"
    ;;
  401) echo "UNAUTHORIZED" ;;
  404) echo "NOT_FOUND"; printf '%s\n' "$JSON" ;;
  502)
    # board 기록은 삭제됐는데 Coolify 삭제만 실패한 부분성공일 수 있다.
    if printf '%s' "$JSON" | grep -qE '"deregistered"[[:space:]]*:[[:space:]]*true'; then
      echo "DEREGISTERED $APP_ID"
    else
      echo "PROXY_ERROR 502"
    fi
    printf '%s\n' "$JSON"
    ;;
  *) echo "PROXY_ERROR $HTTP"; printf '%s\n' "$JSON" ;;
esac
