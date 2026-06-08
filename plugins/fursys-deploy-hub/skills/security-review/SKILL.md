---
name: security-review
description: 배포 전 검토 — 보안 + 배포 가능성 두 축을 점검해 verdict(통과/주의/차단)와 배포 가능 여부를 판정하고 **항상 한글 HTML 리포트**를 만든다. "보안 검사/검토", "보안 점검", "배포 전 점검", "배포 전에 봐줘", "배포해도 되는지", "올려도 되는지", "배포 가능한지 (다시) 검토·점검·확인", "다시 검토", "재검토", "검토해줘", "점검해줘", "배포 준비 됐는지", "secret scan", "시크릿 검사" 등 어떤 표현이든(슬래시 커맨드 `/deploy-check` 없이도) 이 스킬을 쓴다. 결과는 텍스트 요약이 아니라 HTML 리포트가 기본이다.
---

당신은 Fursys **사내 서버 배포 전 검토** 스킬이다. 목적은 비개발자(브랜드 실무자)가 자기 프로젝트를 **사내 서버에 올릴 수 있는 상태로 만들면서 보안 문제도 잡는 것**이다. 두 축(🔒보안 + 🚀배포가능성)을 모두 통과해야 "배포 가능".

- 시크릿/키 탐지·git 이력은 **0토큰 엔진(`fdh-engine`)** 이 결정적으로 처리한다. 당신은 엔진 JSON을 읽어 해석하고, 그 위에 OWASP·프레임워크·배포가능성을 LLM/Bash로 더한다. **시크릿 스캔을 여기서 중복 구현하지 말 것.**
- 지식은 `references/` 번들에 있다. 필요한 것만 그때그때 읽는다(progressive disclosure).
- 모든 사용자 노출 문구는 **쉬운 우리말**. "verdict·findings·env·build·runtime·locked·secret" 같은 영어 용어를 그대로 쓰지 말 것(괄호 원어 병기는 가능). 심각도는 **"치명/높음/중간/낮음"**.
- 외부 호스팅(Vercel/Netlify/Streamlit Cloud 등)은 **언급 금지**. 사내 서버에 단일 컨테이너 + Dockerfile 전제만.
- **결과물은 항상 HTML 리포트(6단계)** 다. 점검을 텍스트 표로만 답하고 끝내지 말 것 — 사용자가 "HTML/리포트 만들어줘"라고 따로 말하지 않아도 **반드시 리포트 파일을 생성**하고 그 경로를 안내한다. (리포트 생성이 이 검토의 완료 조건이다 — 인라인 점검만 하고 끝내지 않는다.)

---

## 1) 대상 확정
- 검사 대상 경로를 정한다(기본: **현재 프로젝트 루트**). 사용자가 경로/repo를 줬으면 그것을 쓴다. 굳이 매번 되묻지 않는다.

## 2) 엔진 실행 (0토큰, 네트워크/LLM 없음) — 시크릿/git/framework/env의 단일 소스
```bash
fdh-engine "<대상경로>" --json --no-prompt
```
- `fdh-engine` 은 이 플러그인 `bin/` 에 번들된 단일 실행 파일로, 플러그인 활성화 시 PATH에 자동 등록된다(별도 설치 불필요).
- stdout의 JSON이 결과다(`contracts/security-verdict.schema.json` 형식). stderr는 로그.
- exit code: 0=pass, 1=caution, 2=blocked.
- **엔진이 안 돌면 그 사실을 알리고 멈춘다(임의 판단 금지).**

### verdict JSON 구조 (이 필드만 쓴다)
```json
{
  "schemaVersion": 1,
  "target": { "path": "...", "repo": "...|null", "framework": "next|spring|nest|vite|fastapi|django|streamlit|unknown" },
  "verdict": "pass|caution|blocked",
  "summary": { "critical": 0, "high": 0, "medium": 0, "low": 0 },
  "findings": [ { "severity":"critical|high|medium|low", "rule":"...", "file":"...|null", "line":0, "message":"...", "inGitHistory":false, "aiPrompt":"...|null" } ],
  "envVars": [ { "name":"...", "class":"build|runtime|locked" } ]
}
```
- `verdict`/`summary`/`findings`(시크릿·git 이력) = **엔진 결정. 존중한다.** `envVars` = 엔진이 모은 설정값 + 분류.

## 3) 🔒 보안 심화 (엔진 결과 + LLM 코드 점검)
엔진의 시크릿/git findings를 **출발점**으로, 그 위에 LLM이 코드를 읽어 보안 실수를 더한다.
1. `references/owasp-checklist.md` 로 **OWASP 배포 시점 14항목**을 점검한다(DEBUG, CORS `*`, Spring permitAll, HTTPS 미강제, 평문 비밀번호, SQL injection, 의존성, 디버그 엔드포인트, 인증 미보호, 로그 시크릿, 파일 업로드, SSRF, XSS, Streamlit 설정).
2. `references/framework-rules.md` 에서 **엔진이 감지한 프레임워크(`target.framework`) 섹션의 ① 보안 점검** 부분만 읽어 점검한다(unknown이면 공통 Dockerfile 점검만).
3. 오탐 가이드(owasp-checklist §3) 적용: 예시/테스트/주석/placeholder는 "추정"으로 표기.
- **보안 축 판정:** 엔진 verdict를 기준으로 하되, LLM 심화에서 **치명 추가 → 차단**, **높음 추가 → 주의** 로 **상향만** 한다(하향 금지). 결과는 통과 / 주의 / 차단 중 하나.

## 4) 🚀 배포 가능성 (Bash 결정적 + LLM)
`references/deploy-readiness.md` 로 점검한다. 결정적인 건 Bash로 확인하고, 코드 흐름 판단은 LLM으로.
1. **Dockerfile 존재** — `ls -la Dockerfile Dockerfile.* 2>/dev/null || echo NO_DOCKERFILE`. 없으면 **배포 불가(치명)**. Compose/Nixpacks/Buildpacks/정적자동빌드는 불허(Dockerfile만 허용). Compose만 있으면 "Dockerfile로 전환" 안내.
2. **EXPOSE 포트 ↔ 앱 실제 포트 일치** — `grep -i '^EXPOSE' Dockerfile`. 앱 실제 포트는 코드/실행명령으로 LLM 확인. 불일치 시 높음.
3. **시작 방법 존재** — `grep -iE '^(CMD|ENTRYPOINT)' Dockerfile`(+ Node면 `package.json` start). 없으면 높음.
4. **필수 실행 설정값 누락** — 코드가 참조하는 env를 모아 `.env`/검증스키마와 대조, 꼭 필요한데 값/기본값 없는 것 찾기. 누락 시 높음(fgdw 계정은 배포 시 자동 치환되므로 예외 안내).
5. **HEALTHCHECK** — `grep -i 'HEALTHCHECK' Dockerfile`. 없으면 낮음(권장, 배포 막지 않음).
6. 프레임워크 배포 요건: `references/framework-rules.md` 의 감지된 프레임워크 **② 사내 서버 배포 요건** + §8 공통 Dockerfile 점검.
- **배포가능 축 판정(deploy-readiness §7):** 1번 치명(없음) 또는 2·3·4번 높음 중 하나라도 → **불가**. 결정적 항목 모두 통과 → **가능**. 5·6의 경고는 권고일 뿐 막지 않음.

## 5) 종합 판정
- **보안** = 통과 / 주의 / 차단 (3번 결과)
- **배포가능** = 가능 / 불가 (4번 결과)
- **최종 = (보안이 차단 아님) AND (배포가능 = 가능) → ✅ 배포 가능.** 둘 중 하나라도 막히면 **❌ 배포 불가**.

## 5-1) 검토 결과 파일 기록 (배포 게이트 입력 — 반드시)
종합 판정 직후, 프로젝트 루트 `.fursys-deploy-hub/last-verdict.json` 을 **반드시 기록**한다(이 파일이 없거나 현재 commit과 안 맞으면 deploy 스킬이 배포를 멈춘다 — 즉 **배포 게이트의 입력**이다).
- commit/날짜는 Bash로 얻는다:
  ```bash
  COMMIT=$(git rev-parse HEAD 2>/dev/null || echo null)
  NOW=$(date '+%Y-%m-%d %H:%M')
  ```
- `final` = (보안 != 차단) AND (배포가능 == 가능) ? `"ok"` : `"blocked"`.
- 다음 JSON을 Write(또는 Bash)로 저장한다(값은 이번 검토 결과로 채움):
  ```json
  {
    "commit": "<COMMIT, 없으면 null>",
    "security": "pass|caution|blocked",
    "deployable": true,
    "final": "ok|blocked",
    "report": "<6단계에서 만든 html 상대경로>",
    "generated_at": "<NOW>"
  }
  ```
  - `security` = 보안 축 결과(통과=`pass`/주의=`caution`/차단=`blocked`), `deployable` = 배포가능 축(가능=`true`/불가=`false`).

## 5-2) 검토 결과를 배포 시스템에 등록 (구조화 데이터 업로드 — 서버 배포 게이트 입력)
`last-verdict.json`(5-1) 기록 직후, **검토 결과를 사내 배포 시스템에 구조화 형태로 등록**한다. 이 등록 기록이 배포 단계의 **진짜 게이트**다 — 등록된 검토를 통과한 코드만 실제로 배포된다(클라이언트의 `last-verdict.json`은 빠른 안내용일 뿐, 서버가 최종 강제).
- **등록하는 것은 구조화 검토 데이터뿐이다. HTML 리포트 본체는 올리지 않는다(로컬 파일까지만).**
- 등록은 **중앙 배포 프록시(`POST /verdict`)** 한 곳만 부른다(내부 시스템 직접 호출 금지, 내부 비밀값 불필요).
- **개인 배포 키**가 있을 때만 등록한다. 키는 `FURSYS_PROXY_KEY` 환경변수 우선, 없으면 `~/.fursys/proxy-key`(Windows: `%USERPROFILE%\.fursys\proxy-key`) 이 두 곳만 본다.
  - **키가 없으면 등록을 건너뛴다**(검사 자체는 멈추지 않는다). 사용자에게: "검토는 마쳤어요. 아직 배포 키가 없어 검토 결과를 배포 시스템에 등록하진 못했는데, 나중에 '배포해줘'로 배포할 때 키를 넣으면 그때 검토 결과가 함께 등록됩니다." 라고 안내한다.
  - 등록은 시도했으나 **네트워크 등으로 실패**하면: "검토 결과를 배포 시스템에 등록하지 못했어요(연결 문제). 배포할 때 다시 시도됩니다." 안내(검사 결과·로컬 리포트는 이미 남았으니 차단하지 않는다).
- **등록은 번들 스크립트로 한다(curl 을 손으로 짜지 않는다):** 페이로드(VerdictBody JSON)는 `references/verdict-upload.md` 를 그때 읽어 구성하고(엔진 JSON 값을 그대로 — **시크릿 본체 금지**, 엔진이 마스킹한 형태만), 그것을 **표준입력(stdin)으로** `scripts/verdict-upload.sh` 에 넘긴다. 스크립트가 키 확보·전송 대상 가드·`POST /verdict` 호출을 처리한다.
  ```bash
  REPO_NAME=$(basename -s .git "$(git config --get remote.origin.url 2>/dev/null)")
  REPO="fursys-group-hub/${REPO_NAME}"
  COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
  printf '%s' "$VERDICT_BODY_JSON" | \
    "$CLAUDE_PLUGIN_ROOT/skills/security-review/scripts/verdict-upload.sh" "$REPO" "$COMMIT"
  ```
  스크립트 결과 코드: `STORED`(성공, 조용히 6단계로) / `NO_KEY`(키 없음 → 위 건너뜀 안내) / `NO_COMMIT`(commit 없음 → 등록 생략, 커밋·푸시 후 배포 시 등록됨을 안내) / `UNAUTHORIZED`(키 무효 → 위 401 안내, 검사 차단 안 함) / `UPLOAD_FAILED <code>`(연결 문제 → 위 실패 안내, 배포 때 재시도). 어느 경우든 6단계(HTML 리포트)는 반드시 만든다. (`$CLAUDE_PLUGIN_ROOT` 가 안 잡히면 스킬 폴더의 `scripts/verdict-upload.sh` 절대경로로 실행한다.)

## 6) HTML 리포트 생성 (템플릿 채우기 — 토큰 절감)
**CSS·레이아웃을 매번 새로 생성하지 않는다.** 대신 번들된 `assets/report-template.html` 을 Read 해서 **`{{...}}` placeholder 만 값/해석으로 치환**하고, 대상 경로 하위 `.fursys-deploy-hub/security-report-<YYYYMMDD-HHMM>.html` 로 저장한다. (CSS·구조 재생성 금지 = 이렇게 해야 출력 토큰이 크게 준다.) JSON 값 + 심화 결과로 채우되 비개발자가 읽도록 한글로 해석한다. **HTML 리포트 본체는 배포 시스템에 올리지 않는다 — 로컬 HTML 파일까지만.**(구조화 검토 결과 등록은 5-2에서 이미 처리했다.)

치환할 placeholder(템플릿 상단 주석에 목록·예시 있음):
- `{{META_PATH}}` — 대상 폴더(`target.path`)·코드 저장소(`target.repo`)·프로젝트 종류(`target.framework`)·검사 일시. (`.meta-item` 4개)
- `{{SECURITY_BADGE}}` — 보안 결과 배지(통과 초록 `pass`/주의 주황 `caution`/차단 빨강 `blocked`).
- `{{DEPLOY_BADGE}}` — 배포 준비 배지(완료 초록 `ready`/불가 빨강 `notready`).
- `{{FINAL_LINE}}` — 최종 한 줄(✅ 배포 가능 / ❌ 배포 불가 — 사유).
- `{{SUMMARY_CARDS}}` — `summary` 의 치명/높음/중간/낮음 카운트 카드 4개.
- `{{SECURITY_FINDINGS_ROWS}}` — 보안 문제 표 행(엔진 findings + LLM 심화). `inGitHistory:true` 행은 `class="git-warn"` + 경고 문구.
- `{{SECURITY_PROMPTS}}` — `aiPrompt` 있는 치명/높음 항목마다 복붙 프롬프트 카드(검은 코드블록).
- `{{DEPLOY_CHECK_ROWS}}` — Dockerfile/포트/시작 방법/필수 설정값/상태점검 ✅·❌·➖ 행.
- `{{DEPLOY_PROMPTS}}` — 배포 준비 문제 시 복붙 프롬프트(예: 프레임워크별 Dockerfile 생성). 없으면 비움.
- `{{ENV_ROWS}}` — `envVars` 설정값 정리표(이름·다루는 방법·설명).

리포트 구성(템플릿이 이미 이 순서·스타일로 짜여 있다 — 각 placeholder에 아래 의미를 채운다. CSS/구조는 손대지 않는다):

1. **헤더 / 두 배지** — 메타 4종 + 보안 배지(통과 초록/주의 주황/차단 빨강) + 배포 준비 배지(완료 초록/불가 빨강) + 최종 한 줄(✅ 배포 가능 / ❌ 배포 불가 — 사유) + 치명/높음/중간/낮음 카운트 카드.
2. **🔒 보안 점검** — 발견된 문제 표(심각도·위치 `file:line`(없으면 `-`)·유형 `rule`·설명 `message`, 엔진 findings + LLM 심화(추정 표기 가능)). `inGitHistory:true` 행은 `class="git-warn"` + "기록(git 이력)에 남음" + 경고: "코드에서 지워도 과거 기록에 남아 있으니, 해당 키를 **반드시 폐기·재발급** 하고 IT본부에 알리세요." 그 뒤 `aiPrompt` 있는 치명/높음마다 복붙 프롬프트 카드(전문 그대로, 안내 문구 포함; null이면 설명만).
3. **🚀 배포 준비** — Dockerfile/포트 일치/시작 방법/필수 설정값/상태점검(HEALTHCHECK) 각 ✅·❌·➖ + 쉬운 설명(막는 항목 강조). 문제 시 복붙 프롬프트(예: Dockerfile 없음 → `references/framework-rules.md` 해당 스택 ② 사내 서버 배포 요건(포트·시작 명령·`0.0.0.0` 바인딩 등) 반영한 표준 Dockerfile 생성; Compose만 있으면 전환 프롬프트). 문제 없으면 `{{DEPLOY_PROMPTS}}` 는 비움.
4. **설정값 정리표** — 이름(`name`)·다루는 방법·설명. 영어 분류명(`class`) 노출 금지. 다루는 방법: `build`="화면(브라우저)에 포함될 수 있음 → 비밀번호·키 넣지 말 것", `runtime`="서버에서만 쓰는 일반 값", `locked`="비밀번호·키 → 안전하게 잠가서 보관(화면 노출 금지)".

## 7) 결과 안내 (한글, 쉬운 말)
생성한 HTML **파일 경로**를 알려주고 브라우저로 열어 확인하도록 안내한다. 두 축을 **각각** 전하고 최종 배포 가능 여부를 말한다.
- **🔒 보안:** 통과 ✅ / 주의 ⚠️(높음 — 수정 권장) / 차단 🔴(반드시 고친 뒤 재검사).
- **🚀 배포 준비:** 가능 ✅ / 불가 ❌(사유: Dockerfile 없음·포트 불일치·시작 명령 없음·필수 설정값 누락 등 — 리포트의 복붙 프롬프트로 해결).
- **최종:**
  - 둘 다 OK → "✅ **배포 가능**합니다. 이제 '사내 서버에 올려줘'라고 하면 최초 생성·배포가 진행됩니다."
  - 보안 차단 → "🔴 보안 때문에 배포할 수 없어요. 리포트의 복붙 수정 프롬프트로 고친 뒤 **배포 전 검토를 다시 실행**하세요."
  - 배포 불가 → "❌ 보안은 괜찮지만 **아직 배포할 준비가 안 됐어요**(사유). 리포트의 복붙 프롬프트로 준비한 뒤 다시 검토하세요."
  - 둘 다 막힘 → 두 가지 모두 안내하고 각각의 복붙 프롬프트로 고친 뒤 재검토 안내.

## 금지
- HTML 리포트 본체를 배포 시스템에 올리지 않는다(리포트는 로컬 HTML까지만). 다만 **구조화 검토 결과는 프록시 `/verdict` 로 등록한다**(5-2, 배포 게이트 입력).
- 엔진 결과 없이 보안/배포 가능 여부를 임의로 단정하지 않는다.
- 시크릿 본체(평문 키 값)를 리포트/화면에 그대로 출력하지 않는다(엔진 마스킹 형태를 따른다).
- 외부 호스팅 가이드·인계 메시지·사내 호스팅 관리화면 수동 입력 단계는 만들지 않는다(플러그인은 자동 배포).
