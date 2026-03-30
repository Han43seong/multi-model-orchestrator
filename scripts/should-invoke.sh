#!/bin/bash
# should-invoke.sh — v6 정책 함수: 모델 호출 여부 판단
# Usage: should-invoke.sh <alias> <context> <failure_mode> <phase>
#
# 출력: INVOKE reason="..." 또는 SKIP reason="..."
# 종료 코드: 0=INVOKE, 1=SKIP

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.json"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
EVAL_DIR="$PROJECT_ROOT/.orchestration/eval"
LATEST_EVAL="$EVAL_DIR/latest-eval.json"
STATE_FILE="$PROJECT_ROOT/.orchestration/state.json"

ALIAS="${1:-}"
CONTEXT="${2:-}"
FAILURE_MODE="${3:-none}"
PHASE="${4:-A}"

if [ -z "$ALIAS" ]; then
  echo 'INVOKE reason="no alias provided, fallback to invoke"'
  exit 0
fi

LOG_DIR="$PROJECT_ROOT/.orchestration/results"
mkdir -p "$LOG_DIR" 2>/dev/null

# --- 임시 Python 파일 생성 (MSYS heredoc 문제 우회) ---
TMPPY=$(mktemp /tmp/should_invoke_XXXXXX.py)
trap "rm -f '$TMPPY'" EXIT INT TERM

cat > "$TMPPY" << 'PYEOF'
import json, os, sys
from datetime import datetime, timezone, timedelta

alias = sys.argv[1]
context = sys.argv[2]
failure_mode = sys.argv[3]
phase = sys.argv[4]
config_path = sys.argv[5]
eval_path = sys.argv[6]
state_path = sys.argv[7]

config = json.load(open(config_path, encoding='utf-8'))
model_policy = config.get('model_policy', {})
failure_routing = config.get('failure_routing', {})
evaluator_cfg = config.get('evaluator', {})
ttl_minutes = evaluator_cfg.get('ttl_minutes', 30)

# 1. eval 데이터 확인
if not os.path.exists(eval_path):
    print('INVOKE reason="fallback: eval data missing"')
    sys.exit(0)

try:
    eval_data = json.load(open(eval_path, encoding='utf-8'))
except Exception:
    print('INVOKE reason="fallback: eval parse failed"')
    sys.exit(0)

# TTL 체크
try:
    eval_ts = datetime.fromisoformat(eval_data['timestamp'])
    now = datetime.now(eval_ts.tzinfo or timezone(timedelta(hours=9)))
    if (now - eval_ts).total_seconds() > ttl_minutes * 60:
        print('INVOKE reason="fallback: eval data stale (TTL exceeded)"')
        sys.exit(0)
except Exception:
    print('INVOKE reason="fallback: eval data stale (timestamp parse failed)"')
    sys.exit(0)

# execution_id + 인접 상태 허용 규칙
if os.path.exists(state_path):
    try:
        state = json.load(open(state_path, encoding='utf-8'))
        if eval_data.get('execution_id') != state.get('execution_id'):
            print('INVOKE reason="fallback: eval data stale (exec_id mismatch)"')
            sys.exit(0)

        eval_state = eval_data.get('state', '')
        current_state = state.get('current_state', '')
        if eval_state != current_state:
            adjacent = {'VERIFYING': ['RETRYING', 'COMPLETED', 'ESCALATED', 'ROLLED_BACK']}
            if eval_state in adjacent and current_state in adjacent[eval_state]:
                pass  # 인접 상태: FRESH
            else:
                print('INVOKE reason="fallback: eval data stale (state mismatch)"')
                sys.exit(0)
    except Exception:
        pass

# 2. failure_routing 매칭
if failure_mode in failure_routing:
    recommended = failure_routing[failure_mode].get('model', '')
    fallback_model = failure_routing[failure_mode].get('fallback')
    if alias != recommended and alias != fallback_model:
        print(f'SKIP reason="failure_routing: {failure_mode} routes to {recommended}, not {alias}"')
        sys.exit(1)

# 3. model_policy 조건 확인
policy = model_policy.get(alias, {})
if policy:
    invoke_phases = policy.get('invoke_phases', [])
    if invoke_phases and phase not in invoke_phases:
        print(f'SKIP reason="policy: phase {phase} not in invoke_phases {invoke_phases}"')
        sys.exit(1)

    invoke_contexts = policy.get('invoke_contexts', [])
    if invoke_contexts and context and context not in invoke_contexts:
        print(f'SKIP reason="policy: context {context} not in invoke_contexts {invoke_contexts}"')
        sys.exit(1)

# 4. eval 결과 기반 필요성 판단
judgment = eval_data.get('judgment', 'UNKNOWN')
results = eval_data.get('results', {})

functional_sources = ['test', 'typecheck', 'lint', 'security']
has_functional = any(results.get(s, {}).get('status') == 'fail' for s in functional_sources)
has_structural = failure_mode == 'structural'

if alias == 'codex' and judgment in ['RETRY'] and has_functional:
    print('INVOKE reason="eval RETRY with functional failure, codex appropriate"')
    sys.exit(0)

if alias == 'gemini' and has_structural:
    print('INVOKE reason="structural issue detected, gemini appropriate"')
    sys.exit(0)

if judgment == 'PASS':
    skip_on_pass = policy.get('skip_if_eval_pass', False)
    if skip_on_pass:
        print(f'SKIP reason="eval passed, skip_if_eval_pass=true for {alias}"')
        sys.exit(1)

print('INVOKE reason="fallback: no specific condition matched, defaulting to invoke"')
sys.exit(0)
PYEOF

RESULT=$(python3 "$TMPPY" "$ALIAS" "$CONTEXT" "$FAILURE_MODE" "$PHASE" "$CONFIG_FILE" "$LATEST_EVAL" "$STATE_FILE" 2>&1)
PYTHON_EXIT=$?

echo "$RESULT"
echo "[$(date '+%H:%M:%S')] [should-invoke] $ALIAS ctx=$CONTEXT fail=$FAILURE_MODE phase=$PHASE → $RESULT" >> "$LOG_DIR/session-log.md"

exit $PYTHON_EXIT
