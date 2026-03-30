---
description: 복잡한 요청을 서브태스크로 분해 → 각각 최적 모델 자동 배정 → 병렬/순차 실행 → 통합 보고서
---
# /orchestrate — 복잡한 태스크를 자동으로 분해 & 실행 (v5)

여러 단계가 얽힌 복잡한 요청을 서브태스크로 쪼개고,
각각에 가장 적합한 모델을 배정해서 자동으로 실행합니다.

**v5 워크플로우**: `설계 → 리뷰 루프 (최대 3회) → 레이어 기준 병렬 구현 → 통합`

## 사용법
```
/orchestrate <복잡한 요청>
```

## 예시
```
/orchestrate 새로운 결제 API를 설계하고 보안 검토까지 해줘
/orchestrate 이 레거시 모듈 리팩토링 계획 세우고 코드 리뷰까지
/orchestrate 현재 파이프라인 버그 찾고 수정 방안 제시해줘
```

## 실행 흐름 (v5)

### Phase 1: 분석 & 분해
1. `$ARGUMENTS`의 복합 태스크 분석
2. 레이어/경계 단위로 서브태스크 분해 (**기능 단위 분해 금지**)
   - 올바른 분해: UI/Presentation, Domain/Service, Data/Repository, Integration/API, Test/Validation
   - 잘못된 분해: 로그인 기능, 프로필 기능, 설정 기능 (→ 공용 코드 충돌)
3. 각 서브태스크에 카테고리 배정 → `agents/config.json`에서 모델 결정
4. 의존 관계 파악 (병렬 가능 vs 순차 필요)

### Phase 2: 사용자 확인
5. 분해 결과 표시:
   ```
   서브태스크 1: [설명] → [모델] (카테고리: xxx)
   서브태스크 2: [설명] → [모델] (카테고리: xxx)
   서브태스크 3: [설명] → [모델] ← 1번 결과 필요
   ```
6. 사용자 승인 대기

### Phase 3: 설계 + 리뷰 루프 (최대 3라운드)

#### Round A: Initial Review
7. Claude: 설계 초안 생성
8. Codex/Gemini 병렬 리뷰 (토큰 최적화 규칙 적용):
   - 입력: 설계 요약 (최대 10줄) + 목표 1줄 + 특정 질문 1개
   - 출력: 최대 5개 항목, 핵심만
   ```
   bash ~/.claude/orchestration/scripts/invoke-parallel.sh "<설계 요약 + 질문>" codex gemini
   ```

#### Round B: Revision Review (필요 시)
9. Claude: 리뷰 반영 (**delta만, 전체 재작성 금지**)
10. Codex/Gemini: **새로운 문제만 지적** (기존 내용 반복 금지)

#### Round C: Final Check (필요 시)
11. Codex/Gemini: **치명적 문제만** 확인
12. Claude: 구현 가능 여부 판정

#### 종료 조건 (모두 만족 시 조기 종료 가능)
- 치명적 문제 0개
- 신규 이슈 <= 2개 (각 모델)
- 구조 변경 제안 없음
- 변경이 국소적
- 병렬 분해 가능

### Phase 4: 병렬 구현
13. Claude가 Sub-Agent 작업 템플릿 작성 (각 작업에 반드시 포함):
    - 담당 파일 목록
    - 수정 가능 범위
    - 생성 가능 파일
    - 금지 영역
    - 의존 인터페이스
    - 완료 조건
    - 테스트 방법
14. 독립 태스크 → 병렬 Bash 호출
15. 의존성 있는 태스크 → 선행 결과를 포함하여 순차 실행

### Phase 5: 통합 & 검증
16. Claude: 전체 결과 병합
17. Codex: 선택적 검증 (기능 결함 체크)
18. 통합 보고서: 각 서브태스크 요약 + 전체 결론 + 다음 단계 제안

## /plan 연동
- `/plan`에서 승인된 계획이 있으면 해당 계획 기반으로 실행
- 실행 결과를 plan 문서에 append:
  ```bash
  obsidian append path="01-Projects/Plans/<파일>.md" content="## 실행 결과\n<결과 요약>"
  ```

## 카테고리 → 모델 라우팅
| 카테고리 | 모델 |
|---------|------|
| backend, security, architecture, debug | codex |
| frontend, research, design | gemini |
| review | opus |
| quick | opus |
