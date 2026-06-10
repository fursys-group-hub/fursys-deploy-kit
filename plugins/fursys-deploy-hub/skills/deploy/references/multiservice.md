# 멀티서비스 배포 (한 프로젝트 → 앱 여러 개)

> deploy 스킬이 `.fursys-deploy-hub/services.json`(서비스 목록 메타데이터)을 발견했을 때만 읽는다.
> 이 파일은 배포 전 검토(security-review)가 멀티서비스를 감지하면 만든다. 없으면 **기존 단일배포 그대로**(이 문서 무시).
> 사용자에게는 "이 앱은 화면과 기능 두 부분으로 올라가요"처럼 쉬운 우리말로만 설명한다. 서비스/서브도메인/env/web/api 같은 용어는 노출 금지.

## 0. 언제 이 흐름을 쓰나
- 프로젝트 루트에 `.fursys-deploy-hub/services.json` 이 있으면 → 이 멀티서비스 흐름.
- 없으면 → 단일배포(앱 1개, app_id=repo). 이 문서를 읽지 않는다.
- 파일 형식은 `contracts/service-manifest.schema.json`(version=1, services[name,dir,dockerfile,port,primary,public,depends_on,build_env,runtime_env]).

## 1. 매니페스트 읽기
```bash
test -f .fursys-deploy-hub/services.json && cat .fursys-deploy-hub/services.json || echo NO_MANIFEST
```
- `NO_MANIFEST` → 단일배포 흐름으로 돌아간다.
- 읽었으면 `services[]` 배열을 메모리에 들고 아래 계산을 한다.

## 2. 사용자에게 묻는 건 단일배포와 동일하게 딱 두 가지
① 어느 브랜드/공간(team) · ② 접속 주소 앞부분(=primary 서비스 주소). **서비스 개수만큼 묻지 않는다.**
- 시작 시 한 줄로 알린다: "이 앱은 두 부분으로 올라가요 — 화면과 기능. 주소는 화면 쪽을 기준으로 정하면 됩니다." (이름·역할은 매니페스트의 name 으로 쉽게 풀어 설명)

## 3. 서브도메인 계산 (입력값 1개 → 서비스마다 결정적)
사용자 입력 주소 앞부분을 `INPUT` 이라 할 때:
- `primary == true` 인 서비스 → 서브도메인 = `INPUT` (그대로).
- 그 외 서비스 → 서브도메인 = `{INPUT}-{name}`.
- primary 가 여러 개면 **첫 번째 true** 를 primary 로 본다. 하나도 없으면 첫 서비스를 primary 로 간주(안내).

예) INPUT=`catalog`, web(primary)·api:
- web → `catalog`
- api → `catalog-api`

## 4. URL 계산 (결정적)
브랜드(brand) = team 에서 `-hub` 제거(`iloom-hub` → `iloom`).
서비스 URL = `https://{서브도메인}.{brand}.hub.fursys.com`.

예) team=`iloom-hub`:
- web → `https://catalog.iloom.hub.fursys.com`
- api → `https://catalog-api.iloom.hub.fursys.com`

## 5. cross-URL 치환 (여기서 한다 — proxy 는 placeholder 를 모름)
각 서비스의 `build_env`·`runtime_env` 값에 들어 있는 `${<svc>.url}` 을 4번에서 계산한 그 서비스의 URL 로 치환한다.
- web.build_env `NEXT_PUBLIC_API_URL=${api.url}` → `https://catalog-api.iloom.hub.fursys.com`
- api.runtime_env `CORS_ORIGINS=${web.url}` → `https://catalog.iloom.hub.fursys.com`
- 참조 대상 svc 가 매니페스트에 없으면 에러로 멈추고 사용자에게 "설정 파일이 가리키는 부분(○○)을 못 찾았어요. 배포 전 검토를 다시 돌려 목록을 새로 만들어 주세요." 안내.

치환 후 env_vars 배열을 만든다(단일배포 ④의 분류 규칙과 동일선):
- `build_env` 의 각 항목 → `{ "key":K, "value":V, "class":"build" }`
- `runtime_env` 의 각 항목 → `{ "key":K, "value":V, "class":"runtime" }`
- (그 외 `.env`/코드에서 추가로 모은 값은 **`references/env-resolve.md` 규칙을 서비스별로** 적용한다: 앱 내부 난수 보안 키는 `gen-secret.sh` 로 자동생성, 사람·외부 값만 질문, fgdw 는 비워두고 계정/비번 item 에 역할 태그(`fgdw_role`)를 달아 보냄(proxy 치환 — `env-resolve.md` §2.3, 서비스 dir 별 env set 마다 독립 적용), class 자동 분류(NEXT_PUBLIC_*/VITE_*→build·비밀류→locked·나머지→runtime). **`.env` 없는 서비스**도 그 dir 의 코드에서 필요한 env 를 감지해 같은 규칙으로 채운다.)

### 5-1. 치환 완료 확인 (빼먹으면 빌드가 조용히 깨진다 — 반드시)
치환을 끝낸 뒤, 만든 env_vars 배열(과 본문)에 `${...}` 가 **하나도 남아 있지 않은지** 직접 확인한다. 하나라도 남아 있으면(치환을 빠뜨렸거나 매핑을 못 찾은 것) **그 서비스 배포를 진행하지 말고 멈춘다.** 리터럴 `${api.url}` 같은 값이 그대로 들어가면 앱을 만드는 과정에서 주소가 빈 채로 굳어 버려 화면·기능이 깨진다.
- 사용자에게는 영어 용어 없이 이렇게만 안내한다:
  > "부분끼리 연결되는 **주소 연결값이 아직 안 채워졌어요.** 배포 전 검토를 다시 돌려 연결 목록을 새로 만든 뒤 다시 시도해 주세요."
- (이중 안전장치) 혹시 이 확인을 놓쳐도, 번들 스크립트 `deploy.sh` 가 본문에 `${` 가 남아 있으면 전송하지 않고 `PLACEHOLDER_UNRESOLVED` 결과 코드로 막는다. 그 코드를 받으면 위와 같은 안내로 처리하고, 배포된 것으로 단정하지 않는다.

## 6. depends_on 위상정렬 — 의존 대상 먼저
`depends_on` 은 "이 서비스가 의존하는 다른 서비스" 목록이다. **의존 대상이 먼저 배포돼야** cross-URL 이 의미를 가진다.
- 위상정렬: in-degree 0(아무도 의존 안 하는 = 의존 대상)부터 배포.
- cataloglens: `web.depends_on=[api]` → **api 먼저 → web 다음.**
- **순환(cycle)** 이면 (web→api→web 등) 진행을 멈추고: "설정이 서로를 의존하도록 꼬여 있어 순서를 정할 수 없어요. 배포 전 검토를 다시 돌려 주세요." 안내.

## 7. 게이트는 repo 단위 1회 (서비스마다 재검사 아님)
- ⑤ 검토 게이트(last-verdict.json final=ok & commit 일치)는 **repo 전체에 대해 1회만** 확인한다(서비스 루프 진입 전에).
- 통과했으면 그 commit 으로 **모든 서비스를 배포**한다. 서비스마다 게이트를 다시 보지 않는다.
- (서버 측 proxy 는 호출마다 verdict-check 하지만 같은 (repo, commit) 이라 결과가 동일하다 — 우리는 추가로 막지 않는다.)

## 8. 순서대로 N회 배포 (deploy.sh 를 서비스마다 호출)
6번 정렬 순서대로 각 서비스에 대해 deploy.sh 를 부른다. 매 호출에 멀티서비스 플래그를 넣는다:
- `--service <service.name>`
- `--base-dir <service.dir>` (예: `backend`. 슬래시 없이 줘도 proxy 가 `/backend` 로 정규화)
- `--dockerfile-loc <service.dockerfile || "Dockerfile">` — **base_directory 기준 상대경로**다. dir 을 앞에 붙이지 말 것(`backend/Dockerfile`처럼 보내면 Coolify가 `/backend/backend/Dockerfile`로 잘못 찾는다). 보통 `Dockerfile` 이라 **생략 가능**(생략 시 proxy 기본값 `/Dockerfile`). proxy 가 선행 슬래시로 정규화한다.
- `--volumes <JSON 배열>` — service.volumes 가 있으면 영속 볼륨 경로 배열(예: `["/data"]`). proxy 가 Coolify persistent storage 로 보장 → 상태저장(SQLite·업로드) 데이터가 재배포 후에도 유지. 없으면 생략. ⚠️ non-root 앱은 그 앱 Dockerfile 이 `USER` 전에 해당 경로를 mkdir+chown 해야 컨테이너가 쓸 수 있다(앱 레포 책임 — 배포 전 검토의 배포가능성 점검에서 경고).
- subdomain(4번째 위치 인자) = 3번에서 계산한 그 서비스의 서브도메인
- port(5번째) = service.port
- env_vars(stdin) = 5번에서 만든 그 서비스의 배열

```bash
# 예: api 먼저 (dockerfile 기본이면 --dockerfile-loc 생략. service.volumes 있으면 --volumes)
printf '%s' "$API_ENV_JSON" | "$CLAUDE_PLUGIN_ROOT/skills/deploy/scripts/deploy.sh" \
  "fursys-group-hub/cataloglens" "$COMMIT" "iloom-hub" "catalog-api" 8100 "" \
  --service api --base-dir backend --volumes '["/data"]'
# → app_id=cataloglens-api, base_directory=/backend, dockerfile_location=/Dockerfile, 볼륨 /data 보장

# 그다음 web
printf '%s' "$WEB_ENV_JSON" | "$CLAUDE_PLUGIN_ROOT/skills/deploy/scripts/deploy.sh" \
  "fursys-group-hub/cataloglens" "$COMMIT" "iloom-hub" "catalog" 3000 "" \
  --service web --base-dir frontend
# → app_id=cataloglens-web
```
- 각 호출의 결과 코드는 단일배포 ⑦과 똑같이 처리한다(CREATED→RUNNING/DEPLOY_FAILED/PENDING, 409 등).
- **`PLACEHOLDER_UNRESOLVED`** 가 나오면 = 치환을 빠뜨려 `${...}` 가 본문에 남은 것(스크립트가 전송 전에 막았다 — 앱은 만들어지지 않았다). 5-1의 안내("주소 연결값이 아직 안 채워졌어요…")로 사용자에게 알리고 **거기서 멈춘다.** 배포 전 검토를 다시 돌려 연결 목록을 새로 만든 뒤 재시도하도록 안내한다.
- **한 서비스라도 실패(DEPLOY_FAILED/PROXY_ERROR)** 하면 거기서 멈추고 사용자에게 어느 부분이 막혔는지 쉽게 알린다(⑨ 실패 해설). 이미 올라간 앞 서비스는 그대로 둔다(중복 생성 시 409 ALREADY_EXISTS → git push 자동재배포 안내).

## 9. 진행 상황 안내 (쉬운 우리말)
- 시작: "기능을 먼저 올리고, 그다음 화면을 올릴게요. (화면이 기능 주소를 알아야 해서 순서가 정해져 있어요.)"
- 각 단계 완료: "기능 올라갔어요 → 주소: https://catalog-api.iloom.hub.fursys.com"
- 전체 완료: 모든 서비스 주소를 보여주고, 대표 주소(primary = 화면)를 강조. "이후 코드 수정은 그냥 git push 하면 양쪽 다 자동으로 다시 배포돼요."

## 요약 (cataloglens 명시)
> `--base-dir backend`(슬래시 없이)만 주면 proxy 가 `/backend` + `/Dockerfile` 로 정규화한다(Coolify 가 선행 슬래시를 요구). dockerfile 이 기본이 아니면(`Dockerfile.prod` 등)만 `--dockerfile-loc` 을 base 기준 상대로 준다.

| 순서 | service | subdomain | base_directory(정규화 후) | dockerfile_location | port | app_id | env(치환 후) |
|---|---|---|---|---|---|---|---|
| 1 | api | catalog-api | /backend | /Dockerfile | 8100 | cataloglens-api | CORS_ORIGINS=https://catalog.iloom.hub.fursys.com (runtime) |
| 2 | web | catalog | /frontend | /Dockerfile | 3000 | cataloglens-web | NEXT_PUBLIC_API_URL=https://catalog-api.iloom.hub.fursys.com (build) |
