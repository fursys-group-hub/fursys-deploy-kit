# Fursys Deploy Hub — Claude Code 플러그인 (kit)

브랜드 실무자가 사내 Coolify에 **보안 검사 → 자가 배포**를 자연어로 수행하는 Claude Code 플러그인.

> **배포 구조**: 이 `kit/` 디렉터리가 **그대로** 별도 경량 repo `fursys-group-hub/fursys-deploy-kit` 로 동기화되어 publish된다. 그래야 사용자가 마켓플레이스를 add 할 때 board·proxy 등 monorepo 나머지가 함께 내려가지 않는다(마켓플레이스 add = 그 repo 전체 clone이기 때문). 동기화는 monorepo 루트에서 `node scripts/publish-kit.mjs` 로 수행한다. 여기 `kit/.claude-plugin/marketplace.json` 이 그 마켓플레이스 정의이며, 로컬 테스트 시엔 `/plugin marketplace add ./kit` 로 바로 쓸 수 있다.

## 구조
```
kit/
├─ .claude-plugin/marketplace.json         마켓플레이스 정의
└─ plugins/fursys-deploy-hub/
    ├─ .claude-plugin/plugin.json           플러그인 매니페스트
    ├─ commands/                             확정적 슬래시 커맨드 입구
    │   ├─ create-app.md                     /create-app → create-app 스킬
    │   ├─ github-setup.md                   /github-setup → github-setup 스킬
    │   ├─ deploy-check.md                   /deploy-check → deploy-check 스킬
    │   ├─ deploy.md                         /deploy → deploy 스킬
    │   └─ my-apps.md                        /my-apps → deploy 스킬의 my-apps.sh
    └─ skills/
        ├─ create-app/                       새 프로젝트 만들기 (scripts/create-app.sh)
        ├─ github-setup/                     회사 GitHub 연결·가입신청·repo 등록 (scripts/github-detect.sh·repo-register.sh)
        ├─ deploy-check/                  배포 전 검토 (scripts/fdh-engine.mjs = 번들된 0토큰 보안 엔진 + scripts/verdict-upload.sh)
        └─ deploy/                           최초 배포·정리 (scripts/deploy.sh·logs.sh·my-apps.sh·delete-app.sh, references/)
```

## 실무자 설치 (1회)
```
/plugin marketplace add fursys-group-hub/fursys-deploy-kit
/plugin install fursys-deploy-hub@fursys-deploy-hub
```
이후 갱신: `/plugin marketplace update fursys-deploy-hub`

> repo 이름은 `fursys-deploy-kit`(플러그인 전용·경량)이고, `install`/`update` 의 `fursys-deploy-hub` 는 marketplace.json 의 name 필드라 repo 이름과 무관하게 유지된다.

> private repo는 로컬 git 자격증명으로 접근된다(실무자는 이미 org에 push 중이라 추가 설정 불필요).
> 백그라운드 자동 갱신이 필요하면 `GITHUB_TOKEN`(repo 읽기 권한) 환경변수를 설정한다.

## 로컬 테스트
```
/plugin marketplace add ./kit
/plugin install fursys-deploy-hub@fursys-deploy-hub
```

## 엔진 수정 시 재빌드 (skills/deploy-check/scripts/fdh-engine.mjs 갱신)
보안 엔진(`engine/`)을 수정하면 플러그인 번들 `skills/deploy-check/scripts/fdh-engine.mjs` 도 다시 번들·갱신해야 한다.
```
cd engine
npm run build:bundle        # 단일 self-contained JS 번들 → kit/plugins/fursys-deploy-hub/skills/deploy-check/scripts/fdh-engine.mjs 로 복사
npm test                    # vitest green 확인
```
그다음:
1. 플러그인 버전업 — `kit/plugins/fursys-deploy-hub/.claude-plugin/plugin.json` 과 `kit/.claude-plugin/marketplace.json` 의 version 을 **일치**시킨다(publish 스크립트가 불일치 시 중단).
2. monorepo 루트에서 `node scripts/publish-kit.mjs --target <fursys-deploy-kit 클론경로> --push`
3. 실무자는 `/plugin marketplace update fursys-deploy-hub`

> **⚠️ 발행해도 설치된 플러그인은 자동 갱신되지 않는다(항목9).** `publish-kit.mjs --push` 로 마켓플레이스 repo 에 새 버전을 올려도, **이미 `/plugin install` 한 환경(사장님 포함)은 옛 버전을 그대로 쓴다** — Claude Code 가 플러그인을 자동 업데이트하지 않기 때문이다. 새 동작(엔진 보강·SKILL 변경 등)을 반영하려면 **각 사용 환경에서 반드시 `/plugin marketplace update fursys-deploy-hub` 를 한 번 실행**해야 한다(그 뒤 필요하면 `/plugin install ...@... ` 로 재설치). 증상: "고쳤다는데 왜 예전처럼 동작하지?" = 십중팔구 마켓플레이스 update 미실행. 발행 안내 시 이 한 줄을 사용자에게 함께 전한다: **"새 버전을 쓰려면 `/plugin marketplace update fursys-deploy-hub` 를 한 번 실행해 주세요."**

> **⚠️ 엔진을 플러그인 최상위 `bin/` 으로 되돌리지 말 것.** claude.ai 호스팅 동기화가 top-level `bin/` 실행파일을 거부한다(CLI 에서는 PATH 에 자동 등록되지만 관리자 승인 화면에는 드러나지 않기 때문 — 실행 진입점은 hooks·commands·mcpServers 로 선언하라는 정책). 그래서 엔진은 **선언된 스킬 번들 안**(`skills/deploy-check/scripts/fdh-engine.mjs`)에 두고 `node "$CLAUDE_PLUGIN_ROOT/skills/deploy-check/scripts/fdh-engine.mjs"` 로 부른다. PATH 명령 `fdh-engine` 은 **존재하지 않는다.**
>
> 이 방식은 부수적으로 옛 PATH 방식의 두 가지 고장을 함께 없앤다 — ① Windows 에서 불안정했던 shim, ② Windows 에서 커밋된 파일의 실행비트가 `100644` 로 기록돼 macOS/Linux 사용자에게 permission denied 가 되던 문제(`node` 로 부르므로 `+x` 가 불필요).

## 비밀 취급
- 플러그인 파일에는 **어떤 비밀도 없다.** 프록시/게시판 주소는 비밀이 아니다.
- 실무자는 개인 배포 키(`fdh_live_…`)만 보유하며, 첫 배포 시 입력해 `~/.fursys/proxy-key` 에 저장된다.
- Coolify 토큰은 전부 중앙 프록시 서버 env에만 존재한다.
