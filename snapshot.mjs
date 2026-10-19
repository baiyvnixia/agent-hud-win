#!/usr/bin/env node
/**
 * agent-hud-win · 数据源
 * ---------------------------------------------------------------------------
 * 把各家 AI 的余额 / 额度查出来，写成一个 JSON 给桌面浮窗（hud.ps1）读。
 * 浮窗本身完全不联网，所以界面永远不会被网络卡住。
 *
 * 用法
 *   一次性:  node snapshot.mjs [--pretty]
 *   常驻:    node snapshot.mjs --watch --out <文件> [--interval 60]
 *   体检:    node snapshot.mjs --check          # 只列出哪些 provider 已配置好
 *
 * 凭证从哪来（优先级从高到低）
 *   1. 环境变量             — 例如 DEEPSEEK_API_KEY=sk-xxx
 *   2. providers.local.json — 本机的私密配置（已在 .gitignore 里排除）
 *   3. DSH 的 ~/.dsh/.credentials.yaml — 如果你装了 DSH，直接复用它的 refs
 *
 * 支持哪些供应商
 *   providers.json 里是一张声明式表。没有内置适配器的供应商，只要它的接口是
 *   「GET 一个 URL，从返回 JSON 的某个字段里取余额」，就能纯配置接入，
 *   不需要写一行代码。详见 docs/ADD-PROVIDER.md。
 *
 * 安全：明文 key 只在内存里用于发请求，绝不出现在输出 / 日志里。
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const DSH_HOME = process.env.DSH_HOME || join(homedir(), '.dsh');

// ---------------------------------------------------------------- 工具函数

/** 按 'a.b.0.c' 这样的点路径取值。 */
function pick(obj, path) {
  if (!path) return undefined;
  let cur = obj;
  for (const seg of String(path).split('.')) {
    if (cur == null) return undefined;
    cur = cur[seg];
  }
  return cur;
}

function num(v) {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v))) return Number(v);
  return null;
}

function readJson(path, fallback) {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return fallback; }
}

// ---------------------------------------------------------------- 凭证

/** 解析 DSH 的 .credentials.yaml 里 refs 段（简单的 key: value，不引第三方 yaml 库）。 */
function readDshRefs() {
  const refs = {};
  const file = join(DSH_HOME, '.credentials.yaml');
  if (!existsSync(file)) return refs;
  try {
    let inRefs = false;
    for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
      if (/^refs:\s*$/.test(line)) { inRefs = true; continue; }
      if (/^[A-Za-z_]/.test(line)) { inRefs = false; continue; }
      if (!inRefs) continue;
      const m = /^\s{2}([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(\S+)\s*$/.exec(line);
      if (m) refs[m[1]] = m[2];
    }
  } catch { /* 读不到就只靠别的来源 */ }
  return refs;
}

const dshRefs = readDshRefs();
const localCfg = readJson(join(HERE, 'providers.local.json'), {});
const localKeys = localCfg.keys || {};

/** 依次找：环境变量 → providers.local.json → DSH refs。 */
function resolveKey(names) {
  for (const n of names || []) {
    if (process.env[n]) return { value: process.env[n], from: `env:${n}` };
    if (localKeys[n]) return { value: localKeys[n], from: `local:${n}` };
    if (dshRefs[n]) return { value: dshRefs[n], from: `dsh:${n}` };
  }
  return null;
}

// ---------------------------------------------------------------- 内置适配器
//
// 内置适配器只用来处理「返回结构比较绕」的供应商。
// 结构简单的供应商不用写适配器，用 providers.json 里的 response 映射即可（generic）。

const ADAPTERS = {
  /** DeepSeek: GET /user/balance → { is_available, balance_infos: [{currency, total_balance, ...}] } */
  deepseek: async (ctx, def) => {
    const body = await ctx.get(def.request.url);
    const infos = Array.isArray(body.balance_infos) ? body.balance_infos : [];
    return infos.map((b) => ({
      label: b.currency || '',
      amount: num(b.total_balance),
      unit: b.currency || null,
      capacity: null,
      ratio: null,
      kind: 'balance',
      text: b.currency ? `${b.currency} ${b.total_balance}` : String(b.total_balance ?? ''),
      expiresAt: null,
    }));
  },

  /** Moonshot / Kimi: GET /v1/users/me/balance → { data: { available_balance, ... } } */
  moonshot: async (ctx, def) => {
    const body = await ctx.get(def.request.url);
    const d = body.data || body;
    const amount = num(d.available_balance) ?? num(d.balance);
    if (amount == null) throw new Error('返回里找不到 available_balance');
    return [{
      label: 'CNY',
      amount,
      unit: 'CNY',
      capacity: null,
      ratio: null,
      kind: 'balance',
      text: `CNY ${amount}`,
      expiresAt: null,
    }];
  },

  /**
   * 智谱 GLM：现金账户和资源包是两个接口。资源包有真实总量，所以圆环能画出百分比。
   * 这里把所有资源包都列出来，浮窗会自动取「最紧的那一项」来决定圆环长度。
   */
  zhipu: async (ctx, def) => {
    const items = [];
    const base = def.request.url.replace(/\/+$/, '');

    // 现金账户
    try {
      const cash = await ctx.get(`${base}/api/biz/account/query-customer-account-report`);
      const amount = num(cash?.data?.balance) ?? num(cash?.data?.amount);
      if (amount != null) {
        items.push({
          label: '现金账户', amount, unit: 'CNY', capacity: null, ratio: null,
          kind: 'balance', text: `CNY ${amount}`, expiresAt: null,
        });
      }
    } catch { /* 现金接口挂了不影响资源包 */ }

    // 资源包（每个包有自己的总量和到期时间）
    // 注意：这个接口的成功返回是 { code, msg, rows[], total }，不是 { data }。
    // 两种形状都兼容，免得接口改版后整块静默失效。
    try {
      const packs = await ctx.get(`${base}/api/biz/tokenAccounts/list/my`);
      const list = Array.isArray(packs?.data) ? packs.data
        : (Array.isArray(packs?.rows) ? packs.rows
        : (Array.isArray(packs?.data?.list) ? packs.data.list
        : (Array.isArray(packs?.data?.rows) ? packs.data.rows : [])));
      let exhausted = 0;
      for (const p of list) {
        const remain = num(p.availableBalance) ?? num(p.tokenBalance)
          ?? num(p.balance) ?? num(p.remainAmount);
        const total = num(p.tokensMagnitude) ?? num(p.totalAmount)
          ?? num(p.total) ?? num(p.capacity);
        if (remain == null) continue;
        // 已用尽 / 已过期的包只是噪音，会把圆环拖到 0%
        const status = String(p.displayStatus || '').toUpperCase();
        if (remain <= 0 || status === 'USED_UP' || status === 'EXPIRED') { exhausted += 1; continue; }
        // 包名很长（如「【新用户专享】1500万GLM-5.3-Flash资源包」），
        // suitableModel 有时又是一整句场景描述——挑短的那个当标签，卡片里更好读
        const modelName = (p.suitableModel || '').trim();
        const packName = (p.resourcePackageName || p.name || '').trim();
        // 有的包里 suitableModel 是一整句场景描述（含「、」「适用」），那种不适合当标签
        const modelIsName = modelName && modelName.length <= 22 && !/[、，,\s]/.test(modelName);
        let label;
        if (modelIsName) label = modelName;
        else if (packName) label = packName.length > 22 ? `${packName.slice(0, 21)}…` : packName;
        else label = modelName || '资源包';
        items.push({
          label,
          amount: remain,
          unit: 'tokens',
          capacity: total,
          ratio: total && total > 0 ? remain / total : null,
          kind: 'quota',
          text: total ? `${remain} / ${total}` : String(remain),
          expiresAt: p.expirationTime || p.packageExpirationTime || p.expireTime || null,
          status: p.displayStatusDesc || p.displayStatus || null,
        });
      }
      if (exhausted > 0 && items.filter((i) => i.kind === 'quota').length === 0) {
        items.push({
          label: '资源包', amount: 0, unit: 'tokens', capacity: null, ratio: 0,
          kind: 'quota', text: `${exhausted} 个资源包已用尽/过期`, expiresAt: null,
        });
      }
    } catch { /* 同上 */ }

    if (items.length === 0) throw new Error('现金与资源包接口都没有拿到数据');
    return items;
  },

  /** OpenRouter: GET /api/v1/credits → { data: { total_credits, total_usage } } */
  openrouter: async (ctx, def) => {
    const body = await ctx.get(def.request.url);
    const total = num(body?.data?.total_credits);
    const used = num(body?.data?.total_usage) ?? 0;
    const remain = total != null ? total - used : null;
    if (remain == null) throw new Error('返回里找不到 total_credits');
    return [{
      label: 'credits', amount: remain, unit: 'USD',
      capacity: total, ratio: total > 0 ? remain / total : null,
      kind: 'balance', text: `$${remain.toFixed(2)} / $${total.toFixed(2)}`, expiresAt: null,
    }];
  },

  /**
   * manual：没有公开余额接口的供应商（Claude / GPT / Gemini / MiniMax ...）。
   * 数值写在 providers.local.json 的 manual 段，例如：
   *   "manual": { "claude": { "amount": 18.5, "capacity": 20, "unit": "USD" } }
   * 配了才显示，没配就静默跳过（不会在界面上显示成错误）。
   */
  manual: async (ctx, def) => {
    const m = (localCfg.manual || {})[def.id];
    if (!m) throw new Error('manual provider 未在本机配置数值');
    const amount = num(m.amount);
    const capacity = num(m.capacity);
    if (amount == null) throw new Error('manual 配置里缺少 amount');
    const unit = m.unit || '';
    return [{
      label: m.itemLabel || def.label || def.id,
      amount,
      unit: unit || null,
      capacity,
      ratio: capacity && capacity > 0 ? amount / capacity : (num(m.ratio) ?? null),
      kind: capacity ? 'quota' : 'balance',
      text: m.text || (capacity
        ? `${amount} / ${capacity}${unit ? ' ' + unit : ''}`
        : `${unit ? unit + ' ' : ''}${amount}`),
      expiresAt: m.expiresAt || null,
    }];
  },
};

/** 通用适配器：纯配置驱动，适合「GET 一个 URL 取某个字段」的供应商。 */
async function genericAdapter(ctx, def) {
  const body = await ctx.get(def.request.url, def.request.headers);
  const map = def.response || {};
  let list = pick(body, map.listPath);
  if (list == null) list = body;
  if (!Array.isArray(list)) list = [list];

  return list
    .map((item) => {
      const amount = num(pick(item, map.amountPath || 'amount'));
      const total = num(pick(item, map.capacityPath));
      const label = pick(item, map.labelPath);
      return {
        label: String(label ?? def.label ?? ''),
        amount,
        unit: pick(item, map.unitPath) ?? null,
        capacity: total,
        ratio: total && total > 0 && amount != null ? amount / total : null,
        kind: total ? 'quota' : 'balance',
        text: total && amount != null ? `${amount} / ${total}` : String(amount ?? ''),
        expiresAt: pick(item, map.expiresPath) ?? null,
      };
    })
    .filter((it) => it.amount != null);
}

// ---------------------------------------------------------------- 主流程

const lastGood = new Map();    // id → 上次成功的数据（断网时标 stale 继续显示）

function buildCtx(keyValue, def) {
  const auth = def.auth || {};
  const headers = { Accept: 'application/json', ...(def.request?.headers || {}) };
  if (keyValue && auth.header) headers[auth.header] = `${auth.scheme ?? ''}${keyValue}`;
  return {
    async get(url, extra) {
      const res = await fetch(url, { headers: { ...headers, ...(extra || {}) } });
      const text = await res.text();
      if (!res.ok) throw new Error(`HTTP ${res.status}: ${text.slice(0, 160)}`);
      try { return JSON.parse(text); } catch { return text; }
    },
  };
}

function todaySpend(providerId) {
  // 可选：如果你在 providers.local.json 里配了 spendFile，就按采样序列估算今日消耗。
  const file = localCfg.spendFile;
  if (!file) return null;
  try {
    const store = JSON.parse(readFileSync(file, 'utf8'));
    const samples = store?.providers?.[providerId];
    if (!Array.isArray(samples) || samples.length < 2) return null;
    const first = samples[0]?.amount;
    const last = samples[samples.length - 1]?.amount;
    if (typeof first !== 'number' || typeof last !== 'number') return null;
    const delta = first - last;
    return delta > 0 ? Number(delta.toFixed(4)) : null;
  } catch { return null; }
}

function loadProviders() {
  const base = readJson(join(HERE, 'providers.json'), []);
  const list = Array.isArray(base) ? base : [];
  // providers.local.json 的 providers 段可覆盖同 id，也可新增
  const extra = Array.isArray(localCfg.providers) ? localCfg.providers : [];
  const byId = new Map(list.map((p) => [p.id, p]));
  for (const p of extra) {
    if (!p || !p.id) continue;
    byId.set(p.id, { ...(byId.get(p.id) || {}), ...p });
  }
  // 环境变量 HUD_PROVIDERS 可只启用其中几个（逗号分隔）
  const only = (process.env.HUD_PROVIDERS || '').split(',').map((s) => s.trim()).filter(Boolean);
  let out = [...byId.values()].filter((p) => p.enabled !== false);
  if (only.length) out = out.filter((p) => only.includes(p.id));
  return out;
}

async function collect() {
  const defs = loadProviders();
  const results = await Promise.all(defs.map(async (def) => {
    const key = resolveKey(def.auth?.env);
    // 需要 key 但没配 → 直接跳过，不当作错误（否则界面上全是红点）
    if (def.auth?.env?.length && !key) return null;
    // manual 类型没在本机填数值 → 也跳过，不要显示成红圈
    if (def.adapter === 'manual' && !(localCfg.manual || {})[def.id]) return null;

    const base = {
      id: def.id, label: def.label || def.id,
      color: def.color ?? null,
      ok: false, stale: false, error: null, items: [],
    };
    try {
      const ctx = buildCtx(key?.value, def);
      const fn = def.adapter ? ADAPTERS[def.adapter] : genericAdapter;
      if (!fn) throw new Error(`未知 adapter: ${def.adapter}`);
      const items = await fn(ctx, def);
      const payload = {
        ...base,
        ok: true,
        items,
        todaySpend: todaySpend(def.id),
        reference: def.reference ?? null,
        color: def.color ?? null,
        icon: def.icon ?? null,
      };
      lastGood.set(def.id, payload);
      return payload;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      // 之前成功过就保留旧数据并标 stale，避免一次网络抖动把圆环抹红
      const prev = lastGood.get(def.id);
      if (prev) return { ...prev, ok: true, stale: true, error: msg };
      return { ...base, error: msg };
    }
  }));

  const providers = results.filter(Boolean);
  return {
    ok: providers.some((p) => p.ok && !p.stale),
    updated: Date.now(),
    providers,
  };
}

function argValue(flag, fallback) {
  const i = process.argv.indexOf(flag);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

// ---------------------------------------------------------------- 入口

if (process.argv.includes('--check')) {
  const defs = loadProviders();
  const rows = defs.map((d) => {
    const key = resolveKey(d.auth?.env);
    const need = d.auth?.env?.length ? (key ? `OK  ${key.from}` : '--  未配置') : '（无需 key）';
    return `${d.id.padEnd(14)} ${String(d.label).padEnd(16)} ${need}`;
  });
  process.stdout.write(`${rows.join('\n')}\n\n共 ${defs.length} 个 provider；DSH 凭证目录: ${DSH_HOME}\n`);
  process.exit(0);
}

if (process.argv.includes('--watch')) {
  const out = argValue('--out', join(tmpdir(), 'agent-hud-win.json'));
  const intervalMs = Math.max(10, Number(argValue('--interval', '60'))) * 1000;
  process.stdout.write(`watching -> ${out} every ${intervalMs / 1000}s\n`);
  for (;;) {
    try {
      writeFileSync(out, JSON.stringify(await collect()), 'utf8');
    } catch (e) {
      writeFileSync(out, JSON.stringify({
        ok: false, updated: Date.now(), providers: [],
        error: e instanceof Error ? e.message : String(e),
      }), 'utf8');
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
} else {
  const payload = await collect();
  process.stdout.write(JSON.stringify(payload, null, process.argv.includes('--pretty') ? 2 : 0));
}
