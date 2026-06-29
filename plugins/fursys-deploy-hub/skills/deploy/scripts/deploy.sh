#!/usr/bin/env bash
# 최초 앱 생성 + 첫 배포: POST /apps → 결과 코드 반환(POST 중심, 장시간 폴링 없음).
# 종결 대기(기동/실패 판정)는 호출측(deploy 스킬 ⑦)이 status.sh 를 backoff 로 반복 호출해 한다(CONTRACTS §11.2).
# 결정적 plumbing. 무인증(배포 키 제거) — 인증 헤더 없이 전송한다.
#
# 사용:
#   deploy.sh <repo> <commit> <team> <subdomain> [port] [env_json] [옵션 플래그]
#     repo      : fursys-group-hub/<name>
#     commit    : git rev-parse HEAD 값
#     team      : (호환용 위치 인자 — 단일팀 전환으로 서버가 무시하고 group-hub 로 고정한다. 빈 값 가능)
#     subdomain : 접속 주소 앞부분 (예: event) → 최종 {subdomain}.group.hub.fursys.com
#     port      : (선택) 앱이 듣는 포트. Dockerfile EXPOSE 값. 비우면 3000.
#                 next=3000 / vite(nginx)=8080 / fastapi=8000 등. 틀리면 502(라우팅 불일치)가 난다.
#     env_json  : (선택) env_vars 배열 JSON. 예) '[{"key":"GREETING","value":"hi","class":"runtime"}]'
#                 표준입력(stdin)으로도 받는다(인자보다 stdin 우선). 시크릿 값이 인자에 안 남게 stdin 권장.
#
#   멀티서비스 옵션 플래그 (선택 — 안 주면 단일배포와 100% 동일):
#     --service <name>          : 이 호출이 만드는 서비스 이름. 주면 proxy 가 app_id=`{repo}-{name}`.
#     --base-dir <dir>          : 빌드 디렉토리(POST /apps 의 base_directory). 예: backend.
#                                 슬래시 없이 줘도 proxy 가 "/backend" 로 정규화한다(Coolify 선행슬래시 요구).
#     --dockerfile-loc <path>   : base_directory **기준 상대** Dockerfile 경로(dir 을 앞에 붙이지 말 것).
#                                 보통 생략 → proxy 기본값 "/Dockerfile".
#     --volumes <json-array>    : (선택, Phase2) 영속 볼륨 마운트 경로 JSON 배열. 예: '["/data"]'.
#                                 proxy 가 각 경로에 Coolify persistent storage 를 멱등 보장(재배포해도 데이터 유지).
#   세 플래그를 모두 생략하면 본문에 해당 필드를 넣지 않아 현행 단일배포 호출과 바이트 동일하다.
#   플래그는 위치 인자(env_json 까지) 뒤에 오며, env_json 은 여전히 stdin 으로 줄 수 있다.
#
# 출력(stdout): 첫 줄에 결과 코드, 이후 줄에 부가정보(JSON 등).
#   결과 코드:
#     CREATED <app_id> <domain>          생성·배포 시작됨(200, 최초 생성) — 폴링
#     REDEPLOY_WEBHOOK <app_id> <domain> 본인 기존앱, 서버가 다시 배포 안 함(200 status:unchanged,
#                                        deploy_triggered:false) — 폴링하지 않음. git push 가 자동 재배포.
#     REDEPLOYED <app_id> <domain>       고아 자가복구로 새로 만듦(200 redeployed:true, deploy_triggered:true)
#                                        — CREATED 와 동일하게 호출측이 status.sh 로 종결 폴링
#     (종결 판정 RUNNING/LIVE_OK/LIVE_PENDING/FAILED/BUILDING/UNKNOWN 은 이제 status.sh 가 낸다 — 이 스크립트는 안 낸다.)
#     PLACEHOLDER_UNRESOLVED         본문에 치환 안 된 ${...} 가 남아 전송 중단(빌드 깨짐 사전 차단)
#     GATE_NO_VERDICT                409 error=no_verdict (서버 게이트 차단)
#     GATE_BLOCKED                   409 error=verdict_blocked (서버 게이트 차단)
#     BAD_REQUEST                    400 (repo/subdomain 누락 등)
#     PROXY_ERROR <http_code>        502 등 기타 오류
#   부가정보로 응답 본문(warnings 포함)을 함께 출력하므로, 호출 측이 warnings 를 읽어 안내한다.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

REPO="${1:-}"; COMMIT="${2:-}"; TEAM="${3:-}"; SUBDOMAIN="${4:-}"; PORT="${5:-}"; ENV_ARG="${6:-}"
# 위치 인자 6개를 소비한 뒤, 남은 인자에서 멀티서비스 옵션 플래그를 파싱한다.
[ "$#" -ge 1 ] && shift "$(( $# < 6 ? $# : 6 ))"
SERVICE=""; BASE_DIR=""; DOCKERFILE_LOC=""; VOLUMES=""; BRANCH=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch)         BRANCH="${2:-}"; shift 2 ;;
    --service)        SERVICE="${2:-}"; shift 2 ;;
    --base-dir)       BASE_DIR="${2:-}"; shift 2 ;;
    --dockerfile-loc) DOCKERFILE_LOC="${2:-}"; shift 2 ;;
    --volumes)        VOLUMES="${2:-}"; shift 2 ;;
    *) echo "UNKNOWN_FLAG $1" >&2; shift ;;
  esac
done
if [ -z "$REPO" ] || [ -z "$COMMIT" ] || [ -z "$TEAM" ] || [ -z "$SUBDOMAIN" ]; then
  echo "USAGE deploy.sh <repo> <commit> <team> <subdomain> [port] [env_json] [--branch B] [--service N] [--base-dir D] [--dockerfile-loc P]" >&2
  exit 2
fi
# 포트: 비었으면 3000(next 기본). 숫자만 허용(아니면 3000).
case "$PORT" in ''|*[!0-9]*) PORT=3000 ;; esac

# 배포 브랜치: --branch 우선 → repo 기본 브랜치(origin/HEAD) → 현재 브랜치 → main 폴백.
# (사내 표준은 main 이지만 repo 기본 브랜치가 master 등일 수 있어 하드코딩하지 않는다.
#  Coolify 가 이 브랜치를 못 찾으면 빌드가 실패하므로 실제 repo 기본값을 보낸다.)
if [ -z "$BRANCH" ]; then
  BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  [ -z "$BRANCH" ] && BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [ -z "$BRANCH" ] && BRANCH=main
fi

# env_vars: stdin 우선, 없으면 인자
ENV_JSON="$ENV_ARG"
if [ ! -t 0 ]; then
  STDIN_DATA="$(cat 2>/dev/null || true)"
  [ -n "$STDIN_DATA" ] && ENV_JSON="$STDIN_DATA"
fi

fdh_resolve_url || true

# 요청 본문 구성.
# 항상 들어가는 필드 + 선택 필드(멀티서비스/ env_vars)를 조립한다.
# 선택 필드는 값이 있을 때만 추가 → 세 멀티서비스 플래그 미전송 시 현행 단일배포 본문과 동일.
BODY="$(printf '{"repo":"%s","commit":"%s","team":"%s","subdomain":"%s","branch":"%s","port":%s' \
  "$REPO" "$COMMIT" "$TEAM" "$SUBDOMAIN" "$BRANCH" "$PORT")"
[ -n "$SERVICE" ]        && BODY="$BODY$(printf ',"service":"%s"' "$SERVICE")"
[ -n "$BASE_DIR" ]       && BODY="$BODY$(printf ',"base_directory":"%s"' "$BASE_DIR")"
[ -n "$DOCKERFILE_LOC" ] && BODY="$BODY$(printf ',"dockerfile_location":"%s"' "$DOCKERFILE_LOC")"
[ -n "$VOLUMES" ]        && BODY="$BODY$(printf ',"volumes":%s' "$VOLUMES")"
[ -n "$ENV_JSON" ]       && BODY="$BODY$(printf ',"env_vars":%s' "$ENV_JSON")"
BODY="$BODY}"

# 미치환 placeholder 잔류 가드 (멀티서비스 cross-URL 치환 누락 사전 차단).
# 치환은 deploy 스킬이 본문 조립 전에 끝내야 하나, 누락 시 리터럴 `${api.url}` 등이
# 빌드 ARG 로 들어가 빌드/런타임이 조용히 깨진다. 본문에 `${` 가 하나라도 남아 있으면
# POST 를 하지 않고 PLACEHOLDER_UNRESOLVED 로 즉시 중단한다(값은 출력하지 않는다 — 키/시크릿 비노출).
# `${` 가 없으면(단일배포·placeholder 없는 멀티서비스 포함) 가드는 발동하지 않는다 → 현행과 동일.
case "$BODY" in
  *'${'*)
    echo "PLACEHOLDER_UNRESOLVED"
    exit 0
    ;;
esac

RESP="$(curl -sS -w $'\n%{http_code}' -X POST "$PROXY_URL/apps" \
  -H "Content-Type: application/json" \
  -d "$BODY" 2>/dev/null || true)"
HTTP="$(printf '%s' "$RESP" | tail -n1)"
JSON="$(printf '%s' "$RESP" | sed '$d')"

extract() { printf '%s' "$JSON" | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/"; }

case "$HTTP" in
  200)
    APP_ID="$(extract app_id)"
    DOMAIN="$(extract domain)"
    # boolean/특정문자열은 문자열 extract 헬퍼가 못 잡으니 별도 판정.
    #   deploy_triggered:false → 이번 호출에서 서버가 deploy 를 안 했다(이중배포 가드, status:unchanged).
    #                            git push webhook 이 재배포하므로 폴링하지 않는다.
    #   redeployed:true        → (deploy_triggered:false 가 아니면) 고아 자가복구로 새로 만듦 → CREATED 와 동일 폴링.
    #   둘 다 아님              → 최초 생성(CREATED).
    DT_FALSE="$(printf '%s' "$JSON" | grep -oE '"deploy_triggered"[[:space:]]*:[[:space:]]*false' | head -n1)"
    REDEPLOYED="$(printf '%s' "$JSON" | grep -oE '"redeployed"[[:space:]]*:[[:space:]]*true' | head -n1)"
    if [ -n "$DT_FALSE" ]; then
      # (b) 정상 경로: 서버가 deploy 안 함(중복 배포 방지). 폴링하지 않고 즉시 종료.
      echo "REDEPLOY_WEBHOOK $APP_ID $DOMAIN"
      printf '%s\n' "$JSON"
      exit 0
    fi
    if [ -n "$REDEPLOYED" ]; then echo "REDEPLOYED $APP_ID $DOMAIN"; else echo "CREATED $APP_ID $DOMAIN"; fi
    printf '%s\n' "$JSON"
    # POST 가 성공해 앱이 만들어졌다(생성 트리거 완료). 종결 대기(기동/실패 판정)는 더 이상
    # 이 스크립트가 장시간 폴링하지 않고, 호출측(deploy 스킬 ⑦)이 status.sh 를 backoff 로 반복
    # 호출해 결정적으로 판정한다(CONTRACTS §11.2). 각 호출이 빠르게 끝나 호출측 타임아웃에 안 걸린다.
    # STILL_BUILDING 트랩 정신(앱은 이미 생성됨·재-POST 금지)은 스킬 루프가 같은 정신으로 유지한다
    # (CREATED/REDEPLOYED 를 받은 서비스는 "이미 만들어진 것" — 다시 POST 하지 않는다).
    exit 0
    ;;
  400) echo "BAD_REQUEST"; printf '%s\n' "$JSON" ;;
  409)
    ERR="$(extract error)"
    case "$ERR" in
      no_verdict) echo "GATE_NO_VERDICT" ;;
      verdict_blocked) echo "GATE_BLOCKED" ;;
      *) echo "PROXY_ERROR 409" ;;
    esac
    printf '%s\n' "$JSON"
    ;;
  502) echo "PROXY_ERROR 502"; printf '%s\n' "$JSON" ;;
  *) echo "PROXY_ERROR $HTTP"; printf '%s\n' "$JSON" ;;
esac
