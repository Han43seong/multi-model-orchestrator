---
description: 사용자 의도 파악 → 요구사항 명세 → Contract 생성 → 구현 + 평가 루프
---
# /harness — 하네스 기반 개발 워크플로우

목표만 정의하고 구현 방법은 열어둔 채, **Contract 기반 반복 시도**로 결과물을 만드는 워크플로우.

## 사용법
```
/harness <목표 설명>
```

## /plan과의 차이
| | /plan | /harness |
|---|------|---------|
| 본질 | 구현 계획서 | 요구사항 명세서 |
| 구현 방법 | 확정 (Step별 파일, 변경 내용) | 비워둠 (Generator가 결정) |
| 평가 | 사용자가 직접 확인 | Contract 기준 PASS/FAIL 자동 판정 |
| 적합한 상황 | 방법이 정해진 작업 | 목표만 있는 작업 |

## 언제 /harness를 쓰는가
- "이걸 만들어줘" (방법은 모르거나 상관없음)
- 여러 구현 방법이 가능한 경우
- 반복 시도로 품질을 높여야 하는 경우

## 언제 /plan을 쓰는가
- "이 방법으로 전환해줘" (방법이 정해져 있음)
- 마이그레이션, 리팩토링 등 순서가 중요한 작업

## 실행 흐름

### Phase 1: 의도 파악
1. `$ARGUMENTS`에서 목표 추출
2. 코드베이스 탐색 (Glob, Grep, Read)
   - 기존 구조, 기술 스택, 제약 사항 파악
3. AskUserQuestion으로 **의도 확인**:
   - "이 작업의 목적이 무엇인가요?"
   - "최종적으로 어떤 상태를 원하시나요?"
   - "반드시 지켜야 할 제약이 있나요?"
   - 사용자가 이미 충분한 정보를 제공했으면 생략 가능

### Phase 2: 요구사항 명세 작성
4. `resolve-project.sh` 실행하여 Vault 경로 획득
   ```bash
   RESOLVE_JSON=$(bash ~/.claude/orchestration/scripts/resolve-project.sh 2>/dev/null)
   # 실패 시: --project <alias> 재시도
   ```
5. 오늘 날짜 + slug로 파일명 생성
6. Write 도구로 명세 문서 생성:
   - 경로: `$VAULT_ROOT/$PLANS_PATH/YYYY-MM-DD-<slug>.md`
   - 아래 템플릿 사용

### Phase 3: 사용자 승인
7. 사용자에게 안내:
   > "요구사항 명세를 작성했습니다. Obsidian에서 확인해주세요."
8. AskUserQuestion으로 승인/수정 요청
   - "승인" → Phase 4로
   - "수정 필요" → 피드백 반영 후 다시 Phase 3

### Phase 4: Contract 생성
9. 승인된 명세의 **성공 기준**을 contract.sh에 전달:
   ```bash
   bash ~/.claude/orchestration/scripts/contract.sh \
     --task "<목적 요약>" \
     --context "<성공 기준 목록>"
   ```
10. Contract JSON 생성 + Codex 검증 + 합의
11. 명세 문서에 Contract 참조 append:
    ```markdown
    ## Contract
    - 파일: `.orchestration/contracts/<task_id>-contract.json`
    - 기준 수: N개
    - 상태: agreed
    ```

### Phase 5: 구현 + 평가 루프
12. 명세 status를 in-progress로 변경
13. **구현**: 목적과 제약만 참고하여 자유롭게 구현
    - 구현 방법은 Generator(Claude)가 결정
    - 막히면 다른 접근법 시도 가능
14. **평가**: Contract 기준으로 판정
    ```bash
    bash ~/.claude/orchestration/scripts/evaluate.sh \
      --contract .orchestration/contracts/latest-contract.json
    ```
15. **리뷰**: FAIL 항목이 있으면 review-loop 실행
    ```bash
    bash ~/.claude/orchestration/scripts/review-loop.sh \
      --diff changes.diff --phase A --failure-mode functional \
      --contract .orchestration/contracts/latest-contract.json
    ```
16. **반복**: FAIL → 수정 → 재평가 (Contract 전체 PASS까지)
17. 완료 시:
    - 명세 status를 completed로 변경
    - 결과 요약 append

## 문서 템플릿

```markdown
---
date: YYYY-MM-DD
project: <canonical_name from resolve-project.sh>
tags: [harness]
status: draft
---

# <목표 제목>

## 목적
- 왜 이 작업을 하는가
- 해결하려는 문제

## 기대 결과
- [ ] 최종 상태 1 (사용자 관점에서)
- [ ] 최종 상태 2

## 제약
- 사용해야 하는 기술/프레임워크
- 하지 말아야 할 것
- 기존 시스템과의 호환성 요구

## 성공 기준
- 검증 가능하고 모호하지 않은 기준 1
- 검증 가능하고 모호하지 않은 기준 2
- (이 항목들이 Contract의 criteria로 변환됨)

## 메모
- 참고 사항, 우선순위, 배경 정보
```

## 구현 방법은 적지 않는다

다음은 명세에 **포함하지 않는다**:
- ~~Step 1: 이 파일을 수정~~ → Generator가 결정
- ~~어떤 함수를 만들지~~ → Generator가 결정
- ~~구현 순서~~ → Generator가 결정
- ~~대상 파일 목록~~ → Generator가 결정

명세는 **"무엇을"과 "하지 말 것"만** 정의한다.

## Frontmatter 상태 라이프사이클

| 상태 | 의미 |
|------|------|
| `draft` | 명세 초안 작성 완료 |
| `review` | 사용자 리뷰 중 |
| `approved` | 승인 완료, Contract 생성 가능 |
| `in-progress` | 구현 + 평가 루프 진행 중 |
| `completed` | Contract 전체 PASS, 작업 완료 |

## 주의사항
- 경로는 반드시 `resolve-project.sh`로 결정 — 하드코딩 금지
- **승인 전에는 코드 작성을 시작하지 말 것**
- 구현 중 막히면 방법을 바꿀 수 있다 — 명세의 목적과 제약만 지키면 됨
- MSYS bash에서 콜론(`:`) 포함 서브커맨드는 `cmd.exe //c` 래핑 필수
