# 보안 차단 예외 처리 (deploy 스킬 ⑤에서 참조)

배포 전 검토에서 보안이 **차단(blocked)** 됐는데, 그것이 **오탐이 확실**할 때만(예: 의도적 템플릿) 쓰는 경로다. "그냥 배포"는 불가하며, **IT본부 예외 승인**을 받아야 진행할 수 있다. 반복 오탐은 예외보다 **엔진 룰 수정**이 정석이다.

키·전송 대상 가드 규칙은 `deploy` 스킬 본문과 동일하다(개인 키는 `FURSYS_PROXY_KEY`→`~/.fursys/proxy-key`, 전송 대상은 `*.hub.fursys.com` 만 허용, 기본 `https://deploy-proxy.hub.fursys.com`). 키 값은 화면에 출력하지 않는다.

## 1) 현재 코드 버전의 예외 승인 여부 확인 (`POST /exceptions/check`)
```bash
KEY="${FURSYS_PROXY_KEY:-$(cat ~/.fursys/proxy-key 2>/dev/null)}"
PROXY_URL="https://deploy-proxy.hub.fursys.com"
COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
curl -sS -X POST "$PROXY_URL/exceptions/check" -H "X-Proxy-Key: $KEY" \
  -H "Content-Type: application/json" \
  -d "{\"repo\":\"fursys-group-hub/<REPO>\",\"commit\":\"$COMMIT\"}"
```
응답: `{ "status": "pending|approved|rejected|none", "approved": true|false }`
- `approved`(또는 `status:"approved"`) → 배포 본문 ⑥으로 진행한다.
- 그 외(`pending`/`none`/`rejected`) → 멈추고, 필요 시 아래 2)로 예외를 요청한다.

## 2) 예외 요청 (`POST /exceptions`)
```bash
curl -sS -X POST "$PROXY_URL/exceptions" -H "X-Proxy-Key: $KEY" \
  -H "Content-Type: application/json" \
  -d "{\"repo\":\"fursys-group-hub/<REPO>\",\"commit\":\"$COMMIT\",\"findings_summary\":\"<차단 요약(비밀값 제외)>\"}"
```
- `findings_summary` 에는 **비밀번호·키 같은 시크릿 본체를 넣지 않는다**(왜 오탐인지 요약만).
- 요청 후 사용자에게: "IT본부 승인 후 다시 배포해주세요(지금 이 코드 기준)." 라고 안내한다.
