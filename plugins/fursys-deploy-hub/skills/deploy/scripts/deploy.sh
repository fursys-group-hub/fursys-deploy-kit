#!/usr/bin/env bash
# 최초 앱 생성 + 첫 배포: POST /apps → 상태 폴링 → 결과 반환.
# 결정적 plumbing. 비밀값(키)은 인자/표준입력으로 받고 echo 하지 않는다.
#
# 사용:
#   deploy.sh <repo> <commit> <team> <subdomain> [port] [env_json] [옵션 플래그]
#     repo      : fursys-group-hub/<name>
#     commit    : git rev-parse HEAD 값
#     team      : creatable_teams 중 하나 (예: iloom-hub)
#     subdomain : 접속 주소 앞부분 (예: event)
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
#                                        — CREATED 와 동일 폴링
#     RUNNING <app_id> <https_url>  폴링 결과 정상 기동 확인(주소는 https 로 정규화해 출력)
#     LIVE_OK <https_url> <code>     기동 후 https 로 실제 응답 확인됨(2xx/3xx) — 바로 접속 가능
#     LIVE_PENDING <https_url> <code> 기동은 됐으나 https 첫 응답이 아직(앱 예열 중일 수 있음 → 잠시 후 접속)
#     DEPLOY_FAILED <app_id>         폴링 중 exited/error/stopped 감지(→ logs.sh 로 해설)
#     PENDING <app_id> <domain>      폴링 시간초과(아직 진행 중)
#     STILL_BUILDING <app_id> <domain>  폴링 중 강제 종료됨(앱은 생성됨 — 재배포 금지, my-apps/logs 로 확인)
#     NAME_TAKEN                     409 error=name_taken → 그 이름(app_id)이 타인 소유(남의 앱 재배포 금지)
#     ALREADY_EXISTS                 409, error 없음/그 외 → 하위호환 잔존(정상 재시도엔 더 이상 안 옴)
#     PLACEHOLDER_UNRESOLVED         본문에 치환 안 된 ${...} 가 남아 전송 중단(빌드 깨짐 사전 차단)
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
if ! fdh_load_key; then
  echo "NO_KEY"
  exit 0
fi

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
  -H "X-Proxy-Key: $KEY" -H "Content-Type: application/json" \
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
    # 폴링 중 호출측 타임아웃 등으로 강제 종료(SIGTERM/INT)되어도 "앱은 이미 생성됨"을 알 수 있게
    # 폴백 한 줄을 남긴다(이게 없으면 출력이 통째로 유실돼, 운영자가 생성 사실을 모르고 중복 배포하는 사고로 이어진다).
    trap 'printf "STILL_BUILDING %s %s\n" "$APP_ID" "$DOMAIN"' TERM INT
    # 상태 폴링: 30초 간격 × 4회(~120초). 호출측 기본 타임아웃(2분)에 근접하므로, 폴링이 그 안에
    # 끝나면 최종 상태(RUNNING/DEPLOY_FAILED/PENDING)를 출력하고, 초과로 강제 종료되면 위 TERM/INT
    # 트랩이 STILL_BUILDING(안전 — 앱은 이미 생성됨·재배포 금지)을 남겨 출력 유실(중복배포 사고)을 막는다.
    # 더 오래 걸리면 PENDING 으로 끝내고, 호출측이 logs.sh/my-apps 로 이어서 확인한다.
    # CREATED/REDEPLOYED 공통(REDEPLOY_WEBHOOK 은 위에서 이미 종료).
    for _ in $(seq 1 4); do
      sleep 30
      SRESP="$(curl -sS "$PROXY_URL/apps/$APP_ID/status" -H "X-Proxy-Key: $KEY" 2>/dev/null || true)"
      STATUS="$(printf '%s' "$SRESP" | grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
      case "$STATUS" in
        *running*)
          # T5: 컨테이너가 떴어도 앱이 실제로 응답하는지 https 로 한 번 확인한다.
          # 앱은 https 로만 서빙되므로(http 는 502 가 난다) 반드시 https 로 정규화해 찍는다.
          if [ -n "$DOMAIN" ]; then HTTPS_URL="https://${DOMAIN#*://}"; else HTTPS_URL=""; fi
          echo "RUNNING $APP_ID ${HTTPS_URL:-$DOMAIN}"
          if [ -n "$HTTPS_URL" ]; then
            # 앱 예열(첫 응답 지연) 대비 최대 ~30초(6회) 동안 2xx/3xx 를 기다린다. 성공 시 즉시 종료.
            LIVE_CODE=""
            for _ in $(seq 1 4); do
              LIVE_CODE="$(curl -sS -o /dev/null -w '%{http_code}' -L --max-time 8 "$HTTPS_URL" 2>/dev/null || true)"
              case "$LIVE_CODE" in 2*|3*) break ;; esac
              sleep 4
            done
            case "$LIVE_CODE" in
              2*|3*) echo "LIVE_OK $HTTPS_URL $LIVE_CODE" ;;
              *)     echo "LIVE_PENDING $HTTPS_URL ${LIVE_CODE:-000}" ;;
            esac
          fi
          exit 0 ;;
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
      name_taken) echo "NAME_TAKEN" ;;
      *) echo "ALREADY_EXISTS" ;;   # 하위호환 잔존(정상 재시도엔 더 이상 안 옴)
    esac
    printf '%s\n' "$JSON"
    ;;
  502) echo "PROXY_ERROR 502"; printf '%s\n' "$JSON" ;;
  *) echo "PROXY_ERROR $HTTP"; printf '%s\n' "$JSON" ;;
esac
