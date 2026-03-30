#!/bin/bash
# review-loop.sh — v6 리뷰 루프: Claude 자체 분류 → 조건부 Codex/Gemini 호출
# Usage:
#   review-loop.sh \
#     --diff <diff_file> \
#     --phase <A|B|C> \
#     --failure-mode <functional|structural|both|none> \
#     --iteration <1|2|3> \
#     --previous-issues <issues.json>
#
# 출력: .orchestration/results/<timestamp>-review/result.json
#
# Phase 0: Claude 자체 리뷰 (failure_mode 분류)
# Phase A: 조건부 Codex/Gemini 호출
# Phase B/C: delta만, 기존 이슈 반복 금지
#
# 기존 invoke-sequential.sh는 수정하지 않음 (하위 호환)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.json"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"

# --- 인자 파싱 ---
DIFF_FILE=""
PHASE="A"
FAILURE_MODE="none"
ITERATION=1
PREV_ISSUES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --diff)             DIFF_FILE="$2"; shift 2 ;;
    --phase)            PHASE="$2"; shift 2 ;;
    --failure-mode)     FAILURE_MODE="$2"; shift 2 ;;
    --iteration)        ITERATION="$2"; shift 2 ;;
    --previous-issues)  PREV_ISSUES="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$DIFF_FILE" ]; then
  echo '{"error": "diff file required (--diff <file>)"}' >&2
  exit 1
fi

# --- 결과 디렉토리 ---
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
LOG_BASE="${ORCH_LOG_DIR:-$PROJECT_ROOT/.orchestration/results}"
mkdir -p "$LOG_BASE" 2>/dev/null
LOG_DIR="$(cd "$LOG_BASE" 2>/dev/null && pwd)"
RESULTS_DIR="$LOG_DIR/${TIMESTAMP}-review"
mkdir -p "$RESULTS_DIR"

echo "[$(date '+%H:%M:%S')] [review-loop] START phase=$PHASE failure=$FAILURE_MODE iter=$ITERATION" >> "$LOG_DIR/session-log.md"

# --- 모델 호출 분기 결정 ---
# failure_mode == none 세부 분기는 should-invoke.sh가 처리
MODELS_TO_INVOKE=""
INVOKE_REASON=""

case "$FAILURE_MODE" in
  functional)
    MODELS_TO_INVOKE="codex"
    INVOKE_REASON="failure_mode=functional → codex only"
    ;;
  structural)
    MODELS_TO_INVOKE="gemini"
    INVOKE_REASON="failure_mode=structural → gemini only"
    ;;
  both)
    MODELS_TO_INVOKE="codex gemini"
    INVOKE_REASON="failure_mode=both → codex + gemini parallel"
    ;;
  none)
    # none: should-invoke로 판단, 기본은 codex
    # eval PASS 근접 시 should-invoke가 SKIP 반환하면 호출 안 함
    CODEX_CHECK=$(bash "$SCRIPT_DIR/should-invoke.sh" codex review none "$PHASE" 2>&1)
    CODEX_EXIT=$?
    GEMINI_CHECK=$(bash "$SCRIPT_DIR/should-invoke.sh" gemini review none "$PHASE" 2>&1)
    GEMINI_EXIT=$?

    if [ $CODEX_EXIT -eq 0 ]; then
      MODELS_TO_INVOKE="codex"
      INVOKE_REASON="failure_mode=none, policy: codex invoke"
    fi
    if [ $GEMINI_EXIT -eq 0 ]; then
      MODELS_TO_INVOKE="$MODELS_TO_INVOKE gemini"
      INVOKE_REASON="$INVOKE_REASON + gemini invoke"
    fi
    MODELS_TO_INVOKE=$(echo "$MODELS_TO_INVOKE" | xargs)
    if [ -z "$MODELS_TO_INVOKE" ]; then
      INVOKE_REASON="failure_mode=none, all models skipped by policy"
    fi
    ;;
esac

# --- diff 내용 읽기 ---
DIFF_CONTENT=""
if [ -f "$DIFF_FILE" ]; then
  DIFF_CONTENT=$(cat "$DIFF_FILE")
else
  DIFF_CONTENT="$DIFF_FILE"
fi

# --- previous issues 읽기 ---
PREV_ISSUES_CONTENT="[]"
if [ -n "$PREV_ISSUES" ] && [ -f "$PREV_ISSUES" ]; then
  PREV_ISSUES_CONTENT=$(cat "$PREV_ISSUES")
fi

# --- 리뷰 프롬프트 생성 ---
build_review_prompt() {
  local MODEL="$1"
  local ROLE=""
  case "$MODEL" in
    codex)  ROLE="You are a functional code reviewer. Focus on: bugs, logic errors, edge cases, test failures, API misuse." ;;
    gemini) ROLE="You are a structural code reviewer. Focus on: architecture, complexity, maintainability, UX flow, component design." ;;
  esac

  local DELTA_RULE=""
  if [ "$PHASE" != "A" ]; then
    DELTA_RULE="
IMPORTANT RULES:
- Only report NEW issues not already in the previous issues list
- Do NOT repeat previously reported issues
- Focus only on changes since last review"
  fi

  echo "${ROLE}
${DELTA_RULE}

Review the following diff (Phase ${PHASE}, Iteration ${ITERATION}):

\`\`\`diff
${DIFF_CONTENT:0:8000}
\`\`\`

Previous issues (do NOT repeat these):
${PREV_ISSUES_CONTENT}

Respond in this exact JSON format:
{
  \"issues\": [
    {\"id\": \"issue-NNN\", \"severity\": \"critical|major|minor\", \"category\": \"functional|structural\", \"file\": \"path\", \"line\": 0, \"description\": \"...\"}
  ]
}

Rules:
- Max 5 issues
- Be specific: file path + line number
- severity: critical (security/crash), major (logic error), minor (style/optimization)
- category: functional (bugs, logic) or structural (architecture, complexity)"
}

# --- 모델 병렬 호출 ---
declare -A MODEL_PIDS
for MODEL in $MODELS_TO_INVOKE; do
  PROMPT=$(build_review_prompt "$MODEL")
  (
    ORCH_OUTPUT_FILE="$RESULTS_DIR/$MODEL.md" \
      bash "$SCRIPT_DIR/invoke-model.sh" --policy-check --context review --failure-mode "$FAILURE_MODE" --phase "$PHASE" "$MODEL" "$PROMPT" \
      2>"$RESULTS_DIR/$MODEL.err"
    echo $? > "$RESULTS_DIR/$MODEL.exit"
  ) &
  MODEL_PIDS[$MODEL]=$!
done

# 대기
for MODEL in $MODELS_TO_INVOKE; do
  wait "${MODEL_PIDS[$MODEL]}" 2>/dev/null || true
done

# --- 결과 통합 (Python) ---
TMPPY=$(mktemp /tmp/review_merge_XXXXXX.py)
trap "rm -f '$TMPPY'" EXIT INT TERM

cat > "$TMPPY" << 'PYEOF'
import json, os, sys, re
from datetime import datetime

results_dir = sys.argv[1]
phase = sys.argv[2]
iteration = int(sys.argv[3])
failure_mode = sys.argv[4]
invoke_reason = sys.argv[5]
prev_issues_str = sys.argv[6]
models_str = sys.argv[7]

models = models_str.split() if models_str.strip() else []
prev_issues = []
try:
    prev_issues = json.loads(prev_issues_str)
except Exception:
    pass
prev_ids = {i.get('id', '') for i in prev_issues if isinstance(i, dict)}

# 각 모델 결과 파싱
all_issues = []
models_invoked = []

for model in models:
    result_file = os.path.join(results_dir, f'{model}.md')
    exit_file = os.path.join(results_dir, f'{model}.exit')

    exit_code = 2  # default: skipped
    if os.path.exists(exit_file):
        try:
            exit_code = int(open(exit_file).read().strip())
        except Exception:
            pass

    if exit_code == 2:
        continue  # policy SKIP

    models_invoked.append(model)

    if not os.path.exists(result_file) or os.path.getsize(result_file) == 0:
        continue

    content = open(result_file, encoding='utf-8', errors='replace').read()

    # JSON 추출 시도
    json_match = re.search(r'\{[\s\S]*"issues"[\s\S]*\}', content)
    if json_match:
        try:
            parsed = json.loads(json_match.group())
            for issue in parsed.get('issues', []):
                issue['source'] = model
                all_issues.append(issue)
        except Exception:
            pass

# delta 규칙: 기존 이슈 필터링
new_issues = []
for issue in all_issues:
    if issue.get('id') not in prev_ids:
        new_issues.append(issue)

# 중복 제거 (같은 file + line +-5)
deduplicated = []
for issue in new_issues:
    is_dup = False
    for existing in deduplicated:
        if issue.get('file') == existing.get('file'):
            try:
                if abs(int(issue.get('line', 0)) - int(existing.get('line', 0))) <= 5:
                    # 중복: severity 높은 쪽 채택
                    sev_order = {'critical': 3, 'major': 2, 'minor': 1}
                    if sev_order.get(issue.get('severity', ''), 0) > sev_order.get(existing.get('severity', ''), 0):
                        deduplicated.remove(existing)
                        deduplicated.append(issue)
                    is_dup = True
                    break
            except Exception:
                pass
    if not is_dup:
        deduplicated.append(issue)

# resolved 감지
resolved = []
for prev in prev_issues:
    if isinstance(prev, dict) and prev.get('id') not in {i.get('id') for i in deduplicated}:
        resolved.append(prev.get('id', ''))

# severity 집계
severity_summary = {'critical': 0, 'major': 0, 'minor': 0}
has_structural = False
for issue in deduplicated:
    sev = issue.get('severity', 'minor')
    severity_summary[sev] = severity_summary.get(sev, 0) + 1
    if issue.get('category') == 'structural':
        has_structural = True

# decision 판정
new_count = len(deduplicated)
critical_count = severity_summary.get('critical', 0)

if critical_count > 0:
    decision = 'ESCALATE'
    decision_reason = f'critical issue {critical_count}건'
elif phase == 'C' and (new_count > 2 or has_structural):
    decision = 'ESCALATE'
    decision_reason = f'Phase C에서 REVISE 조건 → ESCALATE (더 이상 반복 불가)'
elif new_count > 2 or has_structural:
    decision = 'REVISE'
    decision_reason = f'new_issues={new_count}, structural={has_structural}'
elif new_count <= 2:
    decision = 'APPROVE'
    decision_reason = f'new_issues={new_count}, no critical, no structural change'
else:
    decision = 'APPROVE'
    decision_reason = 'no issues found'

result = {
    'timestamp': datetime.now().astimezone().isoformat(),
    'phase': phase,
    'iteration': iteration,
    'models_invoked': models_invoked,
    'invoke_reason': invoke_reason,
    'issues': deduplicated,
    'new_issues': [i.get('id', '') for i in deduplicated],
    'resolved_issues': resolved,
    'severity_summary': severity_summary,
    'decision': decision,
    'decision_reason': decision_reason
}

# 저장
result_file = os.path.join(results_dir, 'result.json')
with open(result_file, 'w', encoding='utf-8') as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

print(json.dumps(result, indent=2, ensure_ascii=False))
PYEOF

FINAL_RESULT=$(python3 "$TMPPY" "$RESULTS_DIR" "$PHASE" "$ITERATION" "$FAILURE_MODE" "$INVOKE_REASON" "$PREV_ISSUES_CONTENT" "$MODELS_TO_INVOKE" 2>&1)

echo "$FINAL_RESULT"

# 세션 로그
DECISION=$(echo "$FINAL_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('decision','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
echo "[$(date '+%H:%M:%S')] [review-loop] DONE phase=$PHASE decision=$DECISION models=[$MODELS_TO_INVOKE]" >> "$LOG_DIR/session-log.md"

echo "ORCH_RESULT_FILE=$RESULTS_DIR/result.json"
