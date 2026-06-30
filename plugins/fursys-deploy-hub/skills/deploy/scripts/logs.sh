#!/usr/bin/env bash
# 배포 실패 진단용 빌드 로그 조회: GET /apps/{app_id}/logs.
# proxy 가 1차로 스크럽한 로그를 받아 그대로 반환한다(LLM 이 읽고 원인 해설).
#
# 사용: logs.sh <app_id>
# 출력(stdout): 첫 줄 결과 코드, 이후 줄에 응답 본문(JSON: status/deployment_uuid/logs).
#   결과 코드:
#     LOGS_OK            200 (본문 JSON 이어서 출력 — logs 가 비었거나 deployment_uuid=null 이면
#                        "기록 없음"으로 안내)
#     NOT_FOUND          404 (미등록 앱)
#     PROXY_ERROR <code> 502 등
# 무인증(배포 키 제거) — 인증 헤더 없이 조회한다.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"
# common.sh 가 'set -euo pipefail' 로 errexit 를 켜므로, 이 스크립트의 선언 모드(set -uo, errexit 미사용)를
# 복원한다(deploy.sh 와 동일). 안 그러면 errexit 가 새어 들어와, 의도적으로 실패를 허용하는 줄(curl·grep·sed
# 의 '|| true' 가드)이 파이프 중간 실패로 조기 종료될 수 있다. 이 스크립트는 rc·분기로 직접 제어하므로
# errexit 를 끈다(주석상 'set -e 로 안 죽게'라 믿던 잠복 누출 차단 — 라운드3 항목18 후속).
set +e

APP_ID="${1:-}"
if [ -z "$APP_ID" ]; then
  echo "USAGE logs.sh <app_id>" >&2
  exit 2
fi

fdh_resolve_url || true

RESP="$(curl -sS -w $'\n%{http_code}' "$PROXY_URL/apps/$APP_ID/logs" \
  2>/dev/null || true)"
HTTP="$(printf '%s' "$RESP" | tail -n1)"
JSON="$(printf '%s' "$RESP" | sed '$d')"

case "$HTTP" in
  200) echo "LOGS_OK"; printf '%s\n' "$JSON" ;;
  404) echo "NOT_FOUND" ;;
  502) echo "PROXY_ERROR 502" ;;
  *) echo "PROXY_ERROR $HTTP" ;;
esac
