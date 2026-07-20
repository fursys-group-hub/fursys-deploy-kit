# 멀티서비스 감지 + 매니페스트 생성 (배포 전 검토에서만)

> deploy-check 가 "🚀 배포 가능성" 점검 중, 이 프로젝트가 **여러 부분(앱 N개)** 으로 올라가야 하는지 판단하고,
> 그렇다면 `.fursys-deploy-hub/services.json` 을 만든다. 단일서비스면 **만들지 않는다**(현행 단일배포 유지).
> 사용자에게는 쉬운 우리말만 쓴다(서비스·서브도메인·env 같은 용어 금지). 스키마는 `contracts/service-manifest.schema.json`.

## 1. 멀티서비스인지 감지
다음 **A·B·C 중 하나라도** 맞으면 "여러 부분으로 나뉜 앱"으로 본다. 위에서부터 신뢰도 순(A 가장 확실 → C 추정):

- **A. 서브디렉터리에 Dockerfile 이 둘 이상** (루트가 아닌 곳에 두 개 이상). 예: `frontend/Dockerfile` + `backend/Dockerfile`.
  ```bash
  ls -1 */Dockerfile **/Dockerfile 2>/dev/null
  ```
- **B. `docker-compose.yml`(또는 `compose.yaml`) 가 있고 서비스가 2개 이상.** compose 는 **구조 힌트로만 읽는다**(서비스 이름·빌드 디렉토리(`build.context`)·포트(`ports`/`expose`)·`depends_on`). **배포에는 compose 를 쓰지 않는다** — 어디까지나 Dockerfile 단위로 N개를 올린다.
- **C. 디렉터리 구조 + 패키지 매니페스트로 추정** (Dockerfile·compose 가 **하나도 없을 때**의 보강 — 이게 빠져서 backend(Python)+frontend(Vite) 류가 단일 `framework` 로 오감지되던 구멍이다).
  - **서로 다른 두 서브디렉터리**가 각자 **독립 패키지 매니페스트**를 가지면 별개 부분으로 본다. 한 디렉터리당 매니페스트는 아래 중 하나:
    - 프론트(Node 계열): `package.json` (안에 `next`/`react`/`vite`/`@nestjs/*` 의존). 단 **루트에도 `package.json` 이 있고 서브가 그 워크스페이스(monorepo workspaces)** 면 한 패키지로 보고 멀티 아님 — 루트 `package.json` 의 `workspaces` 필드를 먼저 확인.
    - 백(Python 계열): `requirements.txt` / `pyproject.toml` / `Pipfile` (FastAPI·Django·Flask 등).
    - 백(JVM): `build.gradle`(`.kts`) / `pom.xml` (Spring 등).
  - 판정: **서로 다른 디렉터리에 위 매니페스트가 2종 이상 분포**하면 멀티서비스. 흔한 형태:
    - `frontend/package.json` + `backend/requirements.txt`
    - `web/package.json` + `api/pyproject.toml`
    - `client/package.json` + `server/package.json` (둘 다 Node 이고 루트 workspaces 가 **아닐** 때)
  ```bash
  # Dockerfile·compose 가 없을 때만 가동하는 추정. 서브디렉터리별 매니페스트를 모은다.
  # (루트 자신은 제외 — 루트 단일 매니페스트는 단일서비스다.)
  find . -mindepth 2 -maxdepth 2 \
    \( -name package.json -o -name requirements.txt -o -name pyproject.toml \
       -o -name Pipfile -o -name pom.xml -o -name 'build.gradle*' \) \
    -not -path '*/node_modules/*' -not -path '*/.venv/*' -not -path '*/venv/*' \
    2>/dev/null | sort -u
  # 위 출력에서 서로 다른 부모 디렉터리가 2개 이상이면 멀티서비스 후보.
  # (단, 모두 한 디렉터리 밑이면 단일. 루트 package.json 의 workspaces 가 서브를 포함하면 단일.)
  ```
  - C 로 감지하면 매니페스트의 프레임워크로 `port`(§3 기본값)와 `primary`(화면 쪽=Next/Vite/React 등 프론트)를 정하고, **각 부분에 Dockerfile 이 없으므로 §3·framework-rules 의 정준 Dockerfile 골격으로 부분별 Dockerfile 을 같이 생성**해야 배포된다(없으면 배포 단계에서 빌드 실패). 이건 사용자에게 "두 부분으로 보여서 각각 올릴 준비를 했어요"로 알린다.

루트에 Dockerfile 1개뿐이고 서브디렉터리 Dockerfile 도 없고, 위 C 의 매니페스트가 한 디렉터리(또는 루트)에만 있으면 → **단일서비스.** 매니페스트를 만들지 않고 현행대로 둔다.

## 2. compose 를 구조 힌트로 읽기 (있을 때)
`docker-compose.yml` 에서 각 서비스마다 뽑는다(배포엔 안 씀, 매니페스트 채우기용):
- 서비스 이름 → `name`
- `build.context`(또는 `build`) → `dir`. `dockerfile:` 지정이 있으면 → `dockerfile`(dir 기준 상대로 환산).
- `ports`/`expose` 의 컨테이너 포트 → `port`.
- `depends_on` → `depends_on`.
- 환경값(`environment`)에 다른 서비스 URL 을 가리키는 게 보이면 cross-URL placeholder(`${<svc>.url}`)로 옮길 후보. (단정 말고 사용자 확인)

compose 가 없으면 Dockerfile 위치·각 디렉토리의 코드(프레임워크)·`.env` 로 추론한다(프론트=화면, 백=기능 식).

## 3. 필드 채우기 규칙
- `name`: 디렉토리/compose 서비스명을 소문자·하이픈으로(`^[a-z0-9][a-z0-9-]*$`). 보통 `web`(화면), `api`(기능).
- `dir`: repo 루트 기준 빌드 디렉토리(`frontend`/`backend`, 루트면 `.`).
- `dockerfile`: dir 기준 상대(기본 `Dockerfile`).
- `port`: 코드/프레임워크 기본(Next 3000 / Spring 8080 / Nest 3000 / Vite-nginx 8080 / FastAPI·Django 8000) 또는 compose 포트.
- `primary`: **화면(사용자가 직접 접속하는 쪽)** 을 true. 보통 web/front. 정확히 1개만 true.
- `public`: 기본 true(MVP 표시용).
- `depends_on`: 의존 관계(화면이 기능 주소를 빌드에 박는다면 web.depends_on=[api]). compose `depends_on` 활용.
- `build_env`/`runtime_env`: 한 서비스가 **다른 서비스의 주소**를 필요로 하면 그 값을 placeholder 로 적는다 — **여기서 실제 URL 로 치환하지 않는다**(deploy 가 치환). 예:
  - 프론트가 백엔드 API 주소를 빌드에 쓰면: web.build_env `{ "NEXT_PUBLIC_API_URL": "${api.url}" }`
  - 백엔드가 프론트 주소를 CORS 허용에 쓰면: api.runtime_env `{ "CORS_ORIGINS": "${web.url}" }`
  - 빌드에 박히는 공개 주소(NEXT_PUBLIC_*/VITE_*)는 build_env, 서버 실행 중 쓰는 값은 runtime_env. 비밀번호·키는 여기 두지 않는다(검토 본문 보안 규칙 그대로).
- `volumes`: 서비스가 **상태(업로드 파일·SQLite 등)를 저장**하면 그 컨테이너 경로를 배열로 적는다(예: `["/data"]`). docker-compose 의 named volume 마운트(`volumes:` 의 `catalog_data:/data` → `/data`)에서 가져온다. 함께, 그 경로를 가리키는 설정값(예: `UPLOAD_DIR=/data/uploads`)도 compose `environment` 에서 가져와 그 서비스 env 에 넣어야 데이터가 볼륨에 쌓인다. ⚠️ 그 앱이 non-root 로 돌면(Dockerfile `USER ...`) **그 앱 Dockerfile 이 `USER` 전에 마운트 경로를 mkdir+chown** 해야 쓰기 가능하다 — 안 돼 있으면 배포 후 권한 에러로 크래시한다(배포가능성 점검에서 경고).

## 4. 자동 판단 + 결과 알림 (확인질문 아님 — 정말 애매할 때만 질문)
감지·필드(1~3)는 **소스로 AI가 판단한다.** 비개발자에게 "맞나요?"로 되묻지 않는다("정할 수 있는 건 묻지 말고 자동 처리한다" 원칙). 대신 판단 결과를 **쉬운 우리말로 알리기만** 하고 진행한다. 예:
> "이 앱은 두 부분으로 보여요: **화면** 과 **기능**. 화면이 기능의 주소를 알아야 해서 **기능을 먼저** 올리고 화면을 나중에 올립니다. (코드를 보고 자동으로 정했어요.)"
- **단, 판단이 정말 애매할 때만 한 가지를 묻는다**(아래 경우에 한해서만 — 그 외엔 묻지 않는다):
  - 화면(primary) 후보가 둘 이상이거나 하나도 못 정하겠을 때(예: 웹앱처럼 보이는 게 둘),
  - 또는 순서(의존관계)를 정할 근거가 없을 때(compose `depends_on` 없음 + 프레임워크로도 앞뒤를 못 가림).
  - 이때만 막힌 **딱 한 가지만** 쉽게 묻는다. 예: "둘 중 사용자가 **직접 접속하는 화면**은 어느 쪽인가요?"
- 영어 용어(service/subdomain/env)는 쓰지 않는다. 감지가 틀린 것 같다고 사용자가 먼저 알려주면 그 설명대로 name/dir/depends_on 을 고친다.

## 5. 파일 쓰기 + .gitignore 안내
판단되면 프로젝트 루트 `.fursys-deploy-hub/services.json` 을 `contracts/service-manifest.schema.json` 형태로 쓴다(version=1).
```
.fursys-deploy-hub/services.json
```
그리고 `.fursys-deploy-hub/` 를 `.gitignore` 에 넣도록 안내한다(이건 내 PC에만 두는 메모라 회사 GitHub 에 올릴 필요가 없다):
```bash
grep -qxF '.fursys-deploy-hub/' .gitignore 2>/dev/null || printf '\n# fursys-deploy-hub 로컬 메타데이터(올릴 필요 없음)\n.fursys-deploy-hub/\n' >> .gitignore
```
사용자에게: "이 앱이 화면·기능 두 부분으로 올라가도록 목록을 만들어 뒀어요. 나중에 '배포해줘' 하면 순서대로(기능 먼저, 화면 나중) 한 번에 올라갑니다."

## cataloglens 예시 (생성 결과)
`.fursys-deploy-hub/services.json`:
```json
{
  "version": 1,
  "services": [
    { "name": "web", "dir": "frontend", "dockerfile": "Dockerfile", "port": 3000, "primary": true, "public": true, "depends_on": ["api"], "build_env": { "NEXT_PUBLIC_API_URL": "${api.url}" } },
    { "name": "api", "dir": "backend",  "dockerfile": "Dockerfile", "port": 8100, "primary": false, "public": true, "depends_on": [], "runtime_env": { "CORS_ORIGINS": "${web.url}" } }
  ]
}
```
(cross-URL 은 placeholder 그대로 — 실제 주소 치환은 deploy 단계에서.)
