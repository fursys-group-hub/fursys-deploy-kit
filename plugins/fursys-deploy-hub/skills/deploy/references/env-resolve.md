# 필요 설정값(env) 해결 규칙 — 범용 (모든 앱·모든 프레임워크 공통)

> deploy 가 앱(서비스)마다 보낼 설정값(env_vars)을 채울 때 따른다. **단일·멀티서비스 공통.**
> 핵심 원칙: **사람이 정할 필요가 없는 값은 묻지 않는다.** 난수 보안 키는 자동 생성하고, 사람만이 아는 값(관리자 비번·외부 자격증명)만 묻는다.
> 이 규칙은 특정 앱(cataloglens 등)이 아니라 **임의의 앱**에 적용된다 — 이름 패턴으로 판정한다(대소문자 무시).
> 비밀 **값**은 `services.json` 등 파일에 적지 않는다. deploy 시점에 해결해 **proxy 로만**(stdin) 보낸다.

## 1. 무엇이 필요한가 (키 목록 만들기)
- 그 앱(서비스) 디렉토리의 `.env`/`.env.example` 키 + 코드가 참조하는 env 를 합친다.
  - 코드 참조 키는 배포 전 검토(`/deploy-check`)의 엔진 결과(`envVars`)를 재활용한다. 없으면 그 서비스 dir 에서 `node "$CLAUDE_PLUGIN_ROOT/skills/deploy-check/scripts/fdh-engine.mjs" <dir> --json --no-prompt 2>/dev/null` 를 1회 돌려 `envVars` 를 얻는다(**stderr 는 버린다 — stdout 만 JSON, 로그가 섞이면 파싱 실패**).
- **멀티서비스면 서비스 dir 단위**로 키 목록을 만든다(각 서비스가 쓰는 것만).
- **`scope:"local"` 항목은 키 목록에서 제외한다.** `last-verdict.json` 의 `env_plan[].scope` 가 `"local"` 인 값은 배포 컨테이너에 안 들어가는 로컬 도구(ETL·갱신 스크립트) 전용이라 **묻지도·`env_vars` 에 넣지도 않는다**(`scope` 미지정/`"container"` 만 처리). 판정 근거는 deploy-check `deploy-readiness.md §8`(Dockerfile COPY 앵커).

## 2. 각 키를 어떻게 채우나 (위에서부터 순서대로 판정)
1. **이미 값이 있음** (`.env` 등에 비어있지 않은 값) → **앞뒤 따옴표만 정규화한 값**으로 사용(따옴표 없으면 그대로).
   - **따옴표 제거 규칙(결정적 — dotenv 동일, 모델 즉석 판단 금지):** `.env` 한 줄 `KEY=VALUE` 의 `VALUE` 를 `env_json` 의 `value` 로 실을 때 기계적으로 적용한다.
     1. 값의 **첫 글자와 끝 글자가 둘 다 `"`** 이거나 **둘 다 `'`** 이고 길이가 2 이상이면, 그 **바깥 한 쌍만** 제거한다. 내부 인용부호는 **보존**.
     2. **큰따옴표**(`"…"`)로 감싼 경우에만 dotenv 처럼 **이스케이프 해제**(`\n`→개행, `\"`→`"`, `\\`→`\`). **작은따옴표**(`'…'`)는 **literal**(이스케이프 해제 안 함).
     3. 따옴표로 **감싸지 않은** 값은 **그대로**(불변).
     4. **한쪽만 따옴표**(`"abc` 또는 `abc"`)는 짝이 안 맞으므로 **제거하지 않는다**(literal 보존 — 사용자 의도일 수 있음).
   - **검증 케이스:** `"a&b"`→`a&b` · `'x'`→`x` · `raw`→`raw`(불변) · `""`→빈 문자열 · `"postgresql://u:p@h:5432/db?a=1&b=2"`→따옴표 없는 raw(Prisma 통과) · `"say \"hi\""`→`say "hi"`(큰따옴표 이스케이프 해제) · `'say "hi"'`→`say "hi"`(작은따옴표 내부 보존) · `"abc`→`"abc`(짝 안 맞음, 불변).
   - **보안 불변식:** 시크릿(키·비밀번호) **값은 화면·로그·파일에 출력하지 않는다.** 정규화 결과 `env_json` 은 stdin 으로만 proxy 에 전달한다. `deploy.sh` 는 변경하지 않는다(조립된 값만 받음). proxy 가 받는 `env_vars[].value` 의미는 불변(따옴표 없는 raw — 지금까지 따옴표째 보내던 버그를 고치는 것).
2. **다른 서비스의 주소 참조** — 매니페스트 `build_env`/`runtime_env` 의 `${<svc>.url}` placeholder → deploy 가 실제 URL 로 치환한다(`multiservice.md`). 묻지 않음.
3. **fgdw(사내 DB) 접속정보** — **비워서 + 역할 태그(`fgdw_role`)를 달아 보낸다.** proxy 가 태그를 보고 사내 공용계정으로 결정적 치환한다. 묻지 않음. 상세는 **§2.3**.

### 2.3 fgdw 자격증명 — 역할 태깅 (핵심)
- **언제 fgdw 로 판정하나(감지 기준, 현행 유지):** 같은 서비스의 어떤 env 의 **값 또는 이름**에 fgdw IP(`192.9.201.23`) 또는 db명(`fgdw`)이 보이면, 그 서비스의 env set 을 fgdw 접속으로 본다.
- **접속그룹(connection-group) 스코핑 — 어떤 키가 fgdw 자격증명인지 좁히는 기준 (핵심):**
  - fgdw set 안에서 **접속정보(IP·db명)를 담은 앵커 키**를 찾는다(값이 fgdw IP 인 `DB_HOST`, 값이 `fgdw` 인 `DB_NAME` 등).
  - 그 앵커 키 이름의 **접두**(역할/컴포넌트 접미사 앞 토큰)를 도출한다: `DB_HOST`→`DB_`, `FGDW_DB_HOST`→`FGDW_DB_`.
  - **자격증명 태깅은 이 접속그룹 접두를 공유하는 키에만 적용한다.** 즉 `DB_HOST`/`DB_NAME` 이 앵커면 `DB_USER`·`DB_PASSWORD`(같은 `DB_` 접두)만 fgdw 자격증명으로 태그한다.
  - **접두가 명백히 다른 키는 역할 접미가 맞아도 태그하지 않는다(앱 도메인 값 보존).** 예: `HQ_ADMIN_ACCOUNT_ID`(접두 `HQ_ADMIN_ACCOUNT_`) — `*ACCOUNT`·`*ID` 패턴에 걸리지만 fgdw 접속그룹(`DB_`)이 아니므로 **fgdw 계정으로 덮지 않는다**. `SESSION_SECRET`(`SESSION_`)·`SUPABASE_PASSWORD`(`SUPABASE_`)도 같은 이유로 제외.
  - **안전판(방어 우선):** 앵커의 공통 접두를 도출할 수 없는 엣지(앵커가 접두 없는 bare 키이거나, 자격증명 후보가 접두 없는 `USER`/`PASSWORD` 인 경우)에서는 유출 방어를 위해 **이름 패턴만으로 태그**한다(broad). 접두를 못 가릴 땐 미탐(평문 유출)보다 방어를 우선한다. 접두가 **명백히 다를 때만** 제외한다.
- **그 set 안에서 키별 처리(접속그룹 접두를 공유하는 키에 한해):**
  - **아이디 성격 키**(이름이 `*USER`/`*ID`/`*UID`/`*ACCOUNT` 류, 또는 맥락상 계정) → `value:""`, `class:"locked"`, **`fgdw_role:"user"`** 를 단다.
  - **비밀번호 성격 키**(이름이 `*PASSWORD`/`*PW`/`*PWD`/`*SECRET` 류) → `value:""`, `class:"locked"`, **`fgdw_role:"password"`** 를 단다.
  - **host/db/port 등 비자격증명** → 태그하지 않고 **사용자가 쓴 이름·값 그대로** 보낸다.
- **키 이름은 표준으로 바꾸지 않는다(이번 규칙의 핵심).** 사용자의 `FGDW_DB_ID`·`DB_PW` 같은 비표준 이름을 그대로 둔 채 태그만 단다(이들도 앵커 `FGDW_DB_HOST`·`DB_HOST` 와 같은 접속그룹 접두를 공유하므로 태그 대상). proxy 가 태그를 보고 키 이름·값과 무관하게 `FGDW_SYS_USER`/`FGDW_SYS_PASSWORD` 로 덮는다.
- **⚠️ 회귀 케이스(desker-exhibit):** `HQ_ADMIN_ACCOUNT_ID`(앱 관리자 계정 ID)가 `*ACCOUNT`·`*ID` 패턴에 걸려 fgdw 시스템 계정(`a_hosting_groups`)으로 덮여, `VITE_HQ_ADMIN_ACCOUNT_ID` 까지 오염(빌드 번들 노출)되던 오탐. 접속그룹 스코핑으로 `DB_` 접두가 아닌 이 키들은 **태그하지 않아 원값이 보존**된다. 이 오탐은 desker 국한이 아니라 **fgdw 를 쓰면서 자체 관리자/외부 SaaS 계정 키를 가진 모든 앱의 구조적 오탐**이었다.
- **값은 빈 문자열 `""`** 로 보낸다(평문 비밀 미전송). proxy 가 어차피 시스템계정으로 덮으므로 원값은 무의미하다.
- **비표준 이름이면 태그하는 게 1차 방어다.** 태그를 달면 proxy 가 키 이름·값과 무관하게 결정적으로 치환한다 — **이것이 정상 경로다(반드시 태그할 것).**
- **하위호환·서버 안전판(태그 강제 아님):** 표준 이름(`FGDW_DB_USER`/`FGDW_DB_PASSWORD`)·연결문자열(`Server=…;User Id=…;Password=…;` 또는 `scheme://user:pass@host`)은 태그 없이도 proxy 폴백이 치환한다. 또한 **비표준 분리키**(예 `SQLSERVER_USER`/`DB_PW`)라도, 같은 set 에 fgdw host(`192.9.201.23`)+db(`fgdw`)가 함께 보이면 proxy 가 **키 이름 패턴**(user 류 `*USER`/`*ID`/`*UID`/`*ACCOUNT`, password 류 `*PASSWORD`/`*PW`/`*PWD`/`*SECRET`)으로 자격증명을 식별해 시스템계정으로 덮는다(개인계정 평문 유출 차단 — fc-cost-table 사고 방지). **이 서버 폴백도 접속그룹 스코핑을 적용한다** — 앵커(host/db) 이름 접두를 공유하는 키만 치환하고, 접두가 명백히 다른 앱 도메인 키(`HQ_ADMIN_ACCOUNT_ID`→`HQ_`, `SESSION_SECRET`→`SESSION_`, `SUPABASE_PASSWORD`→`SUPABASE_`)는 역할 접미가 맞아도 건드리지 않는다(과치환=엉뚱한 계정 주입으로 앱 크래시 방지). 앵커 접두를 못 가리면 방어(broad) 로 폴백한다. **다만 이 서버 폴백에만 기대지 말 것** — 이름이 패턴에서 벗어나면(예 `MY_ACCT`) 서버가 못 잡으므로, 비표준 이름은 **태깅이 우선이고 서버 폴백은 보조 안전판**이다.
- **단일·멀티서비스 공통:** 서비스 dir 별 env set 마다 위 규칙을 독립적으로 적용한다.

#### env item 최종 예시 (비표준 이름 + 태그, 접속그룹 스코핑)
```json
[
  { "key": "DB_HOST",             "value": "192.9.201.23", "class": "runtime" },
  { "key": "DB_NAME",             "value": "fgdw",         "class": "runtime" },
  { "key": "DB_PORT",             "value": "1672",         "class": "runtime" },
  { "key": "DB_USER",             "value": "", "class": "locked", "fgdw_role": "user" },
  { "key": "DB_PASSWORD",         "value": "", "class": "locked", "fgdw_role": "password" },
  { "key": "HQ_ADMIN_ACCOUNT_ID", "value": "app-admin", "class": "runtime" },
  { "key": "VITE_HQ_ADMIN_ACCOUNT_ID", "value": "app-admin", "class": "build" }
]
```
→ 앵커 `DB_HOST`(IP)·`DB_NAME`(fgdw) 접두 = `DB_`. proxy 가 **같은 `DB_` 접두**인 `DB_USER`→`FGDW_SYS_USER`, `DB_PASSWORD`→`FGDW_SYS_PASSWORD` 로 치환. host/db/port 는 그대로. **`HQ_ADMIN_ACCOUNT_ID`·`VITE_HQ_ADMIN_ACCOUNT_ID`(접두 `HQ_ADMIN_ACCOUNT_`)는 `*ACCOUNT`/`*ID` 패턴에 걸려도 접속그룹(`DB_`)이 아니므로 태그하지 않아 원값 보존**(빌드 번들 오염 없음).

> 표준 이름(`FGDW_DB_*`) 예도 동일 원리다: 앵커 `FGDW_DB_HOST`/`FGDW_DB_DATABASE`(접두 `FGDW_DB_`)면 `FGDW_DB_ID`/`FGDW_DB_PW`(같은 `FGDW_DB_` 접두)만 태그된다.
4. **앱 내부 난수 보안 키 → 자동 생성**(사람이 정할 값이 아님). 키 **이름**이 아래에 매칭되면:
   `SECRET_KEY` · `*_SECRET_KEY` · `JWT_SECRET*` · `SESSION_SECRET` · `NEXTAUTH_SECRET` · `*_SALT` · `ENCRYPTION_KEY` · `APP_KEY` · `CSRF_SECRET`
   → `scripts/gen-secret.sh` 로 강한 난수를 만들어 `class=locked` 로 전송. 사용자에겐 **"보안 키는 자동으로 안전하게 만들어 넣었어요"** 만 알린다(값 미출력). **묻지 않는다.**
5. **사람이 정하는 값 → 질문.** `ADMIN_PASSWORD` · `*ADMIN_PASSWORD` · 초기 관리자 비번류 → 한 개씩 쉽게:
   > "관리자 비밀번호를 정해서 알려주세요. (나중에 이 값으로 로그인합니다. 모르면 비워두고 IT본부에 문의하세요.)"
6. **외부 서비스 자격증명 → 질문**(추측·생성 불가). `*_API_KEY` · `*_TOKEN` · `*_ACCESS_KEY` · fgdw 가 아닌 외부 `*_PASSWORD`/`*_SECRET`(URL·호스트가 사외) · **Supabase 등 외부 서비스 접속값**(`SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY`/`SUPABASE_ANON_KEY`/외부 `DATABASE_URL` 류) → `note:"ask"`.
   > "이 앱이 '○○'(쉬운 설명) 값을 필요로 하는데 아직 없어요. 값이 있으면 붙여넣어 주세요."
   - **강제 게이트:** 배포 시 이 값이 비어 있으면 deploy 가 **배포 전에 반드시 묻는다**(`deploy` ④). 모델이 임의로 "선택값"이라 보고 건너뛰거나 빈 값으로 배포하지 않는다 — 비워두고 진행할지는 **사용자가 명시적으로 택할 때만**.
7. **그 외 일반값 → 자동(묻지 않음).** `NODE_ENV=production`, 포트(Dockerfile `EXPOSE`/기본), 공개 URL 등.

## 3. class 자동 분류 (사용자에게 묻지 않음)
- `NEXT_PUBLIC_*` / `VITE_*` / `REACT_APP_*` → `build` (빌드에 박히는 공개값)
- 비밀번호·키·토큰류(4·5·6에서 다룬 것) → `locked`
- 그 외 → `runtime`

## 4. 보안 불변식
- 자동 생성·수집·치환한 비밀 **값을 화면·로그·파일에 출력하지 않는다.** `services.json` 에도 비밀 값을 적지 않는다(키·출처만). 값은 deploy 가 `deploy.sh` 의 stdin(env_json)으로 proxy 에만 전달.
- 자동 생성 비밀은 **그 배포 세션 동안 한 번만 만들어 재사용**한다(같은 배포에서 매번 새로 만들지 않음). proxy 는 최초 생성 전담이라 보통 앱당 1회다. 이후 수정은 `git push` 자동 재배포라 이 값이 유지된다(자동생성 키를 바꾸려면 IT가 재설정).

## 예시 (cataloglens — 규칙의 한 인스턴스일 뿐, 전용 규칙 아님)
| 키 | 판정 | 처리 |
|---|---|---|
| `JWT_SECRET_KEY` | 4 (내부 난수) | gen-secret.sh 자동 생성, locked |
| `ADMIN_PASSWORD` | 5 (사람이 정함) | 질문 |
| `DB_HOST`(fgdw) | 3 (fgdw, 비자격증명) | 이름·값 그대로 |
| `DB_USER`(fgdw) | 3/§2.3 (아이디) | 비워 보냄 + `fgdw_role:"user"` → proxy 치환 |
| `DB_PASSWORD`(fgdw) | 3/§2.3 (비번) | 비워 보냄 + `fgdw_role:"password"` → proxy 치환 |
| `NEXT_PUBLIC_API_URL` | 2 (cross-URL) | `${api.url}` → deploy 치환, build |
| `NODE_ENV` 등 | 7 (일반) | 자동 |
