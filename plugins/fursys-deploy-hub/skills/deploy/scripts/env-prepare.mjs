#!/usr/bin/env node
/**
 * env_vars 페이로드 조립기 — **시크릿 값을 다루는 유일한 지점**.
 *
 * 호출은 env-prepare.sh 만 한다(직접 호출 금지 — 임시 디렉터리·.gitignore 보호·0600 은 .sh 가 세운다).
 *
 * 입력:
 *   --plan <plan.json>   값이 없는 plan (모델이 Write 로 작성. key/name·class·note·scope·fgdw_role·value(비밀 아닌 것만))
 *   --out  <payload>     조립 결과(env_vars 배열 JSON)를 쓸 경로
 *   --env  <.env 경로>   값 출처. 여러 번 줄 수 있고 **앞에 준 것이 우선**. 생략 시 ./.env
 *   --ask  <ask.env>     (선택) 사용자가 채팅으로 준 값(dotenv 형식). 있으면 .env 보다 우선.
 *
 * 보안 불변식:
 *   - **값을 stdout/stderr 에 절대 출력하지 않는다.** 키 이름·개수만 출력한다(길이도 안 찍는다).
 *   - **plan 에 이름이 있는 키만** 읽고 내보낸다(`.env` 전체를 실어보내지 않는다).
 *   - `--env`/`--ask` 경로가 프로젝트(cwd) 밖이면 거부한다(홈·상위 폴더 자격증명 수집 방지).
 *
 * 출력(stdout, 첫 줄이 결과 코드):
 *   ENV_READY <out> <개수>     성공(파일 생성)
 *   ENV_EMPTY <out>            내보낼 항목 0개 → `[]` 를 씀(proxy 는 [] 를 미전송과 동일 처리)
 *   ENV_MISSING <KEY> ...      note:"ask" 인데 값이 없음 → 파일 안 만듦(배포 금지, 사용자에게 물어야 함)
 *   PLAN_INVALID <사유> / ENV_SRC_OUTSIDE <경로> / WRITE_FAILED <경로>
 *   부가 줄: GENERATED <KEY>... / OMITTED <KEY>... / LOCAL_SKIPPED <KEY>...
 * exit: 0 = ENV_READY/ENV_EMPTY, 3 = ENV_MISSING(사용자 입력 필요), 4 = 오류.
 */
import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'node:fs';
import { resolve, sep } from 'node:path';
import { randomBytes } from 'node:crypto';

const argv = process.argv.slice(2);
const one = (n) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : undefined; };
const many = (n) => argv.reduce((a, v, i) => (v === n && argv[i + 1] ? [...a, argv[i + 1]] : a), []);

const planPath = one('--plan');
const outPath = one('--out');
const askPath = one('--ask');
const envPaths = many('--env');
if (!planPath || !outPath) { console.log('PLAN_INVALID usage'); process.exit(4); }

const die = (code, extra, rc = 4) => { console.log(extra ? `${code} ${extra}` : code); process.exit(rc); };

// ── 경로 가드: 프로젝트(cwd) 밖의 자격증명 파일은 읽지 않는다 ─────────────────
const inProject = (p) => {
  const abs = resolve(p);
  const root = resolve(process.cwd());
  return abs === root || abs.startsWith(root + sep);
};

// ── dotenv 파싱 (env-resolve.md §2.1 규칙 그대로 — 결정적) ────────────────────
const KEY_RE = /^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_.]*)[ \t]*=(.*)$/;

// 닫는 따옴표가 from 이후에 있나(큰따옴표는 `\"` 이스케이프 고려, 작은따옴표는 literal).
function hasClosing(s, q, from) {
  for (let k = from; k < s.length; k++) {
    if (q === '"' && s[k] === '\\') { k++; continue; }
    if (s[k] === q) return true;
  }
  return false;
}

// 따옴표 짝이 맞나(§2.1 ①의 조건).
const isQuotedPair = (v) =>
  v.length >= 2 && ((v[0] === '"' && v[v.length - 1] === '"') || (v[0] === "'" && v[v.length - 1] === "'"));

// 값 뒤 공백/탭은 **그것을 지우면 따옴표 짝이 맞아질 때만** 지운다
// (따옴표 없는 값은 §2.1 ③ "그대로" 를 유지 — 임의 트림으로 값을 바꾸지 않는다).
function pickRaw(raw) {
  const t = raw.replace(/[ \t]+$/, '');
  return !isQuotedPair(raw) && isQuotedPair(t) ? t : raw;
}

// §2.1: ① 짝이 맞는 바깥 따옴표 한 쌍만 제거 ② 큰따옴표만 이스케이프 해제(\n·\r·\"·\\)
//       ③ 따옴표 없으면 그대로 ④ 한쪽만 따옴표면 그대로(짝 안 맞음)
function normalizeValue(raw) {
  const v = raw;
  if (v.length >= 2) {
    const a = v[0], b = v[v.length - 1];
    if (a === '"' && b === '"') {
      return v.slice(1, -1).replace(/\\([\s\S])/g, (m, c) =>
        c === 'n' ? '\n' : c === 'r' ? '\r' : (c === '"' || c === '\\' || c === "'") ? c : m);
    }
    if (a === "'" && b === "'") return v.slice(1, -1);   // literal
  }
  return v;
}

// 줄 단위 스캐너. **줄 기준**이라 짝이 안 맞는 따옴표(§2.1 ④)가 뒷줄의 다른 키를 삼키지 않는다.
// 여러 줄 값은 "뒤에서 닫히고 그 사이에 `KEY=` 가 없을 때만" 이어 붙인다(결정적 구분).
function parseDotenv(text) {
  const map = new Map();
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const m = KEY_RE.exec(lines[i]);
    if (!m) continue;
    let raw = m[2].replace(/^[ \t]+/, '');
    const q = raw[0];
    if ((q === '"' || q === "'") && !hasClosing(raw, q, 1)) {
      let buf = raw, close = -1;
      for (let j = i + 1; j < lines.length; j++) {
        if (KEY_RE.test(lines[j])) break;            // 다음 키가 시작됨 → 여러 줄 값이 아니다(짝 안 맞음)
        buf += '\n' + lines[j];
        if (hasClosing(lines[j], q, 0)) { close = j; break; }
      }
      if (close >= 0) { raw = buf; i = close; }
    }
    if (!map.has(m[1])) map.set(m[1], normalizeValue(pickRaw(raw)));   // 같은 키 중복 시 첫 줄 우선
  }
  return map;
}

function loadSource(p) {
  if (!p) return new Map();
  if (!inProject(p)) die('ENV_SRC_OUTSIDE', p);
  if (!existsSync(p)) return new Map();
  try { return parseDotenv(readFileSync(p, 'utf-8')); } catch { return new Map(); }
}

// ── plan 읽기 ────────────────────────────────────────────────────────────────
let plan;
try { plan = JSON.parse(readFileSync(planPath, 'utf-8')); }
catch (e) { die('PLAN_INVALID', 'json'); }
const items = Array.isArray(plan) ? plan
  : Array.isArray(plan?.items) ? plan.items
  : Array.isArray(plan?.env_plan) ? plan.env_plan
  : null;
if (!items) die('PLAN_INVALID', 'items');

// ── 값 출처 (앞에 준 --env 가 우선. ask 는 .env 보다 우선) ────────────────────
const sources = (envPaths.length ? envPaths : ['.env']).map(loadSource);
const ask = loadSource(askPath);
const fromEnv = (key) => {
  for (const s of sources) if (s.has(key)) return s.get(key);
  return undefined;
};

const CLASSES = new Set(['build', 'runtime', 'locked']);
const deriveClass = (key, note) =>
  /^(NEXT_PUBLIC_|VITE_|REACT_APP_)/.test(key) ? 'build'
  : (note === 'secret-gen' || note === 'ask' || note === 'fgdw') ? 'locked'
  : 'runtime';

const out = [], missing = [], omitted = [], generated = [], localSkipped = [];

for (const it of items) {
  const key = String(it?.key ?? it?.name ?? '').trim();
  if (!key) continue;
  const note = String(it?.note ?? '');
  const cls = CLASSES.has(it?.class) ? it.class : deriveClass(key, note);

  // 1) scope:"local" — 배포 컨테이너 밖(로컬 도구 전용) → 묻지도·보내지도 않는다.
  if (it?.scope === 'local') { localSkipped.push(key); continue; }

  // 2) fgdw 자격증명 — 값은 **빈 문자열** + 역할 태그(proxy 가 사내 공용계정으로 치환). `.env` 를 읽지 않는다.
  //    `note:"fgdw"` 인데 태그가 빠진 경우(모델 누락)도 값을 비워 보낸다 — 개인계정 평문을 proxy 로
  //    보내지 않는 게 §2.3 규칙이고, 태그가 없어도 proxy 의 이름패턴 폴백이 치환한다.
  const role = (it?.fgdw_role === 'user' || it?.fgdw_role === 'password') ? it.fgdw_role : '';
  if (role || note === 'fgdw') {
    const e = { key, value: '', class: CLASSES.has(it?.class) ? it.class : 'locked' };
    if (role) e.fgdw_role = role;
    out.push(e);
    continue;
  }

  // 3) plan 이 값을 직접 준 경우(모델이 계산한 **비밀 아닌** 값: NODE_ENV·포트·cross-URL·공개 URL)
  if (typeof it?.value === 'string') { out.push({ key, value: it.value, class: cls }); continue; }

  // 4) 사용자가 채팅으로 준 값(ask.env) → 5) 로컬 .env
  const asked = ask.get(key);
  if (typeof asked === 'string' && asked !== '') { out.push({ key, value: asked, class: cls }); continue; }

  const envVal = fromEnv(key);
  if (typeof envVal === 'string' && envVal !== '') { out.push({ key, value: envVal, class: cls }); continue; }

  // 6) 값이 없음 — note 에 따라 자동생성 / 강제질문 / 제외
  if (note === 'secret-gen') {
    out.push({ key, value: randomBytes(32).toString('hex'), class: CLASSES.has(it?.class) ? it.class : 'locked' });
    generated.push(key);
    continue;
  }
  if (note === 'ask') {
    if (it?.allow_empty === true) out.push({ key, value: '', class: cls });   // 사용자가 "비워두고 진행" 을 명시
    else missing.push(key);
    continue;
  }
  // `.env` 에 키는 있는데 값이 빈 경우는 "빈 값" 그대로 보낸다(키 존재 자체가 의미일 수 있음).
  if (typeof envVal === 'string') { out.push({ key, value: envVal, class: cls }); continue; }
  omitted.push(key);
}

// 이전 실행의 payload 가 남아 재사용되지 않게 항상 먼저 지운다(stale 전송 방지).
try { if (existsSync(outPath)) unlinkSync(outPath); } catch { /* noop */ }

if (missing.length) { console.log(`ENV_MISSING ${missing.join(' ')}`); process.exit(3); }

try { writeFileSync(outPath, out.length ? JSON.stringify(out) : '[]', { mode: 0o600 }); }
catch { die('WRITE_FAILED', outPath); }

console.log(out.length ? `ENV_READY ${outPath} ${out.length}` : `ENV_EMPTY ${outPath}`);
if (generated.length) console.log(`GENERATED ${generated.join(' ')}`);
if (omitted.length) console.log(`OMITTED ${omitted.join(' ')}`);
if (localSkipped.length) console.log(`LOCAL_SKIPPED ${localSkipped.join(' ')}`);
process.exit(0);
