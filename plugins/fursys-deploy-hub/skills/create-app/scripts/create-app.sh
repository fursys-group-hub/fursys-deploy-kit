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
  # 사용자 노출 완료 메시지를 스크립트가 직접 조립한다(모델은 ===SHOW===~===END=== 사이를 그대로 보여주기만 함 → 모델별 편차 제거).
  # 빌드 원시출력($OUT)은 사용자에게 노출하지 않는다(예: .env 기술 안내를 모델이 임의로 끌어오던 문제 차단).
  case "$TYPE" in
    web-next)       KIND="웹 서비스" ;;
    data-fastapi)   KIND="데이터 분석" ;;
    dashboard-vite) KIND="경량 대시보드" ;;
  esac
  DEST="$(pwd)/$NAME"
  if [ "$FGDW" = "--fgdw" ]; then
    FGDW_LINE="- 회사 데이터 창고(fgdw): 연결됨 (읽기 전용 — 자료를 조회해서 보여주기만 가능, 저장·수정은 안 돼요)"
    FGDW_NOTE=$'\n\n> ⚠️ **fgdw 연결 계정:** DATALink에서 발급받은 아이디와 패스워드 설정은 각자 진행해주세요. (프로젝트의 `.env` 파일에 본인 계정을 입력하면 돼요 — 파일에 안내가 적혀 있고, 배포 시 공용계정으로 자동 치환돼요.)'
  else
    FGDW_LINE="- 회사 데이터 창고(fgdw): 연결 안 함"
    FGDW_NOTE=""
  fi
  # DB 안내는 type 에 따라 분기한다. dashboard-vite 는 nginx 정적이라 서버 런타임이 없어
  # DB 를 붙일 수 없다(붙이려면 웹 서비스로 새로 만들어야 함). 나머지는 백엔드가 있어 별도 DB 추가가 가능.
  if [ "$TYPE" = "dashboard-vite" ]; then
    DB_NOTE="> 💡 이 종류는 화면만 보여주는 정적 앱이라 자료 저장·DB는 붙일 수 없어요. 나중에 입력을 기록·조회해야 한다면 \`/create-app\` 으로 '웹 서비스'를 새로 만들어 주세요(그쪽은 DB를 붙일 수 있어요)."
  else
    DB_NOTE=$'> 💡 만약 자료를 저장·수정해야 한다면(예: 사용자 입력을 기록), 회사 데이터 창고(fgdw)는 읽기 전용이라 안 돼요. 별도 DB가 필요하고, 만든 뒤 이 가이드를 보고 추가하면 돼요 →\n> https://ai-library.hub.fursys.com/guides/data-db/overview'
  fi
  cat <<EOF
===SHOW===
✅ 새 프로젝트가 만들어졌어요!

**만들어진 위치**

\`${DEST}\`
- 종류: ${KIND}
${FGDW_LINE}${FGDW_NOTE}

**이제 이런 순서로 진행하시면 돼요**

1. **회사 GitHub 연결** — "깃허브 연결해줘"(또는 \`/github-setup\`)라고 하시면, 회사 GitHub 연결을 확인하고(미가입이면 신청을 돕고) 이 프로젝트를 올릴 수 있게 등록해 드려요. (배포의 전제 — 코드가 회사 GitHub에 있어야 올릴 수 있어요.)
2. **개발** — 만들어진 \`${NAME}\` 폴더에서 원하는 화면·기능을 만들어요.
3. **배포 전 검토** — 올리기 전에 "배포 전 검토 해줘"(또는 \`/deploy-check\`)라고 하시면 점검 리포트를 채팅에 바로 보여드려요. 문제가 나오면 "\`/deploy-fix\`"라고 하시면 확인 후 자동으로 고쳐드려요.
4. **배포** — "사내 서버에 올려줘"(또는 \`/deploy\`)라고 하시면 주소 앞부분만 정해서 처음 한 번 올라가요. 이후 수정은 그냥 저장하면 자동으로 다시 올라가요.

${DB_NOTE}

다음으로 무엇을 도와드릴까요? 😊
===END===
EOF
else
  echo "SCAFFOLD_FAILED"
  printf '%s\n' "$OUT"
fi
