# 배포 실패 원인 해설 플레이북 (deploy 스킬 ⑨에서 참조)

배포가 실패해 빌드 기록(`logs.sh` → `GET /apps/{app_id}/logs` 의 `logs`)을 받았을 때, **그 텍스트를 읽고 원인을 진단**해 비개발자에게 안내하기 위한 참고 자료다. 아래는 자주 나오는 실패 유형과, 그때 쓰는 **쉬운 우리말 설명 + 복붙 수정 프롬프트**의 예시다.

> 사용 원칙
> - 로그의 **마지막 에러 줄** 근처가 진짜 원인일 때가 많다. 위에서부터 줄줄이 읽지 말고 끝부분부터 본다.
> - 아래 유형 중 가장 가까운 것을 고르되, **로그에 실제로 나온 표현을 근거로** 설명한다(추측으로 단정하지 않는다).
> - 어떤 유형에도 안 맞으면, 마지막 에러 줄을 근거로 같은 3단 형식(무엇/어떻게/다음)으로 직접 만든다.
> - 기술용어를 사용자에게 노출하지 않는다. (아래 "로그 신호"는 에이전트가 보는 것일 뿐, 사용자에게 그대로 읽어주지 않는다.)
> - **복붙 수정 프롬프트**는 사용자가 "저(또는 코드 도우미)에게 그대로 붙여넣는" 문장이다. 코드 도우미가 바로 실행 가능하도록 구체적으로 적는다.

---

## 1) 필요한 부품(의존성)이 빠짐
- **로그 신호**: `Cannot find module '...'`, `Module not found`, `npm ERR! 404`, `Could not resolve "..."`, `ImportError: No module named ...`, `ModuleNotFoundError`.
- **쉬운 설명**: "앱을 만드는 데 필요한 부품 하나(`○○`)가 목록에 빠져 있어서 멈췄어요."
- **복붙 수정 프롬프트**:
  ```
  배포 빌드에서 '○○' 모듈을 찾지 못해 실패했어. package.json(또는 requirements.txt) 의존성 목록에 '○○'를 추가하고, lockfile(package-lock.json / pnpm-lock.yaml / requirements 등)도 같이 갱신해줘.
  ```
- **먼저 갈라보기:** 못 찾는 모듈이 **빌드 도구**(`tailwindcss`, `@tailwindcss/postcss`, `postcss`, `autoprefixer`, `typescript`, `sass` 등)이고 **이미 `package.json` 의 `devDependencies` 에 들어 있다면**, 1번이 아니라 **1-1번**(production 설치로 스킵)이다. 로그에 설치 패키지 수가 비정상적으로 적게(예: `added 52 packages`) 찍혔는지도 단서.

## 1-1) 빌드 도구가 devDependencies 라서 production 설치 때 빠짐
- **로그 신호**: `Cannot find module '@tailwindcss/postcss'`(또는 `tailwindcss`/`postcss`/`typescript` 등 **빌드 전용 도구**) + 그 도구가 `package.json` 의 **`devDependencies`** 에 있음. 종종 설치 단계에 `npm ci --omit=dev`(구 `--production`) 또는 빌드 단계 `NODE_ENV=production` 흔적, 설치 패키지 수 급감(`added NN packages`)이 함께 보인다.
- **원인**: `npm ci` 가 `NODE_ENV=production` 상태(또는 `--omit=dev`)로 돌면 **devDependencies 를 건너뛴다.** Next.js(Tailwind v4)·Nest 등은 `tailwindcss`·`@tailwindcss/postcss`·`typescript` 같은 **빌드에 꼭 필요한 도구를 devDependencies 에 두므로**, 그 상태로 설치하면 빌드가 모듈을 못 찾고 멈춘다. **특히 사내 Coolify 는 빌드에 `NODE_ENV=production` 을 주입하므로, Dockerfile 에 NODE_ENV 를 명시하지 않아도 스킵될 수 있다.** (모듈은 목록에 **있다** — 그래서 1번의 "package.json 에 추가"는 오진이다.)
- **쉬운 설명**: "앱을 만들 때 쓰는 도구(`○○`)가 '운영용 설치' 모드 때문에 빠졌어요. 설치 방식을 살짝 바꾸면 돼요."
- **복붙 수정 프롬프트**:
  ```
  배포 빌드가 production 모드로 의존성을 설치해서 devDependencies(예: tailwindcss, @tailwindcss/postcss)가 빠져 '○○' 모듈을 못 찾고 실패했어. 사내 Coolify 가 빌드에 NODE_ENV=production 을 주입하니, Dockerfile 의 npm ci 가 도는 스테이지(보통 deps)에 npm ci 직전 `ENV NODE_ENV=development` 를 추가해 그 주입값을 덮어써줘(또는 `npm ci --include=dev`). `NODE_ENV=production` 은 마지막 runner 스테이지에서만 두고, `npm ci --omit=dev`/`--production` 이 있으면 제거해줘. (standalone 멀티스테이지면 devDependencies 는 최종 이미지에 안 들어가 안전.)
  ```

## 2) 의존성 잠금파일(lockfile) 불일치
- **로그 신호**: `npm ci` 실패 + `lock file ... is not in sync`, `frozen-lockfile`, `pnpm-lock.yaml is not up to date`, `The lockfile ... is outdated`.
- **쉬운 설명**: "부품 목록과 실제 잠금 기록이 서로 안 맞아서 멈췄어요. 둘을 다시 맞춰주면 돼요."
- **복붙 수정 프롬프트**:
  ```
  배포 빌드에서 lockfile이 package.json과 맞지 않아 실패했어. 의존성을 다시 설치해 lockfile(package-lock.json / pnpm-lock.yaml / yarn.lock)을 최신으로 갱신하고 커밋해줘.
  ```

## 3) 코드 자체 오류로 빌드 멈춤 (타입/문법 에러)
- **로그 신호**: `npm run build` 실패 + `Type error:`, `SyntaxError`, `Failed to compile`, `error TS####`, `did not complete successfully: exit code 1`.
- **쉬운 설명**: "앱을 완성하는 과정에서 코드에 고쳐야 할 부분이 있어 멈췄어요. (`파일명:줄번호` 근처)"
- **복붙 수정 프롬프트**:
  ```
  배포 빌드(build) 단계에서 '<로그의 에러 메시지 핵심 한 줄>' 오류로 실패했어. 해당 파일의 그 부분을 고쳐서 빌드가 통과하게 해줘.
  ```

## 4) 노출 포트(EXPOSE)와 앱이 듣는 포트 불일치
- **로그 신호**: 빌드는 성공했는데 시작 직후 종료(`exited`), 헬스체크 실패, `connection refused`, 앱 로그상 `listening on 3000` 인데 Dockerfile `EXPOSE` 가 다른 번호.
- **쉬운 설명**: "앱이 실제로 손님을 받는 문(포트)과, 설정에 적힌 문 번호가 서로 달라서 연결이 안 됐어요."
- **복붙 수정 프롬프트**:
  ```
  배포 후 앱이 바로 종료됐어. 앱이 실제로 listen 하는 포트와 Dockerfile의 EXPOSE 값을 같은 번호로 맞춰줘. (앱이 환경변수 PORT를 쓰면 그 값과도 일치시켜줘.)
  ```

## 5) 시작 명령(CMD/ENTRYPOINT) 오류
- **로그 신호**: 빌드 성공 후 시작 시 `exec: "..." : not found`, `command not found`, `npm error Missing script: "start"`, `permission denied`, 컨테이너가 즉시 `exited`.
- **쉬운 설명**: "앱을 켜는 명령에 문제가 있어서 시작하자마자 멈췄어요."
- **복붙 수정 프롬프트**:
  ```
  배포 후 시작 명령이 '<로그의 에러 한 줄>'로 실패했어. Dockerfile의 CMD/ENTRYPOINT(또는 package.json의 start 스크립트)가 실제로 실행되는 올바른 명령이 되도록 고쳐줘.
  ```

## 6) Dockerfile 단계 자체가 실패
- **로그 신호**: `failed to solve:`, `process "/bin/sh -c ..." did not complete successfully`, `COPY failed: ... no such file or directory`, `the requested image ... not found`.
- **쉬운 설명**: "앱을 만드는 설명서(Dockerfile)의 한 단계에서 막혔어요. (`○○` 단계)"
- **복붙 수정 프롬프트**:
  ```
  배포 빌드가 Dockerfile의 '<실패한 명령 한 줄>' 단계에서 실패했어. 그 단계가 통과하도록 Dockerfile을 고쳐줘. (예: COPY 경로가 실제 파일과 맞는지, base 이미지가 올바른지 확인)
  ```

## 7) 필수 설정값(환경변수) 누락으로 시작 실패
- **로그 신호**: 시작 직후 종료 + 앱 로그에 `undefined is not ... (env)`, `Missing required environment variable`, `KeyError: '...'`, `xxx is not defined`(설정값 이름).
- **쉬운 설명**: "앱이 켜질 때 꼭 필요한 설정값(`○○`)이 없어서 멈췄어요."
- **복붙 수정 프롬프트**:
  ```
  배포 후 앱이 필요한 설정값 '○○'가 없어 시작하지 못했어. 이 값이 무엇인지/어디서 받는지 알려줘. (비밀번호·키라면 화면에 직접 적지 말고, 배포할 때 설정값으로 넣을 수 있게 안내해줘.)
  ```
  - 이 경우 사용자에게는: "이 앱이 '○○' 값을 필요로 해요. 값이 있으면 알려주시고, 모르면 IT본부에 문의하세요." 라고 덧붙인다.

## 8) 빌드 메모리 부족(만드는 중 멈춤)
- **로그 신호**: **exit code 137**(=128+9, 강제 종료) + 직전 줄이 `Collecting build traces`(또는 `Finalizing page optimization` 직후 중단) + **명시적 에러 메시지 없음**. Coolify 측 `Command execution failed (exit code 137)`. (※ 137 + 메시지 없음 = 메모리 부족 전형. 코드 에러면 exit 1 + 메시지가 남는다 → 3)번 `build-error` 와 구분.)
- **쉬운 설명**: "앱을 만드는 컴퓨터의 메모리가 잠깐 부족해서 멈췄어요. (코드 문제가 아니에요.) 만드는 부담을 줄이는 설정을 넣으면 돼요."
- **복붙 수정 프롬프트**:
  ```
  배포 빌드가 'Collecting build traces' 단계에서 메모리 부족(exit 137)으로 멈췄어. next.config(.mjs/.js/.ts)에 experimental: { cpus: 1, workerThreads: false } 를 추가해 빌드 trace 수집의 메모리 피크를 낮춰줘. (NODE_OPTIONS=--max-old-space-size 상향은 해법이 아니니 쓰지 마.)
  ```
- **금지(반드시)**: `NODE_OPTIONS=--max-old-space-size` 상향을 자동수정으로 넣지 않는다. 137 은 cgroup 메모리(RSS) 초과이고 trace 수집 메모리는 네이티브 비중이 커서 V8 힙 상한으로 안 잡힌다 — 오히려 메모리를 더 키운다.
- **폴백(자동수정이 안 통하면, 안내만)**:
  - **IT본부에 빌드 메모리/swap 상향 요청**(인프라 — 코드 밖, 근본 해결): "IT본부에 '배포 빌드 메모리를 조금 늘려달라'고 요청해 주세요."
  - **최후수단**: `next.config` 에서 `output: 'standalone'` 제거(+ Dockerfile runner 를 전체 `node_modules`+`.next`+`next start` 로 변경 — 이미지 커짐). **자동수정 대상이 아니라 안내만**(아키텍처 변경, 사람 판단).
- **예방**: 정준 standalone 골격은 그대로 두되, 빌드 메모리가 빠듯한 호스트면 위 `experimental: { cpus: 1, workerThreads: false }` 를 처음부터 두면 trace 수집 피크가 낮아진다.

## 9) public 폴더가 없어 마지막 복사 단계 실패
- **로그 신호**: 빌드(`npm run build`)는 **성공**(`#NN DONE`) 후, **runner 스테이지 COPY 단계에서 exit 1** + `"/app/public": not found`(또는 `failed to calculate checksum of ref ... "/app/public": not found` / `failed to compute cache key`). exit code **1**(8)번 메모리 부족의 137 과 구분 — 메모리가 아니라 경로 문제).
- **쉬운 설명**: "앱을 담는 설명서가 'public' 이라는 폴더를 복사하려는데 그 폴더가 없어서 멈췄어요. 빈 폴더 하나만 만들어 두면 돼요."
- **복붙 수정 프롬프트**:
  ```
  배포 빌드의 마지막 단계에서 public 폴더가 없어 COPY 가 실패했어(/app/public not found, exit 1). 프로젝트 루트에 public/ 폴더를 만들고 빈 public/.gitkeep 파일을 추가한 뒤 커밋해줘. (Dockerfile 은 그대로 둔다.)
  ```
- **예방**: 새 프로젝트는 처음부터 `public/.gitkeep` 을 두거나, 정준 Dockerfile builder 스테이지에 `RUN mkdir -p /app/public` 을 포함하면 이 오류가 원천 차단된다.

---

## 참고로만 — 빌드는 통과했는데 켜진 뒤 문제 (1줄씩)
> 아래는 빌드 실패가 아니라 **빌드·기동은 성공한 뒤** 생기는 증상이라 위 1~9 유형과 진단 경로가 다르다. 인식용으로만 둔다.
- **설정값에 따옴표가 따라 들어감**: 빌드·기동은 성공했는데 로그인 등 API 가 500 + `the URL must start with postgresql://`/값이 `"` 로 시작 → 설정값이 따옴표째 들어갔어요. Coolify 설정값에서 앞뒤 `"`/`'` 제거 후 재배포. (deploy 가 `.env` 값을 보낼 때 앞뒤 따옴표를 자동으로 떼므로 이후 새 배포에선 안 생긴다.)
- **비밀값이 빌드 단계에 노출(경고)**: 빌드 경고 `SecretsUsedInArgOrEnv: ARG "<비밀>"` → 런타임 전용 비밀이 빌드타임에 노출. 그 값을 Coolify 'Runtime only' 로 옮긴다.

---

## 진단이 애매할 때
- 마지막 에러 줄이 위 유형 어디에도 안 맞으면, **그 줄을 근거로** 같은 3단 형식으로 직접 설명을 만든다(없는 원인 추측 금지).
- 로그 전체가 그래도 이해되지 않으면:
  > "빌드 기록을 봤지만 원인을 정확히 짚기 어려워요. 이 내용을 IT본부에 전달해 도움을 받으세요."
  라고 안내하고, 로그의 **핵심 에러 줄만** 추려 전달한다(원문 통째 노출 금지, 비밀번호·키처럼 보이는 값은 가린다).
