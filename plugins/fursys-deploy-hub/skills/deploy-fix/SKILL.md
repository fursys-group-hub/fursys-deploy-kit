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
| **B. 빌드 실패 수정**(신규) | **`logs.sh <app_id>` 빌드로그** + `references/deploy-failure-playbook.md`(deploy 스킬 번들) 진단 | **git push → `status.sh <app_id>` 재폴링** | `/deploy-fix --from-deploy-failure <app_id>` |

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
  - `_engine.json` 의 `findings[]` = `{severity, rule, file, line, message, inGitHistory, aiPrompt}`. 이게 **고칠 항목의 정본**이다.
  - `last-verdict.json` 의 `commit`(검토 당시 코드)·`security`·`deployable`·`final`·`env_plan[]`.
- LLM 심화 finding 의 자세한 맥락이 필요하면 `.md` 리포트 본문을 **참고용으로만** 읽을 수 있다(기계 입력 1순위는 어디까지나 `_engine.json`).

## ② commit 일치 확인 (낡은 리포트로 엉뚱한 수정 방지)
```bash
COMMIT_NOW=$(git rev-parse HEAD 2>/dev/null || echo null)
```
- `last-verdict.json` 의 `commit` 과 `COMMIT_NOW` 가 **다르면** → "검토 이후 코드가 바뀌었어요. **`/deploy-check`** 를 다시 한 번 돌려 최신 상태로 점검한 뒤 다시 시도해 주세요." 안내 후 **멈춘다.**
- (둘 다 `null` 인 경우 — 아직 한 번도 저장 안 한 프로젝트 — 는 일치로 보고 진행하되, ⑤ 끝의 저장 안내를 잊지 않는다.)
- 일치하면 ③으로.

## ③ 자동수정 대상 선별 + 수정 계획 요약 (고정 형식)
findings 를 **자동수정 대상**과 **사람 판단 필요(안내만)** 로 나눈다.
- **자동수정 대상:** `aiPrompt` 가 있는 finding(검토가 만든 복붙 수정 지침). LLM 이 그 지침대로 코드를 고칠 수 있는 것.
- **자동수정에서 제외(안내만):** 아래는 LLM 이 만들 수 없는 값이라 자동수정·재시도 대상에서 뺀다.
  - `last-verdict.json.env_plan[]` 중 `note=="ask"` 인 항목(사람이 정하는 값 — 관리자 비밀번호 등).
  - 외부 서비스 자격증명(외부 API 키·토큰·사외 비밀번호 등).
  - `aiPrompt` 가 비어 있어(`null`) 수정 지침이 없는 finding.
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
4. **변경한 파일 목록을 사용자에게 쉬운 말로 통보**한다(어떤 파일의 무엇을 고쳤는지). 시크릿 값은 출력하지 않는다.

## ⑥ 자동 재검토 (최대 2라운드 — 진전 없으면 즉시 중단)
수정 직후 **`/deploy-check`(security-review) 로직을 자동 실행**해 통과 여부를 다시 판정하고, 새 `.md` 리포트·`_engine.json`·`last-verdict.json` 을 갱신한다.
- **security-review 스킬의 절차(엔진 실행 → 보안 심화 → 배포 가능성 → 종합 판정 → 산출물 기록 → `.md` 리포트 생성)를 그대로 자동 수행**한다(사용자에게 `/deploy-check` 를 다시 치라고 시키지 않는다 — 여기서 자동으로 돌린다).
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
- **`LOGS_OK`** → 이어지는 JSON `{ "status", "deployment_uuid", "logs" }` 를 읽는다. `logs` 텍스트(끝부분 = 실제 에러)를 **deploy 스킬 번들 `references/deploy-failure-playbook.md`** 의 유형(의존성 누락 / lockfile / 타입에러 / 포트 / 시작명령 / Dockerfile 단계 / 필수 설정값 누락)에 매핑한다.
- **로그가 비었거나 `deployment_uuid` 가 `null`** → "자세한 빌드 기록을 가져오지 못했어요. 잠시 후 다시 시도하거나 IT본부에 문의하세요." 하고 **멈춘다**(없는 원인 지어내지 않는다).
- **`UNAUTHORIZED`/`NOT_FOUND`/`PROXY_ERROR`** → 각각 키 재발급·미등록·재시도 안내 후 멈춘다(deploy ⑨ 결과 코드와 동일).
- **시크릿 비노출:** 로그 원문을 통째로 옮기지 않는다. 원인이 된 **핵심 줄만** 추리고, 비밀번호·키처럼 보이는 값은 가린다(proxy 스크럽 1차 + 여기 2차).

## ⑨ 수정 계획 요약 (고정 형식 — 스크립트 출력)
진단 결과를 **고정 형식으로 렌더**한다(모델별 문구 흔들림 방지). `plan-summary.mjs` 를 로그 진단 모드로 부른다:
```bash
node "$CLAUDE_PLUGIN_ROOT/skills/deploy-fix/scripts/plan-summary.mjs" --logs <유형키> "<핵심 에러 한 줄>" ["<모듈/경로 등 인자>"]
```
- `<유형키>` 는 playbook 유형: `dep-missing`·`dep-devdep`·`lockfile`·`build-error`·`port`·`start-cmd`·`dockerfile`·`env-missing`·`unknown` 중 하나.
- 스크립트가 **자동수정 대상인지 / 사람 판단 필요(안내만)인지**를 쉬운 우리말 고정 형식으로 출력한다(시크릿 값 미포함). 그 출력을 그대로 사용자에게 보여준다 — 문구를 즉석에서 새로 짓지 않는다.
- **자동수정 제외(안내만):** `env-missing`(필수 설정값 누락) 중 사람만 아는 값·외부 자격증명, `note:"ask"` 항목, `inGitHistory` 시크릿, 아키텍처 변경이 필요한 경우. 이때는 "값을 알려주세요 / IT본부에 문의"로만 안내하고 자동수정·재폴링하지 않는다.

## ⑩ 확인 → 수정 → git push 재배포 → 재폴링 (≤2라운드)
1. **`AskUserQuestion`(고정 옵션):** `고쳐 주세요`·`안 할래요`. `안 할래요` 면 여기서 멈춘다.
2. **안전 스냅샷 먼저**(⑤와 동일 — 고치기 전 상태 보관, git 용어 비노출): "원래대로 되돌릴 수 있게 지금 상태를 보관했어요."
   ```bash
   git stash push -u -m "deploy-fix-snapshot $(date '+%Y%m%d-%H%M')" >/dev/null 2>&1 && git stash apply >/dev/null 2>&1 || true
   ```
3. **playbook 진단대로 코드 Edit.** 한 가지씩 고치고, **어떤 파일의 무엇을 고쳤는지** 쉬운 말로 통보한다(시크릿 미출력).
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
