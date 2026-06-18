#!/usr/bin/env bash
# 현재 폴더를 사내 GitHub(fursys-group-hub/<name>) repo 로 등록한다 — 상황 따라 자동.
#   - git 미초기화/커밋 없음 → 초기화 + 첫 커밋
#   - remote origin 이 이미 fursys-group-hub → push 만
#   - remote 없음 → gh 있으면 비공개 repo 생성+연결+push / gh 없으면 org 주소로 push 시도(repo 미생성이면 1회 생성 안내)
# 자격증명·토큰을 출력하지 않는다. 회사 코드이므로 항상 private.
#
# 사용: repo-register.sh <name>
#   name : repo 이름(영문 소문자·하이픈). 보통 폴더명.
#
# 출력 첫 줄 코드:
#   REGISTERED <full> <url>  새로 생성·연결·push 완료
#   PUSHED <full>            이미 fursys-group-hub remote → push 만 함
#   NEED_REPO_CREATE <name> <url>  gh 없음 + repo 미생성 → 미리 채워진 링크로 빈 private repo 1회 생성 후 재실행하면 자동 push
#   REMOTE_MISMATCH <url>    origin 이 fursys-group-hub 아님(다른 remote) → 사용자 확인 필요
#   NAME_TAKEN <full>        org 에 같은 이름 repo 가 이미 있음(본인 것이 아닐 수 있음)
#   PUSH_FAILED              push 실패(출력 이어서 표시 — 우회/추측 금지)
#   GIT_FAILED               git 초기화/커밋 실패
set -uo pipefail
ORG="fursys-group-hub"
NAME="${1:-}"
[ -z "$NAME" ] && { echo "USAGE repo-register.sh <name>" >&2; exit 2; }
FULL="${ORG}/${NAME}"

# 사용자 노출 완료 메시지를 스크립트가 직접 조립한다(모델은 ===SHOW===~===END=== 사이를 그대로 보여주기만 함 → 모델별 편차 제거).
# $1 = repo URL(있으면 링크 표시, 없으면 링크 없이)
emit_done() {
  if [ -n "${1:-}" ]; then HEAD_LINE="🎉 회사 GitHub에 올렸어요: $1"; else HEAD_LINE="🎉 회사 GitHub에 올렸어요."; fi
  cat <<EOF
===SHOW===
${HEAD_LINE}

이제 가장 신나는 단계예요 — **직접 만들어볼 차례!** 💪
만들어진 폴더에서 원하는 화면·기능을 하나씩 붙여 보세요. 처음이라도 괜찮아요, 막히는 부분은 언제든 저에게 말씀해 주시면 같이 해결해요. 응원할게요! 🙌

개발이 어느 정도 되면, 이렇게 올리면 돼요:

1. **배포 전 검토** — "배포 전 검토 해줘"(또는 \`/deploy-check\`)라고 하시면 보안·배포 준비를 점검해 드려요.
2. **배포** — "사내 서버에 올려줘"(또는 \`/deploy\`)라고 하시면 처음 한 번 올려요. 이후 수정은 그냥 저장하면 자동으로 다시 올라가요.
===END===
EOF
}

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
    if OUT="$(git push -u origin HEAD 2>&1)"; then echo "PUSHED ${FULL}"; emit_done "https://github.com/${FULL}"; else echo "PUSH_FAILED"; printf '%s\n' "$OUT"; fi
    exit 0
  else
    echo "REMOTE_MISMATCH ${REMOTE}"   # 다른 remote 가 이미 연결됨 — 함부로 바꾸지 않는다
    exit 0
  fi
fi

# 3) remote 없음
# 3a) gh 없음(브라우저 인증 멤버 등): org 주소로 연결 후 push 시도.
#   성공            → 이미 repo 있고 push 권한 있음(REGISTERED)
#   "not found"     → repo 가 아직 없음 → 빈 repo 1회 생성 안내(NEED_REPO_CREATE). origin 은 정리해 재실행 시 같은 안내가 나오게 한다.
#   그 외(권한 등)  → PUSH_FAILED
if ! command -v gh >/dev/null 2>&1; then
  URL="https://github.com/${FULL}"
  git remote add origin "${URL}.git" 2>/dev/null || git remote set-url origin "${URL}.git"
  if OUT="$(git push -u origin HEAD 2>&1)"; then
    echo "REGISTERED ${FULL} ${URL}"; emit_done "${URL}"
  elif printf '%s' "$OUT" | grep -qiE "not found|does not exist|404"; then
    git remote remove origin 2>/dev/null
    echo "NEED_REPO_CREATE ${NAME} https://github.com/new?owner=${ORG}&name=${NAME}"
  else
    echo "PUSH_FAILED"; printf '%s\n' "$OUT"
  fi
  exit 0
fi
# 3b) gh 있음 → 비공개 repo 생성·연결·push
if gh repo view "$FULL" >/dev/null 2>&1; then
  echo "NAME_TAKEN ${FULL}"   # 이미 존재 — 본인 것인지 사용자 확인 필요
  exit 0
fi
if OUT="$(gh repo create "$FULL" --private --source=. --remote=origin --push 2>&1)"; then
  URL="$(gh repo view "$FULL" --json url --jq .url 2>/dev/null || echo "https://github.com/${FULL}")"
  echo "REGISTERED ${FULL} ${URL}"; emit_done "${URL}"
else
  echo "PUSH_FAILED"
  printf '%s\n' "$OUT"
fi
