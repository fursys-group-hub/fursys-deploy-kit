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
#                 표준입력(stdin)으로도 받는다. 시크릿 값이 인자(argv)에 안 남게 stdin/--env-file 권장.
#                 우선순위: --env-file > stdin > env_json 인자.
#
#     --env-file <path>  : (선택, 권장) env_vars 배열 JSON 이 담긴 파일 경로. **읽은 뒤 즉시 삭제**한다.
#                          Windows(Git Bash)에서 `printf | deploy.sh` stdin 파이프가 간헐적으로
#                          exit 1·빈출력으로 깨지는 문제를 우회하는 안정 경로다(파일은 파이프와 달리
#                          버퍼링/EOF 레이스가 없다). 호출측이 mktemp 로 0600 파일에 써서 넘긴다
#                          → 시크릿이 argv·프로세스 목록·stdout 에 남지 않는다.
#
#   서버 선택 옵션 (선택 — 안 주면 첫 서버 + group.hub 도메인, 현행 100% 동일):
#     --server <이름>           : 배포 대상 Coolify 서버 이름(대소문자 무시) 또는 uuid. /deploy2 가
#                                 `coolify-oper-web-2` 로 준다. 값이 있으면 본문에 "server":"<값>" 을
#                                 추가한다(미전송이면 필드 없음 → 현행 바이트 동일). 서버 지정 시 주소
#                                 접미사가 group.hub 가 아니라 hub.fursys.com 이 되고, 예약 주소는 거부된다.
#
#   앱 식별 옵션 (선택 — 안 주면 app_id=repo 이름, 현행 100% 동일):
#     --app <key>               : (#38) 명시 app 키. 같은 repo 를 subdomain(주소)만 바꿔 **별도 앱**으로
#                                 배포할 때 준다(예: iloom-order-shortage 를 order/shortage 두 주소로).
#                                 안 주면 app_id=repo 이름 → 같은 repo 두 번째 주소가 기존 앱으로 수렴해
#                                 새 주소 배포가 막힌다. 주면 app_id 가 이 키로 분리돼 각 주소가 별도 앱.
#                                 영문/숫자/-/_ 만 유효(proxy 가 정규화). service 와 함께면 service 우선.
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
#     SERVER_UNKNOWN                 400 error=unknown_server (--server 이름/uuid 를 못 찾음)
#     SUBDOMAIN_RESERVED             400 error=reserved_subdomain (서버 지정 시 예약 주소 앞부분 거부)
#     PROXY_ERROR <http_code>        502 등 기타 오류
#   부가정보로 응답 본문(warnings 포함)을 함께 출력하므로, 호출 측이 warnings 를 읽어 안내한다.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"
# common.sh 가 'set -euo pipefail' 로 errexit 를 켜므로, 이 스크립트의 선언 모드(set -uo, errexit 미사용)를
# 재확인한다. 안 그러면 errexit 가 새어 들어와, 의도적으로 실패를 허용하는 줄(예: 브랜치 폴백의
# 'git symbolic-ref | sed' 파이프라인 — origin/HEAD 미설정 시 rc=128)에서 스크립트가 조기 종료해
# POST 전에 죽는다(Windows Git Bash 의 'exit 1·빈출력' 증상의 실제 원인). 폴백·stdin·--env-file 가
# "실패해도 다음으로 진행"하도록 errexit 를 끈다(이 스크립트는 분기·rc 로 직접 제어한다).
set +e

REPO="${1:-}"; COMMIT="${2:-}"; TEAM="${3:-}"; SUBDOMAIN="${4:-}"; PORT="${5:-}"; ENV_ARG="${6:-}"
# 위치 인자 6개를 소비한 뒤, 남은 인자에서 멀티서비스 옵션 플래그를 파싱한다.
[ "$#" -ge 1 ] && shift "$(( $# < 6 ? $# : 6 ))"
SERVICE=""; BASE_DIR=""; DOCKERFILE_LOC=""; VOLUMES=""; BRANCH=""; ENV_FILE=""; APP_KEY=""; SERVER=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch)         BRANCH="${2:-}"; shift 2 ;;
    --app)            APP_KEY="${2:-}"; shift 2 ;;
    --server)         SERVER="${2:-}"; shift 2 ;;
    --service)        SERVICE="${2:-}"; shift 2 ;;
    --base-dir)       BASE_DIR="${2:-}"; shift 2 ;;
    --dockerfile-loc) DOCKERFILE_LOC="${2:-}"; shift 2 ;;
    --volumes)        VOLUMES="${2:-}"; shift 2 ;;
    --env-file)       ENV_FILE="${2:-}"; shift 2 ;;
    *) echo "UNKNOWN_FLAG $1" >&2; shift ;;
  esac
done
if [ -z "$REPO" ] || [ -z "$COMMIT" ] || [ -z "$TEAM" ] || [ -z "$SUBDOMAIN" ]; then
  echo "USAGE deploy.sh <repo> <commit> <team> <subdomain> [port] [env_json] [--branch B] [--app K] [--server S] [--service N] [--base-dir D] [--dockerfile-loc P] [--env-file F]" >&2
  exit 2
fi
# 포트: 비었으면 3000(next 기본). 숫자만 허용(아니면 3000).
case "$PORT" in ''|*[!0-9]*) PORT=3000 ;; esac

# 배포 브랜치: --branch 우선 → repo 기본 브랜치(origin/HEAD) → 현재 브랜치 → main 폴백.
# (사내 표준은 main 이지만 repo 기본 브랜치가 master 등일 수 있어 하드코딩하지 않는다.
#  Coolify 가 이 브랜치를 못 찾으면 빌드가 실패하므로 실제 repo 기본값을 보낸다.)
if [ -z "$BRANCH" ]; then
  # ① repo 기본 브랜치(origin/HEAD). ref 없는 clone(set-head 미실행)이면 symbolic-ref 가
  #    실패해 빈 문자열이 된다 — pipefail 로 파이프라인 rc 가 128 이 되지만, 이 줄은 대입이라
  #    스크립트를 종료시키지 않는다(set -e 미사용). 다음 폴백으로 넘어간다.
  BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  # ② 현재 체크아웃 브랜치. 단 detached HEAD 면 git 이 리터럴 "HEAD" 를 돌려준다 —
  #    이는 브랜치명이 아니므로(Coolify 가 "HEAD" 브랜치를 못 찾아 빌드 실패) 빈 값으로 취급한다.
  if [ -z "$BRANCH" ]; then
    BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [ "$BRANCH" = "HEAD" ] && BRANCH=""
  fi
  # ③ 최종 폴백: 사내 표준 main.
  [ -z "$BRANCH" ] && BRANCH=main
fi

# env_vars 해결 — 우선순위: --env-file > stdin > 인자.
# (--env-file = Windows Git Bash stdin 파이프 불안정 우회. 읽은 즉시 파일 삭제 → 시크릿 잔류 0.)
# --env-file 을 먼저 처리하고, 그게 성공하면 stdin 은 읽지 않는다(항목7). stdin cat 을
# 먼저 하면, 비대화형으로 stdin 이 열린 채 상속된 경우(--env-file 로 호출하면서 stdin 을
# 명시적으로 닫지 않은 호출자) cat 이 EOF 를 기다리며 무한 블록 → 정상 출력이 안 나온다.
ENV_JSON="$ENV_ARG"
ENV_RESOLVED=""
if [ -n "$ENV_FILE" ]; then
  if [ -r "$ENV_FILE" ]; then
    FILE_DATA="$(cat "$ENV_FILE" 2>/dev/null || true)"
    rm -f "$ENV_FILE" 2>/dev/null || true   # 시크릿 파일은 읽은 즉시 삭제(잔류 방지)
    if [ -n "$FILE_DATA" ]; then ENV_JSON="$FILE_DATA"; ENV_RESOLVED=1; fi
  else
    echo "ENV_FILE_UNREADABLE" >&2   # 경로 오류는 진단만(stderr) — stdin/인자 값으로 폴백
  fi
fi
# --env-file 로 값을 얻지 못했을 때만 stdin 을 시도(폴백). 그래야 env-file 호출 시
# 열린 stdin 상속으로 cat 이 블록되는 일이 없다.
if [ -z "$ENV_RESOLVED" ] && [ ! -t 0 ]; then
  STDIN_DATA="$(cat 2>/dev/null || true)"
  [ -n "$STDIN_DATA" ] && ENV_JSON="$STDIN_DATA"
fi

fdh_resolve_url || true

# 요청 본문 구성.
# 항상 들어가는 필드 + 선택 필드(멀티서비스/ env_vars)를 조립한다.
# 선택 필드는 값이 있을 때만 추가 → 세 멀티서비스 플래그 미전송 시 현행 단일배포 본문과 동일.
BODY="$(printf '{"repo":"%s","commit":"%s","team":"%s","subdomain":"%s","branch":"%s","port":%s' \
  "$REPO" "$COMMIT" "$TEAM" "$SUBDOMAIN" "$BRANCH" "$PORT")"
[ -n "$APP_KEY" ]        && BODY="$BODY$(printf ',"app":"%s"' "$APP_KEY")"
[ -n "$SERVER" ]         && BODY="$BODY$(printf ',"server":"%s"' "$SERVER")"
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
  400)
    ERR="$(extract error)"
    case "$ERR" in
      unknown_server)     echo "SERVER_UNKNOWN" ;;
      reserved_subdomain) echo "SUBDOMAIN_RESERVED" ;;
      *)                  echo "BAD_REQUEST" ;;
    esac
    printf '%s\n' "$JSON"
    ;;
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
