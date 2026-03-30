#!/bin/bash
# log-outcome.sh — v6 운영 지표 기록 (기록만, 자동 정책 변경 금지)
# Usage:
#   log-outcome.sh \
#     --execution-id <id> \
#     --model <alias> \
#     --context <context> \
#     --failure-mode <mode> \
#     --phase <phase> \
#     --contributed <true|false> \
#     --adopted <count> \
#     --total <count> \
#     --retry-count <count> \
#     --rate-limit-hit <true|false>
#
# 출력: .orchestration/results/policy-log.jsonl에 1줄 append

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
LOG_FILE="$PROJECT_ROOT/.orchestration/results/policy-log.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

# 인자 파싱
EXEC_ID="" MODEL="" CONTEXT="" FAILURE_MODE="" PHASE=""
CONTRIBUTED="false" ADOPTED=0 TOTAL=0 RETRY_COUNT=0 RATE_LIMIT="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execution-id)   EXEC_ID="$2"; shift 2 ;;
    --model)          MODEL="$2"; shift 2 ;;
    --context)        CONTEXT="$2"; shift 2 ;;
    --failure-mode)   FAILURE_MODE="$2"; shift 2 ;;
    --phase)          PHASE="$2"; shift 2 ;;
    --contributed)    CONTRIBUTED="$2"; shift 2 ;;
    --adopted)        ADOPTED="$2"; shift 2 ;;
    --total)          TOTAL="$2"; shift 2 ;;
    --retry-count)    RETRY_COUNT="$2"; shift 2 ;;
    --rate-limit-hit) RATE_LIMIT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$MODEL" ]; then
  echo '{"error": "model required"}' >&2
  exit 1
fi

# JSONL 1줄 생성 (Python으로 안전하게)
TMPPY=$(mktemp /tmp/log_outcome_XXXXXX.py)
trap "rm -f '$TMPPY'" EXIT INT TERM

cat > "$TMPPY" << 'PYEOF'
import json, sys
from datetime import datetime

entry = {
    "timestamp": datetime.now().astimezone().isoformat(),
    "execution_id": sys.argv[1],
    "model": sys.argv[2],
    "invocation": {
        "context": sys.argv[3],
        "failure_mode": sys.argv[4],
        "phase": sys.argv[5]
    },
    "outcome": {
        "contributed": sys.argv[6].lower() == "true",
        "adopted_issues": int(sys.argv[7]),
        "total_issues": int(sys.argv[8]),
        "adoption_rate": round(int(sys.argv[7]) / max(int(sys.argv[8]), 1), 2)
    },
    "recovery": {
        "retry_count": int(sys.argv[9]),
        "resolved_by": None
    },
    "rate_limit": {
        "hit": sys.argv[10].lower() == "true",
        "remaining_quota": None
    }
}

log_file = sys.argv[11]
line = json.dumps(entry, ensure_ascii=False)

with open(log_file, 'a', encoding='utf-8') as f:
    f.write(line + '\n')

print(line)
PYEOF

python3 "$TMPPY" "$EXEC_ID" "$MODEL" "$CONTEXT" "$FAILURE_MODE" "$PHASE" \
  "$CONTRIBUTED" "$ADOPTED" "$TOTAL" "$RETRY_COUNT" "$RATE_LIMIT" "$LOG_FILE"
