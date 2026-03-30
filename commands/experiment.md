---
description: 대규모 작업 전 가설 검증 — 짧은 실행으로 PASS/FAIL/UNSURE 판정
---
# /experiment — 가설 검증 실험

대규모 구현 전에 핵심 가설을 빠르게 검증합니다.
전체 구현은 금지하고, 최소한의 실행으로 판단 근거를 만듭니다.

**패턴**: `가설 → 검증 방법 → 결과(PASS/FAIL/UNSURE) → 리스크 → 다음 액션`

## 사용법
```
/experiment <가설 또는 질문>
```

## 언제 쓰나
- 새로운 접근법이 실제로 동작하는지 확인할 때
- 대규모 리팩토링 전에 핵심 전제를 검증할 때
- 라이브러리/API가 의도대로 동작하는지 확인할 때
- 성능 가설을 빠르게 측정할 때

## 예시
```
/experiment Unity URP에서 스텐실 버퍼로 포탈 마스킹이 가능한가?
/experiment WebSocket 대신 SSE로 실시간 알림이 충분한가?
/experiment 이 쿼리에 인덱스 추가 시 50% 이상 개선되는가?
```

## 실행 방법

### Phase 1: 가설 구조화
1. `$ARGUMENTS`에서 가설 추출
2. 다음 항목 정의:
   - **가설**: 검증하려는 명제 (참/거짓 판별 가능해야 함)
   - **검증 방법**: 최소한의 코드/명령으로 확인할 수 있는 방법
   - **성공 기준**: PASS로 판정하기 위한 구체적 조건
   - **제약**: 전체 구현 금지, 기존 코드 변경 최소화

### Phase 2: 최소 실행
3. 검증에 필요한 최소한의 코드/명령 실행
   - 프로토타입 코드는 `/tmp` 또는 별도 브랜치에서만
   - 기존 프로덕션 코드 수정 금지
   - 실행 시간 5분 이내 목표

### Phase 3: 판정
4. 결과를 다음 중 하나로 판정:
   - **PASS**: 가설이 성공 기준을 충족
   - **FAIL**: 가설이 명확히 틀림
   - **UNSURE**: 추가 정보 필요, 판단 불가

### Phase 4: 보고
5. Obsidian에 실험 결과 기록:
   ```bash
   obsidian create name="YYYY-MM-DD-experiment-<slug>" path="01-Projects/Experiments/" content="---
   date: YYYY-MM-DD
   tags: [experiment]
   result: <PASS|FAIL|UNSURE>
   ---

   # <가설>

   ## 가설
   <검증하려는 명제>

   ## 검증 방법
   <수행한 실행>

   ## 결과: <PASS|FAIL|UNSURE>
   <근거 데이터>

   ## 리스크
   <발견된 리스크 또는 제약>

   ## 다음 액션
   - PASS: 본 구현 진행 (/plan 또는 /orchestrate)
   - FAIL: 대안 탐색 또는 포기
   - UNSURE: 추가 실험 필요 (구체적 방향 제시)"
   ```

6. 사용자에게 판정 + 다음 액션 제안

## 제약
- 전체 기능 구현 금지
- 프로덕션 코드 직접 수정 금지
- 실행은 짧게 (5분 이내)
- 결과는 반드시 PASS/FAIL/UNSURE 중 하나로 명확히 판정
