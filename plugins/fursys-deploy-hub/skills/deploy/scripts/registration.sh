#!/usr/bin/env bash
# 배포 전 앱 등록 사전확인: GET /registration?repo=<org/repo>.
# 읽기 전용 조회다 — 부수효과 없음. **강제(게이트)는 여전히 POST /apps 가 한다**(⑥).
# 이건 "설정값·비밀번호를 다 물어본 뒤에야 미등록으로 막히는" 흐름을 없애기 위한 안내용이며,
# 확인 실패(502·네트워크)는 배포를 막지 않는다(fail-open — 호출측이 그대로 진행한다).
#
# 사용: registration.sh <repo>
#   <repo>: org/repo(예: fursys-group-hub/nps-dashboard) 또는 git URL. proxy 가 정규화한다.
# 출력(stdout): 첫 줄 결과 코드, 이후 줄에 응답 본문(JSON: ok/reason/name/repo_key/build).
#   결과 코드:
#     REGISTERED [앱이름]       200 + ok:true (신청 있음. name 이 null/빈값이면 이름 없이 REGISTERED 만)
#     NOT_REGISTERED            200 + ok:false (신청 없음 — 호출측이 등록 신청 안내 후 멈춘다)
#     CHECK_UNAVAILABLE <code>  502·네트워크 실패·타임아웃·빈 응답 등 **확인 불가**.
#                               미등록과 절대 같이 취급하지 않는다 — 막지 말고 그대로 진행할 것.
#     BAD_REQUEST               400 (호출 인자 문제) — 역시 막지 않는다.
#   ※ exit code 는 항상 0. 판정은 첫 줄로만 한다.
# 무인증(배포 키 제거) — 인증 헤더 없이 조회한다.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"
# common.sh 가 'set -euo pipefail' 로 errexit 를 켜므로, 이 스크립트의 선언 모드(set -uo, errexit 미사용)를
# 복원한다(deploy.sh 와 동일). 안 그러면 errexit 가 새어 들어와, 의도적으로 실패를 허용하는 줄(curl·grep·sed
# 의 '|| true' 가드)이 파이프 중간 실패로 조기 종료될 수 있다. 이 스크립트는 rc·분기로 직접 제어하므로
# errexit 를 끈다.
set +e

REPO="${1:-}"
if [ -z "$REPO" ]; then
  echo "USAGE registration.sh <repo>" >&2
  exit 2
fi

fdh_resolve_url || true

# repo 에는 '/'(org/repo)나 git URL 이 들어오므로 쿼리 인코딩이 필수다.
# --get + --data-urlencode 로 curl 이 직접 인코딩하게 한다(수동 조립 금지).
RESP="$(curl -sS -w $'\n%{http_code}' --get --data-urlencode "repo=$REPO" "$PROXY_URL/registration" \
  2>/dev/null || true)"
HTTP="$(printf '%s' "$RESP" | tail -n1)"
JSON="$(printf '%s' "$RESP" | sed '$d')"

case "$HTTP" in
  200)
    # 등록/미등록 모두 200 이다(미등록은 에러가 아니라 조회 결과). ok 로만 가른다.
    OK_TRUE="$(printf '%s' "$JSON" | { grep -oE '"ok"[[:space:]]*:[[:space:]]*true' || true; } | head -n1)"
    OK_FALSE="$(printf '%s' "$JSON" | { grep -oE '"ok"[[:space:]]*:[[:space:]]*false' || true; } | head -n1)"
    if [ -n "$OK_TRUE" ]; then
      # name 이 null 이면 문자열 매치가 안 잡혀 빈 값이 된다 → 이름 없이 REGISTERED 만 출력.
      NAME="$(printf '%s' "$JSON" | { grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*"' || true; } | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
      if [ -n "$NAME" ]; then printf 'REGISTERED %s\n' "$NAME"; else echo "REGISTERED"; fi
    elif [ -n "$OK_FALSE" ]; then
      echo "NOT_REGISTERED"
    else
      # 200 인데 ok 가 없다(빈 본문·예상 밖 응답) → 판정 불가. 미등록으로 단정하지 않는다.
      echo "CHECK_UNAVAILABLE 200"
    fi
    printf '%s\n' "$JSON"
    ;;
  400) echo "BAD_REQUEST"; printf '%s\n' "$JSON" ;;
  502) echo "CHECK_UNAVAILABLE 502"; printf '%s\n' "$JSON" ;;
  *)   echo "CHECK_UNAVAILABLE ${HTTP:-000}"; [ -n "$JSON" ] && printf '%s\n' "$JSON" ;;
esac
exit 0
