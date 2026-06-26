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

### ② 사내 서버 배포 요건
- 실행 설정값: `NODE_ENV=production` 필수.
- Prisma `DATABASE_URL` 은 잠금(locked) 보관.
- AWS region(`BEDROCK_REGION`) 환경별 분리(jp/global).
- 포트: 앱 listen 포트(보통 3000)와 Dockerfile `EXPOSE` 일치.
- 시작 방법: 빌드(`nest build`) 후 `node dist/main.js` 형태 `CMD` 존재. Prisma 사용 시 `prisma generate` 가 빌드 단계에 포함됐는지.

---

## 4. React + Vite (`vite`)

### ① 보안 점검
- `VITE_*` 에 시크릿(`VITE_API_SECRET` 등) 들어가지 않았는지(클라이언트 번들 포함).
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
  - `gatherUsageStats = false` **권장(사내 정책 — 텔레메트리/데이터 외부 송신 방지). 누락 시 지적.**
- `st.secrets["KEY"]` 로 접근하는 키들을 모두 추출해 배포 설정값으로 매핑.
- 파일 업로드 위젯 크기/형식 제한.
- 사용자 입력 → SQL/shell 실행 경로 없는지.

### ② 사내 서버 배포 요건
- 사내 서버는 `secrets.toml` 을 직접 지원하지 않음 → 코드에서 `os.environ.get()` 사용 권장(설정값으로 주입). 또는 시작 스크립트에서 환경변수를 `secrets.toml` 로 변환 후 실행.
- 텔레메트리 비활성: `gatherUsageStats=false`(또는 `STREAMLIT_BROWSER_GATHER_USAGE_STATS=false`) 필수.
- 포트: 보통 `8501`. Dockerfile `EXPOSE 8501` + 실행 시 `--server.port=8501` 일치.
- 시작 방법: `CMD` 가 `streamlit run app.py --server.port=8501 --server.address=0.0.0.0` 형태인지(`0.0.0.0` 바인딩 필수 — 안 하면 컨테이너 밖에서 접속 불가).

---

## 6. FastAPI (`fastapi`)

### ① 보안 점검
- `DEBUG`/`RELOAD` 운영 비활성.
- CORS Middleware origin 화이트리스트(`*` 금지).
- OAuth2/JWT 미들웨어가 모든 보호 라우트에 적용됐는지.
- Pydantic Settings로 환경변수 검증(필수 변수 누락 감지).
- `/docs`·`/redoc` 운영 노출 시 보호 여부.

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
