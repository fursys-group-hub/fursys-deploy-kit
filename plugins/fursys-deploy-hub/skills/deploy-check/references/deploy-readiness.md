# 🚀 배포가능성 점검 (사내 서버 단일 컨테이너 전제)

> deploy-check 스킬이 "🚀 배포 가능성" 단계에서 쓰는 결정적(Bash) + 해석(LLM) 체크리스트다.
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
4-2. 볼륨 경로가 코드 WORKDIR 과 겹치면 안 됨 (재배포 코드 미반영 근본원인)
5. HEALTHCHECK 권장 (+ 5-1. localhost→IPv6 불일치 함정 — nginx·Node 공통 · 5-2. 대상 경로 점검 — 전용 경로인가·싸게 반환하는가)
6. 설정값 종류 분류 (빌드 포함 / 일반 / 잠금)
7. 배포가능 축 판정 규칙
8. 설정값이 컨테이너 안인가 로컬 도구 전용인가 (scope 판정 — Dockerfile 앵커)
9. 런타임 접속 대상 점검 (localhost 하드코딩 · 정적 배포에서 깨지는 내부 API 의존)
10. 응답 헤더 비-ASCII 리터럴 (런타임 env 주입 후에만 터지는 500 — 배포 전 grep 경고)
11. 동일 컨테이너 same-origin 이면 CORS 불필요 (경고 — B-2 하이브리드 단일컨테이너)

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
- **`RUN npm ci` 인데 `package-lock.json` 이 없음 → 첫 빌드 반드시 실패(높음).** `npm ci` 는 **락파일(`package-lock.json`)이 반드시 있어야** 동작한다(없으면 즉시 에러로 종료) → **첫 빌드가 확정 실패**(letus-edu 실사례). 이 검토는 빌드를 안 돌려 놓치기 쉬운 **확정 실패** 유형이라 **높음**. 결정적 grep 으로 탐지(락파일은 Dockerfile 빌드 컨텍스트 기준 — 단일 서비스는 보통 repo 루트, 멀티서비스는 각 서비스 dir):
  ```bash
  grep -qiE 'npm ci([[:space:]]|$)' Dockerfile && ! test -f package-lock.json \
    && echo "WARN: Dockerfile 이 'npm ci' 를 쓰는데 package-lock.json 이 없어 첫 빌드가 반드시 실패"
  ```
  → 자동수정 `type:"npm-ci-no-lock"`: Dockerfile 의 `npm ci` → `npm install` 로 **한 줄 치환**(락파일을 새로 만드는 게 아님 — `framework-rules.md` §1 ②-2 정준 골격이 `npm install` 을 쓰는 이유와 동일: Windows 개발 PC 에서 만든 락은 linux-musl 네이티브 의존을 누락해, 락 완전일치를 요구하는 `npm ci` 가 alpine 에서 오히려 깨진다). 화면 문구: "도커 설정이 잠금 파일 없이 'npm ci' 를 써서 **첫 빌드가 반드시 실패해요.** 'npm install' 로 바꾸면 됩니다." **오탐 가드:** 이미 `npm install` 이거나 `package-lock.json` 이 **존재하면** 정상 → 경고·수정 안 함(락파일이 있으면 `npm ci` 가 재현빌드에 오히려 안전하니 그대로 둔다).
- **non-root + 볼륨 경로 미준비 →** 앱이 `USER`(non-root)로 돌고 영속 볼륨(`services.json` 의 `volumes`, 예 `/data`)을 쓰는데, Dockerfile 이 `USER` 전에 그 경로를 `mkdir -p` + `chown` 하지 않으면, 볼륨이 **root 소유**로 마운트돼 컨테이너 사용자가 못 써 **배포 후 권한 에러로 크래시**(예: `PermissionError: '/data'`). 볼륨 경로가 있으면 Dockerfile 에 `RUN mkdir -p <경로> && chown <user> <경로>` 가 `USER` **앞**에 있는지 확인 → 없으면 **높음**. (빈 볼륨 첫 마운트 시 이미지의 그 경로 소유권이 복사되므로 이렇게 하면 해결.)
- **`public/` COPY 대상 없음(ERR-01, Next.js standalone) →** runner 가 `COPY --from=builder /app/public ./public` 을 하는데, 프로젝트 루트에 `public/` 디렉터리가 없고 builder 에 `RUN mkdir -p /app/public` 도 없으면, **빌드(`npm run build`)는 성공한 뒤 runner COPY 단계에서 `"/app/public": not found`(exit 1)** 로 깨진다(빌드 미실행 검토로는 놓치기 쉬운 정적-미탐 유형. OOM 의 137 과 구분 — 이건 메모리가 아니라 **경로** 문제). 점검:
  ```bash
  grep -qiE '^COPY .*[/ ]public( |$)|/app/public' Dockerfile && {   # Dockerfile 이 public 을 복사하나
    test -d public || grep -qE 'RUN +mkdir +-p +/app/public' Dockerfile || echo "WARN: public COPY 대상 없음(public/ 폴더도 mkdir 도 없음) → runner COPY 실패 위험"
  }
  ```
  → 둘 다 없으면 **높음**. 사전 차단: 빈 `public/.gitkeep` 추가(권장) **또는** builder 에 `RUN mkdir -p /app/public`(COPY 앞 — `framework-rules.md` Next.js ②-2 정준 골격엔 이미 포함). 화면 문구: "도커 설정이 `public` 폴더를 복사하는데 그 폴더가 없어 **빌드가 멈춰요.** 빈 `public` 폴더만 만들어 두면 됩니다." (이 항목은 빌드를 깨는 정적 유형이라 **높음** — 배포 전에 잡아야 빌드 실패·재시도를 피한다.)

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
# (item49) 파일 기반 상태저장 — SQLite/VOLUME 외에 순수 파일 쓰기(open(...,'w')·json.dump·fs.writeFileSync)로
#   data/·상태 파일을 지속 기록하는 앱. 재배포 때마다 사라지면 데이터 유실.
grep -rnoE "open\([^)]*['\"][^'\"]*\.(json|csv|txt|db|sqlite|dat)['\"][^)]*,\s*['\"][aw]" . --include='*.py' 2>/dev/null | grep -viE '/(node_modules|\.venv|tests?|fixtures?)/' | head
grep -rnoE "(fs\.(writeFileSync|writeFile|appendFileSync|createWriteStream)|json\.dump)\s*\(" . --include='*.py' --include='*.js' --include='*.ts' --include='*.cjs' --include='*.mjs' 2>/dev/null | grep -viE '/(node_modules|\.venv|tests?|fixtures?)/' | head
```
- **Dockerfile `VOLUME ["<경로>"]` 선언** — 그 경로가 영속 볼륨 후보.
- **SQLite 사용**(`better-sqlite3`/`sqlite3`/`DB_PATH=/dir/...`) + DB 파일 경로가 디렉터리 아래(`*.db`) — 그 **상위 디렉터리**가 후보(예: `DB_PATH=/data/memos.db` → `/data`).
- **업로드/저장 디렉터리 설정값**(`UPLOAD_DIR=/data/...` 등) — 그 디렉터리가 후보.
- **(item49) 순수 파일 기반 상태저장** — `open(path,'w'|'a')`·`json.dump(..., open(...))`·`fs.writeFileSync`·`fs.createWriteStream` 등으로 **런타임에 데이터/상태 파일을 쓰는데 그 경로가 앱 디렉터리 안**(예 `data/results.json`·`state.db`)이면, 재배포 때 이미지가 새로 빌드돼 **그 파일이 초기화(유실)** 된다. → 그 파일이 쓰이는 **디렉터리**를 볼륨 후보로 잡는다(예 `data/`→컨테이너 경로 `/app/data` 또는 `/data`). **오탐 주의:** 로그 출력(`app.log`)·빌드 산출물(`dist/`)·`/tmp` 임시파일·읽기전용(`open(...,'r')`)은 후보 아님. **"사용자가 만든 업무 데이터를 유지해야 하나"** 로 LLM 이 판정(단순 캐시/임시는 제외).
- **기록 규칙:** 후보 경로의 **상위 디렉터리**(파일 아님 — 예 `/data`)를 모아 중복 제거한다. 이 목록을 5-1(deploy-check SKILL)의 `volumes_plan` 에 적는다. 신호가 하나도 없으면 `volumes_plan` 은 생략하거나 `[]`(볼륨 미요청 — 현행 동일). **⚠️ 후보 경로가 코드가 사는 WORKDIR·COPY 대상과 겹치면(예 `/app`·`/app/app`) 그대로 `volumes_plan` 에 넣지 말고 §4-2 로 — 볼륨이 코드를 덮어 재배포해도 최신 코드가 안 반영된다.**

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

## 4-2. ⚠️ 볼륨 경로가 코드 WORKDIR 과 겹치면 안 된다 (item R9-1 — claim-ansung 근본원인)

**증상(치명급 마찰):** 재배포해도 **최신 코드가 반영 안 됨** — 새 이미지·새 컨테이너인데 앱 동작은 옛날 그대로. 여러 번 재배포해도 계속 옛것.

**근본 원인:** 영속 볼륨을 **코드가 있는 경로(WORKDIR 또는 그 하위)** 에 마운트하면, 배포 때 이미지에 새로 빌드된 코드 위에 **옛 볼륨 스냅샷이 덮어씌워진다.** claim-ansung 은 `WORKDIR /app` + 코드가 `app/` 하위(`/app/app/main.py`)라 `BASE_DIR=/app/app`, DB·업로드가 전부 `/app/app` 하위 → `volumes_plan:["/app/app"]` 로 잡혀 **볼륨이 코드 디렉터리를 통째로 덮음.** 그래서 새 코드가 옛 볼륨 내용으로 가려졌다. (덤: 그 볼륨이 root 소유로 마운트돼 non-root 앱이 쓰기 실패 → 권한 크래시까지 겹친다.)

**점검:** `volumes_plan`(또는 감지된 볼륨 후보) 경로가 Dockerfile 의 `WORKDIR` 이나 코드 COPY 대상과 겹치는지 본다.
```bash
WD="$(grep -iE '^WORKDIR' Dockerfile | tail -1 | awk '{print $2}')"   # 예 /app
# 볼륨 후보 경로가 WORKDIR 과 같거나 그 하위면 위험 (예 /app, /app/app, /app/data)
echo "WORKDIR=$WD ; 볼륨 후보가 이 경로(또는 하위)면 코드가 덮인다"
```
- 볼륨 후보가 **WORKDIR 자신 또는 그 하위**(코드가 실제 COPY 되는 경로)면 → **높음(재배포 시 코드 미반영·데이터/코드 혼재).**

**수정(데이터 전용 경로로 분리 — 코드와 절대 안 겹치게):**
1. **데이터 경로를 코드 밖(`/data`)으로 빼고 `DATA_DIR` env 로 주입한다.** 코드가 저장 위치를 하드코딩(`BASE_DIR/"claims.db"`)하지 말고 `os.environ.get("DATA_DIR", <로컬 기본>)` 를 읽게 한 뒤, DB·업로드를 `DATA_DIR` 하위로 옮긴다(claim-ansung 최종형):
   ```python
   DATA_DIR = Path(os.environ.get("DATA_DIR", str(BASE_DIR)))  # 로컬은 코드 옆, 배포는 /data
   DB_PATH = DATA_DIR / "claims.db"
   UPLOAD_DIR = DATA_DIR / "uploads"
   ```
   → `volumes_plan:["/data"]`(코드 밖) + `env_plan` 에 `DATA_DIR=/data`(runtime). 이러면 볼륨이 코드를 안 덮고, 재배포마다 최신 코드 + 보존 데이터가 공존한다.
2. **non-root 면 그 볼륨 경로 권한을 앱 사용자에게 준다.** 빈 볼륨은 첫 마운트 시 **root 소유**로 붙어 non-root 앱이 못 쓴다(PermissionError). 두 방법:
   - **(간단) Dockerfile 에서 `USER` 앞에 `RUN mkdir -p /data && chown <user> /data`** — 단, 이건 *이미지 안의 빈 디렉터리* 소유권만 바꾼다. Coolify/Docker 가 named volume 을 처음 만들 때 그 소유권을 복사하므로 대개 충분(§4-1 참조).
   - **(런타임 확실) entrypoint 에서 `chown` 후 non-root 로 강등(gosu/su-exec).** 볼륨이 런타임에 root 로 마운트되는 환경에서 확실히 통한다(카멕이 claim-ansung 에 적용한 패턴): 컨테이너는 root 로 시작 → entrypoint 가 `chown -R <user> /data` → `exec gosu <user> <원래 CMD>` 로 권한을 낮춰 앱 실행.
     ```dockerfile
     # (예시 골격 — 볼륨이 런타임 root 마운트라 이미지 chown 만으론 부족할 때)
     RUN apk add --no-cache su-exec    # 또는 gosu
     COPY entrypoint.sh /entrypoint.sh
     ENTRYPOINT ["/entrypoint.sh"]
     CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
     ```
     ```sh
     #!/bin/sh
     # entrypoint.sh
     mkdir -p "${DATA_DIR:-/data}" && chown -R appuser "${DATA_DIR:-/data}"
     exec su-exec appuser "$@"
     ```
- **자동수정 성격:** 저장 위치를 `DATA_DIR` 로 빼는 것은 **코드 몇 줄 + Dockerfile 변경**이라 침투적 → deploy-fix 는 **안내(복붙 프롬프트) 위주**로 하고 자동 일괄치환은 하지 않는다(저장 경로 로직은 앱마다 달라 오작동 위험). 이미 배포·운영 중인 앱이면 **데이터 유실 위험이 있으므로 반드시 사람이 판단**(볼륨 경로 변경은 기존 데이터 마이그레이션 동반).

> **볼륨 경로 규칙 요약:** *영속 볼륨은 코드가 사는 곳(WORKDIR·COPY 대상)이 아니라, 코드와 겹치지 않는 데이터 전용 경로(`/data`)에만 건다.* (오피스 MEMORY [[coolify-redeploy-commit-pin]] 와 동일 결론.)

---

## 5. HEALTHCHECK 권장 (+ nginx IPv6 불일치 함정)

```bash
grep -i 'HEALTHCHECK' Dockerfile
```

- 없으면 **낮음(권장)** 으로만 표시(배포를 막지 않음). 화면 문구: "상태 점검(HEALTHCHECK)을 넣으면 배포 후 정상 여부를 더 정확히 확인할 수 있어요(권장)."

### 5-1. `localhost` HEALTHCHECK = IPv6(`::1`) 불일치 롤백 (item66 + R9-5 — nginx·Node 공통, 있으면 높음)
HEALTHCHECK 이 **있어도** `wget/curl http://localhost/` 를 쓰면 배포가 깨질 수 있다(빌드·서빙은 정상인데 healthcheck 자가진단만 실패 → Coolify unhealthy 판정 → 롤백 → 신규 앱은 되돌릴 컨테이너가 없어 **404**). alpine 의 `localhost` 는 **`::1`(IPv6) 을 먼저** 시도하는데, 앱이 IPv6 를 안 듣고 있으면 연결 거부되기 때문이다. **두 갈래로 공통 발생:**
- **정적/nginx**: `nginx:alpine` 은 custom conf 를 쓰면 IPv6(`listen [::]:80`) 자동추가를 스킵 → IPv4 만 청취.
- **Node/Express·기타 서버(R9-5, fursys-import)**: 앱이 `app.listen(PORT, '0.0.0.0')`(또는 `'0.0.0.0'` 바인딩)이면 **IPv4 전용**으로 listen → HEALTHCHECK `localhost`(`::1`)가 리스너 없어 refused → 롤백. Python(uvicorn/gunicorn `--host 0.0.0.0`)·Go 등 `0.0.0.0` 바인딩 서버 전부 동일.

```bash
# (A) nginx custom conf 케이스
CONF="$(ls nginx.conf .nginx.conf default.conf 2>/dev/null; find . -maxdepth 2 -name '*.conf' -path '*nginx*' 2>/dev/null | head)"
if [ -n "$CONF" ] && ! grep -rqE 'listen\s+\[::\]' $CONF 2>/dev/null; then
  grep -qiE 'HEALTHCHECK.*localhost' Dockerfile && echo "WARN(nginx): custom conf 에 listen [::]:80 없음 + HEALTHCHECK localhost → IPv6 불일치 롤백 위험"
fi
# (B) 범용: 앱이 0.0.0.0(IPv4)로 바인딩하는데 HEALTHCHECK 가 localhost 면 위험 (Node/Python/Go 공통)
if grep -qiE 'HEALTHCHECK.*localhost' Dockerfile 2>/dev/null; then
  grep -rqE "listen\([^)]*['\"]0\.0\.0\.0['\"]|--host[= ]+0\.0\.0\.0|['\"]0\.0\.0\.0['\"]" . \
    --include='*.js' --include='*.ts' --include='*.mjs' --include='*.cjs' --include='*.py' --include='Dockerfile' 2>/dev/null \
    | grep -viE '/(node_modules|\.venv|dist|build)/' | head -1 >/dev/null \
    && echo "WARN(app): 앱이 0.0.0.0(IPv4) 바인딩 + HEALTHCHECK localhost → ::1 refused 롤백 위험(127.0.0.1 로 바꿔야 함)"
fi
```
- 해당하면 **높음**(배포 후 롤백→404). 화면 문구: "상태 점검이 앱에 접속하지 못해 **배포가 되돌려질 수 있어요(롤백).** 점검 주소를 `127.0.0.1` 로 바꾸면 돼요." 자동수정 `type:"healthcheck-ipv4"`(구 `nginx-healthcheck` 포함 — HEALTHCHECK `localhost`→`127.0.0.1` 한 줄 + nginx custom conf 면 `listen [::]:80` 동반) — 상세는 `framework-rules.md` §4 ②-1.
- **오탐 가드:** 앱이 이미 IPv6 도 듣거나(`listen('::')`·`listen [::]`), HEALTHCHECK 가 이미 `127.0.0.1`/`[::1]` 이면 경고 안 함. `0.0.0.0` 바인딩 + `localhost` HEALTHCHECK 조합일 때만 높음.

---

### 5-2. HEALTHCHECK 대상 점검 — 전용 경로인가 · 동작하는가 (item67, 있으면 중간)

HEALTHCHECK 이 **있고 연결도 되는데**(§5-1 통과) 대상이 잘못된 경우. 빌드·서빙·화면이 전부 정상이라
검토로 보이지 않는다. 점검 주기마다 테이블 전량이 DB→서버로 전송돼 egress 만 쌓이거나(sidiz-sitting-lab
실사례 — **일 2.35GB**), 설정 한 줄에 대상이 404 가 되어 롤백된다.

**1단계 — 대상 경로 추출 (결정적, 프레임워크 무관):**
```bash
# 주석이 아닌 HEALTHCHECK 문장을 백슬래시 줄이음까지 결합해 URL 경로만 뽑는다.
# CRLF(\r) 제거 필수 — Windows 체크아웃 레포에서 줄이음 결합이 깨진다(실측: 미제거 시 27건 중 25건 추출 실패).
# 주석 줄을 먼저 걸러야 한다 — 파일 상단 설명 주석의 'HEALTHCHECK' 를 먼저 집으면 실제 문장을 놓친다.
tr -d '\r' < Dockerfile | awk '
  /^[[:space:]]*#/ {next}
  /^[[:space:]]*HEALTHCHECK/ {
    s=$0
    while (s ~ /\\[[:space:]]*$/ && (getline nx) > 0) { sub(/\\[[:space:]]*$/,"",s); s = s " " nx }
    print s; exit
  }' | grep -oE 'https?://[^ "'"'"')]+' | sed -E 's|https?://[^/]*||'
```
- `/`·`/index.html`·`/health`·`/healthz`·`/api/health`·`/_stcore/health`·`/actuator/health`·`/livez`·`/readyz` → **전용 경로로 인정, 통과** (**끝 슬래시 유무는 무시한다** — Django `APPEND_SLASH` 관례상 `/health/` 로 잡히는 게 정상이다)
- 그 외 → 화면·업무용 엔드포인트를 빌려 쓴 것이므로 2단계
- 단 `/` 는 **정적 서빙 증거**(`express.static`·`send_from_directory`·`StaticFiles`·nginx `root`/`try_files`)가 있을 때만 인정. Django/Flask 처럼 `/` 가 DB 로 페이지를 만드는 서버렌더링이면 2단계로 보낸다.

**2단계 — 그 경로의 핸들러를 찾아 판정 (LLM).** 라우트 정의 문법이 프레임워크마다 달라
(Express `app.get('/x')` · FastAPI `@app.get("/x")` · Flask `@app.route` · Django `urls.py`→`views.py` ·
Spring `@GetMapping` · Next.js 파일기반) **이 단계를 단일 grep 으로 만들지 않는다** — Python·Java·Next.js
앱에서 조용히 미발화해 "검사했는데 문제없음" 으로 보이는 게 가장 나쁘다.

- **(a) 항상 200 인가:** 라우트 등록이 **조건부**인지 본다. 환경변수·디버그 플래그 분기 안에서 등록되면
  그 조건이 거짓일 때 404 → 롤백. FastAPI `docs_url=... if ... else None`, Django `if settings.DEBUG`,
  Express `if (process.env.NODE_ENV !== 'production')` 등 → **중간**.
  화면 문구: "상태 점검 주소가 **설정에 따라 사라질 수 있어요.** 항상 열려 있는 전용 주소로 바꾸는 게 좋아요."
- **(b) 싸게 반환하는가:** 핸들러가 상수·정적 파일 반환이거나 DB 접근이 `SELECT 1`·`count(*)`·`LIMIT 1`
  수준이면 통과. **`SELECT *`·`LIMIT` 없는 조회·행 목록 반환**(`res.json(result.rows)` 등) → **중간**.
  화면 문구: "상태 점검이 **데이터 조회 API** 를 30초마다 호출해서 **DB 통신량이 크게 발생할 수 있어요.**
  가벼운 전용 주소로 바꾸는 게 좋아요."

**(d) 점검 명령이 이미지에 있는가 (결정적):**
```bash
# 판정 기준은 HEALTHCHECK 이 도는 스테이지 = 멀티스테이지면 **마지막** FROM.
# 빌더 alpine + 런타임 nginx/Debian 이 이 룰셋의 정준 골격(§1 ②-2·§4 ②)이라,
# 첫 FROM 에 앵커하면 "alpine 이니 wget 있음" 으로 조용히 미탐한다.
tr -d '\r' < Dockerfile | grep -iE '^[[:space:]]*FROM' | tail -1
grep -iE 'HEALTHCHECK|^[[:space:]]+CMD' Dockerfile | grep -oE '\b(wget|curl)\b' | head -1
grep -qiE 'apt-get install.*(wget|curl)|apk add.*(wget|curl)' Dockerfile   # 설치 줄 유무
```
**"Debian 계열" 로 뭉뚱그려 판정하지 않는다 — 같은 Debian 이라도 변종마다 정반대다.** 마지막 FROM 의
이미지 이름으로 본다(설치 줄이 있으면 아래와 무관하게 통과):

| 마지막 FROM | `wget` | `curl` | 판정 |
|---|---|---|---|
| `alpine:*` · `*-alpine` | ✅ busybox 내장 | ❌ | `curl` 을 쓰면 **높음**, `wget` 이면 통과 |
| `nginx:*`(alpine 태그 제외) | ❌ | ❌ | 둘 중 무엇을 쓰든 **높음** |
| `*-slim`(`node:*-slim`·`python:*-slim`) | ❌ | ❌ | **높음** |
| `debian:*` · `ubuntu:*` | ❌ | ❌ | **높음** |
| `node:<n>` · `python:<n>` (변종 접미사 없는 full) | ✅ | ✅ | **통과** — buildpack-deps 기반이라 둘 다 있다 |

해당하면 **높음**(기동은 정상인데 헬스체크만 ExitCode 1 → 롤백. iloom-channel-sales-dashboard
실사례 2026-08-24). **표에 이름이 없는 이미지는 경고하지 않는다**(아래 미검증 ② — 근거가 한 건뿐이라
넓게 잡으면 `node:20` 같은 흔한 베이스에 불필요한 설치 층을 넣게 된다).

**자동수정:** (a)(b) 는 **담지 않는다** — 앱 코드에 새 엔드포인트를 추가해야 하므로(`healthcheck-ipv4` 처럼
한 줄 치환이 아니다) `deploy_fixes` 에 넣지 말고 복붙 프롬프트로만 안내. (d) 는 자동수정 가능 —
`type:"healthcheck-cmd-missing"`(설치 한 줄. **반드시 `HEALTHCHECK` 이 속한 스테이지 = 마지막 `FROM`
뒤에** 넣어야 한다. 지침·오탐 가드는 `../deploy-fix/SKILL.md` ⑤).
규칙 상세·유형별 전용 경로 표는 `framework-rules.md` §8 item67.

**실측(2026-08-25 · 사내 레포 43개 / HEALTHCHECK 27건):** 1단계 경로 추출 성공 27/27(파싱 실패 0).
전용 경로 인정 23(정적 루트 15 · 전용 규약 8), 2단계 대상 4. 2단계 판정: Flask `/api/version`(상수 반환 → 통과) ·
Next.js `/login`(`"use client"` 컴포넌트 → 통과) · FastAPI `/docs`(**(a) 위반**) ·
Express+node:sqlite `/api/courses`(**(b) 위반 — `SELECT *` 무제한 + N+1**). **오탐 0 · 미탐 0**
(수정 전 sidiz `/api/reports` 정상 검출).

**미검증:** ① Django·Spring Boot 서버렌더링 앱이 표본에 없어 `/` 가 DB 를 타는 케이스는 실측하지 못했다.
1단계의 "정적 서빙 증거" 가드가 그 대비다. ② **(d) 는 위 27건에 돌려보지 않았다** — 위 "오탐 0 · 미탐 0"
은 1·2단계까지의 숫자이고, (d) 의 근거는 iloom-channel-sales-dashboard 한 건이다. 그래서 (d) 는 표에
이름이 있는 이미지에만 경고하고 모르는 이미지는 통과시킨다(좁게 잡아 오탐을 만들지 않는 쪽).

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

---

## 8. 설정값이 컨테이너 안인가 로컬 도구 전용인가 (scope 판정 — Dockerfile 앵커)

설정값(env) 중에는 **배포 컨테이너에 아예 안 들어가는 코드**(로컬 ETL·자료 갱신 스크립트, 예 `scripts/fgdw/*.cjs`·`refresh.ps1`)만 쓰는 것이 있다. 이런 값은 배포에 필요 없으므로 deploy 가 묻지도·주입하지도 않아야 한다. 그 구분을 여기서 **Dockerfile COPY 앵커**로 판정해 각 env 에 `scope`(`container`/`local`)를 부여한다. 결과는 5-1(deploy-check SKILL)의 `env_plan[].scope` 에 적는다.

> **`scope` 와 `class`/`note` 는 직교다.** `class`(build/runtime/locked)·`note`(fgdw/ask 등) = *컨테이너 안에서* 그 env 를 어떻게 다루나. `scope` = *컨테이너 안에 들어가나(빌드+런타임), 로컬 도구 전용이나.* 둘을 합치지 말 것. **기본값은 `container`**(생략 = container, 하위호환).

### 판정 절차 (결정적 — 휴리스틱·폴더이름 추측 금지)
1. **COPY 대상 파일집합 산출.** Dockerfile(루트, 멀티스테이지 전부)의 `COPY`/`ADD` 인자로 **컨테이너 어느 스테이지든 들어가는 파일·디렉터리 집합**을 구한다. `COPY --from=<stage>` 로 이전 스테이지 산출물(빌드 결과)을 가져오는 경로도 포함한다.
   ```bash
   grep -niE '^\s*(COPY|ADD)' Dockerfile 2>/dev/null
   ```
   (예 scm-monitoring: builder `COPY inventory-monitoring/ .` → `inventory-monitoring/**`, runner `COPY --from=builder /app/build` → 빌드 산출물.)
2. **각 env 의 참조 파일을 본다.** 그 env 이름을 참조하는 소스 파일(코드/`.env`)이 위 COPY 집합 **안**이면 → **`container`**. `CMD`/`ENTRYPOINT` 가 실행하는 코드가 읽으면 런타임, 빌드 단계(`RUN ... build`)에서 인라인되면 빌드타임 — **어느 쪽이든 `scope=container`**.
3. **컨테이너 밖 파일만 참조하면 → `local`.** 그 env 가 **COPY 집합에 없는 파일**(예 `scripts/fgdw/*.cjs`·`refresh.ps1`)에서만 참조되고, 컨테이너 안 파일 어디서도 안 쓰이면 → **`local`**.
4. **불확실하면 `container`(보수적).** COPY 범위 산출이 모호하거나(와일드카드·복잡한 멀티스테이지), 같은 env 가 컨테이너 안/밖 양쪽에서 참조되면 → **`container` 유지**.

### 보수적 편향 (안전 핵심 — 불변식)
- **오분류 비대칭:** 런타임/빌드 env 를 `local` 로 오판 → deploy 가 값을 안 넣어 **앱이 설정값 없이 크래시**(비개발자는 원인도 못 찾음) = **치명**. 로컬 env 를 `container` 로 오판 → deploy 가 불필요 질문 1번 = **경미**.
- **→ 불확실하면 무조건 `container` 유지.** `scope:"local"` 은 **Dockerfile 상 컨테이너 밖임이 확실할 때만** 부여한다.
- **`VITE_*`/`NEXT_PUBLIC_*` 는 빌드타임 → 항상 `container`(local 금지).** 정적 빌드(Vite→nginx)라도 이 값들은 빌드 단계(`RUN npm run build`)에서 번들에 인라인되므로 컨테이너 안이다. `local` 로 빼면 build-arg 가 안 들어가 빌드가 깨지거나 `undefined` 로 인라인된다. (Vite 의 빌드타임 내장값 `import.meta.env.BASE_URL` 등도 마찬가지로 `container`.)

### scm-monitoring 적용 예 (검증된 결과 — 규칙을 손으로 따라간 결과)
Dockerfile: builder `COPY inventory-monitoring/ .`(+ runner `COPY --from=builder /app/build`). → **COPY 집합 = `inventory-monitoring/**`(+ 빌드 산출물 `build/`).** `scripts/fgdw/*.cjs`·`scripts/supabase/*.cjs`·`refresh.ps1` 은 **집합 밖.**

| env | 참조 파일 | 판정 |
|---|---|---|
| `BASE_URL` | `inventory-monitoring/**`(`import.meta.env.BASE_URL`, Vite 빌드타임 내장값) | **`container`**(class=build — local 금지) |
| `TABLEAU_SERVER`·`TABLEAU_USER`·`TABLEAU_PW` | `scripts/fgdw/extract-tableau-supply-plan.cjs` 등 ETL 만 | **`local`** |
| `SOC_SHEET_ID`·`CUSTOMER_IMPACT_SHEET_ID` | `scripts/fgdw/parse-*.cjs` ETL 만 | **`local`** |
| `MSSQL_SERVER/PORT/DATABASE/USER/PASSWORD` | `scripts/fgdw/conn.cjs` ETL 만 | **`local`** |
| `SUPABASE_DB_URL` | `scripts/supabase/*.cjs` ETL 만(컨테이너 안 코드는 미참조) | **`local`** |
| `BRANDS`(env)·`FULL`·`LOOKBACK_MONTHS` | `scripts/**` ETL 파라미터만(`.tsx` 의 `BRANDS` 는 코드 내 const 배열이지 env 가 아님) | **`local`** |

> ⚠️ **`BRANDS` 주의:** `inventory-monitoring/**` 의 `.tsx` 에 `const BRANDS = [...]` 가 보이지만 이는 **코드 안의 배열 리터럴**이지 `import.meta.env.BRANDS` 가 아니다(=env 참조 아님). env `BRANDS` 는 `scripts/supabase/migrate-item-history.cjs` 의 `process.env.BRANDS` 만 → `local`. 코드의 동명 식별자에 속지 말고 **env 참조(`process.env.X`/`import.meta.env.X`)인지** 본다.

**기대 효과:** scm-monitoring 재검토 시 ETL 전용 env 가 `scope:"local"` 로 분류 → deploy 가 TABLEAU/SHEET/MSSQL/SUPABASE 를 **묻지 않고** nginx 정적 앱을 바로 배포(현재는 강제 질문). `BASE_URL` 은 `container` 로 남아 빌드 정상.

---

## 9. 런타임 접속 대상 점검 (localhost 하드코딩 · 정적 배포에서 깨지는 내부 API 의존)

빌드·기동이 정상이어도 **앱이 접속하려는 대상이 배포 환경에 없으면** 화면은 뜨는데 기능이 죽는다(사용자는 "왜 데이터가 안 나와요?"). 검토는 빌드를 안 돌리므로 놓치기 쉽다 — 아래 두 유형을 소스에서 확인한다. **이건 배포가능 축을 막지 않는 "기능 경고"**(§7 결정적 차단 항목 아님)이므로, verdict 는 ok 여도 리포트에 별도로 표시해 배포 후 깨짐을 예고한다.

### 9-1. `localhost`/`127.0.0.1` + 포트 하드코딩 (item63)
클라이언트/서버 코드가 `http://localhost:PORT` 또는 `http://127.0.0.1:PORT` 를 **접속 대상으로 하드코딩**하면(예: `const SERVER='http://localhost:5002'` 를 `fetch(SERVER+...)` 에 사용), 배포 컨테이너/브라우저에는 그 포트의 서비스가 없어 **연결 거부**로 기능이 깨진다.
```bash
# 접속 대상으로 쓰이는 localhost/127.0.0.1:포트 하드코딩 (주석·문서는 노이즈 → 코드 파일만)
grep -rnoE 'https?://(localhost|127\.0\.0\.1)(:[0-9]+)?' . \
  --include='*.js' --include='*.jsx' --include='*.ts' --include='*.tsx' \
  --include='*.mjs' --include='*.cjs' --include='*.py' --include='*.html' --include='*.vue' \
  2>/dev/null | grep -viE '/(node_modules|\.venv|dist|build)/' | head -30
```
- 매칭이 **fetch/axios/XHR/requests/WebSocket 등 실제 접속에 쓰이면 → 높음**(기능 깨짐). 화면 문구: "앱이 **내 PC(localhost) 주소로 접속**하도록 되어 있어요. 사내 서버에 올리면 그 주소가 없어 **해당 기능이 동작하지 않습니다.** 접속 주소를 설정값(env)으로 빼거나 상대경로(`/api/...`)로 바꿔야 해요."
- **오탐 주의(높음으로 올리지 않음):** ① 개발용 CORS 허용목록·`--server.address` 바인딩(`0.0.0.0`/`localhost` listen)·주석·README 예시 → 접속 대상이 아니므로 경고 안 함. ② 이미 `process.env.X || 'http://localhost:PORT'` 처럼 **env 우선 + localhost 는 로컬 폴백**이면 배포 시 env 로 대체되니 **낮음(안내만)** — env 를 배포 설정값으로 넣도록만 짚는다. **"실제 접속 대상으로 쓰이는 순수 하드코딩"일 때만 높음.**
- 자동수정 성격: 접속 주소는 보통 **env 로 분리 + 로컬 폴백**(`const SERVER = process.env.API_BASE || '/api'` 또는 상대경로)이 정답. 어느 대상으로 바꿀지는 앱 구조 판단이라 복붙 프롬프트로 안내(자동 일괄치환 금지 — 여러 대상이 섞이면 오작동).
- **(item45) env 폴백 기본값이 외부 호스팅 URL(`process.env.SHEETS_REFERER || 'https://xxx.vercel.app'`)이면 → 낮음(안내).** 배포 설정값을 넣으면 대체되지만, 안 넣으면 **외부 주소로 요청이 나가거나 그 도메인으로 403** 이 난다(사내 정책·기능 양쪽 문제). 폴백 기본값은 **사내 도메인이나 빈 문자열('')/상대경로**로 바꾸도록 안내한다(외부 호스팅 도메인을 코드 기본값에 남기지 않는다 — round7 item31·framework-rules §10 연장). 자동수정보다 "배포 설정값으로 사내 주소를 넣으세요 + 코드 기본값은 사내/빈값으로" 안내가 우선.

### 9-2. 상대경로 내부 API 의존 페이지를 "순수 정적"으로 오판 (item64)
`fetch('/scp/api/...')`·`axios.get('/api/data')` 처럼 **상대경로 내부 API** 를 호출하는 페이지는, **nginx 등 정적 서버 단독**으로 배포되면 그 `/api` 를 받아 줄 백엔드가 없어 **404 로 기능이 깨진다**(HTML·CSS·JS 는 떠서 겉보기엔 정상 → verdict ok 인데 기능 불가). "정적 사이트니 nginx 로 올리면 끝"이라 **오판하기 쉬운 게 핵심.**
```bash
# 상대경로 내부 API 호출(스킴 없이 / 로 시작) — 정적 배포면 받아줄 백엔드가 필요
grep -rnoE "(fetch|axios(\.(get|post|put|delete|patch))?|XMLHttpRequest)[^\n]{0,40}['\"]/[a-zA-Z0-9_]" . \
  --include='*.js' --include='*.jsx' --include='*.ts' --include='*.tsx' --include='*.html' --include='*.vue' \
  2>/dev/null | grep -viE '/(node_modules|\.venv|dist|build)/' | head -30
```
- **판정(LLM 맥락):** 이 repo 의 배포 형태가 **정적 서빙(nginx/serve, 백엔드 프로세스 없음)** 인가를 먼저 본다(Dockerfile 이 nginx:alpine 등 정적 서버이고, `/api` 를 처리할 서버 코드·프록시(`proxy_pass`)·멀티서비스 백엔드가 없음). 그렇다면 위 상대경로 API 를 쓰는 페이지들은 **배포 후 기능 불가 → 높음(기능 경고)**. 화면 문구: "이 앱의 일부 화면(○○·○○)은 **자체 데이터 서버(API)** 에 연결해야 동작하는데, 지금 방식(정적 파일 서버 단독)으로 올리면 그 부분이 **작동하지 않습니다.** 정적으로 서빙 가능한 화면만 쓰거나, 데이터 서버를 함께 올리는(멀티서비스) 구성이 필요해요."
- **오탐 주의:** ① 백엔드가 같은 앱에 함께 뜨거나(FastAPI/Express 가 정적 + `/api` 둘 다 서빙), ② nginx conf 에 `/api` `proxy_pass` 로 사내 API 를 프록시하거나, ③ 멀티서비스로 백엔드 서비스가 함께 배포되면 → **정상(경고 안 함).** "상대경로 API 를 쓴다"만으로 무조건 경고하지 말고 **"이 배포 구성에서 그 API 를 받아 줄 것이 있나"** 로 판정한다.
- **#51(IS_FURSYS 호스트분기)·#65(외부 SaaS 직접의존)·Supabase 직접호출도 같은 계열**(브라우저가 배포 환경에 없는 대상에 접속) — 그쪽은 `framework-rules.md` §10(외부 PaaS) 로, 이 §9 는 **내부/localhost 접속 대상**을 다룬다.

> **§9 는 verdict 를 막지 않는다(§7 불변).** localhost 하드코딩·정적배포 API 의존은 "높음(기능 경고)"으로 리포트에 표시하되, Dockerfile/포트/시작/필수env 같은 배포가능 축 결정 항목은 아니다. 사용자가 "기능 일부 깨져도 겉은 뜬다"는 걸 배포 전에 알게 하는 게 목적이다(iloomscm 처럼 겉은 200 인데 특정 페이지 기능 불가 — 사후 혼란 방지).

---

## 10. 응답 헤더에 비-ASCII 리터럴 (item R9-4 / G-new-9 — 런타임 env 주입 후에만 터지는 500)

**증상(치명급 카테고리):** 보안 검토·배포가능성 다 통과했는데 **배포 직후 첫 접속부터 500.** 로컬 개발에선 멀쩡했다.

**근본 원인 — "정적 검증이 못 잡는, 런타임에만 열리는 코드 경로":** HTTP **응답 헤더 값**에는 latin-1 로 인코딩 안 되는 문자(한글 등)를 넣으면 서버(Starlette/Express 등)가 헤더를 만들 때 `UnicodeEncodeError` 로 500 을 낸다. 위험한 건 이 경로가 **평소엔 실행 안 되다가 배포 후 env 가 채워질 때 처음 열리는** 유형이다(review-guide-checker):
- `WWW-Authenticate: Basic realm="체험단 검수 도구"`(한글 realm) → 로컬은 `APP_PASSWORD` 미설정이라 인증 미들웨어가 우회돼 이 줄이 **한 번도 실행 안 됨.** 배포 때 `env_plan` 대로 `APP_PASSWORD` 를 처음 채우면 인증 분기가 활성화 → 첫 무인증 요청에서 즉시 500.
- `Content-Disposition: attachment; filename*=UTF-8''파일명_검수이력.xlsx`(퍼센트 인코딩 없는 한글 파일명) → 그 다운로드 라우트를 처음 호출할 때 500.

**→ deploy-check 가 응답 헤더에 들어가는 문자열 리터럴을 grep 해 비-ASCII 포함 여부를 배포 전에 경고**하면 "env 채워지면 터지는" 사고를 예방할 수 있다(정적으로 값이 안 채워져 있어도 리터럴은 코드에 보인다).
```bash
# 응답 헤더 딕셔너리/설정에 들어가는 문자열 중 비-ASCII(한글 등) 포함 라인
# (headers={...}·set_header·WWW-Authenticate·Content-Disposition 조합)
grep -rnE "(headers\s*[=:]\s*[\{\(]|WWW-Authenticate|Content-Disposition|set_header|setHeader|add_header|Response\([^)]*headers)" . \
  --include='*.py' --include='*.js' --include='*.ts' --include='*.mjs' --include='*.cjs' 2>/dev/null \
  | grep -viE '/(node_modules|\.venv|dist|build|tests?|fixtures?)/' \
  | perl -ne 'print if /[^[:ascii:]]/' | head -20
```
> 비-ASCII 필터는 `grep -P '[^\x00-\x7F]'` 가 일부 환경(Windows Git Bash 로케일)에서 `-P supports only unibyte and UTF-8 locales` 로 실패한다 → **`perl -ne 'print if /[^[:ascii:]]/'`** 로 거른다(POSIX·이식성). perl 이 없으면 `awk '/[\x80-\xff]/'`(gawk) 대체.
- 헤더 값에 비-ASCII 가 보이면 → **높음(배포 후 500 위험)**. 화면 문구: "응답 헤더에 한글이 들어가 있어요 — 배포 후 특정 요청에서 **500 오류**가 날 수 있어요(헤더는 영문/ASCII 만 가능). realm 이름은 영문으로, 파일명은 퍼센트 인코딩(`quote()`)으로 바꿔야 해요."
- **자동수정 성격:** ① `realm="한글"` → 영문 라벨로(값 자체는 표시용이라 안전). ② `Content-Disposition` 파일명은 `urllib.parse.quote(name)`(Python)/`encodeURIComponent`(JS) + ASCII 폴백 파일명 병기(RFC 6266/5987). **응답 바디(body/content)의 한글은 문제 없음**(latin-1 제약은 헤더에만) — 바디는 건드리지 않는다.
- **오탐 가드:** 응답 **바디**(`content=`·`body=`·`res.send(...)`)의 한글, 주석·로그 문자열, 요청(request) 헤더 읽기는 대상 아님. **응답 헤더 값으로 조립되는 리터럴**일 때만 경고(위 grep 은 헤더 조합 앵커로 좁힘 — LLM 이 실제 헤더값인지 최종 확인).
- **연계:** 예외 은폐 구조(인증 미들웨어가 다운스트림까지 try/except 로 감싸 이 500 을 401 로 위장) 는 `owasp-checklist.md` §1-16(안내성) 참조 — 원인 추적을 사실상 불가능하게 만든다. 이 §10 은 그 **원인(헤더 한글)** 을, §1-16 은 그 **증상 은폐** 를 각각 다룬다.

> **§10 은 verdict 를 막지 않는 "배포 후 오류 예고"**(§9 와 동급 — 기능/런타임 경고). 다만 500 은 앱 전체를 죽일 수 있어 **높음**으로 표시하고 배포 전 수정을 강권한다.

---

## 11. 동일 컨테이너 same-origin 이면 CORS 불필요 (경고 — B-2 하이브리드 단일컨테이너)

백엔드가 프론트(정적 파일)를 **같은 컨테이너에서 same-origin 으로 서빙**하면, 브라우저는 프론트를 API 와 **같은 출처(origin)** 에서 로드하므로 **교차출처(CORS)가 발생하지 않는다** → CORS 미들웨어와 `CORS_ORIGIN`/`ALLOWED_ORIGINS` 류 설정값은 **불필요·혼동요소**다(오히려 origin 을 잘못 넣어 배포 후 앱이 자기 자신을 차단하는 사고를 부른다). 이 경우 리포트에 "불필요" **경고**로 표시한다. **verdict 는 막지 않는다**(§7 불변 — 정리 권고).

**"단일 컨테이너 same-origin" 확신 판정 (아래를 *모두* 충족할 때만 — 하나라도 불확실하면 경고 생략 또는 "확인 권장" 경고만):**
1. **단일 서비스** — 멀티서비스가 아니다(`.fursys-deploy-hub/services.json` 없음, 루트 Dockerfile 1개). 판정 신호는 `multiservice-detect.md` §6.
2. **백엔드가 프론트를 same-origin 서빙** — 같은 앱이 정적 프론트를 서빙(`express.static(...)` / FastAPI `app.mount("/", StaticFiles(...))` / NestJS `ServeStaticModule` / Flask `static_folder`·`send_from_directory`)하면서 API 라우트도 **같은 앱**에 있다. 즉 브라우저가 프론트를 API 와 같은 origin 에서 받는다.
3. **외부 클라이언트/별도 프론트 배포 신호 없음** — origin 화이트리스트가 **의미있게** 설정돼 있지 않다(빈 값·`*`·`localhost`(개발용)만). 특정 외부 도메인을 화이트리스트하거나(예 `origin: 'https://partner.example.com'`), 별도 프론트가 다른 곳에 배포되는 정황이 있으면 = **외부에서 이 API 를 부르는 클라이언트가 있다** → CORS 가 필요하다(제거 금지).

```bash
# CORS 로직·헤더 존재(있어야 논의 대상)
grep -rniE 'cors\(|enableCors|CORSMiddleware|Access-Control-Allow-Origin' . \
  --include='*.js' --include='*.jsx' --include='*.ts' --include='*.tsx' --include='*.mjs' --include='*.cjs' --include='*.py' \
  2>/dev/null | grep -viE '/(node_modules|\.venv|dist|build)/' | head
# 같은 앱이 프론트 정적 서빙을 하나(same-origin 신호)
grep -rniE 'express\.static|StaticFiles|ServeStaticModule|send_from_directory|static_folder' . \
  --include='*.js' --include='*.ts' --include='*.py' 2>/dev/null \
  | grep -viE '/(node_modules|\.venv|dist|build)/' | head
```

**판정 흐름:**
- 1·2·3 **모두 충족** → "CORS 불필요" 경고 + deploy-fix `type:"cors-remove-same-origin"` 자동제거 후보로 `deploy_fixes[]` 에 기록.
- 2 가 불확실(정적 서빙을 안 함 = 프론트가 별도이거나 SPA 를 다른 데서 빌드/배포)하거나 3 의 화이트리스트가 **의미있으면** → **경고 생략 또는 "확인 권장" 경고만**(자동제거 항목을 만들지 않는다). 코드 삭제라 리스크가 크니 **애매하면 삭제하지 말고 사람 판단**.

- 화면 문구(경고): "이 앱은 화면과 데이터를 **한 서버(같은 주소)** 에서 함께 내보내고 있어요. 이런 경우 교차출처 허용(CORS) 설정은 필요 없고, 오히려 주소를 잘못 넣으면 배포 후 앱이 스스로를 막을 수 있어요 — 관련 설정을 빼는 걸 권해요."
- **오탐 가드(핵심):** 별도 프론트 배포·외부 클라이언트 가능성이 있거나 origin 화이트리스트가 의미있게 설정돼 있으면 **자동제거 금지 → 경고만**. CORS 제거는 되돌리기 어려운 코드 삭제라 **확신 없으면 건드리지 않는다**(미제거로 인한 무해한 잔존 < 잘못 제거로 인한 외부 클라이언트 차단). 프레임워크별 CORS 보안 점검은 `framework-rules.md` §3(NestJS)·§6(FastAPI)·§11(Express), 자동제거 처리는 deploy-fix SKILL ⑤-4 `cors-remove-same-origin`.

> **§11 은 verdict 를 막지 않는다(§7 불변).** 단일 컨테이너 CORS 불필요는 "정리 권고(경고)"이며, deploy-fix 가 위 확신 조건에서만 자동제거한다.
