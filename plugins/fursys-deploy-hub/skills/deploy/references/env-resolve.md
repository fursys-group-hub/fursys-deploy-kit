# 필요 설정값(env) 해결 규칙 — 범용 (모든 앱·모든 프레임워크 공통)

> deploy 가 앱(서비스)마다 보낼 설정값(env_vars)을 채울 때 따른다. **단일·멀티서비스 공통.**
> 핵심 원칙: **사람이 정할 필요가 없는 값은 묻지 않는다.** 난수 보안 키는 자동 생성하고, 사람만이 아는 값(관리자 비번·외부 자격증명)만 묻는다.
> 이 규칙은 특정 앱(cataloglens 등)이 아니라 **임의의 앱**에 적용된다 — 이름 패턴으로 판정한다(대소문자 무시).
> 비밀 **값**은 `services.json` 등 파일에 적지 않는다. deploy 시점에 해결해 **proxy 로만**(stdin) 보낸다.

## 1. 무엇이 필요한가 (키 목록 만들기)
- 그 앱(서비스) 디렉토리의 `.env`/`.env.example` 키 + 코드가 참조하는 env 를 합친다.
  - 코드 참조 키는 배포 전 검토(`/deploy-check`)의 엔진 결과(`envVars`)를 재활용한다. 없으면 그 서비스 dir 에서 `fdh-engine <dir> --json --no-prompt` 를 1회 돌려 `envVars` 를 얻는다.
- **멀티서비스면 서비스 dir 단위**로 키 목록을 만든다(각 서비스가 쓰는 것만).

## 2. 각 키를 어떻게 채우나 (위에서부터 순서대로 판정)
1. **이미 값이 있음** (`.env` 등에 비어있지 않은 값) → 그대로 사용.
2. **다른 서비스의 주소 참조** — 매니페스트 `build_env`/`runtime_env` 의 `${<svc>.url}` placeholder → deploy 가 실제 URL 로 치환한다(`multiservice.md`). 묻지 않음.
3. **fgdw(사내 DB) 접속정보** — **비워서 + 역할 태그(`fgdw_role`)를 달아 보낸다.** proxy 가 태그를 보고 사내 공용계정으로 결정적 치환한다. 묻지 않음. 상세는 **§2.3**.

### 2.3 fgdw 자격증명 — 역할 태깅 (핵심)
- **언제 fgdw 로 판정하나(감지 기준, 현행 유지):** 같은 서비스의 어떤 env 의 **값 또는 이름**에 fgdw IP(`192.9.201.23`) 또는 db명(`fgdw`)이 보이면, 그 서비스의 env set 을 fgdw 접속으로 본다.
- **그 set 안에서 키별 처리:**
  - **아이디 성격 키**(이름이 `*USER`/`*ID`/`*UID`/`*ACCOUNT` 류, 또는 맥락상 계정) → `value:""`, `class:"locked"`, **`fgdw_role:"user"`** 를 단다.
  - **비밀번호 성격 키**(이름이 `*PASSWORD`/`*PW`/`*PWD`/`*SECRET` 류) → `value:""`, `class:"locked"`, **`fgdw_role:"password"`** 를 단다.
  - **host/db/port 등 비자격증명** → 태그하지 않고 **사용자가 쓴 이름·값 그대로** 보낸다.
- **키 이름은 표준으로 바꾸지 않는다(이번 규칙의 핵심).** 사용자의 `FGDW_DB_ID`·`DB_PW` 같은 비표준 이름을 그대로 둔 채 태그만 단다. proxy 가 태그를 보고 키 이름·값과 무관하게 `FGDW_SYS_USER`/`FGDW_SYS_PASSWORD` 로 덮는다.
- **값은 빈 문자열 `""`** 로 보낸다(평문 비밀 미전송). proxy 가 어차피 시스템계정으로 덮으므로 원값은 무의미하다.
- **비표준 이름이면 반드시 태그해야 치환된다.** 태그를 빠뜨리면 proxy 가 그 변수를 알아보지 못해 경고로 빠진다.
- **하위호환(태그 강제 아님):** 표준 이름(`FGDW_DB_USER`/`FGDW_DB_PASSWORD`)이나 연결문자열(`Server=…;User Id=…;Password=…;`) 케이스는 태그를 안 달아도 proxy 폴백 경로가 알아서 치환한다. 비표준 이름일 때만 태깅이 필수.
- **단일·멀티서비스 공통:** 서비스 dir 별 env set 마다 위 규칙을 독립적으로 적용한다.

#### env item 최종 예시 (비표준 이름 + 태그)
```json
[
  { "key": "FGDW_DB_HOST",     "value": "192.9.201.23,1672", "class": "runtime" },
  { "key": "FGDW_DB_DATABASE", "value": "fgdw",              "class": "runtime" },
  { "key": "FGDW_DB_ID",       "value": "", "class": "locked", "fgdw_role": "user" },
  { "key": "FGDW_DB_PW",       "value": "", "class": "locked", "fgdw_role": "password" }
]
```
→ proxy 가 `FGDW_DB_ID` 를 `FGDW_SYS_USER` 로, `FGDW_DB_PW` 를 `FGDW_SYS_PASSWORD` 로 치환. host/db 는 그대로.
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
