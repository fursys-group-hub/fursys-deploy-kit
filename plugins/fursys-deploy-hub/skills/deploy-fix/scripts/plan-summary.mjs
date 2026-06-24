#!/usr/bin/env node
// /deploy-fix 수정 계획 요약 — 고정 형식 렌더(모델별 문구 흔들림 방지).
// 입력: <engine.json> <last-verdict.json>
//   engine.json    : security-verdict.schema.json findings[] = {severity,rule,file,line,message,inGitHistory,aiPrompt}
//   last-verdict   : { commit, env_plan:[{name,class,note}], ... }
// 출력(stdout): 비개발자용 한글 고정 형식. 자동수정 대상 / 사람 판단 필요(안내만) 분리.
//   시크릿(키·비밀번호) 값은 절대 출력하지 않는다(이름·위치·설명만 — 엔진 마스킹 원칙).
// 결과 코드(첫 줄): PLAN_OK <autoCount> <manualCount>  /  PLAN_EMPTY  /  PLAN_ERROR <reason>
"use strict";
import fs from "node:fs";

const [, , enginePath, verdictPath] = process.argv;
if (!enginePath || !verdictPath) {
  console.log("PLAN_ERROR usage: plan-summary.mjs <engine.json> <last-verdict.json>");
  process.exit(2);
}

let eng, lv;
try { eng = JSON.parse(fs.readFileSync(enginePath, "utf8")); }
catch (e) { console.log("PLAN_ERROR engine_read: " + e.message); process.exit(1); }
try { lv = JSON.parse(fs.readFileSync(verdictPath, "utf8")); }
catch (e) { console.log("PLAN_ERROR verdict_read: " + e.message); process.exit(1); }

const SEV_KO = { critical: "치명", high: "높음", medium: "중간", low: "낮음" };
const findings = Array.isArray(eng.findings) ? eng.findings : [];
const envPlan = Array.isArray(lv.env_plan) ? lv.env_plan : [];

// 사람만 아는 값(자동수정 불가) 이름 집합 — note=="ask" 인 설정값.
const askNames = new Set(envPlan.filter((e) => e && e.note === "ask").map((e) => e.name));

const sevRank = { critical: 0, high: 1, medium: 2, low: 3 };
const bySev = (a, b) => (sevRank[a.severity] ?? 9) - (sevRank[b.severity] ?? 9);

const auto = [];     // 자동수정 대상
const manual = [];   // 사람 판단 필요(안내만)

for (const f of findings) {
  if (!f || typeof f !== "object") continue;
  const sev = SEV_KO[f.severity] || f.severity || "?";
  const loc = f.file ? (f.line ? `${f.file}:${f.line}` : `${f.file}`) : "-";
  const reasonManual =
    f.inGitHistory ? "git-history" :
    (!f.aiPrompt) ? "no-prompt" :
    (f.file && askNames.has(f.file)) ? "ask" : null;
  const item = { sev, loc, type: f.rule || "-", message: f.message || "" };
  if (reasonManual) { item.reason = reasonManual; manual.push(item); }
  else auto.push(item);
}
// env_plan 의 note=="ask" 항목(코드 finding 과 별개로 사람이 정할 값)도 안내 목록에 추가.
for (const e of envPlan) {
  if (e && e.note === "ask") {
    manual.push({ sev: "-", loc: e.name, type: "사람이 정할 값", message: "직접 입력이 필요해요(자동으로 만들 수 없어요).", reason: "ask" });
  }
}

auto.sort(bySev);

const REASON_KO = {
  "git-history": "과거 기록에 남아 있어 코드만 고쳐선 끝나지 않아요(키 폐기·재발급 + IT본부 통보 필요).",
  "no-prompt": "자동 수정 지침이 없어 사람이 직접 봐야 해요.",
  "ask": "사람이 정하거나 외부에서 받아야 하는 값이라 제가 만들 수 없어요.",
};

const out = [];
out.push("───────────────────────────────");
out.push("🛠️  수정 계획");
out.push("───────────────────────────────");
out.push("");
if (auto.length === 0) {
  out.push("✅ 자동으로 고칠 수 있는 문제: 없음");
} else {
  out.push(`✅ 제가 자동으로 고칠 수 있는 문제: ${auto.length}개`);
  for (const it of auto) out.push(`   · [${it.sev}] ${it.loc} — ${it.type}: ${it.message}`);
}
out.push("");
if (manual.length > 0) {
  out.push(`⚠️  사람 판단이 필요한 항목(제가 자동으로 못 고쳐요): ${manual.length}개`);
  for (const it of manual) {
    const why = REASON_KO[it.reason] || "사람 확인이 필요해요.";
    out.push(`   · ${it.loc} — ${it.message} (${why})`);
  }
  out.push("");
}
out.push("───────────────────────────────");

const head = auto.length === 0 && manual.length === 0
  ? "PLAN_EMPTY"
  : `PLAN_OK ${auto.length} ${manual.length}`;
console.log(head);
console.log(out.join("\n"));
