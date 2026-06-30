# My Dev Workflow

![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25)

Claude Code 안에서 **opus(Claude) · codex(OpenAI) · gemini(Google)** 3개 모델을 CLI subprocess로 오케스트레이션하는 개발 워크플로우 플러그인.

---

## 목적

단일 모델 한계를 보완하기 위해 슬래시 커맨드 하나로 여러 AI를 적재적소에 배정하고, Evaluator + 상태 머신이 구현 → 검증 → 롤백 사이클을 자동으로 관리한다. "어떤 모델에게 무엇을 맡길지"를 사람이 직접 판단하는 비용을 없애는 것이 목표다.

---

## 원리 / 동작 방식

```
Claude Code (Opus) — 오케스트레이터
        │  슬래시 커맨드
        ▼
invoke-model.sh (통합 디스패처)
  ├─ should-invoke.sh: eval 결과·failure_mode·model_policy 3단계 판단
  │   → 필요없으면 SKIP, 필요하면 INVOKE
  ├─ Opus   — 설계·판단·핵심 구현
  ├─ Codex  — 기능 검증·디버깅·Micro 구현
  └─ Gemini — UI·구조 리뷰, Embedding(벡터 검색)
        │
        ▼
evaluate.sh → PASS / RETRY / ESCALATE / ROLLBACK
state-machine.sh → DRAFT→…→COMPLETED (9개 상태, Obsidian 단방향 동기화)
```

**`/plan` → `/orchestrate` 자동 전환**: `/plan`에서 생성된 계획 문서가 `approved` 상태가 되면 `state-machine.sh`가 자동으로 `/orchestrate` 실행으로 전환한다.

**ivfflat 인덱스**: Learning System의 스킬/세션 벡터 검색에 PostgreSQL `ivfflat` 인덱스를 사용해 대규모 임베딩에서도 빠른 유사도 검색을 제공한다.

---

## 주요 기능

### 슬래시 커맨드 (9개)

| 커맨드 | 동작 |
|--------|------|
| `/delegate <model> <작업>` | 단일 모델에 위임 |
| `/parallel <작업>` | 3개 모델 동시 실행 → 공통점·차이점·합성 결론 |
| `/sequential <modelA> <modelB> <작업>` | A 구현 → B 검증 |
| `/adversarial <modelA> <modelB> <질문>` | 제안 vs 반박 토론 |
| `/consensus <질문>` | Codex·Gemini 의견 → Claude 최종 판정 (adjudication) |
| `/orchestrate <복합 작업>` | 레이어 분해 → 모델 배정 → 리뷰 루프 → 통합 |
| `/plan <계획>` | Obsidian 계획 문서 생성 → 승인 → `/orchestrate` 자동 전환 |
| `/experiment <가설>` | 5분 이내 핵심 전제 검증 → PASS/FAIL/UNSURE |
| `/harness <작업>` | "무엇을"만 정의, Contract 기반 반복 시도로 "어떻게" 탐색 |

### v6 인프라 스크립트

- **`evaluate.sh`** — build/lint/typecheck/test/security 실행 후 PASS·RETRY·ESCALATE·ROLLBACK 자동 판정. Contract 기준 판정 레이어 포함.
- **`state-machine.sh`** — 9개 상태 전이, retry 카운터 자동 관리(micro 2회·structural 1회), 한도 초과 시 자동 ESCALATE.
- **`review-loop.sh`** — Claude가 Phase 0에서 functional/structural/both/none 분류 → 조건부 모델 호출.
- **`contract.sh`** — 구현 전 성공 기준 사전 합의 (Claude 초안 → Codex 검토 → 최대 2라운드).
- **`should-invoke.sh`** — 3단계 정책 판단으로 불필요한 모델 호출 SKIP.
- **`log-outcome.sh`** — 호출 결과를 JSONL로 기록(`policy-log.jsonl`).

### Learning System (v6.2)

PostgreSQL + pgvector 기반 경험 축적 시스템:
- 복잡한 작업 후 경험을 구조화된 스킬로 자동 저장
- Gemini Embedding + ivfflat 인덱스로 유사 스킬·세션 시맨틱 검색
- 사용자 선호도·전문성 자동 추론 → 다음 세션에 주입
- 90일 미사용 자동 archive, 카테고리당 20개 상한

---

## 설치 & 사용법

```bash
# 1. 필수 CLI 설치 및 로그인
npm install -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli
claude        # Anthropic 로그인
codex auth    # OpenAI 로그인
gemini        # Google 로그인

# 2. 플러그인 설치
git clone https://github.com/Han43seong/My-Dev-Workflow.git
cd My-Dev-Workflow
bash install.sh

# 3. CLAUDE.md에 스니펫 추가
# claude-md-snippet.md 내용을 ~/.claude/CLAUDE.md 에 붙여넣기

# 4. (선택) Obsidian 연동
# Settings > General > CLI > Register
# ~/.claude/orchestration/project-map.json 프로젝트에 맞게 수정
```

사용 예시:
```bash
/orchestrate 결제 API 설계부터 보안 검토까지 해줘
/plan 인증 시스템을 JWT로 전환
/experiment WebSocket 대신 SSE로 실시간 알림이 충분한가?
/harness 결제 API 만들어줘
```

---

## 요구사항 / 의존성

| 항목 | 버전/비고 |
|------|-----------|
| `@anthropic-ai/claude-code` | npm 최신 |
| `@openai/codex` | npm 최신 |
| `@google/gemini-cli` | npm 최신 |
| Python 3 | `state-machine.sh` 내부 사용 |
| Docker | Learning System (PostgreSQL + pgvector) |
| Obsidian | `/plan`, `/experiment` 연동 시 선택 |

---

## 주요 변경 이력

| 날짜 | 내용 |
|------|------|
| 2026-03-04 | 초기 공개 — Claude Code 멀티모델 오케스트레이터 플러그인 |
| 2026-03-17 | v3.1 — Advisor + Synthesizer + Async Executor 아키텍처 도입 |
| 2026-03-30 | v6 전면 업그레이드 — Evaluator·상태 머신·Obsidian 연동 |
| 2026-03-31 | Harness 패턴 도입 — Contract Phase + Stress Test (`/harness` 커맨드) |
| 2026-04-01 | Learning System 도입 — PostgreSQL + pgvector 스킬·세션·프로필 관리 |
| 2026-04-01 | `/plan`→`/orchestrate` 자동 전환 + ivfflat 인덱스 + Stress Test 검증 |
