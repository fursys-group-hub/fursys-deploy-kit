---
name: deploy-fix
description: 배포 전 검토(`/deploy-check`)에서 나온 문제를 확인 후 코드에 자동 반영하고, 자동으로 다시 검토까지 돌려 통과 여부를 알려준다. **오직 슬래시 커맨드 `/deploy-fix` 으로 호출될 때만** 이 스킬을 쓴다. "고쳐줘", "문제 해결해줘", "수정해줘" 같은 자연어 요청만으로는 절대 자동 활성화하지 말 것 — 코드를 바꾸는 위험 동작이라 명시 호출만 허용한다. 그런 요청에는 스킬을 시작하지 말고 `/deploy-fix` 입력을 안내하라.
---

당신은 Fursys **배포 전 검토에서 나온 문제를 자동으로 고쳐주는** 스킬이다. 브랜드 실무자(비개발자)가 검토 리포트의 복붙 프롬프트를 직접 다른 곳에 붙여넣는 왕복 없이, **확인 한 번으로 수정 + 재검토**까지 끝내게 돕는다.

- **이 스킬은 오직 `/deploy-fix` 명시 호출에서만 시작한다.** "고쳐줘"·"수정해줘" 같은 자연어만으로는 시작하지 말고 `/deploy-fix` 입력을 안내한다(코드 자동변경은 위험 동작이라 명시 opt-in 만 허용).
- 모든 사용자 노출 문구는 **쉬운 우리말**. "verdict·finding·env·commit·git·secret" 같은 영어/기술 용어를 사용자에게 그대로 쓰지 않는다(괄호 병기 가능). 심각도는 **치명/높음/중간/낮음**.
- **시크릿(키·비밀번호) 값은 화면·로그에 출력하지 않는다.** 외부 호스팅은 언급하지 않는다.
- 검토(`/deploy-check`)는 읽기 전용·빠른 진단으로 두고, **코드를 바꾸는 건 이 스킬만** 한다(책임 분리).

---

## ⓪ 모드 판별 (두 모드 — 공유 머신: 요약→확인→수정→재검증)
이 스킬은 **두 가지 입력 모드**를 갖는다. 어느 모드인지 먼저 정한다.

| 모드 | 입력 정본 | 재검증 | 진입 |
|---|---|---|---|
| **A. 검토 수정**(기존) | `_engine.json` findings + `last-verdict.json` commit | `/deploy-check`(security-review) 재실행 | `/deploy-fix`(인자 없음) |
| **B. 빌드 실패 수정**(신규) | **`logs.sh <app_id>` 빌드로그** + `../deploy/references/deploy-failure-playbook.md`(deploy 스킬 번들) 진단 | **git push → `status.sh <app_id>` 재폴링** | `/deploy-fix --from-deploy-failure <app_id>` |

- **인자 `--from-deploy-failure <app_id>` 가 있으면 → 모드 B**(deploy 가 빌드 실패에서 위임한 경로). 그 `app_id` 를 대상으로 한다.
- **인자가 없으면:** 최근 빌드 실패 앱을 감지해 본다 — `my-apps.sh` 로 내 앱을 조회하고, 가장 최근에 만든 앱이 아직 기동되지 않았으면(상태가 불확실하면) "방금 올리다 막힌 앱(○○)을 고칠까요, 아니면 배포 전 검토에서 나온 문제를 고칠까요?"를 `AskUserQuestion`(고정 2옵션: `방금 올리다 막힌 앱`·`검토에서 나온 문제`)으로 한 번 확인한다. 감지가 애매하거나 사용자가 검토 문제를 고르면 **모드 A**. (명시적으로 빌드 실패 앱을 골랐으면 모드 B, 그 `app_id` 사용.)
- **모드 B → 아래 ⑧~⑪(빌드로그 모드)로** 간다. **모드 A → 그대로 ①~⑦(검토 수정 모드).**
- **정본 구분(중요):** 모드 B 의 정본은 **빌드로그**다. `_engine.json` 을 파싱해 빌드 실패 원인을 만들지 않는다(빌드 실패는 엔진 finding 이 아니라 빌드 출력이 근거).

---

## ① 검토 산출물 로드 (정본만 읽는다 — `.md` 파싱 금지) — 모드 A
프로젝트 루트 `.fursys-deploy-hub/` 의 검토 산출물을 읽는다. **finding 의 정본은 `_engine.json`, commit 의 정본은 `last-verdict.json` 이다. `.md` 리포트를 파싱해 finding 을 복원하지 않는다**(`.md` 는 사람·board 용 표현이라 기계 입력으로 부적합).
```bash
test -f .fursys-deploy-hub/_engine.json && test -f .fursys-deploy-hub/last-verdict.json && echo HAS_ARTIFACTS || echo NO_ARTIFACTS
```
- **`NO_ARTIFACTS`** → "먼저 **`/deploy-check`**(배포 전 검토)를 한 번 실행해 주세요. 무엇을 고쳐야 하는지 거기서 먼저 확인해야 제가 고쳐드릴 수 있어요." 안내 후 **멈춘다.**
- **`HAS_ARTIFACTS`** → 두 파일을 읽는다:
  - `_engine.json` 의 `findings[]` = `{severity, rule, file, line, message, inGitHistory, aiPrompt}`. 이게 **보안 고칠 항목의 정본**이다.
  - `last-verdict.json` 의 `commit`(검토 당시 코드)·`security`·`deployable`·`final`·`env_plan[]`·**`deploy_fixes[]`**.
  - **(deployfix2) `last-verdict.json.deploy_fixes[]` = 엔진 finding 에 없는 자동수정 가능 문제 목록**(`{type, severity, file, message, aiPrompt}`). security-review 가 적어 둔 **두 출처**를 담는다: ① 🚀 배포 준비 문제(`copy-public`·`port`·`start-cmd`·`streamlit-config` 등 — 4)·4-1 점검), ② 🔒 **LLM 심화 보안 발견(`type:"sec-llm"`)** — 3) 보안 심화에서 LLM 이 잡았으나 엔진이 `_engine.json` 으로 못 잡은 보안 문제(소스 박힌 개인계정 평문·DEBUG·CORS `*` 등). **이 목록의 `aiPrompt` 있는 항목도 ③의 자동수정 대상에 포함**한다 — 그래야 리포트가 "deploy-fix 가 고쳐줘요"라 안내한 문제를 실제로 고친다(계약갭 해소). `_engine.json`(엔진 보안 finding)과 **출처만 다를 뿐 같은 자동수정 파이프라인**으로 처리한다. **엔진 finding 이 비어 있어도(`findings:[]`) `deploy_fixes` 에 `sec-llm` 항목이 있으면 자동수정이 동작**한다(과거 `PLAN_EMPTY` 오판 해소). 없거나 `[]` 면 현행과 동일(엔진 보안 finding 만 처리).
- LLM 심화 finding 의 자세한 맥락이 필요하면 `.md` 리포트 본문을 **참고용으로만** 읽을 수 있다(기계 입력 1순위는 어디까지나 `_engine.json`).

## ② commit 일치 확인 (낡은 리포트로 엉뚱한 수정 방지)
```bash
COMMIT_NOW=$(git rev-parse HEAD 2>/dev/null || echo null)
```
- `last-verdict.json` 의 `commit` 과 `COMMIT_NOW` 가 **다르면** → "검토 이후 코드가 바뀌었어요. **`/deploy-check`** 를 다시 한 번 돌려 최신 상태로 점검한 뒤 다시 시도해 주세요." 안내 후 **멈춘다.**
- (둘 다 `null` 인 경우 — 아직 한 번도 저장 안 한 프로젝트 — 는 일치로 보고 진행하되, ⑤ 끝의 저장 안내를 잊지 않는다.)
- 일치하면 ③으로.

## ③ 자동수정 대상 선별 + 수정 계획 요약 (고정 형식)
**보안 finding(`_engine.json`)** 과 **배포준비 문제(`last-verdict.json.deploy_fixes`)** 를 합쳐 **자동수정 대상**과 **사람 판단 필요(안내만)** 로 나눈다.
- **자동수정 대상:**
  - `aiPrompt` 가 있는 **보안 finding**(`_engine.json` — 검토가 만든 복붙 수정 지침). LLM 이 그 지침대로 코드를 고칠 수 있는 것.
  - **(deployfix2) `aiPrompt` 가 있는 배포준비 문제**(`last-verdict.json.deploy_fixes[]` — `type` 이 `copy-public`·`port`·`start-cmd`·`next-build-env`·`volume-perm`·`streamlit-config`·`secrets-to-env`·`static-folder`·`nginx-healthcheck`·`dockerfile` 등). 이것도 같은 자동수정 파이프라인으로 ⑤에서 고친다(public 폴더 생성·포트 맞춤·`.streamlit/config.toml` 생성·설정값 폴백·정적 폴더 좁히기 등). **소스 최소 변경 원칙**: 코드 변경 없이 설정파일/Dockerfile 로 풀 수 있으면 그 경로를 우선한다(⑤-4 참조).
- **자동수정에서 제외(안내만):** 아래는 LLM 이 만들 수 없거나 위험한 값이라 자동수정·재시도 대상에서 뺀다.
  - `last-verdict.json.env_plan[]` 중 `note=="ask"` 인 항목(사람이 정하는 값 — 관리자 비밀번호 등).
  - 외부 서비스 자격증명(외부 API 키·토큰·사외 비밀번호 등).
  - `aiPrompt` 가 비어 있어(`null`) 수정 지침이 없는 finding **또는 deploy_fixes 항목**(예: Dockerfile 자체 부재로 표준을 통째 새로 써야 하는데 지침이 없는 경우 — 리포트 안내로만).
  - **`inGitHistory:true` 인 시크릿 노출** — 코드를 고쳐도 과거 기록에 남으므로 자동수정으로 끝나지 않는다. "해당 키를 폐기·재발급하고 IT본부에 알리세요"로 안내만 한다(자동수정·재시도 제외).

수정 계획은 **고정 형식으로 렌더**한다(모델별 문구 흔들림 방지) — 번들 스크립트로 출력:
```bash
node "$CLAUDE_PLUGIN_ROOT/skills/deploy-fix/scripts/plan-summary.mjs" .fursys-deploy-hub/_engine.json .fursys-deploy-hub/last-verdict.json
```
(`$CLAUDE_PLUGIN_ROOT` 가 안 잡히면: `PS="$(find "$HOME/.claude/plugins" -path '*/fursys-deploy-hub/skills/deploy-fix/scripts/plan-summary.mjs' 2>/dev/null | head -1)"; node "$PS" .fursys-deploy-hub/_engine.json .fursys-deploy-hub/last-verdict.json`)
- 이 스크립트는 자동수정 대상·제외 항목을 **쉬운 우리말 고정 형식**으로 출력한다(시크릿 값 미포함). 그 출력을 그대로 사용자에게 보여준다 — 문구를 즉석에서 새로 짓지 않는다.
- 고칠 게 하나도 없으면(자동수정 대상 0개) → "자동으로 고칠 수 있는 문제가 없어요." + (제외 항목이 있으면) 그 안내만 하고 멈춘다.

## ④ 사용자 확인 (AskUserQuestion — 고정 옵션)
`AskUserQuestion` 으로 "이대로 고칠까요?"를 묻는다. **옵션은 고정**(다른 보기를 만들지 않는다):
- `전부 고쳐주세요` — 자동수정 대상 전부.
- `치명·높음만` — 심각도 치명/높음 finding 만.
- `안 할래요` — 아무것도 고치지 않고 종료.
선택에 따라 고칠 finding 집합을 확정한다. `안 할래요` 면 여기서 멈춘다.

## ⑤ 적용 (확인 후에만 — 안전 스냅샷 먼저)
**확인 전 적용 금지.** ④에서 확인받은 뒤에만 고친다.
1. **시작 직전 안내(한 줄):** "지금까지 작업한 게 있으면 먼저 저장해두세요. 제가 고치기 전 상태를 따로 보관해 둘게요 — 마음에 안 들면 원래대로 되돌릴 수 있어요." (git 용어는 노출하지 않는다.)
2. **안전 스냅샷 1개** 를 만든다(고치기 전 상태 보관). 사용자에겐 "원래대로 되돌릴 수 있게 지금 상태를 보관했어요"로만 알린다:
   ```bash
   git stash push -u -m "deploy-fix-snapshot $(date '+%Y%m%d-%H%M')" >/dev/null 2>&1 && git stash apply >/dev/null 2>&1 || true
   ```
   (스냅샷을 만들되 작업 트리는 그대로 유지한다. 되돌리기를 요청하면 보관된 스냅샷으로 복원한다 — 사용자에겐 git 명령을 보여주지 않는다.)
3. **확정된 finding 의 `aiPrompt`(복붙 수정 지침)대로 해당 코드를 Edit 한다.** finding 의 `file`·`line`·`message`·`aiPrompt` 를 근거로 그 파일을 직접 고친다. 한 finding 씩 처리한다.
   - **하드코딩 값 제거 시 값 보존(반드시 — 값 유실 방지):** `aiPrompt` 가 **하드코딩된 값을 코드에서 빼라**고 지시할 때(예 `process.env.X || "2351496"` → `process.env.X`, `const SHEET_ID = "1qJDD…"` → `process.env.SHEET_ID`), 코드만 고치면 그 실제 값이 증발해 로컬 자료 갱신(ETL 등)이 깨진다. **코드 교체와 함께 아래 4단계를 같이 수행한다:**
     1. **코드 교체:** `process.env.X`(또는 프레임워크별 참조)로 교체 — 위 현행 동작.
     2. **값 보존 → gitignored `.env`:** 코드에서 뺀 **실제 값**을 프로젝트 루트 `.env` 에 `X=<값>` 으로 기록한다. **`.env` 가 없으면 생성.** 이미 `X=` 가 있으면 **비어 있을 때만** 채운다(기존 값 덮어쓰기 금지).
     3. **`.env` gitignore/dockerignore 보장:** `.gitignore` 에 `.env` 가 없으면 한 줄 추가, `.dockerignore` 에 `.env` 가 없으면 한 줄 추가(컨테이너 빌드 컨텍스트·git 전송에서 제외 — 값이 새지 않게).
     4. **`.env.example` 빈 키:** `.env.example` 에 `X=`(빈 키) + 한 줄 설명을 추가(자가문서화). **값은 적지 않는다.**
     - **보안 불변식(절대):** 뺀 값을 **화면·로그·git·서버에 노출하거나 전송하지 않는다.** `.env` 는 그 PC 로컬에만 남고 `.gitignore`+`.dockerignore` 로 전송 차단된다. 사용자 통보는 **시크릿 미출력 고정 문구**(키 이름만, 값 금지)로만: "하드코딩돼 있던 값을 코드에서 빼고 **본인 PC `.env`에 안전하게 옮겨 적었어요**(git에 안 올라가요). 자료 갱신은 그대로 동작해요." (이 문구는 verbatim 고정 — 즉석에서 새로 짓지 않는다.)
     - **이미 git 이력에 커밋된 시크릿(`inGitHistory:true`)은 별개** — 코드만 고쳐선 안 끝난다(폐기·재발급·IT 통보, ③·⑦ 안내 유지). 이 단계는 **코드에 하드코딩됐으나 아직 이력에 안 남은** 값의 로컬 보존만 다룬다.
4. **(deployfix2) 확정된 `deploy_fixes` 항목의 `aiPrompt` 대로 배포준비 문제를 고친다.** 보안 finding 과 같은 방식으로 `type`·`file`·`message`·`aiPrompt` 를 근거로 직접 Edit/Write 한다. 유형별 구체 처리는 빌드로그 모드(⑩-3)와 동일 규칙을 따른다(중복 정의 금지 — 같은 동작):
   - **(소스 최소 변경 원칙 — 우선 경로) 사용자 코드를 직접 손대기보다 env·설정파일·Dockerfile 로 풀 수 있으면 그 경로를 먼저 쓴다.** `aiPrompt` 에 비침투적(코드 무변경·설정파일 생성·한두 줄 추가) 경로가 적혀 있으면 그대로 따른다. **코드를 뜯어고치는 침투적 수정은 마지막 수단**이고, 그럴 때만 ⑤의 통보에 **어떤 파일의 무엇을 왜 바꿨는지(범위·이유)** 를 사용자에게 쉬운 말로 명시한다. `message` 가 "코드를 일부 바꿔야 해요(범위…)"로 적혀 있으면 그 안내를 그대로 전한다. diff 는 최소로 — 인접 코드·포맷·주석을 함께 손대지 않는다.
   - **`copy-public` → `public/.gitkeep` 생성**(⑩-3 `copy-public` 과 동일): 프로젝트 루트에 `public/` 디렉터리 + 빈 `public/.gitkeep`. **Dockerfile 은 고치지 않는다.**
   - **`secrets-to-env`(항목25 — Streamlit `st.secrets`→설정값) → 로컬 동작 보존하며 비침투적으로:** 사내 서버는 `secrets.toml` 을 직접 지원하지 않아 `st.secrets["X"]` 가 깨진다. **코드를 통째로 `os.environ` 으로 바꾸지 않는다**(로컬 `secrets.toml` 흐름이 파괴됨). `aiPrompt` 대로 ① 앱 진입부에 `from dotenv import load_dotenv; load_dotenv()` 한 줄 추가(이미 있으면 생략), ② 깨지는 `st.secrets["X"]` 호출만 `st.secrets.get("X", os.environ.get("X"))` 폴백으로 **최소 교체**(secrets.toml 있으면 그대로, 없으면 env). ③ **`.env.example` 생성/보강**(코드가 참조하는 키만 빈 값으로 — 값은 적지 않는다) + ④ 로컬 실행 안내 한 줄(주석/README: "로컬은 `.streamlit/secrets.toml` 또는 `.env`, 사내 서버는 설정값으로 주입"). `requirements.txt` 에 `python-dotenv` 가 없으면 한 줄 추가. 통보(고정): "사내 서버에서 비밀값을 읽도록 설정값을 더했어요 — **로컬 실행(`secrets.toml`)은 그대로 동작**해요. `.env.example` 도 만들어 뒀어요(빈 칸만, 비밀값은 안 적었어요)." 시크릿 값은 출력하지 않는다.
   - **`conn-string`(항목62 — DB 연결 문자열 평문 비밀번호) → 값 일부 치환 금지·전체 교체 or 파일 제외:** `aiPrompt` 가 가리키는 연결 문자열(`DATABASE_URL=postgresql://user:pass@host:port/db` 등)을 고칠 때, **비밀번호 일부만 `${ENV}` 로 바꾸지 않는다** — 비번이 중간에서 잘려 평문 조각+호스트가 그대로 남고 값도 깨진다(sidiz 사고: `DATABASE_URL=${DATABASE_URL}n6ozb…@host`로 "해소"라 오보됨). 처리: ① **그 변수의 값 전체**(`scheme://user:pass@host:port/db` 전체)를 **통째로** 하나의 env 참조(`DATABASE_URL=${DATABASE_URL}`)로 교체하고, 실제 값은 ④-2~4(gitignored `.env`·`.dockerignore`·`.env.example` 빈 키) 절차로 보존한다. ② **단, 그 파일이 배포에 안 쓰이는 파일(특히 `docker-compose.yml`/`compose.yaml` — 배포는 Dockerfile 단독, compose 는 구조 힌트로만 읽고 배포엔 안 씀)이면 치환하지 말고**, `.dockerignore`·`.gitignore` 에 그 파일을 추가해 빌드 컨텍스트·git 전송에서 제외한다(평문이 이미지·git 에 안 실리게). **그 파일이 어디에도 안 쓰이는 게 확실하면** ⑦에서 삭제를 권한다(자동 삭제는 하지 않음 — 사용자 자료일 수 있어 파일 제거는 사람 확인). 통보: "연결 문자열에 비밀번호가 평문으로 있어서 비밀값 전체를 환경변수로 옮겼어요(중간에서 잘리지 않게 통째로요)." 또는 "이 파일은 배포에 안 쓰여서 빌드·git 전송에서 빼 뒀어요(평문이 새지 않게)." 시크릿 값은 출력하지 않는다.
   - **`static-folder`(항목35 — Flask/FastAPI/Express 정적 루트가 서버 폴더 전체) → 최소 수정 + 안내:** 서버 루트 전체(소스·`.env`·설정)가 URL 로 노출되는 위험. **코드를 크게 뜯어고치지 않는다.** `aiPrompt` 대로 정적 폴더 인자만 안전한 전용 폴더로 좁히는 **한 줄 변경**(`static_folder="static"`·`StaticFiles(directory="static")`·`express.static("public")`)을 적용하고, 그 폴더가 없으면 함께 생성(빈 `.gitkeep`). **단, 공개 자산이 실제로 루트에 흩어져 있어 파일 이동이 필요한 경우(=`aiPrompt:null`·`message` 가 "공개 파일만 옮겨야 해요"로 안내)는 자동으로 파일을 옮기지 않는다** — ⑦에서 "어떤 파일이 외부 공개여도 되는지는 직접 정하셔서 `static/` 으로 옮겨 주세요"로 안내만 한다(공개 여부는 사람 판단). 한 줄 변경을 적용했으면 통보에 "정적 파일을 내보내는 폴더를 서버 전체에서 `static`(공개 전용 폴더)으로 좁혔어요 — 소스·설정이 외부에 노출되지 않게요." 를 넣는다.
   - **`streamlit-config` → `.streamlit/config.toml` 표준 생성:** 프로젝트 루트에 `.streamlit/config.toml` 이 없거나 표준 설정이 빠졌으면 생성·보강한다. **사내 표준(필수):** `[browser]\ngatherUsageStats = false`(텔레메트리 차단 — 사내 정책), `[server]\nheadless = true`, 포트가 Dockerfile `EXPOSE` 와 달라야 하면 `port = <EXPOSE 값>`. 기존 키는 보존(병합).
   - **`nginx-healthcheck`(항목66 — nginx `localhost` HEALTHCHECK IPv6 불일치) → 최소 치환:** nginx 정적 서버 앱에서 Dockerfile `HEALTHCHECK` 이 `http://localhost/` 를 쓰고 custom nginx conf 에 `listen [::]:80` 이 없으면, alpine 의 `localhost`(`::1` IPv6 우선)에 nginx 가 안 들어 healthcheck 실패 → Coolify 롤백 → 404(빌드·서빙은 정상인데 자가진단만 실패). **가장 안전·최소 수정 = HEALTHCHECK 의 `localhost` → `127.0.0.1`(IPv4 명시) 한 줄 치환**(conf·IPv6 설정과 무관하게 동작). 추가로 custom nginx conf(`*.conf`)가 있으면 그 `server {}` 의 `listen 80;` 옆에 `listen [::]:80;` 한 줄을 동반 추가한다(IPv4/IPv6 둘 다 듣게). **빌드·서빙·라우팅 로직은 건드리지 않는다.** 통보: "상태 점검이 앱에 접속하지 못해 배포가 되돌려지던 문제(롤백)를 고쳤어요 — 점검 주소를 `127.0.0.1` 로 바꿨어요." 상세는 `../security-review/references/framework-rules.md` §4 ②-1.
   - **`port` → EXPOSE/시작포트 맞춤**(⑩-3 `port` 동일): `aiPrompt` 가 가리키는 대로 Dockerfile `EXPOSE` 또는 앱 시작 포트를 일치시킨다.
   - **`start-cmd` / `next-build-env` / `volume-perm` / `dockerfile`** → 각 `aiPrompt` 지침대로 Dockerfile 의 해당 부분만 외과적으로 고친다(다른 단계 보존).
   - **(odbc-base) Python + ODBC/pyodbc 앱의 base 이미지 고정:** deploy-fix 가 **Python Dockerfile 의 `FROM` 을 새로 쓰거나 base 를 고를 때**(특히 `dockerfile` 자동수정에서 base 줄을 만질 때), 그 앱이 **`pyodbc`·ODBC·MSSQL 드라이버(`unixodbc`·`msodbcsql*`)에 의존**하면 base 를 **`python:3.x-slim-bookworm`(Debian 12)** 로 고정한다. **`python:3.x-slim`(태그 미고정)·`-slim-trixie`(Debian 13)를 쓰지 않는다** — trixie 는 OpenSSL SHA1 서명 거부로 Microsoft ODBC 드라이버(`msodbcsql18`) 설치/실행이 깨진다. 의존 판단 근거: `requirements.txt`/`pyproject.toml` 의 `pyodbc`, Dockerfile 의 `unixodbc-dev`·`msodbcsql`·`ACCEPT_EULA`. ODBC 의존이 **아닌** Python 앱의 base 는 건드리지 않는다(기존 줄 보존 — 과수정 금지). **이 규칙은 deploy-fix 의 생성/수정 로직에만 적용**한다(create-app 템플릿은 별도). **멀티서비스(services.json 존재)에서도 동일** — 서비스마다 그 dir 의 `requirements.txt`/Dockerfile 로 ODBC 의존을 **서비스별로 독립 판정**해, backend/api 같은 한 서비스만 ODBC 면 그 서비스 Dockerfile 의 base 만 `slim-bookworm` 으로 고정한다(항목29 — deploy `references/multiservice.md` §10 연계). ODBC 아닌 형제 서비스(프론트 등)는 그대로 둔다.
   - **`aiPrompt:null` 인 deploy_fixes 항목은 고치지 않는다**(③에서 이미 안내만으로 분류 — Dockerfile 자체 부재 등). ⑦에서 안내한다.
4-1. **(gitignore 충돌 점검 — 생성 파일이 무시되지 않게) 항목23.** `copy-public`·`streamlit-config`·`static-folder` 등이 **새로 만든 파일**(`public/.gitkeep`·`.streamlit/config.toml`·`static/.gitkeep` 등)은 원본 `.gitignore` 가 그 경로를 제외하면 **`git add` 해도 누락 → push 해도 배포에 안 실려** 같은 실패가 반복된다(특히 `.streamlit/secrets.toml` 만 무시하려다 `.streamlit/` 디렉터리 통째 무시, `public/`·`static/` 통째 무시가 흔하다). **생성 직후 각 파일마다** `git check-ignore -q <경로>` 의 **종료코드**로 무시 여부를 판정한다(`rc=0`=무시됨, `rc=1`=추적됨). 무시되면(`rc=0`) **프로젝트 `.gitignore` 끝에 부정 패턴(`!<경로>`) 한 줄**을 추가해 그 파일만 추적되게 보정한다(원본 무시 규칙은 그대로 두고 예외만 추가 — 외과적). 예: `.streamlit/` 가 무시되면 `!.streamlit/` + `!.streamlit/config.toml` 두 줄(디렉터리·파일 둘 다 풀어야 git 이 본다 — 디렉터리가 무시되면 그 안 파일은 부정 패턴이 안 먹는다), `public/` 무시면 `!public/` + `!public/.gitkeep`. **`.env`·`secrets.toml`·키 파일 등 시크릿 경로는 절대 부정 패턴으로 풀지 않는다**(무시가 정상 — `secrets-to-env`(④-2~3)의 `.env` gitignore 보장과 충돌 금지). 보정 후 **`git check-ignore -q <경로>` 가 `rc=1`(추적됨)** 인지 재확인한다(주의: `-v`(verbose)는 부정 패턴이 매칭돼도 그 라인을 출력하고 `rc=0` 을 내므로 "빈 출력"으로 판정하면 안 된다 — `-q` 의 종료코드로만 본다). 보강한 `.env` 등은 여전히 `rc=0`(무시) 이어야 정상. 통보에 "설정 파일이 git 제외 규칙에 걸려 안 올라가던 걸 풀어 뒀어요(비밀 파일은 그대로 제외)." 한 줄을 넣는다.
5. **변경한 파일 목록을 사용자에게 쉬운 말로 통보**한다(어떤 파일의 무엇을 고쳤는지). 시크릿 값은 출력하지 않는다. (위 값 보존을 한 경우, 통보에 그 **고정 문구**를 함께 넣는다.)

## ⑥ 자동 재검토 (최대 2라운드 — 진전 없으면 즉시 중단)
수정 직후 **`/deploy-check`(security-review) 로직을 자동 실행**해 통과 여부를 다시 판정하고, 새 `.md` 리포트·`_engine.json`·`last-verdict.json` 을 갱신한다.
- **security-review 스킬의 절차(엔진 실행 → 보안 심화 → 배포 가능성 → 종합 판정 → 산출물 기록 → `.md` 리포트 생성)를 그대로 자동 수행**한다(사용자에게 `/deploy-check` 를 다시 치라고 시키지 않는다 — 여기서 자동으로 돌린다).
  - **(treegate) 이 재검토가 `last-verdict.json` 을 다시 쓸 때, security-review 5-1 의 `_fdh_tree` 산출이 그대로 포함되므로 `tree` 도 함께 갱신된다.** deploy-fix(모드 A)는 **커밋하지 않으므로**(현행 유지), 여기 기록되는 `tree` 는 방금 수정한 **작업트리 내용**의 해시다. deploy ①이 그 작업트리를 커밋하면 commit SHA 는 바뀌어도 tree 는 같아, deploy ⑤ 게이트가 재검토 없이 통과시킨다(SHA 무효화 루프 제거).
- **루프 방지(반드시):**
  - **최대 2라운드.** (이번 수정 → 재검토 = 1라운드. 여전히 실패면 같은 절차로 한 번 더 = 2라운드까지.)
  - **직전 라운드 대비 finding 수가 줄지 않으면 그 자리에서 즉시 중단**한다(자동으로 못 고치는 신호 — 더 돌리지 않는다).
  - ③에서 제외한 항목(`note:"ask"`·외부 자격증명·`inGitHistory` 시크릿·`aiPrompt` 없음)은 **애초에 재시도 대상이 아니다** — 이것들 때문에 finding 이 남아도 재검토를 반복하지 않는다.

## ⑦ 결과 안내 (한글, 쉬운 말)
재검토 결과로 분기한다(새 `last-verdict.json` 의 `final` 기준):
- **통과(`final=="ok"`)** → "고쳤고 검토도 통과했어요. 이제 **`/deploy`** 라고 하시면 사내 서버에 올릴 수 있어요."
- **일부 남음** → "여기까진 제가 자동으로 고쳤어요. 남은 건 사람 판단이 필요해요." + 남은 항목을 ③의 같은 고정 형식으로 보여준다. 자동수정 불가 항목(사람이 정하는 값·외부 자격증명·기록에 남은 시크릿)은 **명확히 구분**해 안내한다:
  - 사람이 정하는 값·외부 자격증명 → "이 값은 ○○(쉬운 설명)인데, 제가 만들 수 없는 값이라 직접 정해 주셔야 해요. `/deploy` 할 때 한 개씩 여쭤볼게요."
  - 기록(git 이력)에 남은 시크릿 → "이건 과거 기록에 남아 있어서 코드만 고쳐선 끝나지 않아요. 해당 키를 **폐기·재발급**하고 **IT본부에 알려** 주세요."
  - **(item60) 아키텍처·인증 구조는 "왜 앱 만든 분(앱 오너) 몫인지"를 명시한다** — 자동으로 못 고치는 대표 3종을 뭉뚱그리지 말고 각각 이유를 붙여 안내한다(caution 이 남아 사용자가 "왜 안 끝나지?"로 2라운드를 또 돌리거나 혼란에 빠지지 않게):
    - **클라이언트(브라우저) 측 인증**(예: `ADMIN_PW_HASH` 를 프론트에서 검사, 클라이언트 SHA256 비번) → "로그인·비밀번호 확인을 **브라우저에서** 하고 있어요. 이건 누구나 소스를 열어 우회할 수 있어서, **서버(백엔드)에서 확인하도록** 앱을 만든 분이 구조를 바꿔야 해요. 제가 자동으로 못 고치는 부분이에요."
    - **API 인증 부재**(무인증 읽기/쓰기 엔드포인트) → "데이터를 주고받는 통로(API)에 **로그인 확인이 없어요.** 누가 인증돼야 하는지는 업무 규칙이라, 앱을 만든 분이 인증을 넣어야 해요."
    - **아키텍처 전환 미완**(외부 SaaS→사내, 이중 백엔드 등 — item50/61 연계) → "이 앱은 예전(외부) 방식과 새(사내) 방식이 **섞여 있어요.** 보안상 급한 건 막았지만, 구조를 하나로 정리하는 건 앱을 만든 분의 판단이 필요해요(아래 참조)."
  - **이 세 종류는 자동수정·재시도 대상이 아니다** — ⑥의 재검토 루프를 이것들 때문에 반복하지 않는다(③ 제외 규칙과 동일). "제가 고칠 수 있는 건 다 했고, 남은 건 제가 손댈 수 없는 종류"임을 분명히 한다.
- **진전 없어 중단** → "제가 자동으로는 더 고치지 못했어요. 리포트의 복붙 수정 프롬프트로 직접 고쳐 보시거나 IT본부에 문의해 주세요." + (원하면) "방금 고친 게 마음에 안 들면 원래대로 되돌려 드릴 수 있어요."
- 수정으로 코드가 바뀌었으면 끝에 한 줄: "이 수정 내용은 **저장(코드 올리기)** 해야 배포에 반영돼요. `/deploy` 로 올릴 때 최신 코드가 함께 올라가요."

---

# 빌드로그 모드 (모드 B — `--from-deploy-failure <app_id>`)
> 빌드/배포가 실패한 뒤 **빌드로그를 근거로** 코드를 고쳐 git push 재배포까지 돕는다. ①~⑦(검토 수정)과 별개 경로다.
> 공유 원칙은 동일하다: **확인 전 코드 수정 금지 · 안전 스냅샷 먼저 · 사람만 아는 값/외부 자격증명/기록 시크릿 제외 · 시크릿 비노출 · ≤2라운드·진전 없으면 중단.**

## ⑧ 빌드로그 확보 + 원인 진단 (정본 = 로그)
대상 앱(`<app_id>`)의 빌드 기록을 가져온다(민감값은 proxy 가 1차로 가린 상태로 온다):
```bash
"$CLAUDE_PLUGIN_ROOT/skills/deploy/scripts/logs.sh" "<app_id>"
```
(`$CLAUDE_PLUGIN_ROOT` 가 안 잡히면: `LS="$(find "$HOME/.claude/plugins" -path '*/fursys-deploy-hub/skills/deploy/scripts/logs.sh' 2>/dev/null | head -1)"; "$LS" "<app_id>"`)
- **`LOGS_OK`** → 이어지는 JSON `{ "status", "deployment_uuid", "logs" }` 를 읽는다. `logs` 텍스트(끝부분 = 실제 에러)를 **deploy 스킬 번들 `../deploy/references/deploy-failure-playbook.md`** 의 유형(의존성 누락 / lockfile / 타입에러 / 포트 / 시작명령 / Dockerfile 단계 / 필수 설정값 누락)에 매핑한다.
- **로그가 비었거나 `deployment_uuid` 가 `null`** → "자세한 빌드 기록을 가져오지 못했어요. 잠시 후 다시 시도하거나 IT본부에 문의하세요." 하고 **멈춘다**(없는 원인 지어내지 않는다).
- **`UNAUTHORIZED`/`NOT_FOUND`/`PROXY_ERROR`** → 각각 키 재발급·미등록·재시도 안내 후 멈춘다(deploy ⑨ 결과 코드와 동일).
- **시크릿 비노출:** 로그 원문을 통째로 옮기지 않는다. 원인이 된 **핵심 줄만** 추리고, 비밀번호·키처럼 보이는 값은 가린다(proxy 스크럽 1차 + 여기 2차).

## ⑨ 수정 계획 요약 (고정 형식 — 스크립트 출력)
진단 결과를 **고정 형식으로 렌더**한다(모델별 문구 흔들림 방지). `plan-summary.mjs` 를 로그 진단 모드로 부른다:
```bash
node "$CLAUDE_PLUGIN_ROOT/skills/deploy-fix/scripts/plan-summary.mjs" --logs <유형키> "<핵심 에러 한 줄>" ["<모듈/경로 등 인자>"]
```
- `<유형키>` 는 playbook 유형: `dep-missing`·`dep-devdep`·`lockfile`·`build-error`·`port`·`start-cmd`·`dockerfile`·`oom`·`copy-public`·`env-missing`·`unknown` 중 하나.
- 스크립트가 **자동수정 대상인지 / 사람 판단 필요(안내만)인지**를 쉬운 우리말 고정 형식으로 출력한다(시크릿 값 미포함). 그 출력을 그대로 사용자에게 보여준다 — 문구를 즉석에서 새로 짓지 않는다.
- **자동수정 제외(안내만):** `env-missing`(필수 설정값 누락) 중 사람만 아는 값·외부 자격증명, `note:"ask"` 항목, `inGitHistory` 시크릿, 아키텍처 변경이 필요한 경우. 이때는 "값을 알려주세요 / IT본부에 문의"로만 안내하고 자동수정·재폴링하지 않는다.

## ⑩ 확인 → 수정 → git push 재배포 → 재폴링 (≤2라운드)
1. **`AskUserQuestion`(고정 옵션):** `고쳐 주세요`·`안 할래요`. `안 할래요` 면 여기서 멈춘다.
2. **안전 스냅샷 먼저**(⑤와 동일 — 고치기 전 상태 보관, git 용어 비노출): "원래대로 되돌릴 수 있게 지금 상태를 보관했어요."
   ```bash
   git stash push -u -m "deploy-fix-snapshot $(date '+%Y%m%d-%H%M')" >/dev/null 2>&1 && git stash apply >/dev/null 2>&1 || true
   ```
3. **playbook 진단대로 코드 Edit.** 한 가지씩 고치고, **어떤 파일의 무엇을 고쳤는지** 쉬운 말로 통보한다(시크릿 미출력). 유형별 구체 수정은 아래와 같다(확인 후에만 적용):
   - **`oom`(빌드 메모리 부족) → `next.config` 수정:** 프로젝트 루트의 `next.config.mjs`/`next.config.js`/`next.config.ts` 중 존재하는 것에서, 최상위 config 객체에 `experimental: { cpus: 1, workerThreads: false }` 를 **병합**한다(이미 `experimental` 가 있으면 그 안에 `cpus`·`workerThreads` 만 추가/덮어쓰고 다른 키는 보존). `output: 'standalone'` 등 기존 키는 **건드리지 않는다.** **`NODE_OPTIONS=--max-old-space-size` 상향은 넣지 않는다**(해법 아님 — 오히려 메모리를 더 키운다). 통보: "앱을 만드는 부담을 줄이는 설정을 `next.config` 에 넣었어요. 메모리 부족으로 멈추던 문제예요." `output: 'standalone'` 제거(최후수단)는 이미지 구조를 바꾸는 아키텍처 변경이라 **자동수정에서 제외** — ⑪에서 안내만 한다.
   - **`copy-public`(public 폴더 없음) → `public/.gitkeep` 생성:** 프로젝트 루트에 `public/` 디렉터리를 만들고 빈 `public/.gitkeep` 파일을 작성한다. **Dockerfile 은 고치지 않는다.** 통보: "비어 있던 'public' 폴더를 만들어 뒀어요. 이제 마지막 복사 단계가 통과해요."
   - **`dockerfile`(빌드 단계 실패) → 해당 단계만 외과적으로 수정.** **(odbc-base)** 그 수정이 **Python + ODBC/pyodbc(MSSQL `msodbcsql*`·`unixodbc`) 앱의 `FROM`/base 를 만질 때**는 base 를 **`python:3.x-slim-bookworm`(Debian 12)** 으로 고정한다(`-slim` 태그 미고정·`-slim-trixie`=Debian 13 금지 — trixie 의 OpenSSL SHA1 거부로 `msodbcsql18` 설치/실행이 깨진다). ODBC 비의존 Python 앱·다른 단계 수정은 base 줄을 건드리지 않는다(과수정 금지). 이 규칙은 deploy-fix 수정 로직 전용(create-app 템플릿 별도).
4. **git push 로 재배포**한다(=Coolify webhook 자동 재배포). **`/deploy` 재실행(재-POST) 금지 — 이중배포 가드 불변.** 같은 앱에 다시 올라간다.
   ```bash
   git add -A && git commit -m "fix: 빌드 실패 자동 수정 (deploy-fix)" && git push
   ```
5. **재폴링:** push 직후 deploy 스킬 ⑦-1 의 종결 폴링 루프를 그대로 돌린다 — `status.sh <app_id> <domain>` 를 backoff(5s→10s→20s→30s, 이후 30s 고정)로 반복, terminal(`RUNNING`/`FAILED`)까지. 상한 ~10분. **`<domain>` 은 그 앱의 접속 도메인**(이미 만들어진 앱이므로 `my-apps.sh` 로 조회해 얻는다 — proxy `/status` 는 domain 을 안 주므로 인자로 넘겨야 RUNNING 시 주소를 보여줄 수 있다. 모르면 생략해도 RUNNING 판정 자체는 정상).
   ```bash
   "$CLAUDE_PLUGIN_ROOT/skills/deploy/scripts/status.sh" "<app_id>" "<domain>"
   ```
6. **라운드 상한 ≤2 · 진전 없으면 즉시 중단:** 다시 `FAILED` 면 새 로그로 **한 번만 더**(총 2라운드). 직전 대비 **진전 없음**(같은 에러 반복 / 로그에 의미 변화 없음 / 같은 실패 신호 반복)이면 **즉시 중단**한다.

## ⑪ 결과 안내 (한글, 쉬운 말)
- **성공(`RUNNING`)** → "고쳤고 이번엔 잘 올라갔어요. 주소: `<https_url>`" (`LIVE_OK`/`LIVE_PENDING` 보조 줄로 접속 가능/예열 안내).
- **미해결(2라운드/진전없음)** → "여기까진 제가 자동으로 고쳤어요. 남은 건 사람 판단이 필요해요." + 핵심 로그(가린 형태) + 다음 단계. **앱은 절대 지우지 않는다**(deploy ⑨ 원칙). 사람만 아는 값/외부 자격증명이 원인이면 "이 값은 ○○인데 제가 만들 수 없어요 — 알려주시거나 IT본부에 문의해 주세요"로 안내.
- 진전 없어 중단이면 "방금 고친 게 마음에 안 들면 원래대로 되돌려 드릴 수 있어요"(스냅샷 복원)도 함께 안내한다.

## 금지
- **자연어 요청만으로 이 스킬을 시작하지 않는다.** "고쳐줘"·"수정해줘" 같은 일반 문장에는 스킬을 띄우지 말고 `/deploy-fix` 입력을 안내한다. **오직 `/deploy-fix` 명시 호출에서만 동작한다.**
- **(모드 B) 빌드 실패 원인의 정본은 로그다 — `_engine.json` 을 파싱해 빌드 원인을 만들지 않는다.** 재배포는 **git push** 로만(재-POST 금지). **앱 삭제 금지.**
- **④ 사용자 확인 전에 코드를 고치지 않는다.**
- `.md` 리포트를 파싱해 finding 을 복원하지 않는다(정본은 `_engine.json`).
- 사람만 아는 값(`note:"ask"`)·외부 자격증명·기록에 남은 시크릿은 **자동수정·재시도하지 않는다**(안내만).
- 시크릿(키·비밀번호) 값을 화면·로그에 출력하지 않는다.
- 자동 재검토는 **최대 2라운드 + 진전 없으면 즉시 중단**(무한 루프 금지).
- 외부 호스팅을 언급하지 않는다(사내 서버 단일 컨테이너 + Dockerfile 전제만).
