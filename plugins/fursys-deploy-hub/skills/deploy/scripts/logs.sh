#!/usr/bin/env bash
# 배포 실패 진단용 빌드 로그 조회: GET /apps/{app_id}/logs.
# proxy 가 1차로 스크럽한 로그를 받아 그대로 반환한다(LLM 이 읽고 원인 해설).
#
# 사용: logs.sh <app_id>
# 출력(stdout): 첫 줄 결과 코드, 이후 줄에 응답 본문(JSON: status/deployment_uuid/logs).
#   결과 코드:
#     LOGS_OK            200 (본문 JSON 이어서 출력 — logs 가 비었거나 deployment_uuid=null 이면
#                        "기록 없음"으로 안내)
#     UNAUTHORIZED       401
#     NOT_FOUND          404
#     PROXY_ERROR <code> 502 등
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

APP_ID="${1:-}"
if [ -z "$APP_ID" ]; then
  echo "USAGE logs.sh <app_id>" >&2
  exit 2
fi

fdh_resolve_url || true
if ! fdh_load_key; then
  echo "NO_KEY"
  exit 0
fi

RESP="$(curl -sS -w $'\n%{http_code}' "$PROXY_URL/apps/$APP_ID/logs" \
  -H "X-Proxy-Key: $KEY" 2>/dev/null || true)"
HTTP="$(printf '%s' "$RESP" | tail -n1)"
JSON="$(printf '%s' "$RESP" | sed '$d')"

case "$HTTP" in
  200) echo "LOGS_OK"; printf '%s\n' "$JSON" ;;
  401) echo "UNAUTHORIZED" ;;
  404) echo "NOT_FOUND" ;;
  502) echo "PROXY_ERROR 502" ;;
  *) echo "PROXY_ERROR $HTTP" ;;
esac
