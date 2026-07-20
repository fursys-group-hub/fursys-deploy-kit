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
11. Express / 일반 Node 백엔드 (`express`/`node`)

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

#### ②-1. `localhost` HEALTHCHECK = IPv6(`::1`) 불일치로 롤백 (item66 + R9-5 — nginx·정적, 그리고 모든 서버 앱 공통)
> Vite→nginx 뿐 아니라 **순수 정적 HTML 을 nginx:alpine 으로 서빙하는 모든 앱**, 그리고 **`0.0.0.0`(IPv4)로 바인딩하는 모든 서버 앱**(Node/Express·Python uvicorn·Go 등 — 그쪽은 §8 공통 규칙에서도 다룬다) 공통이다.

**증상:** 빌드·서빙은 정상인데 **HEALTHCHECK 자가진단만 실패** → Coolify 가 컨테이너를 unhealthy 로 보고 10회 재시도 후 **롤백**(신규 앱은 되돌릴 이전 컨테이너가 없어 결국 **404**). status.sh 가 잠깐 RUNNING 을 줬어도 실제로는 롤백된다.

**근본 원인(IPv6 불일치):**
- `nginx:alpine` 은 **기본 `default.conf` 에 `listen [::]:80;`(IPv6) 자동추가 스크립트(`10-listen-on-ipv6-by-default.sh`)** 를 넣는다 — 단, **custom conf 를 마운트/COPY 하면 그 스크립트가 스킵**된다. custom `.nginx.conf` 가 `listen 80;`(IPv4)만 가지면 nginx 는 IPv6 를 안 듣는다.
- Dockerfile `HEALTHCHECK` 이 `wget http://localhost/` 를 쓰면, alpine 의 `localhost` 는 보통 **`::1`(IPv6) 을 먼저** 시도 → nginx 가 IPv6 를 안 듣고 있어 **연결 거부** → healthcheck 실패 → 롤백.

**deploy-fix 가 nginx Dockerfile/conf 를 생성·수정할 때 지킬 규칙(둘 다 적용 권장):**
1. **HEALTHCHECK 는 `127.0.0.1`(IPv4 명시)로** — `localhost` 금지. custom conf 유무·IPv6 설정과 무관하게 안전:
   ```dockerfile
   HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
     CMD wget -q --spider http://127.0.0.1/ || exit 1
   ```
2. **custom nginx conf 를 둘 거면 `listen [::]:80;` 를 `listen 80;` 와 함께** 명시(IPv4/IPv6 둘 다 듣게 — 자동추가 스크립트 스킵 보완):
   ```nginx
   server {
     listen 80;
     listen [::]:80;
     ...
   }
   ```

**점검(deploy-readiness §5 연계):** nginx custom conf(`*.conf`/`nginx.conf`/`.nginx.conf`)가 있고 `listen [::]` 가 없는데 Dockerfile HEALTHCHECK 이 `localhost` 를 쓰면 → **높음**(배포 후 롤백→404 위험). 아래 grep 으로 확인:
```bash
CONF="$(ls nginx.conf .nginx.conf default.conf 2>/dev/null; find . -maxdepth 2 -name '*.conf' -path '*nginx*' 2>/dev/null | head)"
if [ -n "$CONF" ] && ! grep -rqE 'listen\s+\[::\]' $CONF 2>/dev/null; then
  grep -qiE 'HEALTHCHECK.*localhost' Dockerfile && echo "WARN: nginx custom conf 에 listen [::]:80 없음 + HEALTHCHECK localhost → IPv6 불일치로 롤백 위험(127.0.0.1 로 바꾸거나 listen [::]:80 추가)"
fi
```
→ 자동수정(`type:"healthcheck-ipv4"` — 구 `nginx-healthcheck` 포함): HEALTHCHECK 의 `localhost`→`127.0.0.1` **한 줄 치환**(가장 안전·최소·프레임워크 무관), 그리고 nginx custom conf 가 있으면 `listen [::]:80;` 동반 추가(Node/일반 서버 앱은 conf 가 없으니 한 줄 치환만으로 끝). 빌드·서빙 로직은 안 건드린다.

---

## 5. Streamlit (`streamlit`)

### ① 보안 점검
- `.streamlit/secrets.toml` 이 `.gitignore` 에 포함됐는지.
- `.streamlit/config.toml` 점검:
  - `enableCORS = false` → 중간 위험
  - `enableXsrfProtection = false` → 중간 위험
  - `gatherUsageStats = false` **필수(사내 정책 — 텔레메트리/데이터 외부 송신 방지).** **누락 시 엔진이 결정적으로 잡는다**(`Streamlit Telemetry Not Disabled`, medium — item14). `gatherUsageStats=false`(config.toml) 또는 `STREAMLIT_BROWSER_GATHER_USAGE_STATS=false`(env) 중 하나라도 있으면 면제. **엔진이 이미 finding 을 만드므로 같은 내용을 `deploy_fixes[]` 에 중복 기재하지 말 것**(엔진 finding 을 deploy-fix 가 처리). 단 어디에도 비활성 선언이 없으면 config.toml `[browser]` 섹션에 추가하도록 안내.
- `st.secrets["KEY"]` 로 접근하는 키들을 모두 추출해 배포 설정값으로 매핑. **`st.secrets["X"]` 직접 첨자 접근은 사내 서버에서 런타임 KeyError 로 깨진다** → 비침투 폴백(`st.secrets.get("X", os.environ.get("X"))` + `load_dotenv()`)으로 고친다(자동수정 `type:"secrets-to-env"` — deploy-fix SKILL ⑤-4, 항목25). 폴백의 두 번째 인자에 **실제 비밀값을 적지 말 것**(env 만, 폴백 리터럴 금지 — 엔진 `Hardcoded Secret Fallback`).
  - **(item48) 이미 안전한 폴백이 있으면 `secrets-to-env` 를 만들지 않는다(과수정 금지).** 앱이 이미 ① `st.secrets.get("X", os.environ.get("X"))`/`os.getenv("X")` 폴백, 또는 ② `try: st.secrets[...] except: os.environ[...]`(또는 `_get_secret()` 같은 헬퍼로 감싼) **try/except 폴백**을 갖고 있으면, 사내 서버 env 로 이미 동작하므로 **수정 대상이 아니다.** `st.secrets["X"]` **직접 첨자 접근이 폴백 없이 그대로** 남아 있는 경우만 `deploy_fixes[]` 에 `secrets-to-env` 를 넣는다. 각 키가 이미 폴백으로 감싸였는지 확인하고, 감싸인 키는 스킵한다(foam-nesting `_get_secret()` 처럼 헬퍼로 감싼 케이스는 자동수정 불필요).
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
- **(item47) `CMD` 의 `uvicorn <모듈>:<앱>` 이 실제 파일·변수와 맞는지 검증한다.** FastAPI 앱은 `if __name__ == "__main__"` 없이 ASGI 서버가 `모듈:앱` 문자열로 임포트하는 구조가 흔해, `모듈:앱` 이 틀리면(파일명·변수명 불일치) 컨테이너가 `ModuleNotFoundError`/`AttributeError` 로 **기동 즉시 죽는다.** LLM 판단에만 맡기지 말고 결정적으로 대조:
  ```bash
  # CMD 의 uvicorn/gunicorn 대상(module:var) 추출
  grep -oiE '(uvicorn|gunicorn)[^\n]*\b([a-zA-Z0-9_.]+):([a-zA-Z0-9_]+)' Dockerfile 2>/dev/null
  # 예 'main:app' → main.py 안에 app = FastAPI(...) 가 있나 (모듈은 . 를 / 로, 파일 존재 + 변수 정의 확인)
  #  MODULE=main VAR=app 이면:  test -f main.py && grep -qE "^\s*app\s*=\s*FastAPI" main.py
  ```
  - `모듈`(`.` → 디렉터리 구분)에 해당하는 `.py` 파일이 없거나, 그 파일에 `<앱> = FastAPI(...)`(또는 `= APIRouter`/할당) 정의가 없으면 → **높음**(기동 실패). 화면 문구: "앱을 켜는 명령이 가리키는 위치(파일·이름)를 찾지 못해요 — 시작 명령의 `모듈:앱` 이름을 실제 파일과 맞춰야 켜집니다."
  - `--factory` 옵션이면 `<앱>` 이 함수(호출 시 앱 반환)일 수 있으니 변수/함수 둘 다 허용.
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
- `COPY .` 시 `.dockerignore` 에 `.env`, `.git`, `node_modules` 가 포함됐는지(시크릿/불필요 파일 유입 방지). **(item54) `node_modules/` 가 `.dockerignore` 에 없으면 특히 위험:** `RUN npm install`(또는 `npm ci`)로 컨테이너 안(linux)에 맞는 의존성을 설치한 뒤 `COPY . .` 가 **로컬(예: Windows/mac) node_modules 를 덮어써** 네이티브 바이너리 불일치·플랫폼 오류로 런타임 크래시가 난다. Node 앱은 `.dockerignore` 에 `node_modules` 가 **반드시** 있어야 한다 — 없으면 **높음**. 없으면 자동수정으로 `.dockerignore` 에 `node_modules`(+`.env`·`.git`) 한 줄씩 추가.
- `ENV` 로 시크릿을 직접 박지 않았는지(반드시 런타임 주입).
- `EXPOSE` 포트가 앱 실제 포트·사내 서버 설정과 일치하는지.
- `HEALTHCHECK` 정의 권장. **(item R9-5 — 모든 서버 프레임워크 공통) HEALTHCHECK 는 `localhost` 대신 `127.0.0.1`(IPv4 명시)로 쓴다.** 앱이 `0.0.0.0`(IPv4 전용)으로 바인딩하는데(Node `app.listen(PORT,'0.0.0.0')`·Python uvicorn/gunicorn `--host 0.0.0.0`·Go 등) HEALTHCHECK 가 `wget/curl http://localhost/` 면, alpine 의 `localhost` 가 `::1`(IPv6) 을 먼저 시도해 **연결 거부 → unhealthy → Coolify 롤백 → 신규 앱 404**(빌드·서빙은 정상, 자가진단만 실패 — fursys-import 실사례). **`0.0.0.0` 바인딩 + HEALTHCHECK `localhost` 조합이면 높음** → `127.0.0.1` 로 한 줄 교정(자동수정 `type:"healthcheck-ipv4"`). 앱이 이미 IPv6 도 듣거나 HEALTHCHECK 가 이미 `127.0.0.1`/`[::1]` 이면 정상(오탐 가드). nginx 정적 케이스는 §4 ②-1(custom conf `listen [::]:80` 동반)로, 그 외 서버 앱은 여기 공통 규칙으로 본다. 탐지 grep 은 `../deploy-check/references/deploy-readiness.md` §5-1(B).
- **(Node/npm 계열 공통 — Next.js·NestJS 등) 빌드 단계에서 `NODE_ENV=production` 으로 의존성을 설치하지 않았는지.** 빌드 도구가 `devDependencies` 에 있으면 스킵되어 빌드가 실패한다. `ENV NODE_ENV=production` 은 실행(runner) 스테이지에서만 두고, 설치/빌드 스테이지에는 두지 않는다. (상세·탐지 grep·정준 Dockerfile 골격은 Next.js ②-1/②-2 참조.)

---

## 11. Express / 일반 Node 백엔드 (`express` / `node`) — (item53)

> 엔진이 `package.json` 의존성으로 감지한다: `express` → `express`, `fastify`/`koa`/`hapi`/`restify` → `node`, 서버 프레임워크 의존성은 없지만 소스에 `http.createServer(...).listen()` / `app.listen()` 같은 서버 기동이 보이면 `node`. (이전엔 이 앱들이 `unknown` 으로 잡혀 프레임워크별 안내가 비었다 — 배포는 됐으나 점검이 얕았다.) **next/nest/vite 가 우선**하므로(Nest·Next 는 내부적으로 express 를 쓰지만 각자 값으로 잡힘) 이 섹션은 순수 Express/Node 서버에만 적용된다.

### ① 보안 점검
- **정적 서빙 루트: `express.static(".")`/`express.static(__dirname)` 금지 — 서버 루트 전체(소스·`.env`·설정)가 URL 로 노출된다.** 전용 폴더(`express.static("public")`)로 좁힌다. (Flask `static_folder="."`·FastAPI `StaticFiles(directory=".")` 와 같은 함정.)
- **시크릿 폴백 하드코딩 금지:** `process.env.SESSION_SECRET || "dev-secret"` 같은 폴백 리터럴 금지(세션·JWT 서명 위조 위험). 부재 시 부팅 실패(fail-fast). (엔진이 `Hardcoded Secret Fallback` 으로 잡으니 중복 finding 만들지 말 것.)
- **CORS:** `cors()` 를 옵션 없이 전역 적용하면 `Access-Control-Allow-Origin: *` — origin 화이트리스트로 좁힌다. 자격증명(`credentials:true`) + `*` 조합은 특히 위험.
- **`helmet` 등 기본 보안 헤더**, body-parser 크기 제한, 사용자 입력 → SQL(파라미터 바인딩)·`child_process`(쉘 주입)·경로조작 점검.
- `app.listen(PORT, "0.0.0.0")` 자체는 컨테이너 배포에 필요(아래 ②) — 보안 문제 아님.

### ② 사내 서버 배포 요건
- 포트: `app.listen(<포트>)` 값과 Dockerfile `EXPOSE`·사내 서버 설정 일치. 포트는 `process.env.PORT` 로 받는 게 안전.
- 바인딩: `app.listen(PORT, "0.0.0.0")` 로 컨테이너 외부 접속 허용(`localhost`/`127.0.0.1` 바인딩이면 컨테이너 밖에서 못 붙는다).
- **HEALTHCHECK 는 `127.0.0.1`(IPv4) 로 — §8 공통 규칙(item R9-5) 적용.** `0.0.0.0` 바인딩 + `HEALTHCHECK localhost` 조합은 alpine 에서 `::1`(IPv6) 우선 시도로 롤백을 부른다(자동수정 `type:"healthcheck-ipv4"`).
- `.dockerignore` 에 `node_modules` 필수(§8 item54) — `RUN npm install` 후 `COPY . .` 가 로컬 node_modules 를 덮어 네이티브 바이너리 불일치 크래시.
- 시작 방법: `CMD ["node","server.js"]`(또는 `npm start`). ts-node 같은 개발 실행기 대신 빌드 산출물(`node dist/…`) 권장.
- 의존성: `package.json`/lock 이 이미지 빌드에 설치되는지(§1 Next.js ②-1 의 `npm install` vs `npm ci` 주의 동일 적용).

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

### 전환 과도기 앱 — "보안증상 제거 ≠ 구조 정상화" (item50·51·61·65 통합)
외부 SaaS(Supabase 등)→사내로 **옮기다 만** 앱은, deploy-fix 가 노출 키를 빈 값(`''`)/env 로 만들어 **치명을 없애고 verdict 를 ok** 로 만들 수 있다. 하지만 그건 **보안 증상만 없앤 것**이고 구조는 그대로다 — ① 구 클라이언트(Supabase) 코드와 신 백엔드 코드가 **동시 존재(이중 백엔드)**, ② `IS_FURSYS = location.hostname.includes('fursys.com')` 같은 **호스트명 기반 분기**로 배포 후에도 브라우저에 외부 SaaS 코드/키 잔존(item51), ③ Google Sheets `gviz/tq`·Apps Script 직접 호출 등 **브라우저의 외부 서비스 직접 의존**(item65) 이 남아 인트라넷에서 동작 불가할 수 있다.

**검토 신호(하나라도 → "구조 미완" 별도 경고, verdict 와 무관):**
```bash
# 이중 백엔드: 외부 SaaS 클라이언트가 아직 남아 있나
grep -rniE '@supabase/supabase-js|createClient\(|firebase/(firestore|auth)|gviz/tq|script\.google\.com/macros' . \
  --include='*.js' --include='*.jsx' --include='*.ts' --include='*.tsx' --include='*.html' --include='*.vue' \
  2>/dev/null | grep -viE '/(node_modules|\.venv|dist|build)/' | head
# 호스트명 기반 환경분기(item51)
grep -rnoE 'location\.hostname[^\n]{0,40}(includes|indexOf|===|==)' . \
  --include='*.js' --include='*.jsx' --include='*.ts' --include='*.tsx' --include='*.html' --include='*.vue' \
  2>/dev/null | grep -viE '/(node_modules|\.venv|dist|build)/' | head
```
- **판정:** 위 신호가 있고 **동시에 사내 경로(`/api/...`)로도 접근**하면 = 전환 과도기(이중 백엔드). → **"구조 미완" 경고(중간)를 리포트에 별도 표시**한다. **verdict 는 막지 않는다**(치명이 이미 해소됐으면 ok 유지 — deploy-readiness §7 불변). 화면 문구: "보안상 급한 문제(노출된 키)는 막았어요. **다만 이 앱은 예전(외부 서비스) 방식과 새(사내) 방식이 섞여 있어**, 일부 화면은 사내에서 데이터가 안 나올 수 있어요. 구조를 사내 방식 하나로 정리하는 건 앱을 만든 분이 결정해 주셔야 해요(어디를 정리할지 짚어 드릴게요)." + 구 클라이언트/분기 위치를 짚어 준다.
- **key→`''` 의 한계 명시(item61):** deploy-fix 가 외부 SaaS 키를 빈 값/env 로 만들어 "치명 해소"가 됐어도, **그 키를 쓰던 기능은 여전히 외부 서비스를 호출**하려 한다(값만 비었을 뿐 코드 경로는 살아 있음) → 인트라넷에서 실패. "키를 뺐다=해결"이 아니라 **"그 기능을 사내 방식으로 바꿔야 완성"** 임을 위 경고로 알린다. (이건 §9-2 정적/내부 API 판정과 짝 — §9 는 내부/localhost, §10 은 외부 SaaS 직접의존.)
- **(item52) 외부 CDN 이미지 대량 직접참조 → 낮음(방화벽서 깨질 수 있음).** `<img src="https://<외부CDN>/...">` 를 대량 인라인(예 sidiz 342개)하면 사내 방화벽에서 외부 CDN 이 막힐 때 이미지가 안 뜬다. 배포는 되고 기능은 살아있으니 **낮음(경고만)** — "이미지를 외부 주소에서 불러와요. 사내망에서 외부가 막히면 이미지가 안 보일 수 있어요(기능엔 지장 없음). 자주 쓰는 이미지는 앱에 포함하는 게 안전해요." 소수(로고 1~2개 등)면 노이즈이니 **다수(수십 개↑)일 때만** 언급.
