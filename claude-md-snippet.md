# CLAUDE.md에 추가할 오케스트레이션 규칙
#
# 이 내용을 ~/.claude/CLAUDE.md에 붙여넣으세요.
# 이미 오케스트레이션 섹션이 있다면 해당 부분을 교체하세요.

## 멀티모델 오케스트레이션 v6 (전역)

어디서든 opus, codex, gemini 3개 모델을 CLI subprocess로 호출 가능.
v6은 **Claude-first + 선택적 멀티모델 검증 + 평가 기반 자동 분기** 구조.

### v6 핵심 규칙
| # | 규칙 |
|---|------|
| 1 | Claude는 **결정할 때만** 사용 (설계, 판단, 통합) |
| 2 | Codex/Gemini는 **짧고 날카롭게** (질문 1개, 출력 5항목 이하) |
| 3 | 리뷰는 **최대 3라운드** (Phase A → B → C) |
| 4 | 병렬 작업은 **레이어 기준 분해** (기능 단위 X) |
| 5 | 모든 변경은 **Claude 승인 기반** |
| 6 | Codex/Gemini 호출은 **선택적** (Claude-first, 정책 함수 기반) |
| 7 | Evaluator가 **PASS/RETRY/ESCALATE/ROLLBACK 자동 판정** |
| 8 | ESCALATE 시 **반드시 사용자 개입** |

### 역할 정의
| 모델 | 역할 | 금지 |
|------|------|------|
| Opus | Planner + Integrator + Core Implementer | 반복 코드, boilerplate |
| Codex | Functional Reviewer + Micro-Implementer | 전체 기능 구현, 구조 재설계 |
| Gemini | Design Critic + UX/Structure Reviewer | 기능 구현 주도, 요구사항 변경 |

### 모델 호출
```bash
# v5 호환 (무조건 실행)
bash ~/.claude/orchestration/scripts/invoke-model.sh <alias> "<prompt>"

# v6 정책 기반 (조건부 실행)
bash ~/.claude/orchestration/scripts/invoke-model.sh --policy-check --context <ctx> --failure-mode <mode> --phase <A|B|C> <alias> "<prompt>"

# 강제 실행
bash ~/.claude/orchestration/scripts/invoke-model.sh --force <alias> "<prompt>"
```
Aliases: `opus`, `codex`, `gemini`

### v6 신규 스크립트
| 스크립트 | 설명 |
|----------|------|
| `evaluate.sh` | build/lint/test 실행 + Contract 기준 판정 → JSON 결과 + 판정 |
| `should-invoke.sh` | 정책 함수: 모델 호출 여부 판단 (INVOKE/SKIP) |
| `state-machine.sh` | 상태 머신: init/transition/status/history |
| `review-loop.sh` | v6 리뷰 루프: Claude 자체 분류 → 조건부 호출 (Contract 기준 주입 지원) |
| `contract.sh` | Contract Phase: 구현 전 성공 기준 사전 합의 (Claude 초안 → Codex 검토) |
| `stress-test.sh` | 하네스 컴포넌트 제거 스트레스 테스트 (bypass 전/후 비교) |

### 슬래시 커맨드
| 커맨드 | 설명 |
|--------|------|
| `/delegate` | 특정 모델에 1:1 위임 |
| `/parallel` | 3개 모델 동시 실행 + 비교 |
| `/sequential` | A 실행 → B 검증 (토큰 최적화 적용) |
| `/adversarial` | 제안 → 반박 논쟁 |
| `/consensus` | Claude 판단 기반 합의 (adjudication, 다수결이 아님) |
| `/orchestrate` | 설계 → 리뷰 루프 → 병렬 구현 → 통합 |
| `/plan` | Obsidian 계획 문서 → 승인 → /orchestrate 연동 |
| `/experiment` | 가설 검증 실험 → PASS/FAIL/UNSURE 판정 |
| `/harness` | 하네스 기반 개발: 요구사항 명세 → Contract → 반복 구현 + 평가 |

### 카테고리 라우팅 + 실패 기반 라우팅
| 의도/실패 유형 | 모델 |
|---------------|------|
| 코드 리뷰, 복잡한 판단 | opus |
| 백엔드, 보안, 디버깅, 컴파일/테스트 실패 | codex |
| UI, 리서치, 구조 복잡도, UX 문제 | gemini |
| 설계 충돌 | opus |

### 설정 파일
- 스크립트/프롬프트/설정: `~/.claude/orchestration/`
- config: `~/.claude/orchestration/config.json` (evaluator, state_machine, model_policy, failure_routing 포함)
- 로그: `$PWD/.orchestration/results/session-log.md` (실행 디렉토리)
- eval 결과: `$PWD/.orchestration/eval/latest-eval.json`
- 상태: `$PWD/.orchestration/state.json`
- contracts: `$PWD/.orchestration/contracts/latest-contract.json`
- stress-test: `$PWD/.orchestration/stress-test/`
