<!--
  배포 전 검토 리포트 — 마크다운 템플릿 (fursys-deploy-hub / security-review)

  사용 규칙 (중요):
  - 이 템플릿의 placeholder(이중 중괄호 토큰)만 값/해석으로 채운다. 고정 문구(섹션 제목·라벨·안내문)는 절대 바꾸지 않는다.
    (고정 문구를 매번 재작성하지 않으므로 토큰을 절감하고, 모델별 문구 흔들림을 없앤다.)
  - 고정 문구(섹션 제목·"아래 글을 그대로 복사해…" 류 안내)는 이 템플릿에 verbatim 으로 박혀 있다.
    LLM 은 placeholder(가변 finding 값)만 채운다.
  - 화면 문구는 쉬운 우리말. 심각도는 "치명/높음/중간/낮음". 링크는 raw URL(한글 하이퍼링크 금지).
  - 배지(보안/배포 준비)는 board 가 서버값으로 교차검증·덮어쓴다(컨트랙트 §3-D 옵션 a).

  placeholder 목록(렌더 시 render-report-md.sh 가 채운다):
    META_LIST              헤더 메타 (대상 폴더·코드 저장소·프로젝트 종류·검사 일시) — 목록 줄들
    SECURITY_BADGE         보안 결과 배지 텍스트 (통과 / 주의 / 차단)
    DEPLOY_BADGE           배포 준비 배지 텍스트 (완료 / 불가)
    FINAL_LINE             최종 한 줄 (배포 가능 / 배포 불가 — 사유)
    SUMMARY_LINE           치명·높음·중간·낮음 개수 한 줄
    SECURITY_FINDINGS_ROWS 보안 문제 표 행 반복 (없으면 "문제 없음" 행)
    SECURITY_PROMPTS       치명/높음 복붙 수정 프롬프트 블록 반복 (없으면 비움)
    DEPLOY_CHECK_ROWS      배포 준비 체크 결과 표 행 반복
    DEPLOY_PROMPTS         배포 준비 문제 시 복붙 프롬프트 블록 반복 (없으면 비움)
    ENV_ROWS               설정값 정리표 행 반복
-->
# 🛡️ 배포 전 검토 결과

보안 점검과 배포 준비 두 가지를 함께 확인했어요. 아래에서 차례대로 보시면 됩니다.

- **보안:** {{SECURITY_BADGE}}
- **배포 준비:** {{DEPLOY_BADGE}}

> {{FINAL_LINE}}

{{META_LIST}}

**발견 요약:** {{SUMMARY_LINE}}

---

## 🔒 보안 점검

코드와 기록에서 발견한 보안 문제예요. 치명·높음은 고친 뒤 다시 검토해주세요.

| 심각도 | 위치 | 유형 | 설명 |
|---|---|---|---|
{{SECURITY_FINDINGS_ROWS}}

{{SECURITY_PROMPTS}}

---

## 🚀 배포 준비

사내 서버에 올릴 수 있는 상태인지 확인했어요. ✅ 통과 · ❌ 문제 · ➖ 권장입니다.

| 점검 항목 | 결과 | 설명 |
|---|---|---|
{{DEPLOY_CHECK_ROWS}}

{{DEPLOY_PROMPTS}}

---

## ⚙️ 설정값 정리

이 앱이 쓰는 설정값과 다루는 방법이에요.

| 설정값 이름 | 다루는 방법 | 설명 |
|---|---|---|
{{ENV_ROWS}}

---

*배포 전 검토 · fursys-deploy-hub · 퍼시스홀딩스 IT본부 AI추진팀*
