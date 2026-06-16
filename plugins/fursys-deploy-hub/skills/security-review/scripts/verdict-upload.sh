#!/usr/bin/env bash
# 검토 결과 등록: POST /verdict (board 에 구조화 저장 → 서버사이드 배포 게이트의 진실원).
# HTML 리포트 본체는 보내지 않는다(구조화 데이터만). 비밀값(키)은 echo 금지.
#
# 사용: verdict-upload.sh <repo> <commit>
#   body(JSON)는 표준입력(stdin)으로 받는다 — 엔진 JSON 값을 그대로 실은 VerdictBody.
#   필수: repo, commit, security, deployable, final, summary
#   선택: framework, findings(마스킹된 형태만), env_vars([{name,class}]), engine_verdict
#   stdin 예:
#     {"repo":"...","commit":"...","security":"pass","deployable":true,"final":"ok",
#      "summary":{"critical":0,"high":0,"medium":1,"low":2},
#      "env_vars":[{"name":"DATABASE_URL","class":"locked"}]}
#   (repo/commit 인자는 검증·로깅용. body 안에도 들어 있어야 한다.)
#
# 출력(stdout): 첫 줄 결과 코드.
#   STORED             200 {"stored":true} → 등록 성공
#   NO_KEY             키 없음 → 등록 건너뜀(검사 자체는 멈추지 않음)
#   NO_COMMIT          commit 인자 없음 → 등록 생략(게이트가 commit 단위)
#   UNAUTHORIZED       401 invalid_key
#   UPLOAD_FAILED <c>  기타/네트워크 실패 → 배포 때 재시도
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

REPO="${1:-}"; COMMIT="${2:-}"
if [ -z "$COMMIT" ]; then
  echo "NO_COMMIT"
  exit 0
fi

BODY="$(cat 2>/dev/null || true)"
if [ -z "$BODY" ]; then
  echo "USAGE: pipe VerdictBody JSON to stdin. verdict-upload.sh <repo> <commit>" >&2
  exit 2
fi

# JSON 내 역슬래시(\\) → 슬래시(/) 정규화.
# Windows에서 fdh-engine이 경로를 역슬래시로 출력하면 프록시 입력 검증에 걸려 400 발생.
# JSON의 \\는 항상 리터럴 역슬래시이므로 /로 치환해도 \n·\t·\" 등 이스케이프는 영향 없음.
BODY="$(printf '%s' "$BODY" | sed 's/\\\\/\//g')"

fdh_resolve_url || true
if ! fdh_load_key; then
  echo "NO_KEY"
  exit 0
fi

RESP="$(curl -sS -w $'\n%{http_code}' -X POST "$PROXY_URL/verdict" \
  -H "X-Proxy-Key: $KEY" -H "Content-Type: application/json" \
  -d "$BODY" 2>/dev/null || true)"
HTTP="$(printf '%s' "$RESP" | tail -n1)"

case "$HTTP" in
  200) echo "STORED" ;;
  401) echo "UNAUTHORIZED" ;;
  *)
    echo "UPLOAD_FAILED $HTTP"
    # 응답 본문(원인 detail)도 출력 — 서버 500 등의 진짜 원인 진단용(키/시크릿 미포함).
    printf '%s\n' "$(printf '%s' "$RESP" | sed '$d')"
    ;;
esac
