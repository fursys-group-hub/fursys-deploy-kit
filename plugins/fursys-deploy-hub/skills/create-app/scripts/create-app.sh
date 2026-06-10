#!/usr/bin/env bash
# 사내 표준 새 프로젝트 생성: create-app 을 비대화 플래그로 실행.
# 대화형(옵션 없는) 실행은 비-TTY 셸에서 ERR_TTY_INIT_FAILED 로 크래시하므로 절대 금지.
# 이 스크립트는 항상 --type 과 fgdw 플래그를 모두 받아 비대화로 실행한다.
#
# 사용: create-app.sh <name> <type> <fgdw_flag>
#   name      : 프로젝트 이름 (영문 소문자·하이픈, 예: iloom-event)
#   type      : web-next | data-fastapi | dashboard-vite
#   fgdw_flag : --fgdw | --no-fgdw
#
# 출력(stdout): 첫 줄 결과 코드, 이후 create-app 출력.
#   SCAFFOLD_OK <name>     생성 성공
#   BAD_TYPE               type 값이 허용 목록 밖
#   BAD_FGDW               fgdw 플래그가 --fgdw/--no-fgdw 아님
#   SCAFFOLD_FAILED        create-app 실패(출력 이어서 표시 — 우회/추측 금지)
set -uo pipefail

NAME="${1:-}"; TYPE="${2:-}"; FGDW="${3:-}"
if [ -z "$NAME" ] || [ -z "$TYPE" ] || [ -z "$FGDW" ]; then
  echo "USAGE create-app.sh <name> <web-next|data-fastapi|dashboard-vite> <--fgdw|--no-fgdw>" >&2
  exit 2
fi

case "$TYPE" in
  web-next|data-fastapi|dashboard-vite) ;;
  *) echo "BAD_TYPE"; exit 0 ;;
esac
case "$FGDW" in
  --fgdw|--no-fgdw) ;;
  *) echo "BAD_FGDW"; exit 0 ;;
esac

# 비대화: --type 과 fgdw 플래그를 모두 넘겨 create-app 이 되묻지 않게 한다.
# --no-install / --no-git 은 넣지 않는다(실사용자에겐 설치·git 초기화가 정상으로 끝나야 함).
if OUT="$(npx @fursys/create-app@latest "$NAME" --type="$TYPE" "$FGDW" 2>&1)"; then
  echo "SCAFFOLD_OK $NAME"
  printf '%s\n' "$OUT"
else
  echo "SCAFFOLD_FAILED"
  printf '%s\n' "$OUT"
fi
