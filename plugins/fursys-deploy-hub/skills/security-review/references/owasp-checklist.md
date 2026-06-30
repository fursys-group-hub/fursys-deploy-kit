# OWASP 배포 시점 점검 (🔒 보안 심화용 지식)

> security-review 스킬이 "🔒 보안 심화" 단계에서 코드를 읽고 판단할 때 참조하는 룰셋이다.
> **시크릿/키 탐지·git 이력은 엔진(`fdh-engine`)이 이미 결정적으로 처리한다.** 여기서는 그 위에
> LLM이 코드를 읽고 판단해야 하는 OWASP 배포 시점 실수 15항목을 다룬다(시크릿 스캔 중복 금지).
> 각 항목: 무엇을 / 어떻게 찾나 / 심각도. 비개발자에게 보여줄 화면 문구는 "치명/높음/중간/낮음"을 쓴다.

## 목차
1. OWASP 배포 시점 15항목
2. 심각도 정의 (배포 가능 여부와의 관계)
3. 오탐(False Positive) 가이드
4. 사내 자주 쓰는 자격증명 맥락 (퍼시스 그룹 특화)

---

## 1. OWASP 배포 시점 15항목

배포 직전에 가장 흔히 터지는 보안 실수다. 코드를 읽고 아래 패턴이 보이면 해당 심각도로 보고한다.
(시크릿 값 자체의 탐지는 엔진 몫 — 여기서는 "설정·구조·코드 흐름"의 위험을 본다.)

| # | 항목 | 무엇을 / 어떻게 찾나 | 심각도 |
|---|------|--------------------|--------|
| 1 | 운영에서 디버그 모드 켜짐 | Django/FastAPI/Flask `DEBUG=True`, Next.js dev 모드 잔존. `settings.py`·환경변수·실행 스크립트 확인. 운영에서 켜지면 에러 스택·내부 경로 노출 | 높음 |
| 2 | CORS 전체 허용(`*`) | `allow_origins=["*"]`, `Access-Control-Allow-Origin: *`. CORS 미들웨어·nginx 설정 grep. 자격증명 동반 시 더 위험 | 높음 |
| 3 | Streamlit 보안 설정 약화 | `.streamlit/config.toml` 의 `enableCORS=false`·`enableXsrfProtection=false`. (별도로 `gatherUsageStats=false` 누락은 사내 정책 위반) | 중간 |
| 4 | Spring `permitAll()` 광범위 | `SecurityConfig` 에서 `.anyRequest().permitAll()` 등 보호 라우트까지 무인증 개방 | 높음 |
| 5 | HTTPS 미강제 | HTTP 평문 허용. `requiresChannel`, `helmet`(HSTS), nginx redirect 부재. (사내 서버가 앞단 TLS를 붙이지만 앱 레벨 강제도 권장) | 중간 |
| 6 | 비밀번호 평문 저장 | 회원가입/DB 스키마에서 비밀번호를 해시 없이 저장. BCrypt/Argon2 등 미사용 | 치명 |
| 7 | SQL Injection 가능성 | 문자열 결합으로 SQL 작성. `${...}`, `% (값)`, f-string 안에 사용자 입력이 들어간 쿼리. 파라미터 바인딩 미사용 | 높음 |
| 8 | 의존성 취약점(오래된 메이저) | `package.json`/`requirements.txt`/`build.gradle` 에서 EOL·구버전 메이저. 알려진 CVE 라이브러리 | 중간 |
| 9 | 디버그 엔드포인트 노출 | `/actuator`(전체 노출), `/_debug`, `/__debug__`, 디버그 라우트. `management.endpoints.web.exposure.include=*` | 높음 |
| 10 | 인증 미보호 엔드포인트 | DRF `AllowAny`, Spring `permitAll`, NestJS 가드 누락. 보호돼야 할 API가 무인증 | 높음 |
| 11 | 로그에 시크릿 출력 | `console.log(token)`, `logger.info(password)`, 예외 로깅에 자격증명 포함. 운영 로그로 키 유출 | 높음 |
| 12 | 파일 업로드/다운로드 경로 조작 | 업로드: 확장자/크기/MIME 미검증. **다운로드: 사용자 입력 파일명을 경로에 그대로 결합**(`/download/<file>`·`/files/{name}`·`send_file(BASE + req.params.name)`·`os.path.join(dir, user_name)`·`open(user_path)`) — `../` 로 상위 디렉터리 탈출 시 `.env`·소스·시스템파일 유출. 방어: 화이트리스트·basename 만 추출·`os.path.realpath` 가 허용 디렉터리 안인지 검증 | 높음 |
| 13 | SSRF / URL 자격증명 삽입 | (a) 사용자가 준 URL을 서버가 그대로 fetch (`requests.get(user_url)`, `fetch(req.body.url)`). 내부망·메타데이터 접근 위험. (b) **연결 URL에 자격증명 평문 삽입**(`uid:pw@host` 형태 — `https://user:pass@host`·`mysql://admin:secret@db`·`mongodb://u:p@...`): URL 에 박힌 비밀은 로그·프록시·에러메시지로 새기 쉽다(코드·설정·로그 grep). 자격증명은 URL 이 아니라 별도 env 로 분리 | 높음 |
| 14 | XSS(신뢰 못 할 입력 직접 렌더) | Next/React `dangerouslySetInnerHTML` + 외부 입력, Django `mark_safe`/`|safe` + 사용자 입력 | 중간 |
| 15 | 정적 서빙 루트가 서버 폴더 전체 | Flask `Flask(__name__, static_folder=".")`/`static_folder=os.getcwd()`(또는 `send_from_directory(".", ...)`·`@app.route('/<path:p>')` 가 루트 그대로 서빙). 서버 디렉터리 전체(소스·`.env`·설정)가 URL 로 노출됨. FastAPI `StaticFiles(directory=".")`·Express `express.static(".")`·`express.static(__dirname)` 도 동형 | 높음 |

**판단 원칙(LLM):**
- 단순 문자열 매칭으로 단정하지 말고 **변수명·파일 위치·주변 흐름**을 함께 본다.
- 사용자 입력이 실제로 그 위험 지점까지 흘러가는지(데이터 흐름)를 가능한 만큼 추적한다.
- 확신이 낮으면 "추정"으로 표기하고 근거를 적는다(3절 참조).

---

## 2. 심각도 정의 (배포 가능 여부와의 관계)

| 심각도(화면 표기) | 정의 | 보안 축 판정에 미치는 영향 |
|---|---|---|
| **치명(critical)** | 노출 시 즉시 사고 — 자격증명/개인정보/시스템계정/운영데이터 노출, 비밀번호 평문 저장 등 | 1건이라도 있으면 보안 = **차단** |
| **높음(high)** | 사고로 이어질 가능성이 큰 설정 — DEBUG, CORS `*`, 인증 미보호, 로그 시크릿 등 | 1건 이상이면 보안 = **주의**(차단 아님, 해소 권장) |
| **중간(medium)** | 모범사례 미준수 — HTTPS 미강제, 의존성 노후 등 | 보안 = 통과 가능(개선 권고) |
| **낮음(low)** | 정보성/컨벤션 | 보안 = 통과 가능 |

> 보안 축 최종 판정은 엔진 verdict(`pass`/`caution`/`blocked`)를 기준으로 삼되, 위 LLM 심화 발견을 합산해
> 치명 추가 시 차단, 높음 추가 시 주의로 **상향**한다(하향은 하지 않는다 — 엔진 결정은 보수적으로 존중).

---

## 3. 오탐(False Positive) 가이드

다음은 **"추정"** 으로 표기하고 근거를 함께 적는다(차단 단정 금지):
- `.env.example`, `config.example.*` 안의 값(예시용)
- `__tests__/`, `*.test.*`, `*.spec.*`, mock/fixture 안의 값
- 주석 처리된 코드 안의 위험 패턴
- 변수명에 `dummy`, `fake`, `test`, `example`, `sample`, `placeholder` 포함

**추정 표기 예:**
> 추정: `tests/fixtures/sample_settings.py` 의 `DEBUG=True` — 테스트 설정으로 보이나, 운영 설정과 분리됐는지 확인 필요.

---

## 4. 사내 자주 쓰는 자격증명 맥락 (퍼시스 그룹 특화)

아래는 사내 시스템에서 자주 쓰이며, 노출 시 즉시 사고로 이어지는 자격증명이다.
이런 변수명이 코드/설정/로그에 평문으로 보이면 특히 주의해서 점검한다.

| 카테고리 | 변수명 예시 | 비고 |
|---|---|---|
| AI Hub DB | `AIHUB_DB_URL`, `aihub_db` | 사내 MySQL |
| JWT | `JWT_SECRET`, `JWT_REFRESH_SECRET` | HS256, 64자+ 권장 |
| AWS Bedrock | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `BEDROCK_REGION` | jp / global region |
| Sendbird | `SENDBIRD_APP_ID`, `SENDBIRD_API_TOKEN` | AppId는 공개 가능, API Token은 절대 노출 금지 |
| S3 | `AIHUB_S3_BUCKET`, `AIHUB_S3_REGION` | 이미지 저장소 |
| JKS Keystore | `KEYSTORE_PATH`, `KEYSTORE_PASSWORD` | HTTPS 인증서 |
| Anthropic | `ANTHROPIC_API_KEY` | AI Voucher 등 |
| fgdw(사내 DW) | `FGDW_DB_HOST/PORT/NAME/USER/PASSWORD` | MSSQL. **USER/PASSWORD는 클라이언트에 두지 말 것** — 배포 시 사내 공용 계정으로 자동 치환됨 |

**점검 시 추가 확인:**
- `application-{profile}.yml` 이 환경별(local/dev/stage/prod)로 분리됐는지, 운영 설정이 git에 평문으로 올라갔는지.
- AWS 정적 키 대신 IAM Role로 대체 가능한지.
- 위 시크릿류는 모두 코드/설정에 박지 말고 환경변수(배포 시 주입)로 분리됐어야 한다.
