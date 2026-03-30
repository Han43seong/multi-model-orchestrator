---
description: 3개 모델이 각자 판단 → Claude가 최종 판정 (adjudication 모델)
---
# /consensus — Claude 판단 기반 합의

3개 모델이 동일한 질문에 각자 의견을 제출하고, **Claude가 최종 판정자로서 결론을 내립니다.**

> **동작 방식**: 다수결이 아닌 adjudication 모델.
> Claude는 Codex/Gemini의 의견을 참고해 판정하며, 필요 시 veto(거부) 권한을 행사합니다.

## 사용법
```
/consensus <결정 또는 질문>
```

## 언제 쓰나
- "이렇게 해도 되나?" 확신이 서지 않을 때
- 리팩토링 / 마이그레이션의 안전성 확인
- 기술 스택 또는 라이브러리 선택
- 배포 전 최종 검증

## 예시
```
/consensus 이 리팩토링이 안전한가?
/consensus TypeScript 마이그레이션 지금 진행해도 되는가?
/consensus Redis를 캐시 레이어로 도입해야 하는가?
/consensus 이 인증 방식에 보안 문제가 없는가?
```

## 실행 방법

### Phase 1: 의견 수집
1. `$ARGUMENTS`를 질문으로 사용
2. Codex와 Gemini 병렬 호출 (검증자 역할):
   ```
   bash ~/.claude/orchestration/scripts/invoke-parallel.sh "<질문>" codex gemini
   ```
3. 각 모델의 입장 정리 (찬성/반대/조건부 + 근거)

### Phase 2: Claude 판정 (adjudicator)
4. Claude가 양측 의견을 검토하고 최종 판정:
   - 양측 근거의 타당성 평가
   - 프로젝트 컨텍스트와 제약 조건 고려
   - 양측 동의 시: 근거 통합하여 결론
   - 양측 충돌 시: Claude가 판단 근거를 명시하며 한쪽 채택 또는 제3의 결론 도출
   - **veto**: Codex/Gemini 다수 의견이라도 Claude 판단에 어긋나면 거부 가능

### Phase 3: 결과 보고
5. 판정 결과 출력:

   **합의 도출 시:**
   > **APPROVED** — [결론 요약]
   > - Codex: [입장 요약]
   > - Gemini: [입장 요약]
   > - Claude 판정: [판정 근거]

   **의견 충돌 시 (Claude veto 포함):**
   > **DECIDED** — [Claude의 결론]
   > - Codex: [입장 요약]
   > - Gemini: [입장 요약]
   > - Claude 판정: [채택 근거 + veto 사유 (해당 시)]
   > - 쟁점: [남은 논의 포인트]

   **판단 불가 시:**
   > **DEFERRED** — 추가 정보 필요
   > - 쟁점 정리 + 필요한 추가 조사 제안
