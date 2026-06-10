---
description: 사내 GitHub 연결을 확인하고, 미가입이면 가입 신청을 돕고, 연결되면 현재 프로젝트를 회사 GitHub repo로 등록한다.
---

사용자가 `/github-setup` 를 실행했다. 사내 GitHub 연결·등록을 시작한다.

**`github-setup` 스킬을 사용해** 처리하라. 스킬의 절차를 그대로 따른다:
- 먼저 연결 상태를 감지(`scripts/github-detect.sh`)해 분기한다.
- 미연결/미가입 → 가입 신청을 돕는다(Slack 도구가 있으면 확인 후 자동 발송, 없으면 가이드 + 복붙 템플릿).
- 연결됨 → 현재 프로젝트를 `fursys-group-hub` repo로 등록한다(`scripts/repo-register.sh`, 상황 따라 생성/연결+올리기).

모든 응답은 한글, 비개발자가 이해할 수 있게 쉽게. 링크는 한글 하이퍼링크 없이 URL을 그대로 보여준다.
