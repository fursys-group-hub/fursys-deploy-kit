#!/usr/bin/env bash
# 등록 본문(VerdictBody) "기계 조립" — LLM 이 JSON 을 손으로 쓰지 않게 한다.
# 목적: findings[].message/aiPrompt·file 등 한글·따옴표(")·역슬래시(\)·줄바꿈이 섞인 위험한 값을
#   사람이 JSON 리터럴에 박아넣다 이스케이프를 틀려 깨뜨리던 문제(#5)와 필수필드 누락(#4)을
#   원천 차단한다. 위험한 값은 전부 엔진 JSON(이미 유효)에서 직렬화기로 그대로 싣고,
#   사람이 넘기는 건 작은 스칼라(repo/commit/security/deployable/final)뿐이다.
#
# 사용: verdict-build.sh <engine-json-path> <repo> <commit> <security> <deployable> <final> [--report-data <path>]
#   <engine-json-path> : 5-2 직전에 저장해 둔 엔진 출력 JSON 파일(예: .fursys-deploy-hub/_engine.json)
#   <deployable>       : "true" | "false"
#   <security>         : "pass" | "caution" | "blocked"   (LLM 심화 반영한 최종 보안 축)
#   <final>            : "ok" | "blocked"
#   --report-data <path> : (선택) 엔진에 없는 LLM/배포준비 산출물 JSON(예: .fursys-deploy-hub/_report-data.json).
#                          있으면 본문 report_data 키로 함께 싣는다 → 등록 성공 시 board 가 추측 불가 토큰 URL 발급.
#                          파일이 없거나 비었거나 JSON 이 깨지면 무시하고 report_data 없이 진행(=구버전 동작, stderr 경고).
#                          report_data 는 LLM 산출물(배지/최종라인/owaspFindings/deployChecks/prompts/envNotes)이며,
#                          엔진 파트(summary/findings/env_vars/engine_verdict)는 절대 다시 싣지 않는다(중복 금지).
# 출력(stdout): 유효한 VerdictBody JSON 한 줄. 이걸 그대로 verdict-upload.sh 의 stdin 으로 넘긴다.
#   실패 시 stderr 에 사유, exit!=0 (이때 등록을 건너뛴다).
set -uo pipefail

# 위치 인자(6개)와 옵션(--report-data)을 섞어 받는다 — 옵션은 위치 인자 뒤에 와도/사이에 와도 동작.
REPORT_DATA=""
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --report-data) REPORT_DATA="${2:-}"; shift 2 ;;
    --report-data=*) REPORT_DATA="${1#--report-data=}"; shift ;;
    *) POS+=("$1"); shift ;;
  esac
done
set -- "${POS[@]:-}"

ENGINE="${1:-}"; REPO="${2:-}"; COMMIT="${3:-}"
SECURITY="${4:-}"; DEPLOYABLE="${5:-}"; FINAL="${6:-}"

if [ -z "$ENGINE" ] || [ -z "$REPO" ] || [ -z "$COMMIT" ] || [ -z "$SECURITY" ] || [ -z "$DEPLOYABLE" ] || [ -z "$FINAL" ]; then
  echo "USAGE: verdict-build.sh <engine-json> <repo> <commit> <security> <deployable:true|false> <final> [--report-data <path>]" >&2
  exit 2
fi
[ -f "$ENGINE" ] || { echo "ENGINE_NOT_FOUND: $ENGINE" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "NODE_REQUIRED" >&2; exit 1; }

# report-data 파일이 지정됐지만 없거나 비면 경고만 하고 무시(등록은 막지 않는다).
if [ -n "$REPORT_DATA" ]; then
  if [ ! -f "$REPORT_DATA" ] || [ ! -s "$REPORT_DATA" ]; then
    echo "REPORT_DATA_SKIPPED: 파일이 없거나 비어 report_data 없이 진행합니다($REPORT_DATA)" >&2
    REPORT_DATA=""
  fi
fi

# 엔진 JSON(위험한 값 포함)은 node 가 읽어 직렬화기로 본문에 싣는다 — 사람이 안 건드린다.
# 스칼라는 argv 로 안전하게 전달. 출력은 JSON.stringify 산물이라 항상 유효 JSON.
# report_data 도 별도 파일에서 node 가 읽어 싣는다(LLM 이 손으로 본문에 박지 않게 — #5 원칙).
#   깨진 report_data 는 등록 자체를 막지 않도록 무시하고 진행(stderr 경고).
node -e '
const fs = require("fs");
const [enginePath, repo, commit, security, deployableStr, final, reportDataPath] = process.argv.slice(1);
let eng;
try { eng = JSON.parse(fs.readFileSync(enginePath, "utf8")); }
catch (e) { console.error("ENGINE_PARSE_FAIL: " + e.message); process.exit(1); }
const body = {
  repo,
  commit,
  security,
  deployable: deployableStr === "true",
  final,
  summary: (eng.summary && typeof eng.summary === "object") ? eng.summary : { critical: 0, high: 0, medium: 0, low: 0 },
};
if (eng.target && eng.target.framework) body.framework = eng.target.framework;
if (Array.isArray(eng.findings) && eng.findings.length) body.findings = eng.findings;       // 엔진 마스킹 형태 그대로
if (Array.isArray(eng.envVars) && eng.envVars.length) body.env_vars = eng.envVars.map(v => ({ name: v.name, class: v.class }));
body.engine_verdict = eng;                                                                   // 감사·재현용 원본
// report_data: 엔진에 없는 LLM/배포준비 산출물. 깨지면 무시(등록은 진행).
if (reportDataPath) {
  try {
    const rd = JSON.parse(fs.readFileSync(reportDataPath, "utf8"));
    if (rd && typeof rd === "object" && !Array.isArray(rd)) body.report_data = rd;
    else console.error("REPORT_DATA_IGNORED: JSON 이 객체가 아니라 무시합니다");
  } catch (e) {
    console.error("REPORT_DATA_IGNORED: " + e.message + " (report_data 없이 진행)");
  }
}
process.stdout.write(JSON.stringify(body));
' "$ENGINE" "$REPO" "$COMMIT" "$SECURITY" "$DEPLOYABLE" "$FINAL" "$REPORT_DATA"
