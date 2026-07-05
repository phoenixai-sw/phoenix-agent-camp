#!/usr/bin/env node
// Phoenix Agent v2.0 model fallback state
"use strict";

const fs = require("fs");
const path = require("path");

const args = process.argv.slice(2);
function arg(name, fallback = "") {
  const idx = args.indexOf(name);
  if (idx === -1 || idx + 1 >= args.length) return fallback;
  return args[idx + 1];
}

const inputDir = path.resolve(arg("--input-dir", process.cwd()));
const workDir = path.resolve(arg("--workdir", ""));
const botName = arg("--bot", "");
const displayName = arg("--display", botName);
const pm2Profile = arg("--profile", "");
const mode = arg("--mode", "update");
const requestedAuthMode = arg("--auth-mode", process.env.PHOENIX_MODEL_AUTH_MODE || process.env.PHOENIX_AUTH_MODE || "");

if (!workDir) {
  console.error("ERROR: --workdir is required.");
  process.exit(1);
}

function inputCandidates(name) {
  return [
    path.join(inputDir, name),
    path.join(inputDir, "..", "2. 인증키_에이전트 모델 인증 키 모음", name),
  ];
}

function readOptionalFile(name) {
  for (const file of inputCandidates(name)) {
    if (!fs.existsSync(file)) continue;
    const value = fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "").trim();
    return { exists: true, value, file };
  }
  return { exists: false, value: "", file: "" };
}

function readEnv(file) {
  const env = {};
  if (!fs.existsSync(file)) return env;
  for (const raw of fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const idx = line.indexOf("=");
    if (idx < 1) continue;
    env[line.slice(0, idx)] = line.slice(idx + 1);
  }
  return env;
}

function writeEnv(file, updates) {
  const existingText = fs.existsSync(file) ? fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "") : "";
  const lines = existingText.split(/\r?\n/);
  const seen = new Set();
  const out = lines.map((line) => {
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=/);
    if (!m) return line;
    const key = m[1];
    if (!Object.prototype.hasOwnProperty.call(updates, key)) return line;
    seen.add(key);
    return `${key}=${updates[key]}`;
  });
  for (const [key, value] of Object.entries(updates)) {
    if (!seen.has(key)) out.push(`${key}=${value}`);
  }
  while (out.length && out[out.length - 1] === "") out.pop();
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, out.join("\n") + "\n", "utf8");
}

const envPath = path.join(workDir, ".env");
const previous = readEnv(envPath);
const authMode = (requestedAuthMode || previous.PHOENIX_MODEL_AUTH_MODE || previous.PHOENIX_AUTH_MODE || "openai").trim().toLowerCase();
const geminiSelected = /^(gemini|google|google-gemini|gemini-selected)$/.test(authMode);

const geminiKey = readOptionalFile("gemini_api_key.txt");
const geminiModelFile = readOptionalFile("gemini_model.txt");
const localBase = readOptionalFile("local_llm_base_url.txt");
const localModel = readOptionalFile("local_llm_model.txt");
const localKey = readOptionalFile("local_llm_api_key.txt");

const geminiModel = geminiModelFile.value || previous.PHOENIX_GEMINI_MODEL || "gemini-2.5-flash";
const localConfigured = !!((localBase.value || previous.PHOENIX_LOCAL_LLM_BASE_URL) && (localModel.value || previous.PHOENIX_LOCAL_LLM_MODEL));
const geminiConfigured = !!(geminiKey.value || previous.PHOENIX_GEMINI_API_KEY || previous.GEMINI_API_KEY || previous.GOOGLE_API_KEY);

const updates = {
  PHOENIX_MODEL_AUTH_MODE: geminiSelected ? "gemini" : "openai",
  PHOENIX_MODEL_PROVIDER_PRIORITY: geminiSelected ? "google,local,openai-codex-import,codex-login" : "openai-codex-import,codex-login,google,local",
  PHOENIX_PRIMARY_MODEL_LABEL: geminiSelected ? `Gemini API (${geminiModel})` : "OpenAI GPT-5.5 (Codex-imported ChatGPT OAuth)",
  PHOENIX_FALLBACK_DISCLOSURE: "explicit",
  PHOENIX_GEMINI_MODEL: geminiModel,
  PHOENIX_GEMINI_BASE_URL: previous.PHOENIX_GEMINI_BASE_URL || "https://generativelanguage.googleapis.com/v1beta/",
  PHOENIX_GEMINI_CONFIGURED: geminiConfigured ? "1" : "0",
  PHOENIX_LOCAL_LLM_CONFIGURED: localConfigured ? "1" : "0",
};

if (geminiKey.value) {
  updates.PHOENIX_GEMINI_API_KEY = geminiKey.value;
  updates.GEMINI_API_KEY = geminiKey.value;
  updates.GOOGLE_API_KEY = geminiKey.value;
}
if (localBase.value) updates.PHOENIX_LOCAL_LLM_BASE_URL = localBase.value;
if (localModel.value) updates.PHOENIX_LOCAL_LLM_MODEL = localModel.value;
if (localKey.value) updates.PHOENIX_LOCAL_LLM_API_KEY = localKey.value;

writeEnv(envPath, updates);
const current = readEnv(envPath);

const state = {
  version: 1,
  mode: geminiSelected ? "gemini-selected-visible" : "explicit-visible-fallback",
  sourceMode: mode,
  authMode: geminiSelected ? "gemini" : "openai",
  botName,
  displayName,
  pm2Profile,
  updatedAt: new Date().toISOString(),
  primary: geminiSelected ? {
    provider: "google",
    model: `google/${current.PHOENIX_GEMINI_MODEL || "gemini-2.5-flash"}`,
    label: `Gemini API (${current.PHOENIX_GEMINI_MODEL || "gemini-2.5-flash"})`,
    configured: current.PHOENIX_GEMINI_CONFIGURED === "1",
    status: current.PHOENIX_GEMINI_CONFIGURED === "1" ? "configured-selected" : "missing-api-key"
  } : {
    provider: "openai",
    model: "openai/gpt-5.5",
    label: "OpenAI GPT-5.5 (Codex-imported ChatGPT OAuth)",
    status: "required-first"
  },
  recovery: {
    provider: geminiSelected ? "google" : "openai-codex-import",
    command: geminiSelected ? "provide gemini_api_key.txt" : "codex login",
    label: geminiSelected ? "Gemini API key via one-line secret file; do not print the key" : "ChatGPT subscription approval through Codex CLI, then import into OpenAI provider"
  },
  fallbacks: [
    {
      provider: "google",
      model: `google/${current.PHOENIX_GEMINI_MODEL || "gemini-2.5-flash"}`,
      baseUrl: current.PHOENIX_GEMINI_BASE_URL || "https://generativelanguage.googleapis.com/v1beta/",
      configured: current.PHOENIX_GEMINI_CONFIGURED === "1",
      visibleLabel: `Gemini API fallback / ${current.PHOENIX_GEMINI_MODEL || "gemini-2.5-flash"}`,
      note: "Use only as an explicitly displayed fallback. Do not imply GPT-5.5 when this provider is active."
    },
    {
      provider: "local-openai-compatible",
      model: current.PHOENIX_LOCAL_LLM_MODEL || "",
      baseUrl: current.PHOENIX_LOCAL_LLM_BASE_URL || "",
      configured: current.PHOENIX_LOCAL_LLM_CONFIGURED === "1",
      visibleLabel: current.PHOENIX_LOCAL_LLM_MODEL ? `Local LLM fallback / ${current.PHOENIX_LOCAL_LLM_MODEL}` : "Local LLM fallback",
      note: "Use only as an explicitly displayed fallback after the local provider/adapter is verified."
    }
  ],
  disclosureRule: "Always tell the user which provider is active or only configured as a fallback candidate. Never silently switch models.",
  providerAvailabilityNote: geminiSelected
    ? "Gemini is explicitly selected as the model auth mode. OpenClaw config must validate with provider google, model google/gemini-*, and env-backed GEMINI_API_KEY or GOOGLE_API_KEY."
    : "This package records and displays Gemini/local fallback configuration. Actual runtime routing requires a compatible OpenClaw provider or adapter to be verified."
};

const stateDir = path.join(workDir, ".openclaw");
fs.mkdirSync(stateDir, { recursive: true });
fs.writeFileSync(path.join(stateDir, "phoenix_model_fallback.json"), JSON.stringify(state, null, 2) + "\n", "utf8");

const warnings = [];
if ((localBase.exists || localModel.exists) && !localConfigured) {
  warnings.push("local fallback skipped: local_llm_base_url.txt and local_llm_model.txt are both required");
}

console.log(JSON.stringify({
  ok: true,
  botName,
  geminiConfigured: state.fallbacks[0].configured,
  localConfigured: state.fallbacks[1].configured,
  warnings
}));
