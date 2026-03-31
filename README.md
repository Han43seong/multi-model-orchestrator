# My Dev Workflow

Claude Code 기반 개발 워크플로우 — **opus(Claude), codex(OpenAI), gemini(Google)** 3개 AI 모델을 CLI subprocess로 호출하고, Evaluator + 상태 머신 + Obsidian 연동으로 설계부터 검증까지 자동화합니다.

## v6 아키텍처

```
+---------------------------------------------------------------------+
|                 Claude Code (Opus) -- 오케스트레이터                    |
|                                                                       |
|  +------------------+  +--------------------+  +------------------+  |
|  | 슬래시 커맨드 (9)  |  | v6 인프라            |  | Harness 패턴      |  |
|  | /delegate         |  | evaluate.sh        |  | contract.sh      |  |
|  | /parallel         |  | should-invoke.sh   |  | stress-test.sh   |  |
|  | /sequential       |  | state-machine.sh   |  +------------------+  |
|  | /adversarial      |  | review-loop.sh     |                        |
|  | /consensus        |  | log-outcome.sh     |                        |
|  | /orchestrate      |  | resolve-project.sh |                        |
|  | /plan             |  +--------------------+                        |
|  | /experiment       |                                                |
|  +--------+---------+                                                |
|           |  CLI subprocess                                            |
|           v                                                            |
|  +----------------------------------------------------------+        |
|  |          invoke-model.sh (통합 디스패처)                     |        |
|  |  + 에이전트 프롬프트 자동 주입 + 정책 함수 기반 조건부 호출     |        |
|  +----+-----------------+-----------------+------------------+        |
|       v                 v                 v                            |
|  +----------+     +----------+     +----------+                       |
|  |  Opus    |     |  Codex   |     |  Gemini  |                       |
|  |  Claude  |     |  GPT     |     |  Google  |                       |
|  +----------+     +----------+     +----------+                       |
|   Planner          Functional       Design Critic                      |
|   Integrator       Reviewer         UX/Structure                       |
|   Core Impl.       Micro-Impl.      Reviewer                          |
+---------------------------------------------------------------------+
          |
          v
+---------------------------------------------------------------------+
|                    Obsidian Vault (/plan + /experiment)                |
|  Plans/      -- 계획 문서 (상태 머신 연동)                               |
|  Experiments/ -- 실험 기록 (PASS/FAIL/UNSURE)                          |
+---------------------------------------------------------------------+
```

## 설치

### 1. 필수 CLI 도구

```bash
npm install -g @anthropic-ai/claude-code   # claude
npm install -g @openai/codex               # codex
npm install -g @google/gemini-cli           # gemini
```

설치 후 로그인:
```bash
claude         # Anthropic
codex auth     # OpenAI
gemini         # Google
```

### 2. 설치 실행

```bash
git clone https://github.com/Han43seong/My-Dev-Workflow.git
cd My-Dev-Workflow
bash install.sh
```

### 3. CLAUDE.md 설정

`claude-md-snippet.md`의 내용을 `~/.claude/CLAUDE.md`에 추가합니다.

### 4. Obsidian 연동 (선택)

`/plan`, `/experiment` 커맨드 사용 시:
- Obsidian CLI 등록: Settings > General > CLI > Register
- `~/.claude/orchestration/project-map.json`을 프로젝트에 맞게 수정

## v6 핵심 규칙

| # | 규칙 |
|---|------|
| 1 | Claude는 **결정할 때만** 사용 (설계, 판단, 통합) |
| 2 | Codex/Gemini는 **짧고 날카롭게** (질문 1개, 출력 5항목 이하) |
| 3 | 리뷰는 **최대 3라운드** (Phase A → B → C) |
| 4 | 병렬 작업은 **레이어 기준 분해** (기능 단위 X) |
| 5 | 모든 변경은 **Claude 승인 기반** |
| 6 | Codex/Gemini 호출은 **선택적** (Claude-first, 정책 함수) |
| 7 | Evaluator가 **PASS/RETRY/ESCALATE/ROLLBACK 자동 판정** |
| 8 | ESCALATE 시 **반드시 사용자 개입** |

## 모델 역할

| 모델 | 역할 | 강점 | 금지 |
|------|------|------|------|
| **Opus** (Claude) | Planner + Integrator + Core Implementer | 설계, 판단, 통합, 핵심 구현 | 반복 코드, boilerplate |
| **Codex** (GPT) | Functional Reviewer + Micro-Implementer | 기능 결함, API 검증, 디버깅 | 전체 기능 구현, 구조 재설계 |
| **Gemini** (Google) | Design Critic + UX/Structure Reviewer | UI/UX, 구조 단순화, 유지보수성 | 기능 구현 주도, 요구사항 변경 |

## 슬래시 커맨드

### /delegate — 단일 모델 위임
```
/delegate codex 이 API의 보안 취약점 찾아줘
/delegate gemini REST vs GraphQL 비교해줘
```

### /parallel — 3개 모델 동시 실행
```
/parallel 이 DB 스키마 리뷰해줘
```
결과: 각 모델 요약 + 공통점 + 차이점 + 합성 결론

### /sequential — A가 작업, B가 검증
```
/sequential codex opus 이 결제 모듈 구현해줘
```

### /adversarial — 제안 vs 반박
```
/adversarial codex gemini Redis 도입이 맞는가?
```

### /consensus — Claude 판단 기반 합의
```
/consensus 이 리팩토링이 안전한가?
```
다수결이 아닌 **adjudication 모델**: Codex/Gemini가 의견 제출 → Claude가 최종 판정 (veto 가능)
- **APPROVED**: 양측 합의
- **DECIDED**: Claude가 한쪽 채택 또는 제3의 결론
- **DEFERRED**: 추가 정보 필요

### /orchestrate — 복합 태스크 자동화
```
/orchestrate 결제 API 설계부터 보안 검토까지 해줘
```
1. 레이어 단위 분해 → 모델 배정
2. 설계 + 리뷰 루프 (최대 3라운드)
3. 병렬 구현 (Sub-Agent 템플릿)
4. 통합 + Codex 검증

### /plan — Obsidian 기반 계획
```
/plan 인증 시스템을 JWT로 전환
```
Obsidian에 계획 문서 생성 → 사용자 승인 → /orchestrate 자동 전환
상태: draft → review → approved → in-progress → completed

### /experiment — 가설 검증
```
/experiment WebSocket 대신 SSE로 실시간 알림이 충분한가?
```
대규모 구현 전 핵심 전제를 빠르게 검증 (5분 이내, 전체 구현 금지)
결과: **PASS / FAIL / UNSURE** + Obsidian 기록

### /harness — 하네스 기반 개발
```
/harness 결제 API 만들어줘
```
**구현 방법을 확정하지 않고**, 목표 + 제약만 정의한 뒤 Contract 기반 반복 시도로 구현:
1. 의도 파악 → 요구사항 명세 (Obsidian)
2. 사용자 승인 → Contract 자동 생성
3. 구현 → Contract 기준 평가 → FAIL이면 다른 방법 시도
4. 전체 PASS → 완료

`/plan`과의 차이: /plan은 "어떻게"를 확정, /harness는 "무엇을"만 정의하고 "어떻게"는 열어둠

## v6 인프라

### Evaluator (`evaluate.sh`)
프로젝트의 build/lint/typecheck/test/security를 실행하고 자동 판정:
- **PASS**: 모든 검증 통과
- **RETRY**: lint/test 소규모 실패 → 자동 재시도
- **ESCALATE**: security critical, 대규모 test 실패 → 사용자 개입
- **ROLLBACK**: build 실패 → 변경 롤백

프로젝트별 override: `.orchestration/eval-config.json`

### 정책 함수 (`should-invoke.sh`)
모델 호출 전 3단계 판단: eval 데이터 → failure_routing → model_policy
- eval PASS + skip_if_eval_pass=true → 불필요한 호출 SKIP
- failure_mode에 따라 적합한 모델만 INVOKE

### 상태 머신 (`state-machine.sh`)
9개 상태, Obsidian 단방향 동기화:
```
DRAFT → REVIEW → APPROVED → IMPLEMENTING → VERIFYING
                                              |
                              RETRYING <-> VERIFYING → COMPLETED
                                 |                  → ROLLED_BACK
                              ESCALATED
```
- retry 카운터 자동 관리 (micro: 2회, structural: 1회)
- 한도 초과 시 자동 ESCALATE
- user_override로 임의 상태 강제 전이 가능

### 리뷰 루프 (`review-loop.sh`)
Claude 자체 분류(Phase 0) → 조건부 모델 호출:
- functional → Codex만
- structural → Gemini만
- both → 병렬
- none → should-invoke.sh 판단

### 운영 지표 (`log-outcome.sh`)
모델 호출 결과를 JSONL로 기록: adoption_rate, retry_count, rate_limit 추적
위치: `.orchestration/results/policy-log.jsonl`

## Harness 패턴 (v6.1)

Anthropic "[Harness Design for Long-Running Apps](https://www.anthropic.com/engineering/harness-design-long-running-apps)" 블로그에서 소개된 패턴을 멀티모델 오케스트레이션에 적용합니다.

### Contract Phase (`contract.sh`)

구현 전에 **성공 기준을 사전 정의하고 합의**하는 단계. TDD에서 테스트를 먼저 작성하는 것과 같은 원리.

```bash
bash ~/.claude/orchestration/scripts/contract.sh --task "TODO 앱 CRUD API 구현"
```

1. Claude가 criteria 초안 생성 (기능별 검증 방법 + PASS 조건)
2. Codex가 검증 가능성 검토 (모호한 조건, 누락 기준 지적)
3. 최대 2라운드 협상 → 합의 확정
4. `.orchestration/contracts/latest-contract.json`에 저장

Contract는 review-loop과 evaluate에 `--contract` 인자로 전달:
```bash
# 리뷰 시 Contract 기준 주입
bash ~/.claude/orchestration/scripts/review-loop.sh \
  --diff changes.diff --phase A --contract .orchestration/contracts/latest-contract.json

# 평가 시 Contract 기준 판정
bash ~/.claude/orchestration/scripts/evaluate.sh \
  --contract .orchestration/contracts/latest-contract.json
```

### Functional Evaluation

기존 evaluate.sh의 build/lint/test 기계적 판정 위에 **Contract 기준 판정 레이어**가 추가됩니다:

| 기계적 판정 | Contract 판정 | 최종 judgment |
|------------|--------------|-------------|
| ROLLBACK/ESCALATE | (무관) | 그대로 (우선) |
| PASS | contract_fail | **RETRY** |
| PASS | contract_pass | PASS |

### Stress Test (`stress-test.sh`)

모델이 발전하면 하네스 컴포넌트가 여전히 필요한지 검증합니다:

```bash
# config.json에서 stress_test.enabled=true 설정 후
bash ~/.claude/orchestration/scripts/stress-test.sh \
  --bypass contract --task "작업 설명"
```

동일 작업을 **정상 실행 vs bypass 실행**으로 비교:
- **KEEP**: bypass 시 품질 저하 → 컴포넌트 필요
- **REMOVE**: 결과 동일 → 컴포넌트 불필요, 제거 가능
- **CONDITIONAL**: 혼합 결과 → 추가 데이터 필요

bypass 가능한 컴포넌트:
| 플래그 | 대상 |
|--------|------|
| `BYPASS_CONTRACT` | contract.sh |
| `BYPASS_EVALUATOR` | evaluate.sh |
| `BYPASS_REVIEW` | review-loop.sh |
| `BYPASS_POLICY` | should-invoke.sh |

## 에이전트 프롬프트

| 에이전트 | 기본 모델 | 역할 |
|---------|----------|------|
| Code Reviewer | opus | 버그, 품질, APPROVE/REJECT |
| Debugger | codex | 기능 결함, 에러 추적, 수정 제안 |
| Researcher | gemini | 구조 평가, 디자인 비판 |
| Architect | - | 시스템 설계, 트레이드오프 |
| Security Analyst | - | OWASP, 취약점 분석 |
| Frontend Designer | - | UI 레이아웃, 컴포넌트 |

모든 프롬프트에 v5 토큰 규칙 적용: 최대 5개 항목, 핵심만.

## 카테고리 라우팅

| 카테고리 | Primary | Fallback |
|---------|---------|----------|
| backend, security, debug | codex | opus |
| frontend, research, design | gemini | opus |
| review, quick | opus | codex |
| architecture | codex | opus |

### 실패 기반 동적 라우팅 (v6)

| 실패 유형 | 모델 |
|----------|------|
| 컴파일/테스트 실패 | codex |
| 구조 복잡도, UX 문제 | gemini |
| 보안 경고, 성능 문제 | codex |
| 설계 충돌 | opus |

## 모델 호출

```bash
# 기본 (무조건 실행)
bash ~/.claude/orchestration/scripts/invoke-model.sh <alias> "<prompt>"

# v6 정책 기반 (조건부)
bash ~/.claude/orchestration/scripts/invoke-model.sh \
  --policy-check --context review --failure-mode functional --phase A \
  codex "<prompt>"

# 강제 실행
bash ~/.claude/orchestration/scripts/invoke-model.sh --force codex "<prompt>"
```

## 파일 구조

```
~/.claude/
├── CLAUDE.md                    ← 글로벌 지시사항 (claude-md-snippet.md 참조)
├── commands/                    ← 9개 슬래시 커맨드
│   ├── delegate.md
│   ├── parallel.md
│   ├── sequential.md
│   ├── adversarial.md
│   ├── consensus.md
│   ├── orchestrate.md
│   ├── plan.md
│   ├── experiment.md
│   └── harness.md
└── orchestration/
    ├── config.json              ← 모델, 역할, 카테고리, evaluator, state_machine, policy
    ├── models.env               ← 모델 ID (refresh-models.sh로 자동 갱신)
    ├── project-map.json         ← Obsidian Vault 프로젝트 매핑
    ├── scripts/
    │   ├── invoke-model.sh      ← 통합 디스패처 (v6: 정책 옵션)
    │   ├── invoke-claude.sh     ← Claude CLI (HOME 격리)
    │   ├── invoke-codex.sh      ← Codex CLI (-o 파일 캡처)
    │   ├── invoke-gemini.sh     ← Gemini CLI
    │   ├── invoke-parallel.sh   ← 병렬 실행
    │   ├── invoke-sequential.sh ← 순차 실행
    │   ├── invoke-adversarial.sh← 논쟁 실행
    │   ├── refresh-models.sh    ← 모델 ID 자동 감지
    │   ├── evaluate.sh          ← Evaluator + Contract 판정
    │   ├── should-invoke.sh     ← 정책 함수
    │   ├── state-machine.sh     ← 상태 머신
    │   ├── review-loop.sh       ← 리뷰 루프 + Contract 기준 주입
    │   ├── log-outcome.sh       ← 운영 지표
    │   ├── resolve-project.sh   ← 프로젝트 매핑
    │   ├── contract.sh          ← Contract Phase (Harness)
    │   └── stress-test.sh       ← 컴포넌트 스트레스 테스트 (Harness)
    └── prompts/
        ├── code-reviewer.md
        ├── debugger.md
        ├── researcher.md
        ├── architect.md
        ├── security-analyst.md
        └── frontend-designer.md
```

## 제거

```bash
bash uninstall.sh
```

## 버전 히스토리

| 버전 | 변경 |
|------|------|
| v1~v3 | Skills/MCP 기반 → CLI subprocess 전환 |
| v4 | CLI subprocess 안정화, HOME 격리 |
| v5 | 역할 기반, 3라운드 리뷰 루프, 토큰 최적화 |
| v6 | Claude-first, Evaluator 자동 판정, 상태 머신, 정책 함수, Obsidian 연동 |
| **v6.1** | Harness 패턴 — Contract Phase, Functional Evaluation, Stress Test |

## 라이선스

MIT
