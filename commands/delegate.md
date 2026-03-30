---
description: 원하는 모델을 직접 지정해서 작업 위임 (codex=코딩/보안, gemini=리서치, opus=판단/리뷰)
---
# /delegate — 특정 모델에 1:1 위임

원하는 모델을 직접 지정해서 작업을 맡깁니다.
모델 선택이 확실할 때 쓰는 가장 단순한 패턴.

## 사용법
```
/delegate <모델> <태스크>
```

| 모델 | 적합한 작업 |
|------|------------|
| opus | 코드 리뷰, 복잡한 추론, 범용 코딩 |
| codex | 코딩, 디버깅, 보안 분석, 아키텍처 설계 |
| gemini | 리서치, UI, 비교 분석, 대용량 처리 |

## 예시
```
/delegate codex 이 API의 보안 취약점 찾아줘
/delegate gemini REST vs GraphQL 장단점 비교해줘
/delegate opus 이 함수의 시간복잡도 분석해줘
```

## 실행 방법
1. `$ARGUMENTS`에서 첫 단어를 모델 alias로, 나머지를 태스크로 분리
2. 다음 명령 실행:
   ```
   bash ~/.claude/orchestration/scripts/invoke-model.sh <alias> "<태스크>"
   ```
3. 결과를 비판적으로 평가하여 핵심 인사이트 합성 후 전달
