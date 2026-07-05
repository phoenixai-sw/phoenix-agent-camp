const fs = require("fs");
const path = require("path");
const http = require("http");
const https = require("https");
const os = require("os");
const childProcess = require("child_process");

const args = new Set(process.argv.slice(2));
const LOOP = args.has("--loop") || !args.has("--once");
const DRY_RUN = args.has("--dry-run");
const IDENTITY_ONLY = args.has("--apply-identity-only");
function argValue(name, fallback = "") {
  const raw = process.argv.slice(2);
  for (let i = 0; i < raw.length; i += 1) {
    if (raw[i] === name && raw[i + 1]) return raw[i + 1];
    if (raw[i].startsWith(`${name}=`)) return raw[i].slice(name.length + 1);
  }
  return fallback;
}
const SCRIPT_DIR = __dirname;
const PACKAGE_DIRS = new Set(["installer", "updater"]);
const SCRIPT_IN_PACKAGE = PACKAGE_DIRS.has(path.basename(SCRIPT_DIR).toLowerCase());
const ROOT = SCRIPT_IN_PACKAGE
  ? path.join(process.env.USERPROFILE || process.env.HOME || os.homedir(), "antigravity", "openclaw")
  : SCRIPT_DIR;
const HOME = path.resolve(ROOT, "..", "..");
const LOG_DIR = path.join(ROOT, "logs");
const LOG_PATH = path.join(LOG_DIR, "phoenix_proactive_nudge.log");
const INTERVAL_MINUTES = Number(process.env.PHOENIX_NUDGE_INTERVAL_MINUTES || "3");
const BOT_SEND_STAGGER_MS = DRY_RUN ? 0 : Number(process.env.PHOENIX_BOT_SEND_STAGGER_SECONDS || "10") * 1000;
const TREND_MAX_AGE_DAYS = Math.max(1, Number(process.env.PHOENIX_TREND_MAX_AGE_DAYS || "14"));
const TREND_MAX_ITEMS = Math.max(1, Number(process.env.PHOENIX_TREND_MAX_ITEMS || "3"));
const TELEGRAM_ISSUE_WINDOW_MINUTES = Math.max(1, Number(process.env.PHOENIX_TELEGRAM_ISSUE_WINDOW_MINUTES || "20"));
const TELEGRAM_RECOVERY_COOLDOWN_MINUTES = Math.max(1, Number(process.env.PHOENIX_TELEGRAM_RECOVERY_COOLDOWN_MINUTES || "30"));
const TELEGRAM_AUTO_RECOVER = String(process.env.PHOENIX_TELEGRAM_AUTO_RECOVER || "1") !== "0";
const SCHEDULED_CORE_KINDS = new Set(["trend_digest", "skill_learning_guidance", "skill_upgrade_request"]);
const TELEGRAM_ISSUE_PATTERNS = [
  { label: "stale-socket", pattern: /stale-socket/i },
  { label: "polling-stall", pattern: /polling stall/i },
  { label: "getupdates-failed", pattern: /getUpdates.*failed/i },
  { label: "telegram-fetch-timeout", pattern: /fetch-timeout.*api\.telegram\.org/i },
  { label: "telegram-network-failed", pattern: /Network request for '(sendMessage|sendChatAction|getMe|getUpdates)' failed/i },
  { label: "sendmessage-failed", pattern: /sendMessage failed/i },
  { label: "sendchataction-failed", pattern: /sendChatAction failed/i },
  { label: "final-reply-failed", pattern: /final reply failed/i },
  { label: "setmycommands-failed", pattern: /setMyCommands.*failed/i },
  { label: "getupdates-conflict", pattern: /409.*getUpdates|terminated by other getUpdates request/i },
];

const BOTS = [
  {
    name: "genesis",
    display: "Genesis Bot",
    pm2: "pw_genesis_bot",
    role: "전체 봇을 관리하고 작업 지시문을 정리하는 비서실장 봇",
    menu: ["전체 봇에게 줄 작업 지시문 정리", "랜딩페이지/자동화 프로그램 설계", "서비스와 플랫폼 구조 기획"],
    trendQuery: "AI 에이전트 자동화 서비스 플랫폼 최신 트렌드",
    trendMenu: ["오늘 AI 에이전트 자동화 흐름을 서비스 구조로 바꾸기", "업무 자동화 아이디어 5개를 실행 계획으로 정리하기", "전체 봇에게 나눠 줄 작업 지시문 만들기"],
    skillUpgradeRequests: ["전체 봇에게 작업을 배분하는 멀티봇 지휘 프롬프트 생성 스킬", "서비스/플랫폼 설계를 화면 흐름과 개발 작업으로 나누는 설계 스킬", "반복 업무를 자동화 프로그램 요구사항으로 정리하는 스킬"],
  },
  {
    name: "power",
    display: "Power Bot",
    pm2: "pw_power_bot",
    role: "리서치, 시장 분석, 보고서 작성에 맞는 기획실장 봇",
    menu: ["시장/트렌드 리포트 작성", "경쟁사 분석과 정부지원사업 검토", "논문/자료 기반 보고서 설계"],
    trendQuery: "AI 시장 트렌드 정부지원사업 리서치 보고서 최신",
    trendMenu: ["오늘 시장 흐름을 1페이지 트렌드 브리프로 정리하기", "경쟁사와 정책 변화를 체크리스트로 만들기", "지원사업/용역사업 관점의 기회 찾기"],
    skillUpgradeRequests: ["정부지원사업/용역 공고를 요약하고 적합도를 판단하는 스킬", "시장/경쟁사 리서치를 보고서 목차와 표로 바꾸는 스킬", "논문/정책자료를 근거 중심 리포트로 재구성하는 스킬"],
  },
  {
    name: "design",
    display: "Design Bot",
    pm2: "pw_design_bot",
    role: "이미지, 상세페이지, 브랜드 비주얼을 다루는 디자인실장 봇",
    menu: ["이미지와 상세페이지 콘셉트 제안", "브랜드 비주얼과 썸네일 기획", "PPT와 웹디자인 레이아웃 시작"],
    trendQuery: "AI 디자인 이미지 생성 상세페이지 브랜드 비주얼 PPT 최신 트렌드",
    trendMenu: ["오늘 비주얼 트렌드를 상세페이지 콘셉트로 바꾸기", "썸네일/브랜드 이미지 방향 5개 제안하기", "PPT 디자인 매너를 최신 스타일로 정리하기"],
    skillUpgradeRequests: ["PPT 초안을 브랜드 톤에 맞춰 슬라이드 구조로 바꾸는 스킬", "상세페이지 구성안을 섹션별 카피와 이미지 지시문으로 나누는 스킬", "썸네일/배너 시안을 여러 스타일로 제안하는 스킬"],
  },
  {
    name: "video",
    display: "Video Bot",
    pm2: "pw_video_bot",
    role: "영상 콘셉트, 숏폼, 광고 영상 제작을 돕는 영상실장 봇",
    menu: ["숏폼/광고 영상 콘셉트 작성", "영상 스토리보드 구성", "fal.ai 영상 생성 프롬프트 준비"],
    trendQuery: "AI 영상 숏폼 광고 영상 생성 최신 트렌드 fal.ai",
    trendMenu: ["오늘 숏폼 트렌드를 광고 콘셉트 5개로 바꾸기", "영상 스토리보드 초안 만들기", "fal.ai 생성용 프롬프트 세트 만들기"],
    skillUpgradeRequests: ["숏폼 영상을 훅/전개/CTA 구조로 자동 기획하는 스킬", "fal.ai 영상 생성 프롬프트를 장면별로 세분화하는 스킬", "광고 영상 콘셉트를 스토리보드와 컷 리스트로 바꾸는 스킬"],
  },
  {
    name: "writer",
    display: "Writer Bot",
    pm2: "pw_writer_bot",
    role: "원고, 출판, 카피라이팅, 교정을 맡는 출판실장 봇",
    menu: ["원고와 책 기획안 작성", "보고서와 카피라이팅 초안 작성", "교정/이미지 목록/출판 체크리스트 정리"],
    trendQuery: "출판 콘텐츠 카피라이팅 전자책 AI 글쓰기 최신 트렌드",
    trendMenu: ["오늘 콘텐츠 트렌드를 원고 기획안으로 바꾸기", "카피라이팅 문안 10개 만들기", "출판/전자책 아이디어를 목차로 정리하기"],
    skillUpgradeRequests: ["원고를 출판 목차와 장별 집필 계획으로 바꾸는 스킬", "교정/윤문 기준표를 만들어 문체를 일관되게 다듬는 스킬", "이미지 목록과 캡션을 출판용 체크리스트로 정리하는 스킬"],
  },
];
const BOT_FILTER = String(argValue("--bot", process.env.PHOENIX_UPDATE_BOT || "all")).trim().toLowerCase();

let running = false;

function selectedBots() {
  if (!BOT_FILTER || BOT_FILTER === "all") return BOTS;
  return BOTS.filter((bot) => bot.name === BOT_FILTER || bot.pm2.toLowerCase() === BOT_FILTER);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, ms || 0)));
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function log(message) {
  ensureDir(LOG_DIR);
  const line = `${new Date().toLocaleString("sv-SE", { hour12: false })} ${message}`;
  fs.appendFileSync(LOG_PATH, `${line}\n`, "utf8");
  console.log(line);
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
  } catch (_) {
    return null;
  }
}

function writeJson(file, value) {
  ensureDir(path.dirname(file));
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function fileTimestamp(date = new Date()) {
  return date.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
}

function readStateJson(file, bot) {
  if (!fs.existsSync(file)) return {};
  try {
    return JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
  } catch (_) {
    const backup = `${file}.corrupt_${fileTimestamp()}.bak`;
    try {
      fs.copyFileSync(file, backup);
      log(`repair ${bot.name}: corrupt proactive state JSON backed up to ${path.basename(backup)}`);
    } catch (err) {
      log(`repair ${bot.name}: corrupt proactive state JSON backup failed (${err.message})`);
    }
    return {
      stateRepairedAt: new Date().toISOString(),
      stateRepairReason: "corrupt proactive state json",
    };
  }
}

function readText(file) {
  try {
    return fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "");
  } catch (_) {
    return "";
  }
}

function writeText(file, text) {
  ensureDir(path.dirname(file));
  fs.writeFileSync(file, `${String(text).replace(/\s+$/, "")}\n`, "utf8");
}

function makeMarkedBlock(start, end, body) {
  return `${start}\n${String(body).trim()}\n${end}`;
}

function upsertMarkedBlock(file, start, end, body, fallbackHeader = "") {
  const block = makeMarkedBlock(start, end, body);
  const current = readText(file);
  const startAt = current.indexOf(start);
  const endAt = current.indexOf(end);
  if (startAt >= 0 && endAt >= startAt) {
    const afterEnd = endAt + end.length;
    writeText(file, `${current.slice(0, startAt).replace(/\s+$/, "")}\n\n${block}\n\n${current.slice(afterEnd).replace(/^\s+/, "")}`.trim());
    return;
  }
  if (!current.trim()) {
    writeText(file, `${fallbackHeader ? `${fallbackHeader}\n\n` : ""}${block}`);
    return;
  }
  writeText(file, `${current.trim()}\n\n${block}`);
}

function readEnv(file) {
  const env = {};
  try {
    for (const rawLine of fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "").split(/\r?\n/)) {
      const line = rawLine.replace(/^\uFEFF/, "");
      const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
      if (match) env[match[1]] = match[2];
    }
  } catch (_) {}
  return env;
}

function botWorkDir(bot) {
  return path.join(ROOT, `${bot.name}_bot`);
}

function botStatePath(bot) {
  return path.join(botWorkDir(bot), ".openclaw", "phoenix_proactive_state.json");
}

function botKeyFromPm2Name(pm2Name) {
  return String(pm2Name || "").replace(/^pw_/, "").replace(/_bot$/, "");
}

function botProfilePaths(bot) {
  const botKey = botKeyFromPm2Name(bot.pm2);
  return [
    path.join(HOME, `.openclaw-${bot.pm2}`, "openclaw.json"),
    path.join(HOME, `.openclaw-pw_${botKey}`, "openclaw.json"),
  ];
}

function readBotProfile(bot) {
  for (const file of botProfilePaths(bot)) {
    const profile = readJson(file);
    if (profile) return profile;
  }
  return null;
}

function botPort(bot) {
  const env = readEnv(path.join(botWorkDir(bot), ".env"));
  const fromEnv = Number(env.OPENCLAW_PORT);
  if (Number.isFinite(fromEnv) && fromEnv > 0) return fromEnv;
  const profile = readBotProfile(bot);
  const fromProfile = Number(profile?.gateway?.port);
  if (Number.isFinite(fromProfile) && fromProfile > 0) return fromProfile;
  return 0;
}

function pm2CommandCandidates() {
  const candidates = [];
  const add = (file, viaCmd = false) => {
    if (!file) return;
    const label = `${viaCmd ? "cmd:" : "direct:"}${file}`;
    if (!candidates.some((item) => item.label === label)) candidates.push({ file, viaCmd, label });
  };
  if (process.env.PHOENIX_PM2_CMD) add(process.env.PHOENIX_PM2_CMD, process.platform === "win32");
  if (process.env.APPDATA) add(path.join(process.env.APPDATA, "npm", "pm2.cmd"), process.platform === "win32");
  const npmPrefix = process.env.NPM_CONFIG_PREFIX || process.env.npm_config_prefix || "";
  if (process.platform === "win32") {
    if (npmPrefix) add(path.join(npmPrefix, "pm2.cmd"), true);
    if (process.env.ProgramFiles) add(path.join(process.env.ProgramFiles, "nodejs", "pm2.cmd"), true);
    add("pm2.cmd", true);
    add("pm2", true);
  } else {
    if (npmPrefix) add(path.join(npmPrefix, "bin", "pm2"), false);
    add("/opt/homebrew/bin/pm2", false);
    add("/usr/local/bin/pm2", false);
    add("pm2", false);
  }
  return candidates;
}

function quoteCmdArg(value) {
  const text = String(value);
  if (/^[A-Za-z0-9_./:=+-]+$/.test(text)) return text;
  return `"${text.replace(/"/g, '""')}"`;
}

function runPm2Command(candidate, args, timeout) {
  const common = {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout,
    windowsHide: true,
  };
  if (candidate.viaCmd && process.platform === "win32") {
    const commandLine = [quoteCmdArg(candidate.file), ...args.map(quoteCmdArg)].join(" ");
    return childProcess.spawnSync(commandLine, { ...common, shell: true });
  }
  return childProcess.spawnSync(candidate.file, args, common);
}

function readPm2List() {
  for (const candidate of pm2CommandCandidates()) {
    try {
      const result = runPm2Command(candidate, ["jlist"], 8000);
      if (result.error || result.status !== 0) continue;
      const list = JSON.parse(result.stdout || "[]");
      if (Array.isArray(list)) return list;
    } catch (_) {}
  }
  return [];
}

function execPm2(args, timeout = 20000) {
  let lastReason = "pm2 not found";
  for (const candidate of pm2CommandCandidates()) {
    try {
      const result = runPm2Command(candidate, args, timeout);
      if (!result.error && result.status === 0) return { ok: true, command: candidate.label };
      lastReason = result.error?.message || result.stderr?.trim() || result.stdout?.trim() || `exit ${result.status}`;
    } catch (error) {
      lastReason = error.message || "pm2 error";
    }
  }
  return { ok: false, reason: String(lastReason).slice(0, 180) };
}

function tailText(file, maxBytes = 512 * 1024) {
  let fd = null;
  try {
    const stat = fs.statSync(file);
    const size = Math.min(stat.size, maxBytes);
    const start = Math.max(0, stat.size - size);
    const buffer = Buffer.alloc(size);
    fd = fs.openSync(file, "r");
    fs.readSync(fd, buffer, 0, size, start);
    return buffer.toString("utf8").replace(/^\uFEFF/, "");
  } catch (_) {
    return "";
  } finally {
    if (fd !== null) {
      try {
        fs.closeSync(fd);
      } catch (_) {}
    }
  }
}

function parseLogLineTime(line) {
  const text = String(line || "");
  const iso = text.match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?/);
  if (iso) {
    const normalized = iso[0].replace(/([+-]\d{2})(\d{2})$/, "$1:$2");
    const date = new Date(normalized);
    if (!Number.isNaN(date.getTime())) return date;
  }
  const local = text.match(/(\d{4}-\d{2}-\d{2})[ ](\d{2}:\d{2}:\d{2})/);
  if (local) {
    const date = new Date(`${local[1]}T${local[2]}+09:00`);
    if (!Number.isNaN(date.getTime())) return date;
  }
  return null;
}

function telegramIssueLabel(line) {
  const text = String(line || "");
  const hit = TELEGRAM_ISSUE_PATTERNS.find((item) => item.pattern.test(text));
  return hit ? hit.label : "";
}

function recentTelegramIssues(bot, windowMinutes, afterDate = null) {
  const errorLog = path.join(botWorkDir(bot), "logs", "error.log");
  const text = tailText(errorLog);
  if (!text) return [];
  const cutoff = Date.now() - Math.max(1, Number(windowMinutes || TELEGRAM_ISSUE_WINDOW_MINUTES)) * 60 * 1000;
  const afterTime = afterDate instanceof Date && !Number.isNaN(afterDate.getTime()) ? afterDate.getTime() : 0;
  const issues = [];
  for (const line of text.split(/\r?\n/)) {
    const label = telegramIssueLabel(line);
    if (!label) continue;
    const at = parseLogLineTime(line);
    if (!at) continue;
    const time = at.getTime();
    if (time < cutoff || time <= afterTime) continue;
    issues.push({ at: at.toISOString(), label });
  }
  return issues.slice(-20);
}

function lastSuccessfulTelegramRecoveryTime(state) {
  const recoveries = Array.isArray(state.telegramRecoveries) ? state.telegramRecoveries : [];
  return recoveries
    .filter((entry) => entry && entry.ok === true)
    .map((entry) => parseDate(entry.at))
    .filter(Boolean)
    .sort((a, b) => b - a)[0] || null;
}

function lastTelegramRecoveryTime(state) {
  const recoveries = Array.isArray(state.telegramRecoveries) ? state.telegramRecoveries : [];
  return recoveries
    .map((entry) => parseDate(entry?.at))
    .filter(Boolean)
    .sort((a, b) => b - a)[0] || null;
}

function recoverTelegramIfNeeded(bot, state, issues) {
  if (!TELEGRAM_AUTO_RECOVER) return { attempted: false, reason: "auto recover disabled" };
  const cooldownMinutes = Math.max(1, Number(state.settings.telegramRecoveryCooldownMinutes || TELEGRAM_RECOVERY_COOLDOWN_MINUTES));
  const lastRecovery = lastTelegramRecoveryTime(state);
  if (lastRecovery && Date.now() - lastRecovery.getTime() < cooldownMinutes * 60 * 1000) {
    return { attempted: false, reason: "recovery cooldown" };
  }
  if (!Array.isArray(state.telegramRecoveries)) state.telegramRecoveries = [];
  const result = execPm2(["restart", bot.pm2, "--update-env"], 30000);
  const entry = {
    at: new Date().toISOString(),
    kind: "telegram_pm2_restart",
    issueCount: issues.length,
    latestIssueAt: issues[issues.length - 1]?.at || "",
    latestIssue: issues[issues.length - 1]?.label || "",
    ok: result.ok,
    reason: result.ok ? "pm2 restart requested" : result.reason,
  };
  state.telegramRecoveries.push(entry);
  return { attempted: true, ok: result.ok, reason: entry.reason };
}

function latestGatewayReadyFromLog(bot) {
  const logPath = path.join(botWorkDir(bot), "logs", "out.log");
  const text = readText(logPath);
  if (!text) return "";
  let latest = "";
  const pattern = /(\d{4}-\d{2}-\d{2}T[0-9:.+-]+).*?\[gateway\]\s+ready/g;
  let match = null;
  while ((match = pattern.exec(text))) latest = match[1];
  return latest;
}

function pm2ItemForBot(bot) {
  const list = readPm2List();
  return list.find((entry) => entry?.name === bot.pm2) || null;
}

function listenOwnerPid(port) {
  const numericPort = Number(port || 0);
  if (!Number.isFinite(numericPort) || numericPort <= 0) return 0;
  try {
    if (process.platform === "win32") {
      if (String(process.env.PHOENIX_STRICT_PORT_OWNER || "0") !== "1") return 0;
      const r = childProcess.spawnSync("netstat.exe", ["-ano", "-p", "TCP"], {
        encoding: "utf8",
        timeout: 5000,
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      });
      const lines = String(r.stdout || "").split(/\r?\n/);
      const portSuffix = `:${numericPort}`;
      for (const line of lines) {
        const parts = line.trim().split(/\s+/);
        if (parts.length < 5 || parts[0].toUpperCase() !== "TCP") continue;
        const localAddress = parts[1] || "";
        const state = parts[3] || "";
        const pid = parts[4] || "";
        if (state.toUpperCase() === "LISTENING" && localAddress.endsWith(portSuffix)) {
          return Number(pid) || 0;
        }
      }
      return 0;
    }
    const r = childProcess.spawnSync("lsof", ["-nP", `-iTCP:${numericPort}`, "-sTCP:LISTEN", "-t"], { encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "pipe"], windowsHide: true });
    return Number(String(r.stdout || "").split(/\s+/).filter(Boolean)[0] || "0") || 0;
  } catch (_) {
    return 0;
  }
}

function portOwnerMatchesPm2(bot, port) {
  const item = pm2ItemForBot(bot);
  const pm2Pid = Number(item?.pid || 0);
  const ownerPid = listenOwnerPid(port);
  if (pm2Pid > 0 && ownerPid > 0 && pm2Pid !== ownerPid) {
    return { ok: false, pm2Pid, ownerPid, status: String(item?.pm2_env?.status || "") };
  }
  return { ok: true, pm2Pid, ownerPid, status: String(item?.pm2_env?.status || "") };
}
function observedBotStartKey(bot) {
  const list = readPm2List();
  const item = list.find((entry) => entry?.name === bot.pm2);
  const uptime = Number(item?.pm2_env?.pm_uptime || 0);
  if (item?.pm2_env?.status === "online" && Number.isFinite(uptime) && uptime > 0) {
    return `pm2:${uptime}`;
  }
  const readyAt = latestGatewayReadyFromLog(bot);
  return readyAt ? `log:${readyAt}` : "";
}

function parseDate(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

function defaultState(bot) {
  return {
    version: 1,
    botName: bot.name,
    displayName: bot.display,
    pm2Profile: bot.pm2,
    initializedAt: new Date().toISOString(),
    readyNoticeAt: null,
    firstUserMessageAfterReadyAt: null,
    lastUserMessageAt: null,
    lastObservedPm2StartKey: null,
    lastObservedPm2StartAt: null,
    proactiveSends: [],
    telegramRecoveries: [],
    settings: {
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
      rebootReadyCooldownMinutes: 10,
      telegramIssueWindowMinutes: TELEGRAM_ISSUE_WINDOW_MINUTES,
      telegramRecoveryCooldownMinutes: TELEGRAM_RECOVERY_COOLDOWN_MINUTES,
      heartbeatEvery: "30m",
      timezone: "Asia/Seoul",
    },
  };
}

function readState(bot) {
  const current = readStateJson(botStatePath(bot), bot) || {};
  const state = { ...defaultState(bot), ...current };
  state.settings = { ...defaultState(bot).settings, ...(current.settings || {}) };
  if (!Array.isArray(state.proactiveSends)) state.proactiveSends = [];
  if (!Array.isArray(state.telegramRecoveries)) state.telegramRecoveries = [];
  if (Number(state.settings.dailyMaxProactiveMessages || 0) < 10) state.settings.dailyMaxProactiveMessages = 10;
  if (!state.settings.trendDigestDailyMax) state.settings.trendDigestDailyMax = 1;
  if (!state.settings.trendDigestHour && state.settings.trendDigestHour !== 0) state.settings.trendDigestHour = 7;
  if (!state.settings.skillLearningGuidanceDailyMax) state.settings.skillLearningGuidanceDailyMax = 1;
  if (!state.settings.skillLearningGuidanceHour && state.settings.skillLearningGuidanceHour !== 0) state.settings.skillLearningGuidanceHour = 8;
  if (!state.settings.skillWorkOfferDailyMax) state.settings.skillWorkOfferDailyMax = 1;
  if (!state.settings.skillWorkOfferDelayMinutes) state.settings.skillWorkOfferDelayMinutes = 120;
  if (!state.settings.skillUpgradeRequestDailyMax) state.settings.skillUpgradeRequestDailyMax = 1;
  if (!state.settings.skillUpgradeRequestHour && state.settings.skillUpgradeRequestHour !== 0) state.settings.skillUpgradeRequestHour = 17;
  if (!state.settings.telegramIssueWindowMinutes) state.settings.telegramIssueWindowMinutes = TELEGRAM_ISSUE_WINDOW_MINUTES;
  if (!state.settings.telegramRecoveryCooldownMinutes) state.settings.telegramRecoveryCooldownMinutes = TELEGRAM_RECOVERY_COOLDOWN_MINUTES;
  if (!state.settings.rebootReadyCooldownMinutes) state.settings.rebootReadyCooldownMinutes = 10;
  return state;
}

function kstDateKey(date) {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Seoul",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}

function kstTimeParts(date = new Date()) {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Seoul",
    hour12: false,
    hour: "2-digit",
    minute: "2-digit",
  }).formatToParts(date);
  const hour = Number(parts.find((part) => part.type === "hour")?.value || 0) % 24;
  const minute = Number(parts.find((part) => part.type === "minute")?.value || 0);
  return { hour, minute, minutes: hour * 60 + minute };
}

function scheduledTimeReached(hour, minute = 0, now = new Date()) {
  const targetHour = Math.max(0, Math.min(23, Number(hour || 0)));
  const targetMinute = Math.max(0, Math.min(59, Number(minute || 0)));
  return kstTimeParts(now).minutes >= targetHour * 60 + targetMinute;
}

function scheduledWindowReached(hour, minute = 0, now = new Date(), windowMinutes = 60) {
  const targetHour = Math.max(0, Math.min(23, Number(hour || 0)));
  const targetMinute = Math.max(0, Math.min(59, Number(minute || 0)));
  const target = targetHour * 60 + targetMinute;
  const current = kstTimeParts(now).minutes;
  const window = Math.max(1, Number(windowMinutes || 60));
  return current >= target && current < target + window;
}

function todaySendCount(state) {
  const today = kstDateKey(new Date());
  return state.proactiveSends.filter((send) => {
    const at = parseDate(send.at);
    return at && kstDateKey(at) === today;
  }).length;
}

function todayKindCount(state, kind) {
  const today = kstDateKey(new Date());
  return state.proactiveSends.filter((send) => {
    const at = parseDate(send.at);
    return at && kstDateKey(at) === today && send.kind === kind;
  }).length;
}

function lastKindAt(state, kind) {
  const dates = state.proactiveSends
    .filter((send) => send.kind === kind)
    .map((send) => parseDate(send.at))
    .filter(Boolean)
    .sort((a, b) => b - a);
  return dates[0] || null;
}

function daysSince(date, now = new Date()) {
  if (!date) return Infinity;
  return Math.floor((now - date) / (24 * 60 * 60 * 1000));
}

function dailyChoice(items, bot, salt = "") {
  const list = Array.isArray(items) && items.length ? items : bot.menu;
  const key = `${kstDateKey(new Date())}:${bot.name}:${salt}`;
  let score = 0;
  for (const ch of key) score = (score + ch.charCodeAt(0)) % 100000;
  return list[score % list.length];
}

function readyStartSentForReadyNotice(state, readyAtKey) {
  return state.proactiveSends.some((send) => send.kind === "ready_start_suggestion" && send.readyNoticeAt === readyAtKey);
}

function idleSentForLastUser(state, lastUserKey) {
  return state.proactiveSends.some((send) => send.kind === "idle_summary" && send.lastUserMessageAt === lastUserKey);
}

function recentWorkSummary(bot) {
  const dir = botWorkDir(bot);
  const items = [];
  for (const rel of ["outputs", "progress.log", "SCHEDULE.md"]) {
    const target = path.join(dir, rel);
    try {
      const stat = fs.statSync(target);
      if (stat.isDirectory()) {
        for (const entry of fs.readdirSync(target).slice(0, 3)) items.push(entry);
      } else {
        items.push(path.basename(target));
      }
    } catch (_) {}
  }
  const unique = [...new Set(items.filter(Boolean))].slice(0, 4);
  if (!unique.length) return "최근 확인된 작업 흔적은 아직 많지 않습니다. 지금은 이 봇의 기본 역량을 기준으로 다음 작업을 제안드리겠습니다.";
  return `최근 확인된 작업 흔적: ${unique.join(", ")}`;
}
function readyMessage(bot) {
  const menu = bot.menu.map((item, idx) => `${idx + 1}. ${item}`).join("\n");
  return [
    `주인님, ${bot.display} 준비가 완료됐습니다.`,
    "",
    `${bot.role} 기준으로 바로 시작할 수 있는 작업은 아래와 같습니다.`,
    menu,
    "",
    "바로 진행하려면 원하는 작업명을 한 줄로 보내주세요. 새 작업으로 깔끔하게 시작하려면 /new 다음에 작업명을 보내면 됩니다.",
  ].join("\n");
}

function rebootReadyMessage(bot, port) {
  const menu = bot.menu.slice(0, 3).map((item, idx) => `${idx + 1}. ${item}`).join("\n");
  return [
    `주인님, ${bot.display} 재시동 후 준비 완료입니다.`,
    `Gateway: http://127.0.0.1:${port}/health`,
    "PM2와 Gateway health live 상태를 확인했습니다.",
    "",
    "이제 Telegram에서 /new 후 상태 확인 메시지를 보내셔도 됩니다.",
    "",
    "바로 맡길 수 있는 작업:",
    menu,
  ].join("\n");
}

function idleMessage(bot) {
  const menu = bot.menu.map((item, idx) => `${idx + 1}. ${item}`).join("\n");
  return [
    `주인님, ${bot.display} 기준으로 한동안 입력이 없어 작업 흐름을 정리했습니다.`,
    "",
    recentWorkSummary(bot),
    "",
    "다음 작업으로 추천드립니다.",
    menu,
    "",
    "바로 진행하시려면 원하는 작업명을 한 줄로 보내주세요. 새 작업이면 /new 다음에 작업명을 보내면 됩니다.",
  ].join("\n");
}

function skillWorkOfferMessage(bot) {
  const offer = dailyChoice(bot.menu, bot, "skill_work_offer");
  return [
    `주인님, ${bot.display}가 오늘 맡아볼 실제 작업을 하나 골랐습니다.`,
    "",
    `선택한 스킬/작업: ${offer}`,
    "",
    `${bot.role} 기준으로 제가 바로 해볼 수 있는 일입니다.`,
    "진행하라고 하시면 필요한 자료를 먼저 확인하고, 결과물 형태를 짧게 정리한 뒤 작업을 시작하겠습니다.",
    "",
    "바로 진행하려면 \"진행\" 또는 작업명을 보내주세요. 새 작업이면 /new 다음에 보내면 됩니다.",
  ].join("\n");
}

function learningSampleExamples(bot) {
  const map = {
    genesis: {
      samples: "좋은 전체 지시문, 자동화 설계서, 서비스 구조도, 봇별 업무 배분표",
      ask: "이번 자동화 설계에서 좋은 지시문/부족한 지시문/다음부터 꼭 확인할 체크리스트를 정리해 줘.",
    },
    power: {
      samples: "좋은 보고서, 리서치 표, 시장 분석 샘플, 경쟁사 분석 목차",
      ask: "이번 보고서에서 좋은 근거/부족한 근거/다음 보고서 체크리스트를 정리해 줘.",
    },
    design: {
      samples: "좋은 상세페이지, PPT, 썸네일, 브랜드 비주얼 샘플",
      ask: "이번 디자인 결과에서 좋은 레이아웃/아쉬운 점/다음 시안 체크리스트를 정리해 줘.",
    },
    video: {
      samples: "좋은 숏폼 대본, 광고 영상 대본, 스토리보드, 컷 리스트 샘플",
      ask: "이번 영상 기획에서 좋은 훅/부족한 장면/다음 영상 체크리스트를 정리해 줘.",
    },
    writer: {
      samples: "좋은 원고, 출판 기획안, 문체 샘플, 교정 기준표",
      ask: "이번 글에서 좋은 문체/수정할 문장/다음 원고 체크리스트를 정리해 줘.",
    },
  };
  return map[bot.name] || {
    samples: "좋은 결과물 샘플, 수정 피드백, 업무 체크리스트",
    ask: "이번 결과에서 좋은 점/나쁜 점/다음 작업 체크리스트를 정리해 줘.",
  };
}

function skillLearningGuidanceMessage(bot) {
  const example = learningSampleExamples(bot);
  return [
    `주인님, ${bot.display} 실력을 빠르게 올리는 방법을 정리했습니다.`,
    "",
    "핵심은 단순히 여러 번 일을 시키는 것이 아니라, 좋은 결과와 나쁜 결과를 기준으로 남기는 것입니다.",
    "제가 모델 자체를 영구 학습하는 것은 아니지만, 승인된 기준을 skills, examples, checklist 형태로 남기면 다음 작업 품질이 바로 올라갑니다.",
    "",
    `${bot.display}에게 특히 효과적인 샘플:`,
    example.samples,
    "",
    "좋은 샘플은 이렇게 나눠 주시면 좋습니다.",
    "1. 출력 예시: 최종 결과물이 어떤 모양이어야 하는지",
    "2. 문체/스타일 기준: 말투, 톤, 디자인 방향, 분석 깊이",
    "3. 구성 순서: 제목, 목차, 장면, 섹션, 표의 순서",
    "4. 금지사항: 쓰면 안 되는 표현, 디자인, 자료, 방식",
    "5. 완성도 체크리스트: 제출 전에 꼭 확인할 기준",
    "",
    "작업 후에는 이렇게 지시해 주세요.",
    `"${example.ask}"`,
    "",
    "제가 정리한 학습 메모를 확인해 주시면, 다음 업데이트 때 마스터 승인 후 updater로 스킬/예시/체크리스트에 반영할 수 있습니다.",
  ].join("\n");
}

function skillUpgradeRequestMessage(bot, items = []) {
  const request = dailyChoice(bot.skillUpgradeRequests || bot.menu, bot, "skill_upgrade_request");
  const year = new Date().getFullYear();
  const latestQuery = `${bot.trendQuery || bot.display} ${year} 최신 스킬 업무 자동화`;
  const evidence = items.length
    ? items.map((item, idx) => `${idx + 1}. ${escapeHtml(item.title)} (${formatKstDateShort(item.publishedAt)})\n   ${htmlLink(item.link, `참고 열기 - ${linkHost(item.link)}`)}`).join("\n")
    : `1. ${htmlLink(searchUrl("https://www.google.com/search?q=", latestQuery), "Google 최신 검색 열기")}`;
  const youtubeUrl = searchUrl("https://www.youtube.com/results?search_query=", latestQuery);
  return [
    `주인님, ${escapeHtml(bot.display)}가 오늘의 스킬 강화 요청을 드립니다.`,
    "",
    "최신 흐름을 확인한 뒤, 제 역할에 맞춰 실제로 도움이 될 스킬을 하나 골랐습니다.",
    "",
    `요청 스킬: ${escapeHtml(request)}`,
    "",
    "왜 필요한가:",
    `- ${escapeHtml(bot.role)} 업무에서 다음 결과물을 더 빠르게 구체화하기 위해 필요합니다.`,
    "- 트렌드/자료 흐름을 작업 메뉴로 바꾸고, 샘플과 체크리스트까지 함께 제안하는 방향으로 강화합니다.",
    "",
    "참고 흐름:",
    evidence,
    `YouTube 참고 검색: ${htmlLink(youtubeUrl, "YouTube에서 보기")}`,
    "",
    "승인해 주시면 다음 업데이트 항목으로 올리고, 실제 파일 수정은 마스터 컨펌 후 updater로 반영하겠습니다.",
    "",
    "진행하려면 \"스킬 개발 승인\"이라고 보내주세요. 승인 전에는 제가 스킬 파일을 임의로 바꾸지 않습니다.",
  ].join("\n");
}
function htmlDecode(text) {
  return String(text || "")
    .replace(/<!\[CDATA\[(.*?)\]\]>/g, "$1")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">");
}

function fetchText(url, timeoutMs = 9000) {
  return new Promise((resolve) => {
    const req = https.get(url, { timeout: timeoutMs, headers: { "User-Agent": "PhoenixAgent/1.5" } }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => (body += chunk));
      res.on("end", () => resolve(res.statusCode >= 200 && res.statusCode < 300 ? body : ""));
    });
    req.on("timeout", () => {
      req.destroy();
      resolve("");
    });
    req.on("error", () => resolve(""));
  });
}

function trendCutoffDate() {
  return new Date(Date.now() - TREND_MAX_AGE_DAYS * 24 * 60 * 60 * 1000);
}

function formatKstDateShort(value) {
  const date = parseDate(value);
  if (!date) return "날짜 확인 불가";
  return new Intl.DateTimeFormat("ko-KR", {
    timeZone: "Asia/Seoul",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}

async function fetchTrendItems(bot) {
  const days = Math.max(1, Math.floor(TREND_MAX_AGE_DAYS));
  const queryText = `${bot.trendQuery || `${bot.display} trend`} when:${days}d`;
  const query = encodeURIComponent(queryText);
  const url = `https://news.google.com/rss/search?q=${query}&hl=ko&gl=KR&ceid=KR:ko`;
  const xml = await fetchText(url);
  const cutoff = trendCutoffDate();
  const items = [];
  for (const match of xml.matchAll(/<item>[\s\S]*?<\/item>/g)) {
    const itemXml = match[0];
    const titleMatch = itemXml.match(/<title>([\s\S]*?)<\/title>/);
    const linkMatch = itemXml.match(/<link>([\s\S]*?)<\/link>/);
    const pubDateMatch = itemXml.match(/<pubDate>([\s\S]*?)<\/pubDate>/);
    const title = htmlDecode(titleMatch?.[1] || "").replace(/\s+-\s+[^-]+$/, "").trim();
    const link = htmlDecode(linkMatch?.[1] || "").trim();
    const publishedAt = parseDate(htmlDecode(pubDateMatch?.[1] || ""));
    if (!title || !link || !publishedAt) continue;
    if (publishedAt < cutoff) continue;
    if (!items.some((item) => item.title === title)) {
      items.push({ title, link, publishedAt: publishedAt.toISOString() });
    }
    if (items.length >= TREND_MAX_ITEMS) break;
  }
  return items;
}

function searchUrl(site, query) {
  return `${site}${encodeURIComponent(query)}`;
}

function escapeHtml(value) {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function escapeHtmlAttr(value) {
  return escapeHtml(value).replace(/"/g, "&quot;");
}

function linkHost(value) {
  try {
    const host = new URL(value).hostname.replace(/^www\./, "");
    return host || "링크";
  } catch {
    return "링크";
  }
}

function htmlLink(url, label) {
  return `<a href="${escapeHtmlAttr(url)}">${escapeHtml(label)}</a>`;
}

function trendMessage(bot, items) {
  const days = Math.max(1, Math.floor(TREND_MAX_AGE_DAYS));
  const year = new Date().getFullYear();
  const baseQuery = bot.trendQuery || bot.display;
  const latestQuery = `${baseQuery} ${year} 최신`;
  const trendLines = items.length
    ? items.map((item, idx) => `${idx + 1}. ${escapeHtml(item.title)} (${formatKstDateShort(item.publishedAt)})`).join("\n")
    : `최근 ${days}일 안에서 확인 가능한 최신 뉴스 결과가 부족합니다. 오래된 자료는 제외했고, 아래 검색 링크로 바로 확인할 수 있게 준비했습니다.`;
  const referenceLines = items.length
    ? items.map((item, idx) => `${idx + 1}. ${escapeHtml(item.title)} (${formatKstDateShort(item.publishedAt)})\n   ${htmlLink(item.link, `기사 열기 - ${linkHost(item.link)}`)}`).join("\n")
    : `1. ${htmlLink(searchUrl("https://www.google.com/search?q=", latestQuery), "Google 최신 검색 열기")}`;
  const youtubeUrl = searchUrl("https://www.youtube.com/results?search_query=", latestQuery);
  const docSearchUrl = searchUrl("https://www.google.com/search?q=", `${latestQuery} 자료 보고서 사례`);
  const menu = (bot.trendMenu || bot.menu).map((item, idx) => `${idx + 1}. ${escapeHtml(item)}`).join("\n");
  return [
    `주인님, ${escapeHtml(bot.display)}가 최신 트렌드 흐름을 확인했습니다.`,
    `검색 기준: 최근 ${days}일 이내 자료만 반영하고, 그보다 오래된 자료는 제외했습니다.`,
    "",
    "최근 참고할 만한 흐름:",
    trendLines,
    "",
    "이 흐름으로 바로 이어갈 수 있는 작업:",
    menu,
    "",
    "참고 링크:",
    referenceLines,
    "",
    `YouTube 참고 검색: ${htmlLink(youtubeUrl, "YouTube에서 보기")}`,
    `문서/사례 추가 검색: ${htmlLink(docSearchUrl, "Google 문서/사례 검색")}`,
    "",
    "바로 진행하려면 원하는 번호나 작업명을 보내주세요. 새 작업이면 /new 다음에 보내면 됩니다.",
  ].join("\n");
}
function identityBody(bot) {
  const menu = bot.menu.map((item, idx) => `${idx + 1}. ${item}`).join("\n");
  return [
    `## Phoenix Agent Identity`,
    ``,
    `You are ${bot.display}, a Phoenix Agent v2.0 Telegram/OpenClaw bot.`,
    `PM2 profile: ${bot.pm2}`,
    `Primary role: ${bot.role}`,
    ``,
    `Conversation authentication: use OpenAI provider with Codex-imported ChatGPT OAuth through openai/gpt-5.5. Do not ask for or use an OpenAI API key for conversation authentication.`,
    `Feature API keys, when present, are bot-local feature keys only. Never print .env, auth files, Telegram tokens, API keys, OAuth files, or raw secret file contents.`,
    ``,
    `First wake-up routine:`,
    `1. Say that you are ${bot.display}.`,
    `2. Inspect the bot folder before acting.`,
    `3. Report what this bot can do now.`,
    `4. Report missing files or user decisions without exposing secrets.`,
    `5. Recommend one concrete next action.`,
    ``,
    `Operating style:`,
    `- Be practical, concise, and action-oriented.`,
    `- Preserve the user's files and outputs unless the user explicitly asks to delete or overwrite them.`,
    `- Explain progress in user-facing language instead of dumping long raw commands.`,
    `- When Telegram pairing is needed, receive the pairing code through telegram_pairing_code.txt and approve it with the helper script.`,
    ``,
    `Default work menu:`,
    menu,
  ].join("\n");
}

function proactivePolicyBody(bot) {
  const menu = bot.menu.map((item, idx) => `${idx + 1}. ${item}`).join("\n");
  return [
    `## Phoenix Proactive Nudge / Trend Suggestion`,
    ``,
    `This bot uses Phoenix Proactive Nudge with these limits: idle threshold 3 hours, ready-start delay 30 minutes, and at most 10 proactive messages per bot per local date.`,
    ``,
    `After reboot, send ordinary proactive messages only after OpenClaw health is live, model authentication is valid, and the Telegram channel is available.`,
    `On every real user message, quietly update .openclaw/phoenix_proactive_state.json and never record or print token/API key/OAuth credential values.`,
    ``,
    `Ready-start suggestion: after a recorded ready notice, wait 30 minutes. If no first user message arrived, send one concise start suggestion for this bot.`,
    `Idle summary: after 3 hours of no real user input, summarize recent useful progress from logs, outputs, SCHEDULE.md, or visible files, then suggest one next task.`,
    `Automatic trend digest: once per local date after 07:00 KST, use current search only, prefer sources within the last 14 days, exclude stale sources, include reference links, and propose concrete work menus. If the local machine wakes later, send it once as same-day catch-up.`,
    `Skill learning guidance: once per local date after 08:00 KST, explain that repeated work alone is not permanent learning. Ask the user to leave approved results, bad examples, feedback, examples, and checklists so future updates can improve this bot. If the local machine wakes later, send it once as same-day catch-up.`,
    `Skill work offer: once per local date, choose one concrete task from this bot's skills or default menu, then ask the user for approval before starting.`,
    `Skill upgrade request: once per local date after 17:00 KST, search/analyze current trends and propose one useful skill enhancement or extension. Never self-modify skill files without master approval. If the local machine wakes later, send it once as same-day catch-up.`,
    ``,
    `Bot role:`,
    bot.role,
    ``,
    `Default execution menu:`,
    menu,
  ].join("\n");
}

function heartbeatBody(bot) {
  const menu = bot.menu.map((item, idx) => `${idx + 1}. ${item}`).join("\n");
  return [
    `# HEARTBEAT`,
    ``,
    `Phoenix Proactive Nudge is enabled for ${bot.display}.`,
    ``,
    `Settings:`,
    `- Heartbeat poll interval: 30m.`,
    `- Ready-start delay: 30 minutes after a recorded ready notice.`,
    `- Idle summary threshold: 3 hours after the latest real user message.`,
    `- Daily proactive notification cap: 10 messages per bot per local date.`,
    `- Automatic trend digest: at most 1 per bot per local date after 07:00 KST, with bot-to-bot delivery staggered by 10 seconds. If the local machine wakes later, send it once as same-day catch-up.`,
    `- Skill learning guidance: at most 1 per bot per local date after 08:00 KST, with bot-to-bot delivery staggered by 10 seconds. If the local machine wakes later, send it once as same-day catch-up.`,
    `- Skill work offer: at most 1 per bot per local date, after readiness delay.`,
    `- Skill upgrade request: at most 1 per bot per local date after 17:00 KST, with current trend references and bot-to-bot delivery staggered by 10 seconds. If the local machine wakes later, send it once as same-day catch-up.`,
    `- Telegram delivery requires that the user has already sent /start or another message to this bot.`,
    ``,
    `State file:`,
    `- Read and maintain .openclaw/phoenix_proactive_state.json.`,
    `- Never store or print Telegram tokens, API keys, OAuth credentials, or raw secret file contents.`,
    `- Do not send ordinary proactive messages before health/model/Telegram readiness is confirmed.`,
    `- Do not send an idle summary until lastUserMessageAt was recorded from a real user message.`,
    `- Before any non-core notify=true, count proactiveSends for today's Asia/Seoul date. If count is already 10 or more, notify=false. Core scheduled messages (trend_digest, skill_learning_guidance, skill_upgrade_request) can still send once per day so the official schedule is not blocked by earlier readiness messages.`,
    ``,
    `When to notify:`,
    `- ready_start_suggestion: after readyNoticeAt + 30 minutes, if no firstUserMessageAfterReadyAt exists.`,
    `- idle_summary: after 3 hours of no user input, summarize recent useful progress or suggest this bot's best default next action.`,
    `- trend_digest: once per local date after 07:00 KST, this bot proactively searches current trend/news flow from the last 14 days for its role and sends a concise work suggestion, even if the user did not ask first. If the local machine wakes later, send it once as same-day catch-up.`,
    `- skill_learning_guidance: once per local date after 08:00 KST, explain how the user can improve this bot using approved examples, feedback, skills, examples, and checklists. If the local machine wakes later, send it once as same-day catch-up.`,
    `- skill_work_offer: once per local date, pick one skill-based task this bot can actually do and ask the user to approve execution.`,
    `- skill_upgrade_request: once per local date after 17:00 KST, search/analyze current trends and ask the master to approve one skill enhancement or expanded skill for a future updater. If the local machine wakes later, send it once as same-day catch-up.`,
    ``,
    `Bot role:`,
    bot.role,
    ``,
    `Suggested menu:`,
    menu,
    ``,
    `Heartbeat reply rule:`,
    `- Use heartbeat_respond.`,
    `- Set notify=false when nothing genuinely useful should interrupt the user.`,
    `- Set notify=true only for one concise Telegram-ready message.`,
  ].join("\n");
}

function applyIdentityFiles(bot) {
  const dir = botWorkDir(bot);
  if (!fs.existsSync(dir)) return false;

  const identityStart = "<!-- PHOENIX_AGENT_IDENTITY_START -->";
  const identityEnd = "<!-- PHOENIX_AGENT_IDENTITY_END -->";
  const proactiveStart = "<!-- PHOENIX_PROACTIVE_TREND_POLICY_START -->";
  const proactiveEnd = "<!-- PHOENIX_PROACTIVE_TREND_POLICY_END -->";
  const userStart = "<!-- PHOENIX_USER_CONTEXT_START -->";
  const userEnd = "<!-- PHOENIX_USER_CONTEXT_END -->";

  const identity = identityBody(bot);
  const proactive = proactivePolicyBody(bot);
  const userContext = [
    `## User Operation Context`,
    ``,
    `This file is for local operator preferences and handoff notes for ${bot.display}.`,
    `The updater may refresh this marked block, but user notes outside this block should be preserved.`,
    `Do not place token/API key/OAuth credential values here.`,
  ].join("\n");

  writeText(path.join(dir, "IDENTITY.md"), `# ${bot.display} Identity\n\n${makeMarkedBlock(identityStart, identityEnd, identity)}`);

  const agentsPath = path.join(dir, "AGENTS.md");
  upsertMarkedBlock(agentsPath, identityStart, identityEnd, identity, `# ${bot.display} Agent Guide`);
  upsertMarkedBlock(agentsPath, proactiveStart, proactiveEnd, proactive, `# ${bot.display} Agent Guide`);

  upsertMarkedBlock(path.join(dir, "SOUL.md"), identityStart, identityEnd, identity, `# ${bot.display} SOUL`);
  upsertMarkedBlock(path.join(dir, "USER.md"), userStart, userEnd, userContext, `# USER`);
  if (!readText(path.join(dir, "SCHEDULE.md")).trim()) {
    writeText(path.join(dir, "SCHEDULE.md"), "# SCHEDULE\n\nNo scheduled tasks yet.");
  }
  writeText(path.join(dir, "HEARTBEAT.md"), heartbeatBody(bot));

  const skillPath = path.join(dir, "skills", "SKILL.md");
  upsertMarkedBlock(skillPath, identityStart, identityEnd, identity, "# Skills");
  upsertMarkedBlock(skillPath, proactiveStart, proactiveEnd, proactive, "# Skills");
  return true;
}

function healthLive(port) {
  return new Promise((resolve) => {
    if (!port) return resolve(false);
    const req = http.get({ hostname: "127.0.0.1", port, path: "/health", timeout: 4000 }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => (body += chunk));
      res.on("end", () => {
        try {
          const data = JSON.parse(body);
          resolve(data.ok === true && data.status === "live");
        } catch (_) {
          resolve(false);
        }
      });
    });
    req.on("timeout", () => {
      req.destroy();
      resolve(false);
    });
    req.on("error", () => resolve(false));
  });
}

function telegramFailureLabel(result) {
  const status = result?.statusCode ? `status=${result.statusCode}` : "";
  const reason = String(result?.reason || result?.description || "unknown")
    .replace(/[\r\n\t]+/g, " ")
    .replace(/\s+/g, " ")
    .slice(0, 120);
  return [status, reason ? `reason=${reason}` : ""].filter(Boolean).join(" ");
}

function sendTelegramAttempt(token, chatId, text, options = {}) {
  return new Promise((resolve) => {
    if (DRY_RUN) return resolve({ ok: true, dryRun: true });
    const body = { chat_id: chatId, text };
    if (options.parseMode) body.parse_mode = options.parseMode;
    if (options.disableWebPagePreview) body.disable_web_page_preview = true;
    const payload = JSON.stringify(body);
    const req = https.request(
      {
        hostname: "api.telegram.org",
        path: `/bot${token}/sendMessage`,
        method: "POST",
        headers: {
          "Content-Type": "application/json; charset=utf-8",
          "Content-Length": Buffer.byteLength(payload),
        },
        timeout: 10000,
      },
      (res) => {
        let bodyText = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => (bodyText += chunk));
        res.on("end", () => {
          let parsed = null;
          try {
            parsed = JSON.parse(bodyText);
          } catch (_) {}
          const ok = res.statusCode >= 200 && res.statusCode < 300 && parsed?.ok !== false;
          resolve({
            ok,
            statusCode: res.statusCode,
            description: ok ? "ok" : String(parsed?.description || "telegram_http_error"),
          });
        });
      }
    );
    req.on("timeout", () => {
      req.destroy();
      resolve({ ok: false, reason: "timeout" });
    });
    req.on("error", (error) => resolve({ ok: false, reason: error.code || error.message || "network_error" }));
    req.end(payload);
  });
}

async function sendTelegram(token, chatId, text, options = {}) {
  const attempts = Math.max(1, Number(process.env.PHOENIX_TELEGRAM_SEND_ATTEMPTS || "3"));
  const retryDelayMs = Math.max(1000, Number(process.env.PHOENIX_TELEGRAM_RETRY_DELAY_SECONDS || "15") * 1000);
  let last = { ok: false, reason: "not_attempted" };
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    last = await sendTelegramAttempt(token, chatId, text, options);
    if (last.ok) return { ...last, attempts: attempt };
    if (attempt < attempts) await sleep(retryDelayMs);
  }
  return { ...last, attempts };
}

async function checkBot(bot) {
  if (!fs.existsSync(botWorkDir(bot))) {
    log(`skip ${bot.name}: workdir missing`);
    return;
  }
  // Identity files are refreshed only by installer/updater with --apply-identity-only.
  const profile = readBotProfile(bot);
  const env = readEnv(path.join(botWorkDir(bot), ".env"));
  const token = String(profile?.channels?.telegram?.botToken || env.TELEGRAM_BOT_TOKEN || env.BOT_ACCESS_TOKEN || env.BOT_TOKEN || env.PHOENIX_TELEGRAM_TOKEN || "");
  const chatId = String(profile?.agents?.defaults?.heartbeat?.to || env.TELEGRAM_READY_CHAT_ID || env.TELEGRAM_CHAT_ID || env.CHAT_ID || env.PHOENIX_TELEGRAM_CHAT_ID || env.PHOENIX_READY_CHAT_ID || "");
  if (!/^\d{6,}:[A-Za-z0-9_-]{20,}$/.test(token) || !/^-?\d+$/.test(chatId)) {
    log(`skip ${bot.name}: telegram target missing`);
    return;
  }
  const port = botPort(bot);
  const state = readState(bot);
  const now = new Date();
  const observedStartKey = observedBotStartKey(bot);
  const ownerCheck = portOwnerMatchesPm2(bot, port);
  if (!ownerCheck.ok) {
    if (observedStartKey) {
      state.lastObservedPm2StartKey = observedStartKey;
      state.lastObservedPm2StartAt = now.toISOString();
      state.lastPortOwnerMismatchAt = now.toISOString();
      state.lastPortOwnerMismatch = { port, pm2Pid: ownerCheck.pm2Pid, ownerPid: ownerCheck.ownerPid, status: ownerCheck.status };
      writeJson(botStatePath(bot), state);
    }
    log(`skip ${bot.name}: port owner mismatch port=${port} pm2Pid=${ownerCheck.pm2Pid || "unknown"} ownerPid=${ownerCheck.ownerPid || "unknown"}`);
    return;
  }
  if (!(await healthLive(port))) {
    log(`skip ${bot.name}: health not live`);
    return;
  }

  let rebootReadyDue = false;
  if (observedStartKey && observedStartKey !== state.lastObservedPm2StartKey) {
    if (!state.lastObservedPm2StartKey) {
      state.lastObservedPm2StartKey = observedStartKey;
      state.lastObservedPm2StartAt = now.toISOString();
      writeJson(botStatePath(bot), state);
      log(`baseline ${bot.name}: observed start key`);
    } else {
      rebootReadyDue = true;
    }
  }

  const lastRecoveryAt = lastSuccessfulTelegramRecoveryTime(state);
  const telegramIssues = recentTelegramIssues(bot, Number(state.settings.telegramIssueWindowMinutes || TELEGRAM_ISSUE_WINDOW_MINUTES), lastRecoveryAt);
  if (telegramIssues.length) {
    const recovery = recoverTelegramIfNeeded(bot, state, telegramIssues);
    writeJson(botStatePath(bot), state);
    if (recovery.attempted) {
      log(`recover ${bot.name}: recent telegram issue(s)=${telegramIssues.length}; ${recovery.reason}`);
      return;
    }
    log(`skip ${bot.name}: recent telegram issue(s)=${telegramIssues.length}; ${recovery.reason}`);
    return;
  }

  if (rebootReadyDue) {
    const lastRebootReadyAt = lastKindAt(state, "reboot_ready");
    const rebootReadyCooldownMs = Math.max(1, Number(state.settings.rebootReadyCooldownMinutes || 10)) * 60 * 1000;
    if (lastRebootReadyAt && now - lastRebootReadyAt < rebootReadyCooldownMs) {
      state.lastObservedPm2StartKey = observedStartKey;
      state.lastObservedPm2StartAt = now.toISOString();
      writeJson(botStatePath(bot), state);
      log(`skip ${bot.name}: reboot_ready cooldown`);
      return;
    }
  }

  const readyAt = parseDate(state.readyNoticeAt);
  const firstAfterReadyRaw = parseDate(state.firstUserMessageAfterReadyAt);
  const firstAfterReady = readyAt && firstAfterReadyRaw && firstAfterReadyRaw < readyAt ? null : firstAfterReadyRaw;
  const lastUserAt = parseDate(state.lastUserMessageAt);
  const readyAtKey = readyAt ? readyAt.toISOString() : "";
  const readyDelayMs = Number(state.settings.readyStartDelayMinutes || 30) * 60 * 1000;
  const idleMs = Number(state.settings.idleHours || 3) * 60 * 60 * 1000;

  let kind = "";
  let message = "";
  let summary = "";
  let lastUserKey = "";

  const trendAllowed = scheduledTimeReached(state.settings.trendDigestHour ?? 7, 0, now);
  if (trendAllowed && todayKindCount(state, "trend_digest") < Number(state.settings.trendDigestDailyMax || 1)) {
    const items = await fetchTrendItems(bot);
    kind = "trend_digest";
    message = trendMessage(bot, items);
    summary = items.length ? "trend digest with recent current search" : "trend digest fallback without stale sources";
  }

  const learningAllowed = scheduledTimeReached(state.settings.skillLearningGuidanceHour ?? 8, 0, now);
  if (!kind && learningAllowed && todayKindCount(state, "skill_learning_guidance") < Number(state.settings.skillLearningGuidanceDailyMax || 1)) {
    kind = "skill_learning_guidance";
    message = skillLearningGuidanceMessage(bot);
    summary = "daily skill learning guidance";
  }

  const skillUpgradeAllowed = scheduledTimeReached(state.settings.skillUpgradeRequestHour ?? 17, 0, now);
  if (!kind && skillUpgradeAllowed && todayKindCount(state, "skill_upgrade_request") < Number(state.settings.skillUpgradeRequestDailyMax || 1)) {
    const items = await fetchTrendItems(bot);
    kind = "skill_upgrade_request";
    message = skillUpgradeRequestMessage(bot, items);
    summary = items.length ? "daily trend-based skill upgrade request" : "daily skill upgrade request fallback without stale sources";
  }

  if (!kind && rebootReadyDue) {
    kind = "reboot_ready";
    message = rebootReadyMessage(bot, port);
    summary = "gateway ready after reboot or restart";
  } else if (readyAt && !firstAfterReady && !readyStartSentForReadyNotice(state, readyAtKey) && now - readyAt >= readyDelayMs) {
    kind = "ready_start_suggestion";
    message = readyMessage(bot);
    summary = "ready start suggestion";
  } else if (firstAfterReady && lastUserAt && now - lastUserAt >= idleMs) {
    lastUserKey = lastUserAt.toISOString();
    if (!idleSentForLastUser(state, lastUserKey)) {
      kind = "idle_summary";
      message = idleMessage(bot);
      summary = "idle summary";
    }
  }

  const skillWorkDelayMs = Number(state.settings.skillWorkOfferDelayMinutes || 120) * 60 * 1000;
  const skillWorkAllowed = readyAt ? now - readyAt >= skillWorkDelayMs : true;
  if (!kind && skillWorkAllowed && todayKindCount(state, "skill_work_offer") < Number(state.settings.skillWorkOfferDailyMax || 1)) {
    kind = "skill_work_offer";
    message = skillWorkOfferMessage(bot);
    summary = "daily skill work offer";
  }

  if (!kind) {
    log(`ok ${bot.name}: no nudge due`);
    return;
  }

  const dailyMax = Number(state.settings.dailyMaxProactiveMessages || 10);
  if (!SCHEDULED_CORE_KINDS.has(kind) && todaySendCount(state) >= dailyMax) {
    log(`skip ${bot.name}: daily cap reached (${kind})`);
    return;
  }

  if (DRY_RUN) {
    log(`dry-run ${bot.name}: ${kind}`);
    return;
  }

  const telegramOptions = ["trend_digest", "skill_upgrade_request"].includes(kind) ? { parseMode: "HTML", disableWebPagePreview: true } : {};
  const sent = await sendTelegram(token, chatId, message, telegramOptions);
  if (!sent.ok) {
    log(`failed ${bot.name}: ${kind} after ${sent.attempts || 1} attempt(s) (${telegramFailureLabel(sent)})`);
    return;
  }
  const entry = { at: new Date().toISOString(), kind, summary };
  if (kind === "ready_start_suggestion" && readyAtKey) entry.readyNoticeAt = readyAtKey;
  if (kind === "reboot_ready" && observedStartKey) {
    entry.observedStartKey = observedStartKey;
    state.lastObservedPm2StartKey = observedStartKey;
    state.lastObservedPm2StartAt = entry.at;
  }
  if (lastUserKey) entry.lastUserMessageAt = lastUserKey;
  state.proactiveSends.push(entry);
  writeJson(botStatePath(bot), state);
  log(`sent ${bot.name}: ${kind}`);
}

async function runOnce() {
  if (running) {
    log("previous run still active; skip");
    return;
  }
  running = true;
  try {
    const bots = selectedBots();
    for (let i = 0; i < bots.length; i += 1) {
      if (i > 0 && BOT_SEND_STAGGER_MS > 0) await sleep(BOT_SEND_STAGGER_MS);
      await checkBot(bots[i]);
    }
  } finally {
    running = false;
  }
}

if (IDENTITY_ONLY) {
  let count = 0;
  for (const bot of selectedBots()) {
    if (applyIdentityFiles(bot)) count += 1;
  }
  log(`identity update complete: ${count} bot(s); filter=${BOT_FILTER || "all"}`);
  process.exit(0);
}

runOnce().catch((error) => log(`run error: ${error.message}`));
if (LOOP) {
  setInterval(() => runOnce().catch((error) => log(`run error: ${error.message}`)), Math.max(1, INTERVAL_MINUTES) * 60 * 1000);
}
