#!/usr/bin/env bash
# 설정값(env_vars) 페이로드 준비 — **모델 대신 이 스크립트가 시크릿을 다룬다.**
#
# 왜 있나(2026-07-31): 예전 deploy 스킬 ⑥ 은 모델이 인라인 Bash 명령문 안에
#   ENV_JSON='[{"key":"DATABASE_URL","value":"<비밀번호가 든 연결문자열>"}, ...]'
# 를 직접 써서 임시파일로 옮기게 했다. 그러면 **시크릿 평문이 모델이 작성한 명령문(도구 입력·
# 명령 이력)에 그대로 남아** Claude Code 의 권한 분류기가 자격증명 노출로 판정해 자동 실행을
# 막는다(현업 fursys-arcade: "마지막 단계에서 권한이 필요합니다" 로 매번 멈춤). 게다가 임시파일을
# 프로젝트 밖(`/tmp`)에 만들어 샌드박스·허용목록으로 커버할 수도 없었다.
# → 값 읽기·따옴표 정규화·난수 생성·파일 생성을 **전부 이 번들 스크립트 안으로** 옮겼다.
#   모델은 **값이 없는 plan**(키 이름·class·note·scope·fgdw_role)만 넘긴다.
#
# 사용:
#   env-prepare.sh --init
#       프로젝트 안의 임시 디렉터리(.fursys-deploy-hub/.tmp)를 만들고 `.gitignore`(`*`)로 보호한다.
#       사용자가 채팅으로 준 값(note:"ask")을 Write 로 저장할 위치(ASK_FILE)를 알려준다.
#
#   env-prepare.sh --plan <plan.json> [--dir <서비스dir>] [--env <.env경로>]... [--name <서비스이름>]
#       plan 대로 값을 채워 env_vars 배열 JSON 페이로드를 만든다(0600). 값 출처 우선순위:
#         plan 의 value(비밀 아닌 계산값) > ask.env(채팅으로 받은 값) > `.env` > secret-gen(난수 자동생성)
#       --dir X   = --env X/.env 의 줄임(멀티서비스: 서비스 dir 의 .env)
#       --env     = 여러 번 가능(앞에 준 것이 우선). 생략 시 ./.env
#       --name    = 멀티서비스에서 서비스별 페이로드를 구분(.tmp/env-<name>.json)
#
#   env-prepare.sh --clean
#       임시 페이로드·ask 파일을 지운다(배포 종료·중단 시 잔류 방지).
#
# 출력(stdout, 첫 줄이 결과 코드 — 호출측은 이 코드로 분기한다):
#   TMP_READY <dir>            (--init 성공. 다음 줄에 `ASK_FILE <경로>`)
#   ENV_READY <경로> <개수>    페이로드 생성 완료 → 그 경로를 deploy.sh `--env-file` 로 넘긴다
#   ENV_EMPTY <경로>           보낼 설정값이 0개(`[]` — proxy 는 미전송과 동일 처리)
#   ENV_MISSING <KEY>...       note:"ask" 인데 값이 없다 → 사용자에게 물어야 한다(파일 안 만듦)
#   (부가 줄) GENERATED/OMITTED/LOCAL_SKIPPED <KEY>... · PORT <n> · VOLUMES <json배열>
#   ENV_NOT_IGNORED <경로>     시크릿 파일이 git 에 추적될 위치다 → 만들지 않는다(fail-closed)
#   NO_PLAN <경로> / PLAN_INVALID <사유> / NODE_REQUIRED / TMP_UNWRITABLE <dir>
#   CLEANED
# exit: 0 성공 / 2 사용법 / 3 진행 불가(ENV_MISSING·ENV_NOT_IGNORED) / 4 오류
#
# 보안 불변식: **값(시크릿)은 stdout·stderr·리포트에 절대 출력하지 않는다**(키 이름만).
#   plan 에 이름이 있는 키만 읽는다. `bash -x` 로 이 스크립트를 추적하지 말 것(값이 트레이스에 남는다).
set -uo pipefail
# common.sh 는 소스하지 않는다 — 이 스크립트는 네트워크(proxy URL)를 쓰지 않고, common.sh 의
# `set -euo pipefail` 이 errexit 로 새어 들어오는 것도 피한다(deploy.sh 항목18 교훈).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FDH_DIR=".fursys-deploy-hub"
TMP_DIR="$FDH_DIR/.tmp"

MODE=""; PLAN=""; NAME=""; ENV_ARGS=()
# 값이 빠진 플래그(예: `--dir` 뒤에 아무것도 없음)에서 `shift 2` 가 실패해 무한루프가 되지 않게
# 실패하면 1칸만 민다(shift 2 는 $# < 2 면 rc=1 이고 아무것도 밀지 않는다).
while [ "$#" -gt 0 ]; do
  case "$1" in
    --init)   MODE="init"; shift ;;
    --clean)  MODE="clean"; shift ;;
    --plan)   MODE="build"; PLAN="${2:-}"; shift 2 2>/dev/null || shift ;;
    --name)   NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
    --dir)    [ -n "${2:-}" ] && ENV_ARGS+=(--env "${2%/}/.env"); shift 2 2>/dev/null || shift ;;
    --env)    [ -n "${2:-}" ] && ENV_ARGS+=(--env "$2"); shift 2 2>/dev/null || shift ;;
    *) echo "UNKNOWN_FLAG $1" >&2; shift ;;
  esac
done
if [ -z "$MODE" ]; then
  echo "USAGE env-prepare.sh --init | --plan <plan.json> [--dir D] [--env F]... [--name N] | --clean" >&2
  exit 2
fi

# 임시 디렉터리 + .gitignore(`*`) — 시크릿이 담긴 파일이 git 에 추적되지 않게 스스로 보호한다.
# (사용자 repo 루트 `.gitignore` 는 건드리지 않는다 — 우리 폴더 안에서만 닫는다.)
ensure_tmp() {
  mkdir -p "$TMP_DIR" 2>/dev/null || { echo "TMP_UNWRITABLE $TMP_DIR"; exit 4; }
  if [ ! -f "$TMP_DIR/.gitignore" ]; then
    # 2>/dev/null 을 먼저 둔다 — 리다이렉트 자체가 실패해도(자리 점유 등) 셸 오류가 새지 않게.
    printf '%s\n' '# fursys-deploy-hub 임시 파일(설정값·시크릿 포함) — 절대 커밋하지 않는다.' '*' \
      2>/dev/null > "$TMP_DIR/.gitignore"
  fi
}

# git 이 이 경로를 무시하는지 **종료코드로만** 판정한다(라운드7 항목23: -v 는 부정패턴에도 rc=0).
#   rc=0 무시됨(안전) / rc=1 추적됨(위험) / 그 외(git 아님·오류) → 커밋 위험 없음으로 본다.
is_ignored() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git check-ignore -q -- "$1" 2>/dev/null
  case "$?" in 0) return 0 ;; 1) return 1 ;; *) return 0 ;; esac
}

case "$MODE" in
  clean)
    rm -f "$TMP_DIR"/env.json "$TMP_DIR"/env-*.json "$TMP_DIR"/ask.env 2>/dev/null
    echo "CLEANED"
    exit 0
    ;;
  init)
    ensure_tmp
    if ! is_ignored "$TMP_DIR/ask.env"; then echo "ENV_NOT_IGNORED $TMP_DIR/ask.env"; exit 3; fi
    echo "TMP_READY $TMP_DIR"
    echo "ASK_FILE $TMP_DIR/ask.env"
    exit 0
    ;;
esac

# ── build 모드 ───────────────────────────────────────────────────────────────
[ -n "$PLAN" ] || { echo "NO_PLAN"; exit 4; }
[ -r "$PLAN" ] || { echo "NO_PLAN $PLAN"; exit 4; }
command -v node >/dev/null 2>&1 || { echo "NODE_REQUIRED"; exit 4; }
ensure_tmp

# 페이로드 경로는 결정적이다(모델이 deploy.sh 에 그대로 적을 수 있게). 이름은 안전문자만 허용.
SAFE_NAME="$(printf '%s' "$NAME" | tr -cd 'A-Za-z0-9._-')"
OUT="$TMP_DIR/env.json"
[ -n "$SAFE_NAME" ] && OUT="$TMP_DIR/env-$SAFE_NAME.json"

# 시크릿 파일을 만들기 **전에** git 무시 여부를 확인한다(fail-closed — 커밋 사고 방지).
if ! is_ignored "$OUT"; then echo "ENV_NOT_IGNORED $OUT"; exit 3; fi

ASK="$TMP_DIR/ask.env"
umask 077   # POSIX 에서 0600 생성(Windows/NTFS 는 모드 미적용 — 그래서 폴더 위치·즉시 삭제로 보호한다)
node "$HERE/env-prepare.mjs" --plan "$PLAN" --out "$OUT" "${ENV_ARGS[@]+"${ENV_ARGS[@]}"}" --ask "$ASK"
RC=$?
chmod 600 "$OUT" 2>/dev/null || true
# 채팅으로 받은 값 파일은 **읽은 즉시 삭제**한다(성공/실패 무관 — 잔류 금지).
rm -f "$ASK" 2>/dev/null || true

# 배포 인자 힌트(읽기만 — 값이 아니라 포트/볼륨). 호출측이 deploy.sh 명령을 **리터럴로 고정된 형태**로
# 쓸 수 있게 여기서 대신 읽어준다($(...) 치환이 명령문에 섞이지 않게 → 허용목록 한 줄로 커버 가능).
#   PORT    : 루트 Dockerfile 의 EXPOSE(단일 배포용. 멀티서비스는 services.json 의 port 를 쓴다)
#   VOLUMES : last-verdict.json 의 volumes_plan(있고 [] 아닐 때만 출력)
if [ "$RC" = 0 ]; then
  P="$(grep -iE '^[[:space:]]*EXPOSE' Dockerfile 2>/dev/null | grep -oE '[0-9]+' | head -1)"
  echo "PORT ${P:-3000}"
  V="$(grep -oE '"volumes_plan"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$FDH_DIR/last-verdict.json" 2>/dev/null \
        | sed -E 's/.*:[[:space:]]*(\[[^]]*\]).*/\1/')"
  case "$V" in ''|'[]') : ;; *) echo "VOLUMES $V" ;; esac
fi
exit "$RC"
