Phoenix Agent v1.9_260702
==========================

Package date: 260702
Release: Phoenix Agent v1.9

Package layout:
- cleaner: delete all bots or selected bot safely, with per-bot outputs backup question.
- installer: clean Phoenix Agent v1.9 bot installation tools and guide files.
- updater: existing v1.6/v1.7/v1.8 installation update tools and guide files.
- 1. 인증키_API 키 모음: blank Telegram and optional image/video input templates.
- 2. 인증키_에이전트 모델 인증 키 모음: blank Gemini/local LLM model-auth input templates.
- Phoenix_Agent_v1.9_새기능_봇별_활용설명서.html: user-facing v1.9 feature guide.
- Phoenix_Agent_v1.9_기능소개_슬라이드.html: user-facing v1.9 slide guide.
- Phoenix_Agent_v1.9_PCS_PTS_스킬업_운영가이드.html: user-facing PCS/PTS skill-up guide for users, bots, and Codex application.

Operator policy:
- No docs/ folder is kept in this user package root.
- PCS/PTS detailed operator documents are stored separately under 02_operator_review_docs.
- User-facing titles and feature descriptions use v1.9.
- v1.6/v1.7/v1.8 expressions are allowed only for updater migration explanations.
- Full packages only. No update_only zip is produced.
- Existing normal v1.6/v1.7/v1.8 users run the Phoenix Agent v1.9 updater only.
- v1.5 users should use the cleaner and then install v1.9 cleanly.

Core inherited features:
- Five Telegram/OpenClaw bots: Genesis, Power, Design, Video, Writer.
- OpenAI/Codex default auth, ChatGPT browser re-auth, Gemini selected auth, and local/open-source LLM fallback candidates.
- Telegram token/chat id file-based input.
- Ready notice and proactive message schedule.
- Outputs/logs preservation during updater.
- Secrets are never printed.

Phoenix Agent v1.9 PCS/PTS:
- PCS (Phoenix Copy Skill): screen-and-workflow based skill-up. It turns demonstrated workflows, screen sequences, click/input order, tool operations, upload/download paths, and repeated business processes into reusable skill candidates.
- PTS (Phoenix Talk Skill): example-and-standard based skill-up. It turns strong samples, reports, scripts, prompts, manuscripts, tone/style rules, and quality criteria into reusable skill candidates.
- Good candidates must separate skills, examples, and checklist updates, and must state target bot, skill name, inputs, output format, success criteria, failure cases, prohibited behavior, and sensitive-information cautions.
- Bots can propose skill candidates, but active skill installation requires master approval.
- Installer/updater create phoenix_v19 and per-bot .phoenix_v19/.agents/skills structures.

Safety:
- Do not put Telegram tokens, API keys, OAuth files, raw .env values, or chat ids into skill files.
- Cleaner removes bot credentials/state tied to deleted bots.
- Updater preserves auth mode, tokens, outputs, logs, and PM2 identity for existing supported installs.

Phoenix Agent v1.9 24-hour local Agent operation:
- Phoenix_Agent_v1.9_24시간_Agent_운영가이드.html explains 24-hour local Agent operation, including installer/updater helper use and Genesis Bot-guided setup.
- configure_laptop_awake_mode.ps1 is an optional Windows helper. It checks or applies lid-close/no-sleep settings only when the user runs it.
- Laptop lid operation is an OS/hardware setting, not a pure Phoenix Agent software feature.
- Local bots keep running only while the laptop is powered on, awake, connected to the internet, and PM2/OpenClaw gateway processes are alive.
- Phoenix Agent v1.9 uses safe diagnosis and approval-based repair language for PM2/gateway conflicts. It must not introduce always-on aggressive auto-repair that kills or restarts healthy bots without user approval.
- installer/updater folders include configure_laptop_awake_mode so users can run the helper from the folder they are already using.
