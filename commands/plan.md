---
description: 태스크 계획을 Obsidian 문서로 작성하고, 사용자 승인 후 실행
---
# /plan — Obsidian 기반 계획 문서 작성 & 실행 (v6)

태스크를 바로 실행하지 않고, **Obsidian에 계획 문서를 먼저 작성**한 뒤
사용자와 문서 기반으로 소통·합의 후 실행하는 워크플로.

## 사용법
```
/plan <태스크 설명>
```

## 필수 조건 (v5: 하나라도 해당 시 /plan 사용)
- 파일 3개 이상 변경
- 구조 변경 포함
- 외부 시스템 연동
- 상태 관리 변경

## 예시
```
/plan 인증 시스템을 JWT 기반으로 전환
/plan 레거시 API를 REST에서 GraphQL로 마이그레이션
/plan 모노레포 CI/CD 파이프라인 구축
```

## 경로 결정: resolve-project.sh 기반

계획 문서의 저장 경로는 **하드코딩하지 않는다**. 반드시 `resolve-project.sh`를 실행하여 프로젝트별 올바른 경로를 획득한다.

```bash
# 프로젝트 경로 자동 해석
RESOLVE_JSON=$(bash ~/.claude/orchestration/scripts/resolve-project.sh 2>/dev/null)

# plans_path 추출
PLANS_PATH=$(echo "$RESOLVE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['plans_path'])")
VAULT_ROOT=$(echo "$RESOLVE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['vault_root'])")
PROJECT_NAME=$(echo "$RESOLVE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['canonical_name'])")

# 전체 경로
FULL_PLANS_DIR="$VAULT_ROOT/$PLANS_PATH"
```

- 자동 해석 실패 시(exit 1): `--project <alias>` 플래그로 명시적 지정
- fallback은 `00-Inbox`이지만, 가능하면 올바른 프로젝트 경로에 생성할 것

## 도구: 직접 파일 작성 (Primary) + Obsidian CLI (Secondary)

Obsidian CLI는 긴 content에서 hang되는 경우가 있으므로, **Vault 경로에 직접 파일을 작성하는 것을 기본으로 한다**.

### Primary: Write 도구로 직접 생성
```
1. resolve-project.sh로 FULL_PLANS_DIR 획득
2. Write 도구로 "$FULL_PLANS_DIR/YYYY-MM-DD-<slug>.md" 생성
```

### Secondary: Obsidian CLI (짧은 작업에만)
프로퍼티 변경, 문서 검색 등 짧은 작업에는 Obsidian CLI 사용 가능.

> **MSYS bash 주의**: `property:set`, `property:read` 등 콜론(`:`) 포함 명령은
> MSYS가 경로로 해석하여 실패한다. 반드시 `cmd.exe //c "obsidian ..."` 래핑을 사용할 것.

| 작업 | 방법 |
|------|------|
| 문서 생성 | Write 도구로 `$FULL_PLANS_DIR/파일.md` 직접 작성 |
| 문서 읽기 | Read 도구로 `$FULL_PLANS_DIR/파일.md` 직접 읽기 |
| 내용 추가 | Edit 도구로 파일 끝에 추가 |
| 덮어쓰기 | Write 도구로 동일 경로에 재작성 |
| 프로퍼티 읽기 | `cmd.exe //c "obsidian property:read name=status path=<vault_relative_path>"` |
| 프로퍼티 설정 | `cmd.exe //c "obsidian property:set name=status value=approved path=<vault_relative_path>"` |
| 문서 검색 | `obsidian search query="검색어"` |

## 실행 흐름

### Phase 1: 분석 & 탐색
1. `$ARGUMENTS`에서 태스크 설명 추출
2. 코드베이스 탐색 (Glob, Grep, Read 사용)
   - 관련 파일, 모듈, 의존성 파악
   - 현재 상태와 문제점 분석
3. 태스크 범위와 영향도 평가

### Phase 2: 경로 해석 & 계획 문서 생성
4. `resolve-project.sh` 실행하여 `plans_path`, `vault_root`, `canonical_name` 획득
   - 실패 시: `--project <alias>` 재시도 또는 사용자에게 프로젝트 확인
5. 오늘 날짜와 태스크로부터 slug 생성 (예: `2026-03-05-jwt-auth-migration`)
6. 아래 템플릿에 맞춰 내용을 채운다
7. Write 도구로 문서 생성 (frontmatter의 status=draft 포함):
   - 경로: `$VAULT_ROOT/$PLANS_PATH/YYYY-MM-DD-<slug>.md`

### Phase 3: 사용자 리뷰 요청
8. 사용자에게 안내:
   > "계획 문서를 작성했습니다. Obsidian에서 `$PLANS_PATH/YYYY-MM-DD-<slug>.md`를 확인해주세요."
9. AskUserQuestion으로 승인/수정 요청:
   - "승인" → Phase 5로
   - "수정 필요" → Phase 4로

### Phase 4: 반복 수정 (필요시)
10. 사용자 피드백에 따라 Edit/Write 도구로 문서 업데이트
11. CLI로 상태를 review로 변경:
    ```bash
    cmd.exe //c "obsidian property:set name=status value=review path=$PLANS_PATH/YYYY-MM-DD-<slug>.md"
    ```
12. 다시 Phase 3으로 돌아가 리뷰 요청

### Phase 5: 승인 → 실행
13. CLI로 상태를 approved로 변경:
    ```bash
    cmd.exe //c "obsidian property:set name=status value=approved path=$PLANS_PATH/<파일>.md"
    ```
14. **실행 방식 판정** — Plan 문서의 Step 수와 복잡도 기준:
    - **단순 (Step 2개 이하, 파일 3개 미만 변경)**: 직접 실행
    - **복합 (Step 3개 이상 또는 다중 레이어)**: `/orchestrate` 자동 전환

15. **복합 태스크 → /orchestrate 자동 전환**:
    - Plan 문서에서 Step 목록 추출
    - 각 Step을 `/orchestrate`의 서브태스크로 변환
    - Skill 도구로 `/orchestrate` 호출:
      ```
      Skill: "orchestrate"
      Args: "Plan '<문서명>'의 Step들을 실행: Step 1: <내용>, Step 2: <내용>, ..."
      ```
    - /orchestrate가 각 Step에 모델 배정 → 병렬/순차 실행 → 통합

16. CLI로 상태를 in-progress로 변경:
    ```bash
    cmd.exe //c "obsidian property:set name=status value=in-progress path=$PLANS_PATH/<파일>.md"
    ```
17. 작업 완료 시:
    - 실행 결과를 plan 문서에 Edit 도구로 append
    - 상태를 completed로 변경:
      ```bash
      cmd.exe //c "obsidian property:set name=status value=completed path=$PLANS_PATH/<파일>.md"
      ```

## 문서 템플릿

경로: `$VAULT_ROOT/$PLANS_PATH/YYYY-MM-DD-<slug>.md`

```markdown
---
date: YYYY-MM-DD
project: <canonical_name from resolve-project.sh>
tags: [plan]
status: draft
---

# <태스크 제목>

## 개요
- **목적**: 무엇을 왜 하는가
- **범위**: 어디까지 다루는가

## 배경
- 현재 상태, 문제점, 관련 컨텍스트

## 목표
- [ ] 구체적 목표 1
- [ ] 구체적 목표 2

## 구현 계획
### Step 1: ...
- 대상 파일:
- 변경 내용:

### Step 2: ...
- 대상 파일:
- 변경 내용:

## 영향 범위
- 변경되는 파일/모듈
- 의존성 영향
- 하위 호환성

## 검증 방법
- 테스트 방법
- 성공 기준

## 메모
- 추가 고려사항, 리스크, 대안
```

## Frontmatter 상태 라이프사이클

| 상태 | 의미 |
|------|------|
| `draft` | 에이전트가 초안 작성 완료 |
| `review` | 사용자 리뷰 중 (수정 반복) |
| `approved` | 사용자 승인 완료, 실행 가능 |
| `in-progress` | 실제 작업 진행 중 |
| `completed` | 작업 완료 (결과 append 포함) |

## 주의사항
- **승인 전에는 절대 코드 변경 작업을 시작하지 말 것**
- 경로는 반드시 `resolve-project.sh`로 결정 — 하드코딩 금지
- Obsidian CLI hang 시 Write/Read/Edit 도구로 직접 파일 조작
- MSYS bash에서 콜론(`:`) 포함 서브커맨드는 `cmd.exe //c` 래핑 필수
