#!/usr/bin/env node
// /deploy-fix 수정 계획 요약 — 고정 형식 렌더(모델별 문구 흔들림 방지).
//
// 모드 A(검토 수정): plan-summary.mjs <engine.json> <last-verdict.json>
//   engine.json    : security-verdict.schema.json findings[] = {severity,rule,file,line,message,inGitHistory,aiPrompt}
//   last-verdict   : { commit, env_plan:[{name,class,note}], ... }
//
// 모드 B(빌드로그): plan-summary.mjs --logs <typeKey> "<핵심 에러 한 줄>" ["<인자: 모듈/경로 등>"]
//   typeKey ∈ dep-missing|dep-devdep|lockfile|build-error|port|start-cmd|dockerfile|oom|copy-public|env-missing|unknown
//   (deploy-failure-playbook.md 유형) — 빌드 실패는 엔진 finding 이 아니라 로그가 정본.
//
// 출력(stdout): 비개발자용 한글 고정 형식. 자동수정 대상 / 사람 판단 필요(안내만) 분리.
//   시크릿(키·비밀번호) 값은 절대 출력하지 않는다(이름·위치·설명만 — 엔진 마스킹 원칙).
// 결과 코드(첫 줄): PLAN_OK <autoCount> <manualCount>  /  PLAN_EMPTY  /  PLAN_ERROR <reason>
"use strict";
import fs from "node:fs";

// ── 모드 B: 빌드로그 진단 요약 ────────────────────────────────────────────────
if (process.argv[2] === "--logs") {
  const typeKey = process.argv[3] || "unknown";
  const errLine = process.argv[4] || "";
  const arg = process.argv[5] || "";
  // 각 유형: { 설명, 자동수정 가능 여부 }. env-missing 은 사람 판단(안내만) 기본.
  const TYPES = {
    "dep-missing":  { auto: true,  ko: "앱을 만드는 데 필요한 부품(모듈)이 빠졌어요." },
    "dep-devdep":   { auto: true,  ko: "앱을 만들 때 쓰는 도구가 '운영용 설치' 모드 때문에 빠졌어요(설치 방식만 살짝 바꾸면 돼요)." },
    "lockfile":     { auto: true,  ko: "부품 목록과 잠금 기록이 서로 안 맞아요(둘을 다시 맞추면 돼요)." },
    "build-error":  { auto: true,  ko: "코드에 고쳐야 할 부분이 있어 만드는 중 멈췄어요." },
    "port":         { auto: true,  ko: "앱이 실제로 쓰는 접속 통로(포트)와 설정의 번호가 달라요." },
    "start-cmd":    { auto: true,  ko: "앱을 켜는 명령에 문제가 있어 시작하자마자 멈췄어요." },
    "dockerfile":   { auto: true,  ko: "앱을 만드는 설명서(Dockerfile)의 한 단계에서 막혔어요." },
    "oom":          { auto: true,  ko: "앱을 만드는 컴퓨터의 메모리가 잠깐 부족해서 멈췄어요(코드 문제가 아니에요)." },
    "copy-public":  { auto: true,  ko: "앱을 담는 설명서가 'public' 폴더를 찾지 못해 멈췄어요(빈 폴더 하나만 만들면 돼요)." },
    "env-missing":  { auto: false, ko: "앱이 켜질 때 꼭 필요한 설정값이 없어요(사람이 정하거나 외부에서 받아야 하는 값일 수 있어요)." },
    "unknown":      { auto: false, ko: "로그만으로는 원인을 정확히 짚기 어려워요(핵심 에러 줄을 보고 사람이 확인해야 해요)." },
  };
  const t = TYPES[typeKey] || TYPES["unknown"];
  const detail = arg ? `${t.ko} (${arg})` : t.ko;
  const out = [];
  out.push("───────────────────────────────");
  out.push("🛠️  수정 계획 (빌드 기록 기준)");
  out.push("───────────────────────────────");
  out.push("");
  if (t.auto) {
    out.push("✅ 제가 자동으로 고칠 수 있어요: 1개");
    out.push(`   · ${detail}`);
  } else {
    out.push("✅ 제가 자동으로 고칠 수 있어요: 없음");
    out.push("");
    out.push("⚠️  사람 판단이 필요해요(제가 자동으로 못 고쳐요): 1개");
    out.push(`   · ${detail}`);
  }
  if (errLine) {
    out.push("");
    out.push(`핵심 에러: ${errLine}`);
  }
  out.push("");
  out.push("───────────────────────────────");
  console.log(t.auto ? "PLAN_OK 1 0" : "PLAN_OK 0 1");
  console.log(out.join("\n"));
  process.exit(0);
}

const [, , enginePath, verdictPath] = process.argv;
if (!enginePath || !verdictPath) {
  console.log("PLAN_ERROR usage: plan-summary.mjs <engine.json> <last-verdict.json>  |  --logs <typeKey> \"<error line>\" [\"<arg>\"]");
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
