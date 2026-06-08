#!/usr/bin/env bash
# 최초 앱 생성 + 첫 배포: POST /apps → 상태 폴링 → 결과 반환.
# 결정적 plumbing. 비밀값(키)은 인자/표준입력으로 받고 echo 하지 않는다.
#
# 사용:
#   deploy.sh <repo> <commit> <team> <subdomain> [port] [env_json]
#     repo      : fursys-group-hub/<name>
#     commit    : git rev-parse HEAD 값
#     team      : creatable_teams 중 하나 (예: iloom-hub)
#     subdomain : 접속 주소 앞부분 (예: event)
#     port      : (선택) 앱이 듣는 포트. Dockerfile EXPOSE 값. 비우면 3000.
#                 next=3000 / vite(nginx)=8080 / fastapi=8000 등. 틀리면 502(라우팅 불일치)가 난다.
#     env_json  : (선택) env_vars 배열 JSON. 예) '[{"key":"GREETING","value":"hi","class":"runtime"}]'
#                 표준입력(stdin)으로도 받는다(인자보다 stdin 우선). 시크릿 값이 인자에 안 남게 stdin 권장.
#
# 출력(stdout): 첫 줄에 결과 코드, 이후 줄에 부가정보(JSON 등).
#   결과 코드:
#     CREATED <app_id> <domain>      생성·배포 시작됨(200)
#     RUNNING <app_id> <domain>      폴링 결과 정상 기동 확인
#     DEPLOY_FAILED <app_id>         폴링 중 exited/error/stopped 감지(→ logs.sh 로 해설)
#     PENDING <app_id> <domain>      폴링 시간초과(아직 진행 중)
#     ALREADY_EXISTS                 409, error 없음/그 외 → 이미 만든 앱(git push 자동재배포)
#     GATE_NO_VERDICT                409 error=no_verdict (서버 게이트 차단)
#     GATE_BLOCKED                   409 error=verdict_blocked (서버 게이트 차단)
#     UNAUTHORIZED                   401
#     FORBIDDEN                      403
#     PROXY_ERROR <http_code>        502 등 기타 오류
#   부가정보로 응답 본문(warnings 포함)을 함께 출력하므로, 호출 측이 warnings 를 읽어 안내한다.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

REPO="${1:-}"; COMMIT="${2:-}"; TEAM="${3:-}"; SUBDOMAIN="${4:-}"; PORT="${5:-}"; ENV_ARG="${6:-}"
if [ -z "$REPO" ] || [ -z "$COMMIT" ] || [ -z "$TEAM" ] || [ -z "$SUBDOMAIN" ]; then
  echo "USAGE deploy.sh <repo> <commit> <team> <subdomain> [port] [env_json]" >&2
  exit 2
fi
# 포트: 비었으면 3000(next 기본). 숫자만 허용(아니면 3000).
case "$PORT" in ''|*[!0-9]*) PORT=3000 ;; esac

# env_vars: stdin 우선, 없으면 인자
ENV_JSON="$ENV_ARG"
if [ ! -t 0 ]; then
  STDIN_DATA="$(cat 2>/dev/null || true)"
  [ -n "$STDIN_DATA" ] && ENV_JSON="$STDIN_DATA"
fi

fdh_resolve_url || true
if ! fdh_load_key; then
  echo "NO_KEY"
  exit 0
fi

# 요청 본문 구성
if [ -n "$ENV_JSON" ]; then
  BODY="$(printf '{"repo":"%s","commit":"%s","team":"%s","subdomain":"%s","port":%s,"env_vars":%s}' \
    "$REPO" "$COMMIT" "$TEAM" "$SUBDOMAIN" "$PORT" "$ENV_JSON")"
else
  BODY="$(printf '{"repo":"%s","commit":"%s","team":"%s","subdomain":"%s","port":%s}' \
    "$REPO" "$COMMIT" "$TEAM" "$SUBDOMAIN" "$PORT")"
fi

RESP="$(curl -sS -w $'\n%{http_code}' -X POST "$PROXY_URL/apps" \
  -H "X-Proxy-Key: $KEY" -H "Content-Type: application/json" \
  -d "$BODY" 2>/dev/null || true)"
HTTP="$(printf '%s' "$RESP" | tail -n1)"
JSON="$(printf '%s' "$RESP" | sed '$d')"

extract() { printf '%s' "$JSON" | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/"; }

case "$HTTP" in
  200)
    APP_ID="$(extract app_id)"
    DOMAIN="$(extract domain)"
    echo "CREATED $APP_ID $DOMAIN"
    printf '%s\n' "$JSON"
    # 상태 폴링: 약 10초 간격, 최대 ~10분(60회)
    for _ in $(seq 1 60); do
      sleep 10
      SRESP="$(curl -sS "$PROXY_URL/apps/$APP_ID/status" -H "X-Proxy-Key: $KEY" 2>/dev/null || true)"
      STATUS="$(printf '%s' "$SRESP" | grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
      case "$STATUS" in
        *running*) echo "RUNNING $APP_ID $DOMAIN"; exit 0 ;;
        *exited*|*error*|*stopped*|*failed*) echo "DEPLOY_FAILED $APP_ID"; exit 0 ;;
      esac
    done
    echo "PENDING $APP_ID $DOMAIN"
    ;;
  401) echo "UNAUTHORIZED" ;;
  403) echo "FORBIDDEN" ;;
  409)
    ERR="$(extract error)"
    case "$ERR" in
      no_verdict) echo "GATE_NO_VERDICT" ;;
      verdict_blocked) echo "GATE_BLOCKED" ;;
      *) echo "ALREADY_EXISTS" ;;
    esac
    printf '%s\n' "$JSON"
    ;;
  502) echo "PROXY_ERROR 502"; printf '%s\n' "$JSON" ;;
  *) echo "PROXY_ERROR $HTTP"; printf '%s\n' "$JSON" ;;
esac
