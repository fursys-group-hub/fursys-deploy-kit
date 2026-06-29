#!/usr/bin/env bash
# 배포 종결 판정용 상태 합성 조회 (CONTRACTS §11.1).
# 두 기존 엔드포인트를 합성해 terminal(기동/실패)·비종결(진행/불명)을 결정적으로 판정한다:
#   GET /apps/{id}/status  = 애플리케이션(컨테이너) 상태(running:healthy/exited/... 소문자)
#   GET /apps/{id}/logs    = 배포(deployment) 상태(queued|in_progress|finished|failed|...) — 빌드 성패 진실원
# 각 호출은 빠르게 끝난다(긴 sleep 없음). 폴링 반복은 호출측(스킬)이 backoff 로 한다.
# 키·전송대상 가드는 common.sh 재사용. 비밀값(키)은 echo 하지 않는다.
#
# 사용: status.sh <app_id> [domain]
#   domain: (선택) 접속 도메인. proxy /status 는 domain 을 반환하지 않으므로, 호출측이 POST /apps 응답
#           (CREATED <app_id> <domain>)에서 보관한 domain 을 넘긴다. 없으면 RUNNING 만(주소 미동반) 출력.
# 출력(stdout): 첫 줄 = 결과 코드. RUNNING 이면(domain 이 있을 때만) 이어서 LIVE 보조 줄(LIVE_OK/LIVE_PENDING).
#   결과 코드:
#     RUNNING <app_id> <https_url|빈값>  컨테이너 기동 확인(terminal-성공). /status 가 *running*.
#                                        domain 인자가 있으면 https URL, 없으면 주소 미동반(호출측이 CREATED domain 사용).
#     LIVE_OK <https_url> <code>       (RUNNING 뒤 보조 줄) https 직접 응답 2xx/3xx — 바로 접속 가능.
#     LIVE_PENDING <https_url> <code>  (RUNNING 뒤 보조 줄) 기동했으나 https 첫 응답 아직(예열).
#     FAILED <app_id>                  terminal-실패. /logs ∈ {failed,cancelled-by-user} 또는
#                                      /status ∈ {exited,error,stopped,failed}.
#     BUILDING <app_id>                비종결(진행 중). /logs ∈ {queued,in_progress} 또는 둘 다 미확정.
#     UNKNOWN <app_id>                 상태 조회 불가(401/404/502, deployment_uuid 부재, 둘 다 unknown).
#
#   ※ 시크릿 비노출: 상태/코드만 출력한다. /logs 를 보더라도 로그 본문을 stdout 으로 토하지 않는다
#     (실패 시 해설은 deploy ⑨ / deploy-fix 빌드로그 모드가 별도로 logs.sh 를 부른다).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

APP_ID="${1:-}"
# 접속 도메인은 인자(2번째)로 받는다 — proxy GET /apps/{id}/status 는 domain 을 반환하지 않으므로
# (응답 = {app_id,status,app_uuid,team}), URL 은 POST /apps 응답의 CREATED <app_id> <domain> 에서 와야 한다.
# 호출측(SKILL ⑦-1)이 CREATED 에서 받은 domain 을 보관해 여기로 넘긴다. 없으면 RUNNING 만(주소 미동반) 낸다.
ARG_DOMAIN="${2:-}"
if [ -z "$APP_ID" ]; then
  echo "USAGE status.sh <app_id> [domain]" >&2
  exit 2
fi

fdh_resolve_url || true

# 한 필드의 문자열 값을 JSON 에서 뽑는다(첫 매치). 없으면 빈 문자열(grep 미스로 스크립트가 죽지 않게 || true).
# 값 자체는 화면에 안 찍는다(변수만).
json_str() { printf '%s' "$1" | { grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" || true; } | head -n1 | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/"; }

# ── 1) /status 먼저 (호출 비용 절감: *running* 이면 /logs 생략) ───────────────────
SRESP="$(curl -sS -w $'\n%{http_code}' "$PROXY_URL/apps/$APP_ID/status" \
  2>/dev/null || true)"
SHTTP="$(printf '%s' "$SRESP" | tail -n1)"
SJSON="$(printf '%s' "$SRESP" | sed '$d')"
STATUS=""
if [ "$SHTTP" = "200" ]; then
  STATUS="$(json_str "$SJSON" status)"
fi
# proxy /status 는 domain 을 안 주므로 인자로 받은 domain 만 쓴다(없으면 빈 값).
DOMAIN="$ARG_DOMAIN"

# https 정규화(앱은 https 로만 서빙 — http 는 502). 빈 입력이어도 set -e 로 죽지 않게 가드.
HTTPS_URL=""
[ -n "$DOMAIN" ] && HTTPS_URL="https://${DOMAIN#*://}"

# 우선순위 1: /status 가 *running* → RUNNING(+LIVE 보조). 컨테이너가 떴으면 빌드 성공 — 최우선.
case "$STATUS" in
  *running*)
    # ⚠️ domain 유무와 무관하게 RUNNING 을 무조건 먼저 echo 한다(domain 없어도 기동 성공 판정 유실 금지).
    echo "RUNNING $APP_ID ${HTTPS_URL:-$DOMAIN}"
    if [ -n "$HTTPS_URL" ]; then
      # 예열(첫 응답 지연) 대비 짧게 2xx/3xx 를 확인한다(각 호출 max-time 8s, 성공 시 즉시 종료).
      LIVE_CODE=""
      for _ in 1 2 3; do
        LIVE_CODE="$(curl -sS -o /dev/null -w '%{http_code}' -L --max-time 8 "$HTTPS_URL" 2>/dev/null || true)"
        case "$LIVE_CODE" in 2*|3*) break ;; esac
      done
      case "$LIVE_CODE" in
        2*|3*) echo "LIVE_OK $HTTPS_URL $LIVE_CODE" ;;
        *)     echo "LIVE_PENDING $HTTPS_URL ${LIVE_CODE:-000}" ;;
      esac
    fi
    exit 0 ;;
esac

# ── 2) running 아님 → /logs 의 deployment status 로 진행/실패를 가린다 ───────────
LRESP="$(curl -sS -w $'\n%{http_code}' "$PROXY_URL/apps/$APP_ID/logs" \
  2>/dev/null || true)"
LHTTP="$(printf '%s' "$LRESP" | tail -n1)"
LJSON="$(printf '%s' "$LRESP" | sed '$d')"
DSTATUS=""
if [ "$LHTTP" = "200" ]; then
  DSTATUS="$(json_str "$LJSON" status)"
fi

# 우선순위 2: /logs deployment status.
case "$DSTATUS" in
  failed|cancelled-by-user)
    echo "FAILED $APP_ID"; exit 0 ;;
  queued|in_progress)
    echo "BUILDING $APP_ID"; exit 0 ;;
  finished)
    # 빌드는 끝났으나 아직 *running* 이 아니면 한 박자 더(다음 폴에서 RUNNING 수렴).
    echo "BUILDING $APP_ID"; exit 0 ;;
esac

# 우선순위 3: /logs 가 unknown(deployment_uuid 부재 등) + /status 가 크래시/종료 → FAILED.
case "$STATUS" in
  *exited*|*error*|*stopped*|*failed*)
    echo "FAILED $APP_ID"; exit 0 ;;
esac

# 우선순위 4: 둘 다 미확정.
#   엔드포인트 자체가 오류(401/404/502)거나 둘 다 조회 자체가 실패(네트워크 등으로 HTTP 코드 없음)면
#   UNKNOWN(조회 불가). 그 외엔 BUILDING(신규 앱이 아직 안 뜬 정상 진행).
case "$SHTTP" in 401|404|502) echo "UNKNOWN $APP_ID"; exit 0 ;; esac
case "$LHTTP" in 401|404|502) echo "UNKNOWN $APP_ID"; exit 0 ;; esac
if [ "$SHTTP" != "200" ] && [ "$LHTTP" != "200" ]; then
  echo "UNKNOWN $APP_ID"; exit 0
fi
echo "BUILDING $APP_ID"
