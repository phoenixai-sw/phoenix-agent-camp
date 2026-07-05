#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const cp = require("child_process");
const crypto = require("crypto");

const HOME = process.env.USERPROFILE || process.env.HOME || "";
const BOT_MAP = {
  genesis: "pw_genesis_bot",
  power: "pw_power_bot",
  design: "pw_design_bot",
  video: "pw_video_bot",
  writer: "pw_writer_bot",
};
const CODEX_IMPORTED_OPENAI_PROFILE = "openai:codex-cli";

function argValue(name, fallback) {
  const idx = process.argv.indexOf(name);
  if (idx >= 0 && process.argv[idx + 1]) return String(process.argv[idx + 1]).toLowerCase();
  return fallback;
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
  } catch {
    return null;
  }
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n", "utf8");
}

function backup(file, stamp) {
  if (fs.existsSync(file)) fs.copyFileSync(file, `${file}.bak_${stamp}`);
}

function resolveCommand(command) {
  if (path.isAbsolute(command) && fs.existsSync(command)) return command;
  const dirs = String(process.env.PATH || "").split(path.delimiter).filter(Boolean);
  const exts = process.platform === "win32" ? [".cmd", ".exe", ".bat", ""] : [""];
  for (const dir of dirs) {
    for (const ext of exts) {
      const full = path.join(dir, command.endsWith(ext) ? command : `${command}${ext}`);
      if (fs.existsSync(full)) return full;
    }
  }
  return command;
}

function quoteCmd(value) {
  return `"${String(value).replace(/"/g, '""')}"`;
}

function run(command, args, options = {}) {
  const resolved = resolveCommand(command);
  const execOptions = {
    encoding: "utf8",
    input: "",
    windowsHide: true,
    timeout: options.timeout || 90000,
    env: options.env || process.env,
  };
  let result;
  if (process.platform === "win32" && /\.(cmd|bat)$/i.test(resolved)) {
    const line = [resolved, ...args].map(quoteCmd).join(" ");
    result = cp.spawnSync(line, [], { ...execOptions, shell: true });
  } else {
    result = cp.spawnSync(resolved, args, execOptions);
  }
  const stdout = result && result.stdout ? String(result.stdout) : "";
  const stderr = result && result.stderr ? String(result.stderr) : "";
  const timedOut = Boolean(result && result.error && result.error.code === "ETIMEDOUT");
  return {
    ok: Boolean(result && !result.error && result.status === 0),
    timedOut,
    stdout,
    stderr,
  };
}

function botKeyFromPm2Name(pm2Name) {
  return String(pm2Name || "").replace(/^pw_/, "").replace(/_bot$/, "");
}

function profileDir(pm2Name) {
  return path.join(HOME, `.openclaw-${pm2Name}`);
}

function legacyProfileDirs(pm2Name) {
  const bot = botKeyFromPm2Name(pm2Name);
  return [
    path.join(HOME, `.openclaw-pw_${bot}_bot`),
    path.join(HOME, `.openclaw-pw_${bot}`),
  ];
}

function readEnvFile(file) {
  const out = {};
  try {
    const raw = fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "");
    for (const line of raw.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const idx = trimmed.indexOf("=");
      if (idx <= 0) continue;
      out[trimmed.slice(0, idx).trim()] = trimmed.slice(idx + 1).trim().replace(/^["']|["']$/g, "");
    }
  } catch {}
  return out;
}

function isGeminiSelectedAuth(pm2Name) {
  const bot = botKeyFromPm2Name(pm2Name);
  const workDir = path.join(HOME, "antigravity", "openclaw", `${bot}_bot`);
  const env = readEnvFile(path.join(workDir, ".env"));
  const envMode = String(env.PHOENIX_MODEL_AUTH_MODE || env.PHOENIX_AUTH_MODE || "").toLowerCase();
  if (/^(gemini|google|google-gemini|gemini-selected)$/.test(envMode)) return true;

  const fallbackState = readJson(path.join(workDir, ".openclaw", "phoenix_model_fallback.json"));
  const provider = String((((fallbackState || {}).primary || {}).provider) || "").toLowerCase();
  const authMode = String((fallbackState || {}).authMode || "").toLowerCase();
  return provider === "google" || provider === "gemini" || /^(gemini|google|google-gemini|gemini-selected)$/.test(authMode);
}

function findProfileDir(pm2Name) {
  const dirs = [profileDir(pm2Name), ...legacyProfileDirs(pm2Name)];
  for (const dir of dirs) {
    if (fs.existsSync(path.join(dir, "openclaw.json"))) return dir;
  }
  return profileDir(pm2Name);
}

function ensureCodexPlugin(pm2Name) {
  run("openclaw", ["--profile", pm2Name, "plugins", "registry", "--refresh", "--json"], { timeout: 60000 });
  let installed = run("openclaw", ["--profile", pm2Name, "plugins", "install", "clawhub:@openclaw/codex", "--force"], { timeout: 120000 });
  if (!installed.ok) {
    installed = run("openclaw", ["--profile", pm2Name, "plugins", "install", "clawhub:@openclaw/codex"], { timeout: 120000 });
  }
  run("openclaw", ["--profile", pm2Name, "plugins", "inspect", "codex"], { timeout: 60000 });
}

function migrateCodexToOpenAI(pm2Name) {
  // On Windows, `openclaw migrate codex` can leave a child process waiting even
  // after the parent command times out. v1.9 repair performs the same intended
  // binding directly: copy Codex auth into the bot CODEX_HOME and pin the
  // OpenAI provider to the codex-imported OAuth profile in openclaw.json.
  return false;
}

function chmodSafe(file, mode) {
  try {
    fs.chmodSync(file, mode);
  } catch {
    // Windows and some mounted filesystems may ignore POSIX permissions.
  }
}

function agentDirForProfile(pm2Name) {
  return path.join(findProfileDir(pm2Name), "agents", "main", "agent");
}

function syncEmbeddedCodexHome(pm2Name) {
  const sourceAuth = path.join(HOME, ".codex", "auth.json");
  const agentDir = agentDirForProfile(pm2Name);
  const codexHome = path.join(agentDir, "codex-home");
  if (!fs.existsSync(sourceAuth)) {
    return { synced: false, codexHome, reason: "global Codex CLI auth.json was not found" };
  }
  fs.mkdirSync(codexHome, { recursive: true });
  chmodSafe(codexHome, 0o700);
  const destAuth = path.join(codexHome, "auth.json");
  fs.copyFileSync(sourceAuth, destAuth);
  chmodSafe(destAuth, 0o600);
  return { synced: true, codexHome, reason: "" };
}

function codexHomeLoginOk(codexHome) {
  if (!codexHome || !fs.existsSync(path.join(codexHome, "auth.json"))) return false;
  const result = run("codex", ["login", "status"], {
    timeout: 60000,
    env: { ...process.env, CODEX_HOME: codexHome, TERM: "xterm-256color" },
  });
  const text = `${result.stdout || ""}\n${result.stderr || ""}`;
  return /logged in|authenticated|chatgpt/i.test(text) && !/not logged|not authenticated|logged out/i.test(text);
}

function modelsAuthList(pm2Name) {
  const result = run("openclaw", ["--profile", pm2Name, "models", "auth", "list"], { timeout: 90000 });
  return { ok: result.ok, text: `${result.stdout || ""}\n${result.stderr || ""}` };
}

function detectOpenAIProfileFromAuthList(text) {
  const raw = String(text || "");
  const match = raw.match(/openai:[A-Za-z0-9_.:-]+/);
  return match ? match[0] : "";
}

function authListHasOpenAIProfile(text) {
  const raw = String(text || "");
  return /openai:[A-Za-z0-9_.:-]+/i.test(raw) && /openai\/oauth|provider:\s*openai|openai/i.test(raw) && !/Profiles:\s*\(none\)/i.test(raw);
}

function randomGatewayToken() {
  return crypto.randomBytes(32).toString("base64url");
}

function modelStatus(pm2Name) {
  const result = run("openclaw", ["--profile", pm2Name, "models", "status", "--json"], { timeout: 90000 });
  if (!result.ok) return null;
  return readJsonFromText(result.stdout);
}

function readJsonFromText(text) {
  try {
    return JSON.parse(String(text || "").replace(/^\uFEFF/, ""));
  } catch {
    return null;
  }
}

function detectOpenAIProfile(status) {
  const oauthProfiles = (((status || {}).auth || {}).oauth || {}).profiles || [];
  for (const item of oauthProfiles) {
    if (item && item.provider === "openai" && String(item.profileId || "").startsWith("openai:")) {
      return String(item.profileId);
    }
  }
  const providers = (((status || {}).auth || {}).providers || []);
  for (const provider of providers) {
    if (!provider || provider.provider !== "openai") continue;
    const labels = ((provider.profiles || {}).labels || []);
    for (const label of labels) {
      const id = String(label).split("=")[0];
      if (id.startsWith("openai:")) return id;
    }
  }
  return "";
}

function hasUsableOpenAIRoute(status) {
  const routes = (((status || {}).auth || {}).runtimeAuthRoutes || []);
  return routes.some((route) => route && route.provider === "openai" && route.runtime === "codex" && route.status === "usable");
}

function patchOpenClawJson(pm2Name, openaiProfileId, stamp) {
  const dir = findProfileDir(pm2Name);
  fs.mkdirSync(dir, { recursive: true });
  const configPath = path.join(dir, "openclaw.json");
  backup(configPath, stamp);
  const cfg = readJson(configPath) || {};
  cfg.gateway = cfg.gateway || { mode: "local" };
  cfg.gateway.auth = cfg.gateway.auth || {};
  cfg.gateway.auth.mode = "token";
  if (!cfg.gateway.auth.token) cfg.gateway.auth.token = randomGatewayToken();
  cfg.agents = cfg.agents || {};
  cfg.agents.defaults = cfg.agents.defaults || {};
  cfg.agents.defaults.model = cfg.agents.defaults.model || {};
  cfg.agents.defaults.model.primary = "openai/gpt-5.5";
  cfg.agents.defaults.models = cfg.agents.defaults.models || {};
  delete cfg.agents.defaults.models["codex/gpt-5.5"];
  delete cfg.agents.defaults.models["openai-codex/gpt-5.5"];
  delete cfg.agents.defaults.models["openai-codex/gpt-5.4"];
  cfg.agents.defaults.models["openai/gpt-5.5"] = cfg.agents.defaults.models["openai/gpt-5.5"] || {};

  cfg.models = cfg.models || {};
  cfg.models.providers = cfg.models.providers || {};
  delete cfg.models.providers.codex;
  delete cfg.models.providers["openai-codex"];
  cfg.models.providers.openai = cfg.models.providers.openai || {};
  cfg.models.providers.openai.auth = "oauth";
  cfg.models.providers.openai.models = [{ id: "gpt-5.5", name: "gpt-5.5", api: "openai-chatgpt-responses" }];

  cfg.auth = cfg.auth || {};
  cfg.auth.profiles = cfg.auth.profiles || {};
  for (const key of Object.keys(cfg.auth.profiles)) {
    if (/^(codex|openai-codex):/i.test(key)) delete cfg.auth.profiles[key];
  }
  if (openaiProfileId) cfg.auth.profiles[openaiProfileId] = { provider: "openai", mode: "oauth" };
  cfg.auth.order = cfg.auth.order || {};
  delete cfg.auth.order.codex;
  delete cfg.auth.order["openai-codex"];
  if (openaiProfileId) cfg.auth.order.openai = [openaiProfileId];

  writeJson(configPath, cfg);
  return configPath;
}

function patchOne(pm2Name, stamp) {
  if (isGeminiSelectedAuth(pm2Name)) {
    return {
      profile: pm2Name,
      ok: true,
      skipped: true,
      authMode: "gemini",
      reason: "Gemini selected-auth mode detected; OpenAI/Codex repair skipped without changing provider routing.",
    };
  }
  ensureCodexPlugin(pm2Name);
  const embeddedCodex = syncEmbeddedCodexHome(pm2Name);
  let status = modelStatus(pm2Name);
  let openaiProfileId = detectOpenAIProfile(status);
  const authListBeforePatch = modelsAuthList(pm2Name);
  openaiProfileId = openaiProfileId || detectOpenAIProfileFromAuthList(authListBeforePatch.text);
  openaiProfileId = openaiProfileId || CODEX_IMPORTED_OPENAI_PROFILE;
  patchOpenClawJson(pm2Name, openaiProfileId, stamp);
  status = modelStatus(pm2Name) || status;
  openaiProfileId = openaiProfileId || detectOpenAIProfile(status);
  const authListAfterPatch = modelsAuthList(pm2Name);
  openaiProfileId = openaiProfileId || detectOpenAIProfileFromAuthList(authListAfterPatch.text);
  const embeddedLoginOk = codexHomeLoginOk(embeddedCodex.codexHome);
  const authListOk = authListHasOpenAIProfile(authListAfterPatch.text) || Boolean(openaiProfileId);

  if (!embeddedLoginOk || !authListOk || !openaiProfileId || !hasUsableOpenAIRoute(status)) {
    return {
      profile: pm2Name,
      ok: false,
      reason: "OpenAI OAuth imported from Codex login is not fully usable yet. Run codex login in this same coding-agent terminal, then rerun this installer/updater.",
    };
  }

  return {
    profile: pm2Name,
    ok: true,
    model: ((status || {}).resolvedDefault || (status || {}).defaultModel || "openai/gpt-5.5"),
    route: "openai via codex",
    embeddedCodexHome: embeddedCodex.synced ? "synced" : "not-found",
    authList: "openai-profile-present",
  };
}

function main() {
  const bot = argValue("--bot", "all");
  const targets = bot === "all" ? Object.values(BOT_MAP) : [BOT_MAP[bot]].filter(Boolean);
  if (!targets.length) {
    console.error(`ERROR: unknown bot target: ${bot}`);
    process.exit(1);
  }
  const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14) + "_v17_openai_codex";
  const results = targets.map((pm2Name) => patchOne(pm2Name, stamp));
  let failed = false;
  for (const result of results) {
    if (result.ok) {
      console.log(`OK ${result.profile}: model=${result.model} auth=${result.route} embedded_codex=${result.embeddedCodexHome} auth_list=${result.authList} status=usable`);
    } else {
      failed = true;
      console.log(`WARN ${result.profile}: ${result.reason}`);
    }
  }
  if (failed) process.exit(1);
}

main();
