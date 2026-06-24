# 🚀 배포가능성 점검 (사내 서버 단일 컨테이너 전제)

> security-review 스킬이 "🚀 배포 가능성" 단계에서 쓰는 결정적(Bash) + 해석(LLM) 체크리스트다.
> 사내 서버는 **레포 루트의 `Dockerfile` 로 단일 컨테이너를 빌드**해 배포한다. 이 전제를 충족하지
> 못하면 보안이 통과여도 **배포 불가**다. (외부 호스팅·정적 자동빌드는 사내 정책상 다루지 않음 — 언급 금지.)
>
> 결과는 비개발자에게 보여야 하므로, 화면 문구는 쉬운 우리말을 쓰고 영어는 괄호로 병기한다.
> 심각도는 "치명/높음/중간/낮음".

## 목차
1. Dockerfile 존재 (없으면 배포 불가 = 치명)
2. EXPOSE 포트 ↔ 앱 실제 포트 일치
3. 시작 방법(ENTRYPOINT/CMD/start) 존재
4. 필수 실행 설정값(env) 누락
4-1. 영속 볼륨 필요 감지 (단일 서비스 — `volumes_plan`)
5. HEALTHCHECK 권장
6. 설정값 종류 분류 (빌드 포함 / 일반 / 잠금)
7. 배포가능 축 판정 규칙

---

## 1. Dockerfile 존재 (없으면 배포 불가 = 치명)

사내 서버 배포의 **최소 전제는 레포 루트의 `Dockerfile`**(또는 `Dockerfile.*`)이다.

```bash
ls -la Dockerfile Dockerfile.* 2>/dev/null || echo NO_DOCKERFILE
```

- **있음** → 통과(이 항목).
- **없음** → 배포가능 = **불가(치명)**. 화면 문구: "이 프로젝트엔 **Dockerfile(도커 설정)이 없어 지금은 배포할 수 없습니다.**"

### 빌드 방식 — Dockerfile 필수 (단일 **또는** 멀티서비스 둘 다 지원)
사내 서버는 **Dockerfile 로 컨테이너를 빌드**한다(빌드팩 자동감지 불가). 두 형태를 지원한다:
- **단일 서비스**: 레포 루트 `Dockerfile` 1개 → 앱 1개.
- **멀티서비스(여러 부분)**: 서브디렉터리마다 Dockerfile(예: `frontend/Dockerfile` + `backend/Dockerfile`) → 배포 전 검토가 감지해 `.fursys-deploy-hub/services.json` 을 만들고, 배포 시 **한 repo 를 앱 N개로** 올린다(`multiservice-detect.md`). docker-compose 는 **구조 힌트로만** 읽고 배포엔 쓰지 않는다.

다음만 있고 **Dockerfile 이 (루트에도 서브디렉터리에도) 하나도 없으면** 배포 불가(치명):
- Nixpacks(`nixpacks.toml` 만) / Heroku Buildpacks(`Procfile` 만) / 정적 사이트 자동빌드 / Compose 만 있고 빌드할 Dockerfile 이 없음

**이유(요약 — security-checklist §3.5):** 빌드·런타임 환경을 명시 통제하지 못하면 ODBC 드라이버·사내 CA·non-root 사용자·기업 프록시 같은 사내 요구사항을 일관 적용할 수 없다. **멀티서비스는 "별도 프로젝트로 분리"가 아니라 한 repo 안에서 서비스별 Dockerfile + 매니페스트로** 처리한다(플랫폼이 N개 앱으로 배포).

### Dockerfile 이 하나도 없을 때 안내
"배포하려면 **Dockerfile(도커 설정)이 필요합니다.** 아래 복붙 프롬프트로 표준 Dockerfile 을 만들어 달라고 하세요." (프레임워크별 표준은 `framework-rules.md`.) Compose 만 있으면 각 서비스 폴더에 Dockerfile 을 만들면 멀티서비스로 배포된다. (루트 Dockerfile 과 서브디렉터리 Dockerfile 이 함께 있으면, 멀티서비스 감지 규칙(`multiservice-detect.md`)으로 판단.)

### Dockerfile **내용** 함정 점검 (Node/npm 계열 — 빌드가 깨지는 정적-미탐 유형)
Dockerfile 이 **있어도** 내용 때문에 배포 빌드가 깨지는 두 유형은 이 검토(빌드 미실행)로는 놓치기 쉽다. Node 계열(Next.js·NestJS 등)이면 반드시 확인한다(상세·grep·정준 골격은 `framework-rules.md` Next.js ②-1/②-2):
- **빌드 단계 `NODE_ENV=production` →** `devDependencies`(tailwind·typescript 등) 스킵으로 `npm run build` 실패. `ENV NODE_ENV=production` 은 runner 에만.
- **`NEXT_PUBLIC_*`/`VITE_*` 빌드 인자 미선언 →** `ARG` 없으면 build-arg 가 무시되어 `undefined` 로 번들에 인라인(빌드는 통과, 런타임 깨짐). 코드가 쓰는 공개 변수마다 builder 에 `ARG`+`ENV` 필요.
- **non-root + 볼륨 경로 미준비 →** 앱이 `USER`(non-root)로 돌고 영속 볼륨(`services.json` 의 `volumes`, 예 `/data`)을 쓰는데, Dockerfile 이 `USER` 전에 그 경로를 `mkdir -p` + `chown` 하지 않으면, 볼륨이 **root 소유**로 마운트돼 컨테이너 사용자가 못 써 **배포 후 권한 에러로 크래시**(예: `PermissionError: '/data'`). 볼륨 경로가 있으면 Dockerfile 에 `RUN mkdir -p <경로> && chown <user> <경로>` 가 `USER` **앞**에 있는지 확인 → 없으면 **높음**. (빈 볼륨 첫 마운트 시 이미지의 그 경로 소유권이 복사되므로 이렇게 하면 해결.)

---

## 2. EXPOSE 포트 ↔ 앱 실제 포트 일치

Dockerfile `EXPOSE` 포트와 앱이 실제로 listen 하는 포트가 다르면 컨테이너가 "정상(healthy)"으로 인식되지 않는다.

```bash
grep -i '^EXPOSE' Dockerfile
```

- `EXPOSE` 가 없거나, 앱 실제 포트(프레임워크 기본: Next 3000 / Spring 8080 / Nest 3000 / Vite-nginx 80 / Streamlit 8501 / FastAPI·Django 8000)와 다르면 **높음**.
- 앱 실제 포트는 코드/실행 명령(`--server.port`, `--bind`, listen 호출)으로 LLM이 확인한다.
- 화면 문구: "프로그램이 실제로 쓰는 접속 포트와 도커 설정의 포트가 달라요. 맞춰야 정상 동작합니다."

> 참고: Streamlit/FastAPI/Django/uvicorn/gunicorn 은 `0.0.0.0` 바인딩이 아니면 컨테이너 밖에서 접속 불가 → 포트가 맞아도 죽은 것처럼 보인다. 이 점도 함께 확인.

---

## 3. 시작 방법(ENTRYPOINT/CMD/start) 존재

컨테이너가 떴을 때 무엇을 실행할지(시작 명령)가 없으면 컨테이너가 바로 종료된다.

```bash
grep -iE '^(CMD|ENTRYPOINT)' Dockerfile
```

- Dockerfile에 `CMD` 또는 `ENTRYPOINT` 가 있는지 확인. 없으면 베이스 이미지 기본 명령에 의존 → 대개 **높음**(앱이 안 뜸).
- Node 계열은 `package.json` 의 `start` 스크립트 존재도 함께 본다(`CMD ["npm","start"]` 패턴).
- 화면 문구: "컨테이너가 켜질 때 **무엇을 실행할지**가 정해져 있어야 합니다(시작 명령)."

---

## 4. 필수 실행 설정값(env) 누락

앱이 시작 시 꼭 필요로 하는 설정값(예: DB 주소, 토큰)이 비면 컨테이너가 떠도 곧바로 죽는다.

- 코드에서 참조하는 환경변수(`process.env.X`, `os.environ[...]`, `@Value("${...}")`, `import.meta.env.VITE_*`, `st.secrets[...]` 등)를 모으고, `.env`/`.env.example`/설정 검증 스키마(Joi/Zod/Pydantic)와 대조해 **꼭 필요한데 어디에도 값/기본값이 없는 것**을 찾는다.
- 누락된 필수값이 있으면 **높음**(컨테이너가 떠도 죽음). 화면 문구: "이 앱이 꼭 필요로 하는 설정값이 빠져 있어요. 비어 있으면 켜지자마자 멈춥니다."
- 단, fgdw(사내 DW) 접속 계정/비밀번호는 **클라이언트에서 채우지 않아도 됨**(배포 시 사내 공용 계정으로 자동 치환). 누락으로 보고하되 "IT가 배포 시 자동 처리"임을 함께 안내.

---

## 4-1. 영속 볼륨 필요 감지 (단일 서비스 — `volumes_plan`)

상태를 저장하는 단일 서비스 앱(SQLite·업로드 등)은 영속 스토리지가 없으면 **재배포 때마다 데이터가 사라진다.** 멀티서비스는 `services.json` 의 `volumes` 로 이미 처리되지만, 단일 서비스(매니페스트 없음)는 여기서 감지해 **`last-verdict.json` 의 `volumes_plan`(컨테이너 디렉터리 경로 배열)** 에 기록한다. 그러면 deploy 가 코드를 다시 안 뒤지고 `--volumes` 로 전달한다(env_plan 과 같은 캐싱).

**감지 신호(하나라도 해당 → 볼륨 필요):**
```bash
grep -iE '^\s*VOLUME' Dockerfile 2>/dev/null                  # Dockerfile VOLUME 선언
grep -riE 'better-sqlite3|[^a-z]sqlite3|DB_PATH|DATABASE_PATH' . --include='*.json' --include='*.ts' --include='*.js' --include='*.py' --include='.env*' 2>/dev/null | head
grep -riE 'UPLOAD_DIR|UPLOADS_DIR|STORAGE_DIR|DATA_DIR' . --include='.env*' --include='*.ts' --include='*.js' --include='*.py' 2>/dev/null | head
```
- **Dockerfile `VOLUME ["<경로>"]` 선언** — 그 경로가 영속 볼륨 후보.
- **SQLite 사용**(`better-sqlite3`/`sqlite3`/`DB_PATH=/dir/...`) + DB 파일 경로가 디렉터리 아래(`*.db`) — 그 **상위 디렉터리**가 후보(예: `DB_PATH=/data/memos.db` → `/data`).
- **업로드/저장 디렉터리 설정값**(`UPLOAD_DIR=/data/...` 등) — 그 디렉터리가 후보.
- **기록 규칙:** 후보 경로의 **상위 디렉터리**(파일 아님 — 예 `/data`)를 모아 중복 제거한다. 이 목록을 5-1(security-review SKILL)의 `volumes_plan` 에 적는다. 신호가 하나도 없으면 `volumes_plan` 은 생략하거나 `[]`(볼륨 미요청 — 현행 동일).

**non-root 권한 점검(단일 서비스에도 적용 — §1 의 멀티서비스 점검을 확장):** 볼륨 경로를 감지했으면, Dockerfile 이 `USER`(non-root) **앞에서** 그 경로를 `mkdir -p <경로> && chown <user> <경로>` 하는지 확인한다.
```bash
grep -niE '^\s*(USER|RUN .*mkdir|RUN .*chown)' Dockerfile 2>/dev/null
```
- `USER` 가 있고(non-root) 그 **앞**에 해당 볼륨 경로의 `mkdir`+`chown` 이 **없으면 → 높음**(빈 볼륨이 root 소유로 마운트돼 컨테이너 사용자가 못 써 **배포 후 권한 크래시**, 예: `PermissionError: '/data'`). 화면 문구: "이 앱은 자료를 저장하는데, 그 저장 공간을 앱이 쓸 수 있게 미리 준비하는 설정이 빠져 있어요(그대로 올리면 켜진 뒤 멈출 수 있어요)." + 복붙 프롬프트(아래).
  ```
  배포 후 앱이 영속 볼륨 경로 '<경로>'에 권한이 없어 크래시할 수 있어. Dockerfile 에서 USER(non-root) 줄 앞에 `RUN mkdir -p <경로> && chown <user> <경로>` 를 추가해줘. (<user> 는 그 Dockerfile 의 USER 값)
  ```
- root 로 도는 앱(`USER` 없음)이면 이 점검은 통과(권장 사항 아님). 볼륨 감지 자체는 그대로 `volumes_plan` 에 기록한다.

> 이 항목은 배포가능 축 판정을 **막지 않는다**(권한 미준비는 높음 경고이되, Dockerfile/포트/시작/필수env 같은 결정적 차단 항목은 아니다 — §7 참조). 단 `volumes_plan` 기록은 deploy 가 영속 스토리지를 마련하도록 항상 남긴다.

---

## 5. HEALTHCHECK 권장

```bash
grep -i 'HEALTHCHECK' Dockerfile
```

- 없으면 **낮음(권장)** 으로만 표시(배포를 막지 않음). 화면 문구: "상태 점검(HEALTHCHECK)을 넣으면 배포 후 정상 여부를 더 정확히 확인할 수 있어요(권장)."

---

## 6. 설정값 종류 분류 (빌드 포함 / 일반 / 잠금)

엔진이 낸 `envVars[].class`(`build`/`runtime`/`locked`)를 비개발자 말로 풀어 설정값 정리표에 쓴다.
분류 기준(coolify-injection-guide 요약):

| 종류(원어) | 기준 | 화면 설명(비개발자) |
|---|---|---|
| 빌드 포함(build) | `NEXT_PUBLIC_*`, `VITE_*` 등 빌드 결과물(번들)에 포함되는 값 | "화면(브라우저)에 포함될 수 있는 값 → **비밀번호·키는 절대 넣지 말 것**" |
| 일반(runtime) | 서버에서만 쓰는 일반 값(공개해도 사고 아님: 포트, 모드, 공개 URL 등) | "서버에서만 쓰는 일반 설정값" |
| 잠금(locked) | 비밀번호·키·토큰·DB 자격증명 등 유출 시 사고 | "비밀번호·키 → 안전하게 **잠가서 보관**(화면 노출 금지)" |

**판단 원칙:** 애매하면 일반(runtime)이 안전한 기본값. 단 비밀번호·키류는 무조건 잠금(locked). `NEXT_PUBLIC_*`/`VITE_*` 인데 비밀로 보이는 값이 있으면 보안 축에서 **치명/높음** 으로도 보고(번들 노출).

---

## 7. 배포가능 축 판정 규칙

- **1번(Dockerfile 없음)** = 치명 → 배포가능 = **불가**(다른 항목과 무관).
- 2·3·4번 중 하나라도 막히면(높음) → 배포가능 = **불가**(고쳐야 컨테이너가 정상으로 뜸).
- 5번(HEALTHCHECK)·6번 분류 경고는 **권고**일 뿐 배포를 막지 않는다.
- 위 결정적 항목이 모두 통과하면 배포가능 = **가능**.

> 최종 "배포 가능" = (보안 not 차단) AND (배포가능 = 가능). 둘 중 하나라도 막히면 배포 불가.
