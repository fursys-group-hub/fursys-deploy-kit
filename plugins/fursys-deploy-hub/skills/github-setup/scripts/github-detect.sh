#!/usr/bin/env bash
# 사내 GitHub(fursys-group-hub) 연결 상태 감지. gh CLI 우선, 없으면 git remote 로 추정.
# 토큰·자격증명을 출력하거나 파일에 쓰지 않는다(상태만 판정).
#
# 출력(stdout) 첫 줄 = 상태 코드:
#   CONNECTED <username>   gh 인증 + fursys-group-hub 정식 멤버(active)         → repo 등록 진행
#   PENDING <username>     gh 인증 + 멤버십 '대기'(초대 수락 전/신청 후 대기)    → 수락 안내
#   NO_ORG <username>      gh 인증됐으나 fursys-group-hub 멤버 아님              → 가입 신청
#   NO_AUTH                gh 있으나 GitHub 로그인 안 됨                          → 로그인+가입 안내
#   NO_GH_GIT_OK           gh 없음 + 현재 폴더 remote 가 fursys-group-hub(연결 추정) → repo 등록(push) 진행
#   NO_GH                  gh 없음 + git 으로도 연결 확인 불가                    → 가입 신청 안내
set -uo pipefail
ORG="fursys-group-hub"

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    USER="$(gh api user --jq .login 2>/dev/null || echo "")"
    STATE="$(gh api "user/memberships/orgs/${ORG}" --jq .state 2>/dev/null || echo "")"
    case "$STATE" in
      active)  echo "CONNECTED ${USER}" ;;
      pending) echo "PENDING ${USER}" ;;
      *)       echo "NO_ORG ${USER}" ;;
    esac
  else
    echo "NO_AUTH"
  fi
else
  REMOTE="$(git remote get-url origin 2>/dev/null || echo "")"
  if printf '%s' "$REMOTE" | grep -qi "$ORG"; then
    echo "NO_GH_GIT_OK"
  else
    echo "NO_GH"
  fi
fi
