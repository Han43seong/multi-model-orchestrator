---
description: 태스크 계획을 Obsidian 문서로 작성하고, 사용자 승인 후 실행
---
# /plan — Obsidian 기반 계획 문서 작성 & 실행 (v5)

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

## 도구: Obsidian CLI 전용

모든 Obsidian 작업은 CLI로 수행한다. MCP는 사용하지 않는다.

> **MSYS bash 주의**: `property:set`, `property:read` 등 콜론(`:`) 포함 명령은
> MSYS가 경로로 해석하여 실패한다. 반드시 `cmd.exe //c "obsidian ..."` 래핑을 사용할 것.

| 작업 | 명령어 |
|------|--------|
| 문서 생성 | `obsidian create name="제목" path="01-Projects/Plans/" content="..."` |
| 문서 읽기 | `obsidian read path="01-Projects/Plans/파일.md"` |
| 내용 추가 | `obsidian append path="01-Projects/Plans/파일.md" content="추가 내용"` |
| 문서 검색 | `obsidian search query="검색어"` |
| 덮어쓰기 | `obsidian create name="문서" path="경로" content="새 내용" overwrite` |
| 이름 변경 | `obsidian rename path="원본.md" name="새이름"` |
| 문서 삭제 | `obsidian delete path="01-Projects/Plans/파일.md"` |
| 프로퍼티 읽기 | `cmd.exe //c "obsidian property:read name=status path=파일경로"` |
| 프로퍼티 설정 | `cmd.exe //c "obsidian property:set name=status value=approved path=파일경로"` |
| 프로퍼티 삭제 | `cmd.exe //c "obsidian property:remove name=키명 path=파일경로"` |
| 프로퍼티 목록 | `obsidian properties path="파일경로"` |
| 폴더 목록 | `obsidian files folder="01-Projects/Plans"` |
| 태그 목록 | `obsidian tags path="파일경로"` |

## 실행 흐름

### Phase 1: 분석 & 탐색
1. `$ARGUMENTS`에서 태스크 설명 추출
2. 코드베이스 탐색 (Glob, Grep, Read 사용)
   - 관련 파일, 모듈, 의존성 파악
   - 현재 상태와 문제점 분석
3. 태스크 범위와 영향도 평가

### Phase 2: Obsidian 계획 문서 생성
4. 오늘 날짜와 태스크로부터 slug 생성 (예: `2026-03-05-jwt-auth-migration`)
5. 아래 템플릿에 맞춰 내용을 채운다
6. Obsidian CLI로 문서 생성 (frontmatter의 status=draft 포함):
   ```bash
   obsidian create name="YYYY-MM-DD-<slug>" path="01-Projects/Plans/" content="---\ndate: YYYY-MM-DD\nproject: <프로젝트명>\ntags: [plan]\nstatus: draft\n---\n\n# <제목>\n\n<본문>"
   ```

### Phase 3: 사용자 리뷰 요청
7. 사용자에게 안내:
   > "계획 문서를 작성했습니다. Obsidian에서 `01-Projects/Plans/YYYY-MM-DD-<slug>.md`를 확인해주세요."
8. AskUserQuestion으로 승인/수정 요청:
   - "승인" → Phase 5로
   - "수정 필요" → Phase 4로

### Phase 4: 반복 수정 (필요시)
9. 사용자 피드백에 따라 문서 업데이트:
   ```bash
   obsidian create name="YYYY-MM-DD-<slug>" path="01-Projects/Plans/" content="<수정된 전체 내용>" overwrite
   ```
10. CLI로 상태를 review로 변경:
    ```bash
    cmd.exe //c "obsidian property:set name=status value=review path=01-Projects/Plans/YYYY-MM-DD-<slug>.md"
    ```
11. 다시 Phase 3으로 돌아가 리뷰 요청

### Phase 5: 승인 → 실행 (v5 /orchestrate 연동)
12. CLI로 상태를 approved로 변경:
    ```bash
    cmd.exe //c "obsidian property:set name=status value=approved path=01-Projects/Plans/<파일>.md"
    ```
13. **실행 방식 결정**:
    - 단순 작업: 직접 실행
    - **복합 태스크: `/orchestrate` 워크플로우로 자동 전환**
      - 계획 문서의 구현 계획을 기반으로 서브태스크 분해
      - v5 리뷰 루프 (최대 3라운드) 적용
      - 레이어 기준 병렬 구현
14. CLI로 상태를 in-progress로 변경:
    ```bash
    cmd.exe //c "obsidian property:set name=status value=in-progress path=01-Projects/Plans/<파일>.md"
    ```
15. 작업 완료 시:
    - 실행 결과를 plan 문서에 append:
      ```bash
      obsidian append path="01-Projects/Plans/<파일>.md" content="\n## 실행 결과\n- 완료일: YYYY-MM-DD\n- 결과 요약: ..."
      ```
    - 상태를 completed로 변경:
      ```bash
      cmd.exe //c "obsidian property:set name=status value=completed path=01-Projects/Plans/<파일>.md"
      ```

## 문서 템플릿

경로: `01-Projects/Plans/YYYY-MM-DD-<slug>.md`

```markdown
---
date: YYYY-MM-DD
project: <프로젝트명 또는 global>
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
- Obsidian CLI가 등록되어 있어야 함 (Settings > General > CLI > Register)
- **승인 전에는 절대 코드 변경 작업을 시작하지 말 것**
- MSYS bash에서 콜론(`:`) 포함 서브커맨드는 `cmd.exe //c` 래핑 필수
