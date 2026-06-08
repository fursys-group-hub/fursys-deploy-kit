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

### 불허 형태 (사내 정책 — Dockerfile만 허용)
다음만 있고 Dockerfile이 없으면 **배포 불가**다:
- Docker Compose (`docker-compose.yml`, `compose.yaml`) — 사내 서버는 **단일 서비스 컨테이너** 단위 배포 기준
- Nixpacks 자동 감지(`nixpacks.toml` 만)
- Heroku Buildpacks(`Procfile`, `runtime.txt` 만)
- 정적 사이트 자동 빌드

**이유(요약 — security-checklist §3.5):** 빌드·런타임 환경을 명시적으로 통제하지 못하면 ODBC 드라이버·사내 CA 인증서·non-root 사용자·기업 프록시 같은 사내 운영 요구사항을 일관되게 적용할 수 없다. 사내 서버는 단일 컨테이너 단위로 배포하므로 Dockerfile만 허용한다. 다중 서비스가 필요하면 서비스별로 별도 프로젝트(각각 Dockerfile 보유)로 분리해 개별 등록한다.

### Compose만 있는 경우 안내
`docker-compose.yml` 만 있고 Dockerfile이 없으면: "Compose 대신 **Dockerfile로 전환**이 필요합니다. 아래 복붙 프롬프트로 AI에게 표준 Dockerfile을 만들어 달라고 하세요." (프레임워크별 표준 Dockerfile 생성 프롬프트는 `framework-rules.md` 의 해당 스택 ② 사내 서버 배포 요건을 근거로 작성)
(Dockerfile과 Compose가 둘 다 있으면 Dockerfile 기준으로 진행, Compose는 참고만.)

### Dockerfile **내용** 함정 점검 (Node/npm 계열 — 빌드가 깨지는 정적-미탐 유형)
Dockerfile 이 **있어도** 내용 때문에 배포 빌드가 깨지는 두 유형은 이 검토(빌드 미실행)로는 놓치기 쉽다. Node 계열(Next.js·NestJS 등)이면 반드시 확인한다(상세·grep·정준 골격은 `framework-rules.md` Next.js ②-1/②-2):
- **빌드 단계 `NODE_ENV=production` →** `devDependencies`(tailwind·typescript 등) 스킵으로 `npm run build` 실패. `ENV NODE_ENV=production` 은 runner 에만.
- **`NEXT_PUBLIC_*`/`VITE_*` 빌드 인자 미선언 →** `ARG` 없으면 build-arg 가 무시되어 `undefined` 로 번들에 인라인(빌드는 통과, 런타임 깨짐). 코드가 쓰는 공개 변수마다 builder 에 `ARG`+`ENV` 필요.

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
