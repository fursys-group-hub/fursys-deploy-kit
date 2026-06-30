# 프레임워크별 점검 (🔒 보안 + 🚀 배포 요건)

> 엔진이 감지한 프레임워크(`target.framework`)에 **해당하는 섹션만** 읽는다(progressive disclosure).
> 각 프레임워크는 ① 보안 점검 + ② 사내 서버 배포 요건(단일 컨테이너 + Dockerfile 전제)을 함께 다룬다.
> 외부 호스팅(Vercel/Netlify/Streamlit Cloud 등)은 사내 정책상 다루지 않는다 — 언급 금지.

## 목차
1. Next.js (`next`)
2. Spring Boot (`spring`)
3. NestJS (`nest`)
4. React + Vite (`vite`)
5. Streamlit (`streamlit`)
6. FastAPI (`fastapi`)
7. Django (`django`)
8. 공통 — Dockerfile 점검 (모든 프레임워크 공통)
9. Flask (엔진은 `unknown`/Python 으로 감지 — Python 앱이면 함께 본다)
10. Firebase / 외부 PaaS 의존 (사내 부적합 — 차단)

> **엔진 0토큰 탐지와의 연계(라운드5):** 아래 보안 점검 중 일부는 이제 `fdh-engine` 이 결정적으로 잡아 `_engine.json` finding 으로 올린다 — 중복으로 다시 finding 을 만들지 말고(엔진이 정본), 엔진이 못 잡은 결만 LLM 으로 더한다.
> - `VITE_*`/`NEXT_PUBLIC_*`/`REACT_APP_*` 에 시크릿(이름이 SECRET/API_KEY/TOKEN/PASSWORD/PRIVATE_KEY, 또는 값이 AWS키·PEM·sk-·JWT) → 엔진 **치명**(`Secret in Build-time Variable`). 빌드 번들 노출.
> - 시크릿 env 폴백 하드코딩(`process.env.SESSION_SECRET || "dev-..."`, `os.environ.get("SECRET_KEY","...")`) → 엔진 **높음**(`Hardcoded Secret Fallback`).
> - 개인 계정 식별자 하드코딩(`USERNAME="firstname_lastname"`/이메일) → 엔진 **높음**(`Hardcoded Personal Account`). 공용/서비스 계정(admin/postgres 등)은 미탐(정상).
> - 업무 데이터 파일 git 커밋(`*.xlsx`/`*.db`/`*.csv` 등) → 엔진 **높음**(`Data File in Git`).
> - 클라우드 서비스계정 키(JSON, `"type":"service_account"`+`private_key`) git 커밋 → 엔진 **치명**(`Service Account Key in Git`).

---

## 1. Next.js (`next`)

### ① 보안 점검
- `NEXT_PUBLIC_*` 에 시크릿이 들어갔는지(가장 흔한 실수 — 클라이언트 번들에 박힘).
- `next.config.mjs` 의 `rewrites()`/proxy 대상이 사내망인지.
- `middleware.ts` 가 모든 보호 라우트를 매칭하는지(인증 우회 경로 없는지).
- `dangerouslySetInnerHTML` + 사용자 입력 조합(XSS).
- `localStorage`/`sessionStorage` 에 access_token 저장 시 XSS 노출 위험 인지.
- Server Action 에서 인증 확인 누락 없는지.

### ② 사내 서버 배포 요건
- `NEXT_PUBLIC_*` 는 **빌드 시 포함되는 값** → 배포 시 "빌드 포함(build)" 으로 넣어야 번들에 들어간다. 비밀은 절대 금지.
- `output: 'standalone'` 권장(이미지 경량화, Dockerfile 멀티스테이지와 궁합 좋음).
- 실제 포트(보통 3000)와 Dockerfile `EXPOSE` 가 일치해야 한다.
- 시작 방법: `next start`(또는 standalone `node server.js`)가 Dockerfile `CMD` 로 명시됐는지.

#### ②-1. Dockerfile 생성·점검 시 반드시 지킬 2가지 (자주 깨지는 함정)
> Dockerfile 은 고정 템플릿이 아니라 생성 시마다 작성된다. 아래 둘은 검토에서 빌드를 돌리지 않아(정적 점검) **놓치기 쉬우니 코드로 확인**한다.

1. **`npm ci` 가 production 모드로 돌면 devDependencies 가 스킵된다 — Coolify 가 빌드에 `NODE_ENV=production` 을 주입한다(핵심).**
   - create-next-app 은 `tailwindcss`·`@tailwindcss/postcss`·`typescript` 등 **빌드에 꼭 필요한 도구를 `devDependencies`** 에 둔다.
   - **사내 Coolify 는 빌드 시 `NODE_ENV=production` 을 주입한다.** 그래서 Dockerfile 이 NODE_ENV 를 명시하지 않아도 `npm ci` 가 **devDependencies 를 건너뛰어**(설치 패키지 수 급감) `npm run build` 가 `Cannot find module '@tailwindcss/postcss'` 류로 실패한다. → **"Dockerfile 에 안 넣었으니 괜찮다"는 오판이다. 주입은 외부에서 온다.**
   - **해결: `npm ci` 가 도는 스테이지(보통 `deps`)에 `npm ci` 직전 `ENV NODE_ENV=development` 를 명시해 주입값을 덮어쓰거나, `RUN npm ci --include=dev` 를 쓴다.** (`next build` 는 NODE_ENV 와 무관하게 production 번들을 만들고, standalone 출력이라 devDependencies 는 최종 이미지에 안 들어간다.) `NODE_ENV=production` 은 **`runner` 스테이지에서만** 둔다.
   - 점검: **설치 스테이지에 devDeps 보장 장치(`ENV NODE_ENV=development` 또는 `npm ci --include=dev`)가 있는지** 확인 — 없으면 **높음**(Coolify 주입으로 스킵 → 빌드 실패). `npm ci --omit=dev`/`--production` 이 보이면 즉시 **높음**.
   ```bash
   # 설치 스테이지에 devDeps 보장 장치가 있는가(없으면 위험)
   grep -qE 'ENV +NODE_ENV=development|npm ci .*--include=dev' Dockerfile \
     || echo "WARN: devDeps 보장 override 없음 → Coolify 의 NODE_ENV=production 주입 시 빌드 실패 위험"
   # production 설치 옵션이 박혀 있는가(있으면 위험)
   grep -nE 'npm (ci|install).*(--omit=dev|--production)' Dockerfile && echo "WARN: production 설치 옵션 발견"
   ```

2. **`NEXT_PUBLIC_*` 는 `builder` 스테이지에 `ARG` 로 선언하고 `ENV` 로 노출한 뒤 `npm run build` 해야 한다.**
   - Coolify(중앙 배포 시스템)는 `NEXT_PUBLIC_*`(build 클래스)를 `--build-arg` 로 넘기지만, Dockerfile 에 **`ARG <이름>` 선언이 없으면 그 값은 무시**된다.
   - 그러면 `npm run build` 시점에 해당 값이 **`undefined` 로 클라이언트 번들에 인라인**되어, 빌드는 통과해도 **배포 후 브라우저에서 깨진다**(런타임 오류 — 정적 점검으로 못 잡음).
   - 점검: 코드가 쓰는 `NEXT_PUBLIC_*` 변수(아래 grep) 각각에 대해 `builder` 스테이지에 `ARG`+`ENV` 가 있는지 확인. 없으면 **높음**.
   ```bash
   # 코드가 참조하는 NEXT_PUBLIC_* 목록 추출 → 각 변수가 Dockerfile builder 에 ARG 로 있는지 대조
   grep -rhoE 'NEXT_PUBLIC_[A-Z0-9_]+' src app 2>/dev/null | sort -u
   grep -nE '^ARG +NEXT_PUBLIC_' Dockerfile
   ```

#### ②-2. 정준(canonical) standalone Dockerfile 골격 (생성·수정 기준)
> **단일 출처 동기화:** 이 골격은 `create-app` 의 `templates/web-next/Dockerfile`(새 프로젝트 생성 시 출하하는 실제 표준)과 **동일하게 유지**한다. 한쪽을 고치면 다른 쪽도 맞춘다(드리프트 금지). base 이미지는 사내 표준 `node:20-alpine`.
> **TODO(create-app 동기화 — 별도 작업):** 아래 builder 의 `RUN mkdir -p /app/public`(ERR-01 예방)은 아직 이 골격에만 반영됐다. `create-app` 의 `templates/web-next/Dockerfile`(외부 패키지)에도 같은 줄과 `public/.gitkeep` 기본 출하를 반영해야 드리프트가 닫힌다(Wave 1 범위 밖).

Dockerfile 을 새로 만들거나 고칠 때 이 골격을 기준으로 한다(②-1 두 함정을 모두 회피한 형태). `NEXT_PUBLIC_*` ARG 줄은 코드가 실제로 쓰는 변수로 채운다(안 쓰면 생략).
```dockerfile
# Stage 1: deps
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
ENV NODE_ENV=development          # Coolify 가 빌드에 주입하는 NODE_ENV=production 덮어쓰기 → devDeps(tailwind 등) 설치 보장
# npm ci 가 아니라 npm install: Windows 개발 PC 에서 만든 package-lock.json 은 linux-musl 전용
# 선택적 네이티브 의존성(@emnapi 등)을 누락해, lock 완전일치를 요구하는 npm ci 가 컨테이너(node:20-alpine)
# 에서 깨진다. npm install 은 플랫폼에 맞게 보충한다.
RUN npm install --no-audit --no-fund

# Stage 2: builder
FROM node:20-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
# 코드가 쓰는 NEXT_PUBLIC_* 마다 ARG+ENV (없으면 build-arg 가 무시되어 undefined 로 인라인):
#   ARG NEXT_PUBLIC_API_BASE_URL
#   ENV NEXT_PUBLIC_API_BASE_URL=$NEXT_PUBLIC_API_BASE_URL
RUN npm run build                # 여기에 ENV NODE_ENV=production 절대 금지
RUN mkdir -p /app/public         # public 폴더가 없어도 runner COPY 가 실패하지 않게 보장(ERR-01 예방)

# Stage 3: runner
FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production          # production 은 runner 에서만
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0
RUN addgroup --system --gid 1001 nodejs \
 && adduser --system --uid 1001 nextjs
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
USER nextjs
EXPOSE 3000
CMD ["node", "server.js"]
```
- 전제: `next.config.*` 에 `output: 'standalone'`. 없으면 `.next/standalone/server.js` 가 안 생겨 runner `COPY` 가 실패한다.
- 빌더에서 빈 public 보장(위 `RUN mkdir -p /app/public`)으로 `public/` 폴더가 없는 프로젝트여도 runner `COPY` 줄을 그대로 둬도 안전하다. (COPY 줄을 빼는 우회는 더 이상 권장하지 않는다.)

---

## 2. Spring Boot (`spring`)

### ① 보안 점검
- `application-prod.yml` 이 git에 올라가 시크릿이 평문 노출되지 않았는지.
- `application.yml` 에 default 시크릿 값이 박혀 있지 않은지(`${ENV:default}` 의 default에 실값 금지).
- JKS Keystore 경로/비밀번호가 환경변수로 분리됐는지.
- `SecurityConfig` 의 `permitAll()` 광범위 사용 여부.
- CSRF 비활성화 시 JWT 등 대안이 적용됐는지.
- Actuator 노출 범위(`management.endpoints.web.exposure.include` 가 `*` 인지).
- BCrypt 사용 여부(비밀번호 평문 저장 금지).
- `@Value` 로 주입한 시크릿이 로그로 출력되는 코드 없는지.

### ② 사내 서버 배포 요건
- profile 활성화: `SPRING_PROFILES_ACTIVE=prod` 를 실행 설정값으로 주입.
- JKS 파일은 이미지에 포함하거나 영구 저장소에 마운트(경로·비번은 잠금 보관).
- 포트: `server.port` 와 Dockerfile `EXPOSE` 일치 확인. (사내 서버 앞단 TLS를 쓰면 앱은 8080 같은 평문 포트로 떠도 됨 — 포트 일치만 맞으면 됨.)
- 시작 방법: 빌드된 `*.jar` 을 `java -jar` 로 실행하는 `CMD`(또는 ENTRYPOINT) 가 있는지. Gradle 멀티스테이지 빌드 권장.

---

## 3. NestJS (`nest`)

### ① 보안 점검
- `@nestjs/config` `ConfigModule.forRoot()` 사용 + `validationSchema`(Joi/Zod)로 필수 변수 누락 즉시 감지.
- `.env.local`/`.env.development`/`.env.production` 모두 `.gitignore` 포함.
- Prisma `DATABASE_URL` 에 평문 비밀번호 노출 여부 — 변수 분리.
- AWS Bedrock 자격증명을 IAM Role로 대체 가능한지(정적 키 회피).
- 환경변수 직접 접근 대신 `ConfigService` 사용.
- Swagger(`/api-docs`) 운영 노출 시 인증 보호 여부.
- Helmet 적용·CORS origin 화이트리스트 검증.
- **세션/JWT 시크릿 폴백 하드코딩 금지: `process.env.SESSION_SECRET || 'dev-secret'`·`?? 'secret'` 처럼 env 가 없을 때 쓰는 비밀 폴백을 코드에 박지 말 것.** 폴백이 있으면 배포 설정값을 깜빡해도 조용히 약한 비밀로 떠서 세션/토큰 위조 위험. 필수값은 폴백 없이 부재 시 부팅 실패(fail-fast)로 처리한다. (엔진이 `Hardcoded Secret Fallback` 높음으로 잡는다 — 중복 finding 금지.)

### ② 사내 서버 배포 요건
- 실행 설정값: `NODE_ENV=production` 필수.
- Prisma `DATABASE_URL` 은 잠금(locked) 보관.
- AWS region(`BEDROCK_REGION`) 환경별 분리(jp/global).
- 포트: 앱 listen 포트(보통 3000)와 Dockerfile `EXPOSE` 일치.
- 시작 방법: 빌드(`nest build`) 후 `node dist/main.js` 형태 `CMD` 존재. Prisma 사용 시 `prisma generate` 가 빌드 단계에 포함됐는지.

---

## 4. React + Vite (`vite`)

### ① 보안 점검
- `VITE_*`(및 CRA 의 `REACT_APP_*`) 에 시크릿(`VITE_API_SECRET`·`VITE_*_API_KEY`·`VITE_*_TOKEN` 등) 들어가지 않았는지(클라이언트 번들 포함). **이건 엔진이 치명(`Secret in Build-time Variable`)으로 잡는다 — 중복 finding 금지, 엔진 결과를 그대로 쓴다.** 공개해도 되는 건 주소/공개 ID(`VITE_API_BASE_URL`·`VITE_*_APP_ID`)뿐.
- Sendbird AppId는 공개 가능하지만 API Token은 절대 클라이언트 노출 금지.
- `import.meta.env.MODE` 분기 처리 적절한지.
- postMessage 사용 시 `targetOrigin` 검증 누락 없는지.
- iframe 임베딩 시 X-Frame-Options 정책.

### ② 사내 서버 배포 요건
- 모든 `VITE_*` 는 **빌드 시 포함되는 값**(build) → 비밀 금지.
- 빌드 결과(`dist/`)는 정적 파일을 서빙하는 작은 웹서버(예: nginx, `serve`)로 컨테이너에서 띄운다. (외부 정적 호스팅 사용 금지 — 컨테이너 안에서 서빙.)
- 포트: 정적 서버 포트(nginx 80 등)와 Dockerfile `EXPOSE` 일치.
- 시작 방법: 멀티스테이지(빌드 → nginx/serve 로 복사) Dockerfile 권장. 운영 빌드에서 source map 비노출 권장.

---

## 5. Streamlit (`streamlit`)

### ① 보안 점검
- `.streamlit/secrets.toml` 이 `.gitignore` 에 포함됐는지.
- `.streamlit/config.toml` 점검:
  - `enableCORS = false` → 중간 위험
  - `enableXsrfProtection = false` → 중간 위험
  - `gatherUsageStats = false` **필수(사내 정책 — 텔레메트리/데이터 외부 송신 방지).** **누락 시 엔진이 결정적으로 잡는다**(`Streamlit Telemetry Not Disabled`, medium — item14). `gatherUsageStats=false`(config.toml) 또는 `STREAMLIT_BROWSER_GATHER_USAGE_STATS=false`(env) 중 하나라도 있으면 면제. **엔진이 이미 finding 을 만드므로 같은 내용을 `deploy_fixes[]` 에 중복 기재하지 말 것**(엔진 finding 을 deploy-fix 가 처리). 단 어디에도 비활성 선언이 없으면 config.toml `[browser]` 섹션에 추가하도록 안내.
- `st.secrets["KEY"]` 로 접근하는 키들을 모두 추출해 배포 설정값으로 매핑. **`st.secrets["X"]` 직접 첨자 접근은 사내 서버에서 런타임 KeyError 로 깨진다** → 비침투 폴백(`st.secrets.get("X", os.environ.get("X"))` + `load_dotenv()`)으로 고친다(자동수정 `type:"secrets-to-env"` — deploy-fix SKILL ⑤-4, 항목25). 폴백의 두 번째 인자에 **실제 비밀값을 적지 말 것**(env 만, 폴백 리터럴 금지 — 엔진 `Hardcoded Secret Fallback`).
- 파일 업로드 위젯 크기/형식 제한.
- 사용자 입력 → SQL/shell 실행 경로 없는지.
- **`st.image(...)` 등에 외부/사용자 제공 URL 을 그대로 넘기지 않는지(SSRF·외부 호출).** 외부 이미지 URL 은 사내망에서 막히거나 SSRF 통로가 될 수 있다 — 정적 자산은 리포지토리에 포함(`st.image("assets/logo.png")`)하거나 검증된 사내 경로만 사용. (`st.image`/`st.video`/`st.audio` 공통.)

### ② 사내 서버 배포 요건
- 사내 서버는 `secrets.toml` 을 직접 지원하지 않음 → `st.secrets["X"]` 가 런타임에 깨진다. **단, 코드를 통째로 `os.environ` 으로 바꾸면 로컬 `secrets.toml` 실행이 파괴되므로 소스 최소 변경(비침투적)이 원칙이다(항목25):** 진입부에 `load_dotenv()` 한 줄 + `st.secrets.get("X", os.environ.get("X"))` 폴백만 추가하면 로컬(secrets.toml)·사내 서버(설정값) 둘 다 동작한다. `.env.example`(빈 키)과 로컬 실행 안내를 함께 둔다. 이 자동수정은 deploy-fix `type:"secrets-to-env"` 가 처리한다(deploy-fix SKILL ⑤-4). (시작 스크립트에서 env→`secrets.toml` 변환 방식도 가능하나 더 무겁다.)
- 텔레메트리 비활성: `gatherUsageStats=false`(또는 `STREAMLIT_BROWSER_GATHER_USAGE_STATS=false`) 필수.
- 포트: 보통 `8501`. Dockerfile `EXPOSE 8501` + 실행 시 `--server.port=8501` 일치.
- 시작 방법: `CMD` 가 `streamlit run app.py --server.port=8501 --server.address=0.0.0.0` 형태인지(`0.0.0.0` 바인딩 필수 — 안 하면 컨테이너 밖에서 접속 불가).

---

## 6. FastAPI (`fastapi`)

### ① 보안 점검
- `DEBUG`/`RELOAD` 운영 비활성.
- CORS Middleware origin 화이트리스트(`*` 금지). **`allow_origins=["*"]` + `allow_credentials=True` 조합은 특히 위험(자격증명 포함 교차출처 허용) — 둘 다 보이면 높음.**
- OAuth2/JWT 미들웨어가 모든 보호 라우트에 적용됐는지.
- Pydantic Settings로 환경변수 검증(필수 변수 누락 감지). 시크릿 `Field(default=...)` 에 실제 비밀값을 박지 말 것(폴백 하드코딩 — 엔진 점검과 동일).
- `/docs`·`/redoc` 운영 노출 시 보호 여부.
- **정적 서빙 루트가 서버 폴더 전체가 아닌지: `StaticFiles(directory=".")` 처럼 루트(`.`) 를 통째로 마운트하면 소스·`.env`·설정이 URL 로 노출된다.** 전용 폴더(`directory="static"`)로 좁힌다(자동수정 `type:"static-folder"` — 항목35). 어떤 파일이 공개여도 되는지는 사람 판단(파일 이동은 안내만).

### ② 사내 서버 배포 요건
- 포트: uvicorn/gunicorn listen 포트(보통 8000)와 Dockerfile `EXPOSE` 일치.
- 시작 방법: `CMD` 가 `uvicorn main:app --host 0.0.0.0 --port 8000`(또는 gunicorn+uvicorn worker) 형태. `--host 0.0.0.0` 필수.
- 의존성: `requirements.txt`/`pyproject.toml` 이 이미지 빌드에 설치되는지.

---

## 7. Django (`django`)

### ① 보안 점검
- `DEBUG=False` 운영 환경.
- `ALLOWED_HOSTS` 명시(`*` 금지).
- `SECRET_KEY` 환경변수 분리(코드에 박지 않음).
- `SECURE_SSL_REDIRECT=True`, `SESSION_COOKIE_SECURE=True`, `CSRF_COOKIE_SECURE=True`.
- `django.contrib.admin` 운영 노출 시 IP 화이트리스트.
- `manage.py` 명령에 평문 비밀번호 인자 미사용.

### ② 사내 서버 배포 요건
- 정적 파일: `collectstatic` 이 빌드/시작 단계에 포함됐는지(whitenoise 등).
- DB 마이그레이션: 시작 스크립트에서 `migrate` 실행 여부(또는 별도 단계).
- 포트: gunicorn listen 포트(보통 8000)와 Dockerfile `EXPOSE` 일치.
- 시작 방법: `CMD` 가 `gunicorn <proj>.wsgi:application --bind 0.0.0.0:8000` 형태. `0.0.0.0` 바인딩 필수.

---

## 8. 공통 — Dockerfile 점검 (모든 프레임워크 공통)

배포가능성 점검은 `deploy-readiness.md` 가 본진이지만, Dockerfile 내용의 보안·품질 점검은 여기서도 본다:
- `FROM` 이 공식/검증 이미지인지(Alpine, Debian slim 등).
- 멀티스테이지로 빌드 산출물만 최종 이미지에 포함하는지.
- `USER` 지시자로 non-root 실행하는지(root 실행 지양).
- `COPY .` 시 `.dockerignore` 에 `.env`, `.git`, `node_modules` 가 포함됐는지(시크릿/불필요 파일 유입 방지).
- `ENV` 로 시크릿을 직접 박지 않았는지(반드시 런타임 주입).
- `EXPOSE` 포트가 앱 실제 포트·사내 서버 설정과 일치하는지.
- `HEALTHCHECK` 정의 권장.
- **(Node/npm 계열 공통 — Next.js·NestJS 등) 빌드 단계에서 `NODE_ENV=production` 으로 의존성을 설치하지 않았는지.** 빌드 도구가 `devDependencies` 에 있으면 스킵되어 빌드가 실패한다. `ENV NODE_ENV=production` 은 실행(runner) 스테이지에서만 두고, 설치/빌드 스테이지에는 두지 않는다. (상세·탐지 grep·정준 Dockerfile 골격은 Next.js ②-1/②-2 참조.)

---

## 9. Flask (엔진은 `unknown`/Python 으로 감지 — Python 앱이면 함께 본다)

> 엔진 `target.framework` 에 Flask 전용 값은 없다(보통 `unknown`). **코드에 `from flask import` / `Flask(__name__)` 가 보이면** 이 섹션을 함께 본다.

### ① 보안 점검
- **`static_folder="."`(또는 `static_folder=os.getcwd()`) 금지 — 서버 루트 전체(소스·`.env`·설정)가 URL 로 노출된다.** 전용 폴더(`static_folder="static"`)로 좁힌다. 자동수정 `type:"static-folder"`(항목35) — 폴더 인자 한 줄만 좁히고, 공개 자산 이동은 사람 판단(안내만). (FastAPI `StaticFiles(directory=".")`·Express `express.static(".")` 도 같은 함정.)
- **`app.run(debug=True)` / `FLASK_DEBUG=1` 운영 금지.** 디버거(Werkzeug)가 켜지면 예외 페이지에서 **임의 코드 실행(PIN 우회 시)** + 소스 노출. 운영은 `debug=False`(기본), WSGI 서버(gunicorn)로 띄운다.
- **`app.secret_key` / `SECRET_KEY` 폴백 하드코딩 금지: `app.secret_key = os.environ.get("SECRET_KEY", "dev")` 같은 폴백 리터럴 금지** — 세션 쿠키 위조 위험. 부재 시 부팅 실패(fail-fast). (엔진이 `Hardcoded Secret Fallback` 으로 잡는다.)
- `app.run(host="0.0.0.0")` 자체는 컨테이너 배포에 필요(아래 ②) — 보안 문제 아님. 문제는 `debug=True` 와의 조합.
- 사용자 입력 → SQL(파라미터 바인딩 여부)·`render_template_string`(SSTI)·`subprocess`(쉘 주입) 경로 점검.

### ② 사내 서버 배포 요건
- 운영은 `flask run`(개발 서버) 대신 **gunicorn**: `CMD ["gunicorn","-b","0.0.0.0:8000","app:app"]`. `0.0.0.0` 바인딩 필수.
- 포트: gunicorn `-b` 포트와 Dockerfile `EXPOSE` 일치(보통 8000).
- 의존성: `requirements.txt` 가 이미지 빌드에 설치되는지. `gunicorn` 이 deps 에 포함됐는지.
- 정적 파일: 전용 `static/` 폴더만 서빙(위 ① 참조).

---

## 10. Firebase / 외부 PaaS 의존 (사내 부적합 — 차단)

> 사내 보안 정책상 **외부 호스팅·외부 백엔드 PaaS 의존은 차단 대상**이다. 코드/설정에 아래 신호가 보이면 **높음**으로 올리고, 사내 대체안을 안내한다(외부 호스팅 가이드는 만들지 않는다 — 사내 Coolify·fgdw 전제).

### 점검 신호
- **외부 호스팅 배포 설정 파일 존재**: `vercel.json`·`netlify.toml`·`render.yaml`(Render)·`firebase.json`(hosting)·`.firebaserc`·`app.yaml`(GAE)·`Procfile`(Heroku)·`fly.toml`(Fly.io)·`railway.json`(Railway) 등 → 사내 Coolify 단일 컨테이너 + Dockerfile 로 전환 필요(높음).
- **GitHub Actions 등 외부 CI/CD 워크플로우**(item33): `.github/workflows/*.yml` 에 **외부 호스팅 배포 단계**가 있으면(예: `amondnet/vercel-action`·`nwtgck/actions-netlify`·`FirebaseExtended/action-hosting-deploy`·`render deploy`·`flyctl deploy`·`aws s3 sync`·외부 PaaS 토큰 사용) 사내 정책 위반(높음) → 배포는 사내 Coolify(git push 자동) 전제, 사내 CI 는 GitLab(`git.fursys.com`) 을 쓴다. **단순 테스트/린트만 도는 `.github/workflows` 는 위반 아님** — 배포·릴리스 스텝이 외부 호스팅을 가리키는 경우만 경고(과탐 주의).
- **Firebase 클라이언트 SDK 로 백엔드 대체**: `firebase/firestore`·`firebase/auth`·`firebase/storage` 직접 호출로 DB/인증/스토리지를 외부 Firebase 에 의존 → 데이터가 사외로 나간다. 사내 백엔드(ai-hub 등)·fgdw 로 대체 검토(높음).
- **Firebase Admin SDK 서비스계정 키**: `firebase-adminsdk-*.json`·`serviceAccountKey.json` 이 repo 에 있으면 **치명**(개인키 git 노출 — 엔진 `Service Account Key in Git` 으로 잡힌다). 즉시 폐기·재발급.
- **외부 서버리스/Edge 함수**: `functions/`(Firebase Functions)·`api/`(Vercel Functions)·Cloudflare Workers(`wrangler.toml`) → 사내 컨테이너 단일 앱으로 합치기 안내(높음).

### 대체 안내(쉬운 우리말)
- "이 앱은 외부 호스팅/외부 데이터베이스(Firebase 등)에 기대고 있어요. 사내 보안 정책상 외부 호스팅은 쓸 수 없어, 사내 서버(컨테이너)와 사내 데이터 저장소로 옮겨야 해요." 라고 알리고, 외부 의존을 어디서 쓰는지(파일·기능) 짚어 준다. **외부 호스팅으로 배포하는 방법은 안내하지 않는다.**
