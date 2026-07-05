#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/antigravity/openclaw"

node <<'NODE'
const fs = require("fs");
const path = require("path");
const http = require("http");
const https = require("https");
const childProcess = require("child_process");

const HOME = process.env.HOME;
const ROOT = path.join(HOME, "antigravity", "openclaw");
const INITIAL_DELAY_MS = Math.max(0, Number(process.env.PHOENIX_READY_INITIAL_DELAY_SECONDS || "60")) * 1000;
const BOTS = [
  { name: "genesis", display: "Genesis Bot", pm2: "pw_genesis_bot", port: 18791 },
  { name: "power", display: "Power Bot", pm2: "pw_power_bot", port: 18798 },
  { name: "design", display: "Design Bot", pm2: "pw_design_bot", port: 18790 },
  { name: "video", display: "Video Bot", pm2: "pw_video_bot", port: 18794 },
  { name: "writer", display: "Writer Bot", pm2: "pw_writer_bot", port: 18795 },
];

function t(base64) {
  return Buffer.from(base64, "base64").toString("utf8");
}

const TEXT = {
  ownerPrefix: t("7KO87J2464uYLCA="),
  readySuffix: t("IOykgOu5hCDsmYTro4zsnoXri4jri6Qu"),
  modelAuthNormal: t("66qo6424IOyduOymnTog7KCV7IOB"),
  untilSuffix: t("IOq5jOyngA=="),
  telegramNext: t("7J207KCcIFRlbGVncmFt7JeQ7IScIC9uZXcg7ZuEIOyDge2DnCDtmZXsnbgg66mU7Iuc7KeA66W8IOuztOuCtOyFlOuPhCDrkKnri4jri6Qu"),
};

function readText(file) {
  try {
    return fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "");
  } catch {
    return "";
  }
}

function readJson(file) {
  try {
    return JSON.parse(readText(file));
  } catch {
    return null;
  }
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n", "utf8");
}

function readEnv(file) {
  const env = {};
  for (const line of readText(file).split(/\r?\n/)) {
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (match) env[match[1]] = match[2].trim();
  }
  return env;
}

function fallbackNotice(bot) {
  const state = readJson(path.join(ROOT, `${bot.name}_bot`, ".openclaw", "phoenix_model_fallback.json"));
  const primary = state && state.primary ? state.primary : null;
  const lines = [];
  const primaryProvider = String((primary && primary.provider) || "").toLowerCase();
  if (primary && (primaryProvider === "google" || primaryProvider === "gemini")) {
    lines.push(`현재 대화 기준: Gemini API / ${primary.model || "google/gemini-2.5-flash"}`);
  } else {
    lines.push("현재 대화 기준: OpenAI provider + Codex-imported ChatGPT OAuth / openai/gpt-5.5");
  }
  if (state && Array.isArray(state.fallbacks)) {
    for (const item of state.fallbacks) {
      if (item && item.configured) {
        lines.push(`fallback 후보: ${item.visibleLabel || item.provider} (명시적 fallback, GPT-5.5 아님)`);
      }
    }
  }
  return lines.join("\n");
}

function botPort(bot, env) {
  for (const key of ["OPENCLAW_PORT", "OPENCLAW_GATEWAY_PORT", "PORT"]) {
    const value = Number(env[key] || 0);
    if (Number.isFinite(value) && value > 0) return value;
  }
  const legacy = bot.pm2.replace(/^pw_/, "").replace(/_bot$/, "");
  const configs = [
    path.join(HOME, `.openclaw-${bot.pm2}`, "openclaw.json"),
    path.join(HOME, `.openclaw-pw_${legacy}`, "openclaw.json"),
    path.join(HOME, `.openclaw-pw_${legacy}_bot`, "openclaw.json"),
  ];
  for (const file of configs) {
    const json = readJson(file);
    const value = Number(json?.gateway?.port || 0);
    if (Number.isFinite(value) && value > 0) return value;
  }
  return bot.port;
}

function health(port) {
  return new Promise((resolve) => {
    const req = http.get({ hostname: "127.0.0.1", port, path: "/health", timeout: 5000 }, (res) => {
      let body = "";
      res.on("data", (chunk) => (body += chunk));
      res.on("end", () => resolve(res.statusCode === 200 && /"ok"\s*:\s*true/.test(body)));
    });
    req.on("timeout", () => {
      req.destroy();
      resolve(false);
    });
    req.on("error", () => resolve(false));
  });
}

function formatKst(ms) {
  return new Date(ms + 9 * 60 * 60 * 1000).toISOString().replace("T", " ").replace(/\.\d+Z$/, " +09:00");
}

function codexCliLoggedIn() {
  try {
    const out = childProcess.execFileSync("codex", ["login", "status"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 8000,
    });
    return /logged in|authenticated|chatgpt/i.test(out) && !/not logged|not authenticated/i.test(out);
  } catch {
    return false;
  }
}

function authStatus(bot, env) {
  const state = readJson(path.join(ROOT, `${bot.name}_bot`, ".openclaw", "phoenix_model_fallback.json"));
  const primary = state && state.primary ? state.primary : null;
  const primaryProvider = String((primary && primary.provider) || "").toLowerCase();
  if (primary && (primaryProvider === "google" || primaryProvider === "gemini")) {
    const hasKey = !!(env.PHOENIX_GEMINI_API_KEY || env.GEMINI_API_KEY || env.GOOGLE_API_KEY);
    if (!hasKey) return { ready: false, expiresText: "", reason: "Gemini API key file is not configured" };
    try {
      const raw = childProcess.execFileSync("openclaw", ["--profile", bot.pm2, "config", "validate", "--json"], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        timeout: 15000,
      });
      const validation = JSON.parse(String(raw || "").replace(/^\uFEFF/, ""));
      if (!validation.valid) return { ready: false, expiresText: "", reason: "Gemini OpenClaw config validation failed" };
    } catch {
      return { ready: false, expiresText: "", reason: "Gemini OpenClaw config validation failed" };
    }
    return { ready: true, expiresText: "", reason: `Gemini API configured (${primary.model || env.PHOENIX_GEMINI_MODEL || "google/gemini-2.5-flash"})` };
  }
  try {
    const raw = childProcess.execFileSync("openclaw", ["--profile", bot.pm2, "models", "status", "--json"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 30000,
    });
    const status = JSON.parse(String(raw || "").replace(/^\uFEFF/, ""));
    const resolved = status.resolvedDefault || status.defaultModel || "";
    if (resolved !== "openai/gpt-5.5") {
      return { ready: false, expiresText: "", reason: "기본 모델이 openai/gpt-5.5가 아님" };
    }
    const routes = (((status || {}).auth || {}).runtimeAuthRoutes || []);
    const usable = routes.some((route) => route && route.provider === "openai" && route.runtime === "codex" && route.status === "usable");
    if (!usable) {
      return { ready: false, expiresText: "", reason: "OpenAI OAuth runtime route가 usable 상태가 아님" };
    }
    return { ready: true, expiresText: "", reason: "정상" };
  } catch {
    return { ready: false, expiresText: "", reason: "models status 확인 실패" };
  }
}

function sendTelegram(token, chatId, text) {
  return new Promise((resolve) => {
    const payload = JSON.stringify({ chat_id: chatId, text });
    const req = https.request(
      {
        hostname: "api.telegram.org",
        path: `/bot${token}/sendMessage`,
        method: "POST",
        headers: {
          "Content-Type": "application/json; charset=utf-8",
          "Content-Length": Buffer.byteLength(payload),
        },
        timeout: 12000,
      },
      (res) => {
        let body = "";
        res.on("data", (chunk) => (body += chunk));
        res.on("end", () => {
          let ok = false;
          try {
            ok = !!JSON.parse(body).ok;
          } catch {}
          resolve(ok);
        });
      }
    );
    req.on("timeout", () => {
      req.destroy();
      resolve(false);
    });
    req.on("error", () => resolve(false));
    req.write(payload);
    req.end();
  });
}

function updateReadyState(bot) {
  const statePath = path.join(ROOT, `${bot.name}_bot`, ".openclaw", "phoenix_proactive_state.json");
  const state = readJson(statePath) || {};
  state.version = 1;
  state.botName = bot.name;
  state.displayName = bot.display;
  state.pm2Profile = bot.pm2;
  state.readyNoticeAt = new Date().toISOString();
  state.firstUserMessageAfterReadyAt = null;
  if (!("lastUserMessageAt" in state)) state.lastUserMessageAt = null;
  if (!Array.isArray(state.proactiveSends)) state.proactiveSends = [];
  state.settings = {
    idleHours: 3,
    readyStartDelayMinutes: 30,
    dailyMaxProactiveMessages: 10,
    trendDigestDailyMax: 1,
    trendDigestHour: 7,
    skillLearningGuidanceDailyMax: 1,
    skillLearningGuidanceHour: 8,
    skillWorkOfferDailyMax: 1,
    skillWorkOfferDelayMinutes: 120,
    skillUpgradeRequestDailyMax: 1,
    skillUpgradeRequestHour: 17,
    heartbeatEvery: "30m",
    timezone: "Asia/Seoul",
  };
  writeJson(statePath, state);
}

(async () => {
  await new Promise((resolve) => setTimeout(resolve, INITIAL_DELAY_MS));
  for (const bot of BOTS) {
    const env = readEnv(path.join(ROOT, `${bot.name}_bot`, ".env"));
    const token = env.TELEGRAM_BOT_TOKEN || env.BOT_ACCESS_TOKEN || env.BOT_TOKEN || "";
    const chatId = env.TELEGRAM_READY_CHAT_ID || env.TELEGRAM_CHAT_ID || env.CHAT_ID || "";
    const port = botPort(bot, env);
    const auth = authStatus(bot, env);
    if (!token || !chatId || !(await health(port))) {
      console.log(`SKIP ${bot.name}: not ready for Telegram notice`);
      continue;
    }
    if (!auth.ready) {
      const problem = `주인님, ${bot.display} 는 Gateway와 Telegram은 준비됐지만 모델 인증 확인에 실패했습니다.\nPM2: ${bot.pm2}\nGateway: http://127.0.0.1:${port}/health\n문제: ${auth.reason || "Codex 인증 확인 필요"}\n${fallbackNotice(bot)}\n\nCodex 앱, Antigravity IDE, Claude Code 중 사용 중인 코딩 에이전트에서 codex login을 먼저 확인하고, 그 다음 v1.9 updater를 다시 실행해 주세요.`;
      const problemOk = await sendTelegram(token, chatId, problem);
      console.log(`${problemOk ? "OK" : "WARN"} ${bot.name}: model auth problem notice ${problemOk ? "sent" : "failed"}`);
      continue;
    }
    const authLine = auth.expiresText ? `${TEXT.modelAuthNormal} (${auth.expiresText}${TEXT.untilSuffix})` : `${TEXT.modelAuthNormal}`;
    const message = `${TEXT.ownerPrefix}${bot.display}${TEXT.readySuffix}\nPM2: ${bot.pm2}\nGateway: http://127.0.0.1:${port}/health\n${authLine}\n${fallbackNotice(bot)}\n${TEXT.telegramNext}`;
    const ok = await sendTelegram(token, chatId, message);
    console.log(`${ok ? "OK" : "WARN"} ${bot.name}: Telegram ready notice ${ok ? "sent" : "failed"}`);
    if (ok) updateReadyState(bot);
  }
})();
NODE
