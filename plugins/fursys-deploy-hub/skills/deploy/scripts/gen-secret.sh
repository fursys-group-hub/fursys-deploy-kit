#!/usr/bin/env bash
# 앱 내부용 강한 난수 비밀 1개를 생성해 stdout 에 한 줄로 출력한다.
#
# 용도: 사람이 정할 필요가 없는 "앱 내부 비밀" 자동 생성에만 쓴다.
#   예) JWT_SECRET_KEY / SESSION_SECRET / SECRET_KEY / *_SALT / NEXTAUTH_SECRET / ENCRYPTION_KEY
# 쓰면 안 되는 곳: 외부 서비스 자격증명(DB 비밀번호·API 키·토큰) — 그건 실제 값을 받아야 한다.
#   (어디에 자동생성/질문할지 분류는 references/env-resolve.md 참조.)
#
# 보안: 생성 값을 로그·파일·주석에 남기지 않는다. 호출 측은 stdout 한 줄만 받아 proxy 로 전달한다.
# 출력: hex 문자열(특수문자 없음 → env/JSON 안전). 길이 = 바이트수 * 2.
set -euo pipefail

LEN="${1:-32}"   # 바이트 수(기본 32 → hex 64자)
case "$LEN" in ''|*[!0-9]*) LEN=32 ;; esac

if command -v openssl >/dev/null 2>&1; then
  openssl rand -hex "$LEN"
elif command -v node >/dev/null 2>&1; then
  node -e "process.stdout.write(require('crypto').randomBytes(${LEN}).toString('hex'))"; echo
elif [ -r /dev/urandom ]; then
  LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c "$((LEN * 2))"; echo
else
  echo "GEN_SECRET_UNAVAILABLE" >&2
  exit 1
fi
