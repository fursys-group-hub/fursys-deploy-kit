#!/usr/bin/env bash
# 현재 폴더를 사내 GitHub(fursys-group-hub/<name>) repo 로 등록한다 — 상황 따라 자동.
#   - git 미초기화/커밋 없음 → 초기화 + 첫 커밋
#   - remote origin 이 이미 fursys-group-hub → push 만
#   - remote 없음 → gh 로 비공개 repo 생성 + 연결 + push (gh 없으면 수동 안내)
# 자격증명·토큰을 출력하지 않는다. 회사 코드이므로 항상 private.
#
# 사용: repo-register.sh <name>
#   name : repo 이름(영문 소문자·하이픈). 보통 폴더명.
#
# 출력 첫 줄 코드:
#   REGISTERED <full> <url>  새로 생성·연결·push 완료
#   PUSHED <full>            이미 fursys-group-hub remote → push 만 함
#   NEED_GH <name>           gh 없음 → 웹에서 직접 repo 생성 후 연결 필요(안내)
#   REMOTE_MISMATCH <url>    origin 이 fursys-group-hub 아님(다른 remote) → 사용자 확인 필요
#   NAME_TAKEN <full>        org 에 같은 이름 repo 가 이미 있음(본인 것이 아닐 수 있음)
#   PUSH_FAILED              push 실패(출력 이어서 표시 — 우회/추측 금지)
#   GIT_FAILED               git 초기화/커밋 실패
set -uo pipefail
ORG="fursys-group-hub"
NAME="${1:-}"
[ -z "$NAME" ] && { echo "USAGE repo-register.sh <name>" >&2; exit 2; }
FULL="${ORG}/${NAME}"

# 1) git 저장소 보장 + 최소 1커밋(없으면 push 불가)
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git init -q || { echo "GIT_FAILED"; exit 0; }
fi
if ! git rev-parse HEAD >/dev/null 2>&1; then
  git add -A 2>/dev/null
  # 커밋 식별자가 없으면 첫 커밋이 실패하므로, 없을 때만 로컬 기본값을 설정한다.
  git config user.name  >/dev/null 2>&1 || git config user.name  "fursys"
  git config user.email >/dev/null 2>&1 || git config user.email "noreply@fursys.com"
  git commit -q -m "초기 커밋 (fursys 표준 프로젝트)" 2>/dev/null || { echo "GIT_FAILED"; exit 0; }
fi

# 2) 기존 origin 판정
REMOTE="$(git remote get-url origin 2>/dev/null || echo "")"
if [ -n "$REMOTE" ]; then
  if printf '%s' "$REMOTE" | grep -qi "$ORG"; then
    # 출력을 캡처해 결과 코드를 항상 첫 줄에 둔다(SKILL '첫 줄 코드' 계약).
    if OUT="$(git push -u origin HEAD 2>&1)"; then echo "PUSHED ${FULL}"; else echo "PUSH_FAILED"; printf '%s\n' "$OUT"; fi
    exit 0
  else
    echo "REMOTE_MISMATCH ${REMOTE}"   # 다른 remote 가 이미 연결됨 — 함부로 바꾸지 않는다
    exit 0
  fi
fi

# 3) remote 없음 → gh 로 생성·연결·push
if ! command -v gh >/dev/null 2>&1; then
  echo "NEED_GH ${NAME}"
  exit 0
fi
if gh repo view "$FULL" >/dev/null 2>&1; then
  echo "NAME_TAKEN ${FULL}"   # 이미 존재 — 본인 것인지 사용자 확인 필요
  exit 0
fi
if OUT="$(gh repo create "$FULL" --private --source=. --remote=origin --push 2>&1)"; then
  URL="$(gh repo view "$FULL" --json url --jq .url 2>/dev/null || echo "https://github.com/${FULL}")"
  echo "REGISTERED ${FULL} ${URL}"
else
  echo "PUSH_FAILED"
  printf '%s\n' "$OUT"
fi
