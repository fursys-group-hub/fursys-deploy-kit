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
3. **fgdw(사내 DB) 접속정보** — 값/이름에 fgdw IP 또는 `fgdw` 가 보이는 USER/PASSWORD 류 → **비워서 보낸다.** proxy 가 사내 공용계정으로 자동 치환한다. 묻지 않음.
4. **앱 내부 난수 보안 키 → 자동 생성**(사람이 정할 값이 아님). 키 **이름**이 아래에 매칭되면:
   `SECRET_KEY` · `*_SECRET_KEY` · `JWT_SECRET*` · `SESSION_SECRET` · `NEXTAUTH_SECRET` · `*_SALT` · `ENCRYPTION_KEY` · `APP_KEY` · `CSRF_SECRET`
   → `scripts/gen-secret.sh` 로 강한 난수를 만들어 `class=locked` 로 전송. 사용자에겐 **"보안 키는 자동으로 안전하게 만들어 넣었어요"** 만 알린다(값 미출력). **묻지 않는다.**
5. **사람이 정하는 값 → 질문.** `ADMIN_PASSWORD` · `*ADMIN_PASSWORD` · 초기 관리자 비번류 → 한 개씩 쉽게:
   > "관리자 비밀번호를 정해서 알려주세요. (나중에 이 값으로 로그인합니다. 모르면 비워두고 IT본부에 문의하세요.)"
6. **외부 서비스 자격증명 → 질문**(추측·생성 불가). `*_API_KEY` · `*_TOKEN` · `*_ACCESS_KEY` · fgdw 가 아닌 외부 `*_PASSWORD`/`*_SECRET`(URL·호스트가 사외) →
   > "이 앱이 '○○'(쉬운 설명) 값을 필요로 하는데 아직 없어요. 값이 있으면 붙여넣어 주세요. 모르면 비워두고 IT본부에 문의하세요."
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
| `DB_HOST`/`DB_USER`/`DB_PASSWORD`(fgdw) | 3 (fgdw) | 비워 보냄 → proxy 치환 |
| `NEXT_PUBLIC_API_URL` | 2 (cross-URL) | `${api.url}` → deploy 치환, build |
| `NODE_ENV` 등 | 7 (일반) | 자동 |
