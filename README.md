# Fursys Deploy Hub — Claude Code 플러그인 (kit)

브랜드 실무자가 사내 Coolify에 **보안 검사 → 자가 배포**를 자연어로 수행하는 Claude Code 플러그인.

> **배포 구조**: 이 `kit/` 디렉터리가 **그대로** 별도 경량 repo `fursys-group-hub/fursys-deploy-kit` 로 동기화되어 publish된다. 그래야 사용자가 마켓플레이스를 add 할 때 board·proxy 등 monorepo 나머지가 함께 내려가지 않는다(마켓플레이스 add = 그 repo 전체 clone이기 때문). 동기화는 monorepo 루트에서 `node scripts/publish-kit.mjs` 로 수행한다. 여기 `kit/.claude-plugin/marketplace.json` 이 그 마켓플레이스 정의이며, 로컬 테스트 시엔 `/plugin marketplace add ./kit` 로 바로 쓸 수 있다.

## 구조
```
kit/
├─ .claude-plugin/marketplace.json         마켓플레이스 정의
└─ plugins/fursys-deploy-hub/
    ├─ .claude-plugin/plugin.json           플러그인 매니페스트
    ├─ bin/fdh-engine                        번들된 0토큰 보안 엔진 (플러그인 활성화 시 PATH 자동 등록)
    ├─ commands/                             확정적 슬래시 커맨드 입구
    │   ├─ create-app.md                     /create-app → create-app 스킬
    │   ├─ github-setup.md                   /github-setup → github-setup 스킬
    │   ├─ deploy-check.md                   /deploy-check → security-review 스킬
    │   ├─ deploy.md                         /deploy → deploy 스킬
    │   └─ my-apps.md                        /my-apps → deploy 스킬의 my-apps.sh
    └─ skills/
        ├─ create-app/                       새 프로젝트 만들기 (scripts/create-app.sh)
        ├─ github-setup/                     회사 GitHub 연결·가입신청·repo 등록 (scripts/github-detect.sh·repo-register.sh)
        ├─ security-review/                  배포 전 검토 (엔진 + scripts/verdict-upload.sh)
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

## 엔진 수정 시 재빌드 (bin/fdh-engine 갱신)
보안 엔진(`engine/`)을 수정하면 플러그인 `bin/fdh-engine` 도 다시 번들·갱신해야 한다.
```
cd engine
npm run build:bundle        # 단일 self-contained JS 번들 → kit/plugins/fursys-deploy-hub/bin/fdh-engine 로 복사
npm test                    # vitest green 확인
```
그다음:
1. 플러그인 버전업 — `kit/plugins/fursys-deploy-hub/.claude-plugin/plugin.json` 과 `kit/.claude-plugin/marketplace.json` 의 version 을 **일치**시킨다(publish 스크립트가 불일치 시 중단).
2. monorepo 루트에서 `node scripts/publish-kit.mjs --target <fursys-deploy-kit 클론경로> --push`
3. 실무자는 `/plugin marketplace update fursys-deploy-hub`

> **Windows 주의(알려진 점검 항목)**: 플러그인 `bin/` 의 PATH 등록(shim)이 Windows 에서 불안정할 수 있다. `fdh-engine` 이 bare 명령으로 동작하지 않으면 폴백으로 `node <bin 경로>/fdh-engine` 형태로 직접 실행한다.

## 비밀 취급
- 플러그인 파일에는 **어떤 비밀도 없다.** 프록시/게시판 주소는 비밀이 아니다.
- 실무자는 개인 배포 키(`fdh_live_…`)만 보유하며, 첫 배포 시 입력해 `~/.fursys/proxy-key` 에 저장된다.
- Coolify 토큰은 전부 중앙 프록시 서버 env에만 존재한다.
