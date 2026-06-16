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

# 변환 결과 수용 판정: ① 비어있지 않고 ② '{' 로 시작(고장난 python 스텁의 'Python ...' 출력 배제)
#   ③ 비ASCII 바이트(0x80~0xFF)가 하나도 없음. 변환은 JSON 직렬화기(node/python)로만 하므로,
#   이 셋을 통과하면 곧 "유효한 ASCII-only JSON" 이다(직렬화기 산물이라 구조가 보장됨).
# (Windows Git Bash 의 python3 는 흔히 작동 안 하는 MS Store 스텁 → exit0+쓰레기 출력일 수 있어 검증 필수.)
_fdh_ascii_ok() {
  [ -n "$1" ] || return 1
  case "$1" in "{"*) ;; *) return 1 ;; esac
  [ "$(printf '%s' "$1" | LC_ALL=C tr -cd '\200-\377' | wc -c | tr -d ' ')" = "0" ]
}

# 본문을 "유효한 ASCII-only JSON" 으로 정규화한다(비ASCII: 한글·한자 등 → \uXXXX).
# 배경: 사내 ingress/WAF 가 3바이트 UTF-8 시퀀스를 깨뜨려 proxy 의 request.json() 이 실패 → 400.
#   본문에 비ASCII 바이트가 없으면 깨질 게 없어 통과(실측 STORED).
# 반드시 JSON 파서를 거치는 도구(node→python)만 쓴다: 출력이 JSON.parse→stringify 산물이라 구조
#   유효성이 보장되고, 백슬래시(\" \\ \n 등)도 직렬화기가 정확히 처리한다. Claude Code 는 Node
#   런타임 위에서 동작하므로 node 는 사실상 항상 존재 → node 우선. 매번 _fdh_ascii_ok 로 재검증.
# (구버전의 sed 's/\\\\/\//g' 백슬래시 치환과 perl 정규식 이스케이프는 이 환경에서 정상 JSON
#   이스케이프 \" 를 /" 로 부수거나 \u 접두를 흘려 깨진 본문을 만들었음 → 둘 다 제거.)
fdh_to_ascii() {
  local s="$1" out
  if command -v node >/dev/null 2>&1; then
    out="$(printf '%s' "$s" | node -e 'let d="";process.stdin.setEncoding("utf8");process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const s=JSON.stringify(JSON.parse(d));let out="";for(let i=0;i<s.length;i++){const n=s.charCodeAt(i);out+=n>127?"\\u"+n.toString(16).padStart(4,"0"):s[i];}process.stdout.write(out);}catch(e){}})' 2>/dev/null)"
    if _fdh_ascii_ok "$out"; then printf '%s' "$out"; return 0; fi
  fi
  # python 은 stdin 을 반드시 UTF-8 로 디코딩(Windows 기본 stdin cp949 회피). json.dumps 의 ensure_ascii 기본값이 \uXXXX.
  if command -v python3 >/dev/null 2>&1; then
    out="$(printf '%s' "$s" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(json.loads(sys.stdin.buffer.read().decode("utf-8"))))' 2>/dev/null)"
    if _fdh_ascii_ok "$out"; then printf '%s' "$out"; return 0; fi
  fi
  if command -v python >/dev/null 2>&1; then
    out="$(printf '%s' "$s" | python -c 'import json,sys; sys.stdout.write(json.dumps(json.loads(sys.stdin.buffer.read().decode("utf-8"))))' 2>/dev/null)"
    if _fdh_ascii_ok "$out"; then printf '%s' "$out"; return 0; fi
  fi
  # 도구가 전무하면 원문 그대로(최선노력). 비ASCII 가 있으면 400 가능하나 더 나빠지진 않는다.
  printf '%s' "$s"
}

# 전송 직전 사전검증 — 서버(proxy /verdict) 게이트와 "똑같은" 조건만 본다.
#   서버는 repo·commit·security·final 이 비었거나, deployable 이 null 이거나, summary 가
#   객체가 아니면 거부하는데 그것도 401 로 돌려준다(→ 키 문제로 오인하기 쉬움). 같은 조건을
#   여기서 먼저 확인해, 보내봤자 실패할 본문이면 보내지 않고 BAD_BODY 로 정확한 사유를 알린다.
#   효과: 본문 JSON 깨짐·필수필드 누락·잘못된 데이터형을 서버 왕복 없이 로컬에서 잡는다.
#   (서버와 동일 조건만 보므로 멀쩡한 본문을 오거부하지 않는다 — 과검증 금지가 핵심.)
# 인자=body. 통과=exit0, 실패=exit1 + 사유 한 줄(stdout). node 없으면 검증 생략(그대로 통과).
_fdh_validate_body() {
  command -v node >/dev/null 2>&1 || return 0
  printf '%s' "$1" | node -e 'let d="";process.stdin.setEncoding("utf8");process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{let o;try{o=JSON.parse(d)}catch(e){console.log("본문 JSON 형식이 깨짐");process.exit(1)}const miss=[];for(const k of ["repo","commit","security","final"])if(!o[k])miss.push(k);if(o.deployable===undefined||o.deployable===null)miss.push("deployable");if(typeof o.summary!=="object"||o.summary===null||Array.isArray(o.summary))miss.push("summary");if(miss.length){console.log("필수값 누락/형식오류: "+miss.join(", "));process.exit(1)}process.exit(0)})'
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

# 전송 직전 본문 정규화: 비ASCII(한글 등)를 \uXXXX 로 바꿔 유효한 ASCII-only JSON 으로 만든다.
#   사내 프록시 앞단 인프라가 3바이트 UTF-8 을 깨뜨려 raw 한글 본문이 400 을 유발하기 때문.
#   (백슬래시 치환은 정상 JSON 이스케이프 \" 를 부수므로 하지 않는다 — fdh_to_ascii 주석 참조.)
BODY="$(fdh_to_ascii "$BODY")"

fdh_resolve_url || true
if ! fdh_load_key; then
  echo "NO_KEY"
  exit 0
fi

# 사전검증(서버 게이트와 동일): 실패하면 보내지 않고 정확한 사유를 알린다(서버 왕복·401 오진단 방지).
if ! REASON="$(_fdh_validate_body "$BODY")"; then
  echo "BAD_BODY ${REASON}"
  exit 0
fi

# 본문은 인자(-d)가 아니라 stdin(--data-binary @-)으로 넘긴다:
#   Windows 자식 프로세스 명령행 길이 한계(약 32K)를 우회 — findings 많은 큰 verdict 도 안전.
#   --data-binary 는 개행/@ 해석 없이 바이트 그대로 전송. 타임아웃으로 네트워크 무한 대기(행) 방지.
RESP="$(printf '%s' "$BODY" | curl -sS -w $'\n%{http_code}' \
  --connect-timeout 10 --max-time 30 \
  -X POST "$PROXY_URL/verdict" \
  -H "X-Proxy-Key: $KEY" -H "Content-Type: application/json" \
  --data-binary @- 2>/dev/null || true)"
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
