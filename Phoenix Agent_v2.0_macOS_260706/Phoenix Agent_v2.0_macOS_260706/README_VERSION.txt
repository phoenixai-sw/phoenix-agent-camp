# Phoenix Agent v2.0_260706

## 버전 정의

Phoenix Agent v2.0은 v1.9 안정판을 기반으로 하는 Web Control Agent 버전입니다.

보존 기능:
- v1.9 Telegram/OpenClaw/PM2 운영 구조
- Codex CLI / ChatGPT 브라우저 / Gemini / local LLM 인증 구조
- proactive 자동 메시지
- PCS / PTS 스킬업 구조
- 24시간 Agent 운영 가이드
- outputs, logs, 기존 학습/스킬 파일 보존

추가 기능:
- Playwright MCP 기반 agent web 컨트롤 원칙
- Genesis Bot의 phoenix command 지휘 구조
- Design/Writer/Video/Power Bot의 담당 agent web 매핑
- 결과물 로컬 outputs 기본 저장
- Telegram 전송은 유저 확인 후 선택 전송
- 영상/유료/외부배포/상담 결과 전달 승인 정책

## v2.0 담당 agent web

- Genesis Bot: phoenix command
- Design Bot: phoenix pages, phoenix slides, phoenix webs, phoenix images
- Writer Bot: phoenix books
- Video Bot: phoenix videos
- Power Bot: phoenix reports, phoenix tax, phoenix dental, phoenix marketing

## 후속 로드맵

v2.0 = Web Control Agent
v2.2 = Master Builder Agent

v2.0 완료 후에는 v2.2 Master Builder Agent 진행을 권장합니다. v2.2는 봇이 작업 경험을 스킬 개선안으로 정리하고, Genesis Bot이 통합 보고하며, 마스터 승인 후 updater로 반영하는 승인형 재귀개선 단계입니다.

## 실행 원칙

- 신규 설치: cleaner 후 installer 사용
- 기존 v1.9 이하 설치본: updater로 v2.0 승급
- 로컬 활성 봇 적용은 마스터 컨펌 후 진행
- API Key, Telegram token, OAuth credential 값은 출력하지 않음