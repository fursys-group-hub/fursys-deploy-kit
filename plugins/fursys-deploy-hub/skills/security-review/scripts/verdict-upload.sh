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

# 변환 결과 수용 판정: ① 비어있지 않고 ② JSON 오브젝트로 시작('{', 고장난 python 스텁의
#   'Python ...' 출력 배제) ③ 서버를 깨는 3바이트 UTF-8 lead byte(0o340~0o357 = 0xE0~0xEF)가 0개.
# (Windows Git Bash 의 python3 는 흔히 작동 안 하는 MS Store 스텁 → exit0+쓰레기 출력일 수 있어 검증 필수.)
_fdh_ascii_ok() {
  [ -n "$1" ] || return 1
  case "$1" in "{"*) ;; *) return 1 ;; esac
  [ "$(printf '%s' "$1" | LC_ALL=C tr -cd '\340-\357' | wc -c | tr -d ' ')" = "0" ]
}

# 비ASCII(특히 3바이트 UTF-8: 한글·한자·€ 등 U+0800~U+FFFF)를 \uXXXX 로 이스케이프.
# 배경: 사내 ingress/WAF 가 3바이트 UTF-8 lead byte 시퀀스를 깨뜨려, proxy 의 request.json() 이
#   UnicodeDecodeError → proxy 가 400 invalid_request 반환(2·4바이트는 통과). 엔진 findings[].message
#   등이 한글이라 매번 재현. 본문을 ASCII 로 보내면 깨질 3바이트가 없어 통과(실측 STORED).
# 도구를 신뢰도 순(perl→node→python)으로 시도하되 매번 _fdh_ascii_ok 로 검증 — 통과한 것만 채택,
# 모두 실패하면 원문 그대로(최선노력; 서버 인프라가 고쳐지면 raw 도 통과).
fdh_to_ascii() {
  local s="$1" out
  if command -v perl >/dev/null 2>&1; then
    # BMP 비ASCII(U+0080~U+FFFF)만 \uXXXX 로. 4바이트(astral, >U+FFFF)는 raw 로 통과(서버가 4바이트는 받음).
    out="$(printf '%s' "$s" | perl -CSD -pe 's/([\x{80}-\x{ffff}])/sprintf("\\u%04x",ord($1))/ge' 2>/dev/null)"
    if _fdh_ascii_ok "$out"; then printf '%s' "$out"; return 0; fi
  fi
  if command -v node >/dev/null 2>&1; then
    out="$(printf '%s' "$s" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{process.stdout.write(JSON.stringify(JSON.parse(d)).replace(/[\s\S]/g,c=>{const n=c.charCodeAt(0);return n>127?"\\u"+n.toString(16).padStart(4,"0"):c}))}catch(e){}})' 2>/dev/null)"
    if _fdh_ascii_ok "$out"; then printf '%s' "$out"; return 0; fi
  fi
  # python 은 stdin 을 반드시 UTF-8 로 디코딩(Windows 기본 stdin 인코딩 cp949 회피).
  if command -v python3 >/dev/null 2>&1; then
    out="$(printf '%s' "$s" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(json.loads(sys.stdin.buffer.read().decode("utf-8"))))' 2>/dev/null)"
    if _fdh_ascii_ok "$out"; then printf '%s' "$out"; return 0; fi
  fi
  if command -v python >/dev/null 2>&1; then
    out="$(printf '%s' "$s" | python -c 'import json,sys; sys.stdout.write(json.dumps(json.loads(sys.stdin.buffer.read().decode("utf-8"))))' 2>/dev/null)"
    if _fdh_ascii_ok "$out"; then printf '%s' "$out"; return 0; fi
  fi
  printf '%s' "$s"
}

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

# 전송 직전 본문 정규화 (사내 프록시 앞단 인프라의 입력 검증 우회 — 두 트리거):
# 1) 역슬래시(\\) → 슬래시(/): Windows 경로(fdh-engine 출력)가 역슬래시면 400.
#    JSON 의 \\는 항상 리터럴 역슬래시라 /로 치환해도 \n·\t·\" 이스케이프엔 영향 없음.
BODY="$(printf '%s' "$BODY" | sed 's/\\\\/\//g')"
# 2) 3바이트 UTF-8(한글 등) → \uXXXX: raw 로 보내면 400(위 fdh_to_ascii 주석 참조).
BODY="$(fdh_to_ascii "$BODY")"

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
