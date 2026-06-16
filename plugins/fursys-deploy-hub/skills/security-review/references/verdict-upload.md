# 검토 결과 등록 (프록시 `/verdict`) — 페이로드 구성 규약

SKILL.md 5-2 단계에서 쓴다. **종합 판정 + `last-verdict.json` 기록이 끝난 뒤**, 검토 결과를
구조화 형태로 사내 배포 시스템(프록시)에 등록한다. 등록된 검토를 통과한 코드만 실제로 배포된다(서버 게이트).

핵심: **HTML 리포트 본체는 올리지 않는다.** 올리는 건 아래 구조화 데이터뿐이다.

**호출은 번들 스크립트(`scripts/verdict-upload.sh`)가 한다.** 이 문서는 그 스크립트에
**stdin 으로 넘길 VerdictBody JSON 을 어떻게 채우는지**(아래 4)와, 키·전송 대상·repo/commit 규칙을
정의한다. curl 을 손으로 짜지 않는다 — 스크립트가 키 확보·`*.hub.fursys.com` 가드·`POST /verdict`
호출·응답 분기를 처리한다.

---

## 1) 개인 배포 키 확보 (스크립트가 처리 — 없으면 등록 건너뜀)
스크립트(`common.sh`)가 키를 `FURSYS_PROXY_KEY` → `~/.fursys/proxy-key` 순으로 읽는다(이 두 곳만).
- 둘 다 없으면 스크립트가 `NO_KEY` 를 돌려준다. 이때 **등록을 건너뛴다.** (검사 자체는 멈추지 않는다.) 사용자에게:
  > "검토는 마쳤어요. 아직 배포 키가 없어 검토 결과를 배포 시스템에 등록하진 못했는데,
  > 나중에 '배포해줘'로 배포할 때 키를 넣으면 그때 검토 결과가 함께 등록됩니다."
  이렇게 안내하고 6단계(HTML 리포트)로 넘어간다.
- 키 값은 화면·로그에 절대 출력하지 않는다. (검토 시점에 새 키를 입력받지 않는다 — 키 입력은 배포 단계의 몫.)

## 2) 전송 대상 고정 (보안 — deploy 와 동일 규칙, 스크립트가 처리)
- 기본값은 `https://deploy-proxy.hub.fursys.com`.
- `FURSYS_PROXY_URL` 로 덮어쓸 수 있으나, **호스트가 `*.hub.fursys.com`(사내) 일 때만** 허용한다(`common.sh` 가드).
  그 외 주소면 무시하고 기본값을 쓴다(개인 키·검토 결과가 외부로 새지 않게).

## 3) repo · commit 결정
- repo: `fursys-group-hub/<repo_name>` 형식(git 원격에서 도출). 프록시 게이트 조회 키와 **동일 형식**이어야 한다.
  ```bash
  REPO_NAME=$(basename -s .git "$(git config --get remote.origin.url)")
  REPO="fursys-group-hub/${REPO_NAME}"
  ```
- commit: `git rev-parse HEAD`(없으면 등록 생략 — 게이트가 commit 단위라 commit 없으면 의미 없음).
  ```bash
  COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
  ```
- 주의: 게이트는 commit 단위로 본다. **검토한 코드가 commit·push 된 상태여야** 나중에 배포 시
  게이트 commit 과 일치한다. 아직 커밋 안 한 변경이 있으면 사용자에게 "지금 변경분을 저장(commit)·
  올린(push) 뒤 배포해야 이 검토 결과가 그대로 인정돼요" 라고 알린다.

## 4) VerdictBody JSON 구성 — 빌더가 기계 조립한다 (직접 작성 금지)
**VerdictBody JSON 을 손으로 쓰지 않는다.** 위험한 값(findings 의 한글·따옴표·역슬래시·줄바꿈)을
사람이 JSON 리터럴에 박아넣다 이스케이프를 틀려 본문이 깨지던 문제(과거 400 의 진짜 원인)와 필수필드
누락을 없애기 위해, `scripts/verdict-build.sh` 가 2단계에서 저장한 엔진 JSON(`.fursys-deploy-hub/_engine.json`)을
읽어 직렬화기로 본문을 만든다. 너는 작은 스칼라(repo/commit/security/deployable/final)만 넘긴다.
선택 필드(`findings`/`env_vars`/`engine_verdict`)는 빌더가 엔진 마스킹 형태 그대로 싣는다(시크릿 본체 금지).
아래 표는 **빌더가 채우는 결과 형태(참고용)** — 직접 만들 형태가 아니다.

```json
{
  "repo":"fursys-group-hub/<REPO_NAME>",
  "commit":"<HEAD SHA>",
  "framework":"<엔진 target.framework>",
  "security":"pass|caution|blocked",
  "deployable":true,
  "final":"ok|blocked",
  "summary":{"critical":0,"high":0,"medium":1,"low":2},
  "findings":[ /* 엔진 findings 배열 그대로(마스킹됨), 없으면 생략 */ ],
  "env_vars":[ {"name":"DATABASE_URL","class":"locked"} ],
  "engine_verdict":{ /* 엔진 원본 verdict JSON 전체, 없으면 생략 */ }
}
```
호출(빌더 → 업로드 파이프):
```bash
ROOT="$CLAUDE_PLUGIN_ROOT/skills/security-review"
"$ROOT/scripts/verdict-build.sh" ".fursys-deploy-hub/_engine.json" \
    "fursys-group-hub/<REPO_NAME>" "<HEAD SHA>" "<SECURITY>" "<DEPLOYABLE:true|false>" "<FINAL>" \
  | "$ROOT/scripts/verdict-upload.sh" "fursys-group-hub/<REPO_NAME>" "<HEAD SHA>"
```

### 보내는 값 (어디서 오는가)
| 필드 | 필수 | 타입 | 출처 |
|---|---|---|---|
| `repo` | ✔ | string | `fursys-group-hub/<repo_name>` (3) |
| `commit` | ✔ | string | `git rev-parse HEAD` (3) |
| `security` | ✔ | `"pass"`\|`"caution"`\|`"blocked"` | 보안 축 판정(3단계) = `last-verdict.json.security` |
| `deployable` | ✔ | bool | 배포가능 축(가능=true/불가=false) = `last-verdict.json.deployable` |
| `final` | ✔ | `"ok"`\|`"blocked"` | 종합 판정 = `last-verdict.json.final` |
| `summary` | ✔ | `{critical,high,medium,low: int≥0}` | 엔진 `summary` |
| `framework` | – | string\|null | 엔진 `target.framework`(표시용) |
| `app_id` | – | string\|null | 보통 미정 → 생략 |
| `brand` | – | string\|null | 보통 미정 → 생략 |
| `findings` | – | array\|null | 엔진 `findings` 그대로(마스킹됨, **평문 시크릿 금지**) |
| `env_vars` | – | array\<{name,class}\>|null | 엔진 `envVars`(값 미포함, name+class만) |
| `engine_verdict` | – | object\|null | 엔진 원본 verdict JSON 전체(감사·재현용) |

- 선택 필드는 **값이 있을 때만** 넣는다(없으면 키 자체를 생략).
- **HTML 리포트 경로·본문은 넣지 않는다.** `last-verdict.json` 의 `report`/`generated_at` 도 보내지 않는다(로컬 전용).
- **전송 직전 자동 정규화·검증(스크립트가 처리 — 별도 처리 불필요):** `verdict-upload.sh` 가 POST 직전에:
  1. **비ASCII → `\uXXXX`**: 한글·한자 등을 ASCII 이스케이프한다(node 직렬화기로 본문을 다시 만들어 처리 → 항상 유효 JSON, 백슬래시·따옴표도 정확히 보존). 사내 프록시 앞단 인프라가 3바이트 UTF-8 시퀀스를 깨 `request.json()` 이 실패하는 문제를 우회한다(의미·서버 저장값 동일). ※ 과거의 "역슬래시→슬래시" 치환은 정상 JSON 이스케이프 `\"` 를 `/"` 로 부숴 오히려 본문을 깨뜨려서 **제거**했다.
  2. **사전검증 게이트**: 서버와 동일 조건(repo·commit·security·final 존재, deployable 비-null, summary 객체)을 보내기 전에 확인해, 실패하면 보내지 않고 `BAD_BODY <사유>` 로 알린다(서버 왕복·401 오진단 방지). 빌더로 본문을 만들면 이 게이트는 통과가 보장되며, 손 조립 우회 시의 안전망으로 남는다.
  3. 본문은 **stdin(`--data-binary @-`)**으로 전송한다(Windows 명령행 길이 한계 우회) + 연결/전체 타임아웃으로 무한 대기 방지.
  - 모두 스크립트가 알아서 한다. (3바이트 UTF-8 의 근본 원인은 프록시 앞단 인프라이며 IT본부가 서버측에서 별도 처리 예정.)

## 5) 응답 처리 (스크립트 결과 코드 기준)
- `STORED` (200 `{"stored":true}`) → 등록 성공. 조용히 6단계로 진행(별도 자랑 불필요).
- `NO_KEY` → 1)의 "키 없어 등록 건너뜀" 안내.
- `NO_COMMIT` → commit 이 없어 등록 생략. "지금 변경분을 저장(commit)·올린(push) 뒤 배포해야
  이 검토 결과가 그대로 인정돼요" 라고 안내(3 참조).
- `UNAUTHORIZED` (401 `invalid_key`) → "배포 키가 유효하지 않거나 회수된 것 같아요. 검토 자체는 끝났고
  로컬 리포트는 만들어졌어요. 키 문제는 IT본부에 문의하고, 배포할 때 다시 시도됩니다." (검사 차단 안 함)
- `UPLOAD_FAILED <code>` / 네트워크 실패 → "검토 결과를 배포 시스템에 등록하지 못했어요(연결 문제).
  배포할 때 다시 시도됩니다." (로컬 리포트·`last-verdict.json` 은 이미 남았으니 그대로 진행)

어느 경우든 **등록 성공 여부와 무관하게 6단계(HTML 리포트)는 반드시 만든다.**
