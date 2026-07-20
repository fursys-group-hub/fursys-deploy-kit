#!/usr/bin/env bash
# 배포 전 검토 리포트(.md) 렌더러 (토큰 절감 + 이중 저작 제거).
# LLM 이 고정 문구(섹션 제목·안내문) 전체를 다시 출력하지 않고, "동적 조각(placeholder 값)"만 담은
# values 파일을 만들면, 이 스크립트가 번들 .md 템플릿의 {{KEY}} 자리에 끼워넣어 완성한다.
# 결과 .md 는 LLM 이 직접 채우던 것과 동일(템플릿 고정 바이트는 손대지 않음).
#
# (구버전 render-report.sh 의 HTML 렌더 메커니즘과 동일 — index()/substr() 리터럴 치환.
#  다른 점은 ① 기본 템플릿이 assets/report-template.md, ② 출력이 .md, 그뿐이다.)
#
# 사용: render-report-md.sh <values_file> <output_md> [template_path]
#   values_file  : 아래 형식의 placeholder 값 파일(LLM 이 Write 로 생성).
#   output_md    : 완성된 리포트 저장 경로(상위 폴더는 자동 생성). 예: .fursys-deploy-hub/security-report-<TS>.md
#   template_path: (선택) 기본은 번들 assets/report-template.md.
#
# values 파일 형식 — 각 placeholder 블록을 구분선으로 나눈다(특수문자 escape 불필요):
#   @@@FDH:META_LIST@@@
#   - **대상 폴더:** `D:\...\my-app`
#   ...여러 줄 가능...
#   @@@FDH:SECURITY_BADGE@@@
#   통과 ✅
#   @@@FDH:END@@@
# - 구분선은 정확히 `@@@FDH:KEY@@@` 한 줄. 마지막은 `@@@FDH:END@@@`(생략해도 됨).
# - 정의되지 않은 placeholder 는 빈 값으로 채운다(예: 문제 없으면 *_PROMPTS 생략 가능).
#
# 출력(stdout): 첫 줄 결과 코드.
#   RENDERED <path>     성공
#   NO_VALUES           values 파일 없음/빈 값
#   NO_TEMPLATE         템플릿 못 찾음
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VALUES="${1:-}"
OUT="${2:-}"
TEMPLATE="${3:-$HERE/../assets/report-template.md}"

if [ -z "$VALUES" ] || [ -z "$OUT" ]; then
  echo "USAGE: render-report-md.sh <values_file> <output_md> [template_path]" >&2
  exit 2
fi
if [ ! -s "$VALUES" ]; then
  echo "NO_VALUES"
  exit 1
fi
if [ ! -f "$TEMPLATE" ]; then
  echo "NO_TEMPLATE"
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

# 1패스: values 파일을 읽어 placeholder 블록을 모으고
# 2패스: 템플릿의 {{KEY}} 토큰을 리터럴(정규식 아님)로 치환한다.
#   - index()/substr() 만 사용 → &, \, 줄바꿈 등 특수문자를 안전하게 보존.
awk -v values="$VALUES" '
function render(line,    res, p, rest, q, key) {
  res = ""
  while ((p = index(line, "{{")) > 0) {
    res = res substr(line, 1, p - 1)
    rest = substr(line, p + 2)
    q = index(rest, "}}")
    if (q == 0) { res = res "{{"; line = rest; continue }
    key = substr(rest, 1, q - 1)
    if (key in V) res = res V[key]
    else res = res "{{" key "}}"      # 미정의 토큰은 원형 유지(눈에 띄게)
    line = substr(rest, q + 2)
  }
  return res line
}
BEGIN {
  cur = ""
  # --- 1패스: values 파일 파싱 ---
  while ((getline ln < values) > 0) {
    if (ln ~ /^@@@FDH:.*@@@$/) {
      k = ln
      sub(/^@@@FDH:/, "", k)
      sub(/@@@$/, "", k)
      if (k == "END") { cur = ""; continue }
      cur = k
      if (!(cur in V)) V[cur] = ""   # 빈 블록도 정의로 인정
      continue
    }
    if (cur != "") {
      V[cur] = (V[cur] == "" ? ln : V[cur] "\n" ln)
    }
  }
  close(values)
}
# --- 2패스: 템플릿 stdin 라인별 치환 ---
# 선두 HTML 주석(유지보수용 템플릿 설명)은 렌더 .md 에 넣지 않는다 — .md 는 사용자 채팅에 그대로 보이므로.
NR == 1 && $0 ~ /^[[:space:]]*<!--/ { skip = 1 }
skip { if ($0 ~ /-->/) skip = 0; next }
{ print render($0) }
' "$TEMPLATE" > "$OUT"

echo "RENDERED $OUT"
