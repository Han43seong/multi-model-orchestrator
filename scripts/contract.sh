#!/bin/bash
# contract.sh — Contract Phase: 구현 전 성공 기준 사전 합의
# Usage:
#   contract.sh --task "작업 설명" [--context "설계 요약"]
#
# 출력: .orchestration/contracts/<task_id>-contract.json
#
# 흐름:
#   1. Claude가 Contract 초안 생성 (criteria JSON)
#   2. Codex가 검증 가능성 검토
#   3. 최대 2라운드 협상 → 합의 or Claude 판정
#
# bypass: BYPASS_CONTRACT=1 → 즉시 종료

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.json"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
LOG_DIR="${ORCH_LOG_DIR:-$PROJECT_ROOT/.orchestration/results}"
mkdir -p "$LOG_DIR" 2>/dev/null

# --- bypass 체크 ---
if [ "${BYPASS_CONTRACT:-0}" = "1" ]; then
  echo "[$(date '+%H:%M:%S')] [contract] BYPASSED (stress_test)" >> "$LOG_DIR/session-log.md"
  echo '{"status": "bypassed", "reason": "stress_test"}'
  exit 0
fi

# --- 인자 파싱 ---
TASK=""
CONTEXT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)    TASK="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$TASK" ]; then
  echo '{"error": "task required (--task \"description\")"}' >&2
  exit 1
fi

# --- config 로드 ---
TMPPY_CFG=$(mktemp /tmp/contract_cfg_XXXXXX.py)
trap "rm -f '$TMPPY_CFG'" EXIT INT TERM

cat > "$TMPPY_CFG" << 'PYEOF'
import json, sys
config = json.load(open(sys.argv[1], encoding='utf-8'))
c = config.get('contract', {})
print(json.dumps({
    'enabled': c.get('enabled', True),
    'max_rounds': c.get('max_negotiation_rounds', 2),
    'reviewer': c.get('reviewer_model', 'codex'),
    'max_criteria': c.get('max_criteria', 10),
    'contract_dir': c.get('contract_dir', '.orchestration/contracts')
}))
PYEOF

CONTRACT_CFG=$(python3 "$TMPPY_CFG" "$CONFIG_FILE" 2>/dev/null)
rm -f "$TMPPY_CFG"

ENABLED=$(echo "$CONTRACT_CFG" | python3 -c "import json,sys; print(json.load(sys.stdin)['enabled'])" 2>/dev/null)
MAX_ROUNDS=$(echo "$CONTRACT_CFG" | python3 -c "import json,sys; print(json.load(sys.stdin)['max_rounds'])" 2>/dev/null)
REVIEWER=$(echo "$CONTRACT_CFG" | python3 -c "import json,sys; print(json.load(sys.stdin)['reviewer'])" 2>/dev/null)
MAX_CRITERIA=$(echo "$CONTRACT_CFG" | python3 -c "import json,sys; print(json.load(sys.stdin)['max_criteria'])" 2>/dev/null)
CONTRACT_DIR_REL=$(echo "$CONTRACT_CFG" | python3 -c "import json,sys; print(json.load(sys.stdin)['contract_dir'])" 2>/dev/null)

if [ "$ENABLED" = "False" ]; then
  echo '{"status": "disabled", "reason": "contract.enabled=false in config"}'
  exit 0
fi

# --- 디렉토리 준비 ---
CONTRACT_DIR="$PROJECT_ROOT/$CONTRACT_DIR_REL"
mkdir -p "$CONTRACT_DIR" 2>/dev/null

TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
TASK_ID="task-${TIMESTAMP}"
CONTRACT_FILE="$CONTRACT_DIR/${TASK_ID}-contract.json"

echo "[$(date '+%H:%M:%S')] [contract] START task_id=$TASK_ID" >> "$LOG_DIR/session-log.md"

# --- Step 1: Claude가 Contract 초안 생성 ---
DRAFT_PROMPT="You are generating a test contract for a development task. Create specific, verifiable success criteria.

Task: ${TASK}
${CONTEXT:+Context: ${CONTEXT}}

Respond in this exact JSON format (NO other text):
{
  \"criteria\": [
    {
      \"id\": \"C-001\",
      \"feature\": \"feature name\",
      \"verification\": \"specific action to verify (e.g., click X, call API Y, check DB Z)\",
      \"pass_condition\": \"exact condition for PASS (no ambiguity)\"
    }
  ]
}

Rules:
- Max ${MAX_CRITERIA} criteria
- Each pass_condition must be binary (PASS or FAIL, no gray area)
- verification must describe a concrete, reproducible action
- Focus on functional correctness, not style"

DRAFT_CONTENT=$(bash "$SCRIPT_DIR/invoke-model.sh" opus "$DRAFT_PROMPT" 2>/dev/null)

if [ -z "$DRAFT_CONTENT" ]; then
  echo '{"error": "failed to generate contract draft"}' >&2
  echo "[$(date '+%H:%M:%S')] [contract] FAILED draft generation" >> "$LOG_DIR/session-log.md"
  exit 1
fi

# --- Draft를 임시 파일에 저장 (쉘 인자 전달 문제 우회) ---
DRAFT_TMPFILE=$(mktemp /tmp/contract_draft_content_XXXXXX.txt)
echo "$DRAFT_CONTENT" > "$DRAFT_TMPFILE"

# --- Contract JSON 생성 (Python) ---
TMPPY=$(mktemp /tmp/contract_build_XXXXXX.py)

cat > "$TMPPY" << 'PYEOF'
import json, sys, re
from datetime import datetime

task_id = sys.argv[1]
task_desc = sys.argv[2]
draft_file = sys.argv[3]
contract_file = sys.argv[4]

draft_content = open(draft_file, encoding='utf-8', errors='replace').read()

# JSON 추출
json_match = re.search(r'\{[\s\S]*"criteria"[\s\S]*\}', draft_content)
criteria = []
if json_match:
    try:
        parsed = json.loads(json_match.group())
        criteria = parsed.get('criteria', [])
    except Exception:
        pass

if not criteria:
    print(json.dumps({"error": "failed to parse criteria from draft"}))
    sys.exit(1)

contract = {
    "task_id": task_id,
    "description": task_desc,
    "criteria": criteria,
    "negotiation_round": 0,
    "status": "draft",
    "created_at": datetime.now().astimezone().isoformat(),
    "history": []
}

with open(contract_file, 'w', encoding='utf-8') as f:
    json.dump(contract, f, indent=2, ensure_ascii=False)

print(json.dumps(contract, indent=2, ensure_ascii=False))
PYEOF

DRAFT_CONTRACT=$(python3 "$TMPPY" "$TASK_ID" "$TASK" "$DRAFT_TMPFILE" "$CONTRACT_FILE" 2>&1)
PARSE_EXIT=$?
rm -f "$TMPPY" "$DRAFT_TMPFILE"

if [ $PARSE_EXIT -ne 0 ]; then
  echo "$DRAFT_CONTRACT" >&2
  echo "[$(date '+%H:%M:%S')] [contract] FAILED parse draft" >> "$LOG_DIR/session-log.md"
  exit 1
fi

echo "[$(date '+%H:%M:%S')] [contract] DRAFT created ($TASK_ID)" >> "$LOG_DIR/session-log.md"

# --- Step 2: Codex 리뷰 + 협상 루프 ---
CURRENT_ROUND=0

while [ $CURRENT_ROUND -lt $MAX_ROUNDS ]; do
  CURRENT_ROUND=$((CURRENT_ROUND + 1))

  # Codex에게 Contract 검토 요청
  CRITERIA_JSON=$(python3 -c "import json; c=json.load(open('$CONTRACT_FILE',encoding='utf-8')); print(json.dumps(c['criteria'], indent=2, ensure_ascii=False))" 2>/dev/null)

  REVIEW_PROMPT="Review this test contract for a development task. Be critical and precise.

Task: ${TASK}

Contract criteria:
${CRITERIA_JSON}

Check for:
1. Ambiguous pass_conditions (could be interpreted multiple ways)
2. Missing criteria (important functionality not covered)
3. Unverifiable criteria (no concrete way to test)
4. Redundant criteria (overlapping checks)

Respond in this exact JSON format (NO other text):
{
  \"verdict\": \"APPROVE|REVISE\",
  \"issues\": [
    {\"criteria_id\": \"C-001\", \"problem\": \"description\", \"suggestion\": \"fix\"}
  ],
  \"missing\": [
    {\"feature\": \"name\", \"reason\": \"why it should be tested\"}
  ]
}

If all criteria are clear, verifiable, and complete, respond with verdict APPROVE and empty issues/missing arrays."

  REVIEW_CONTENT=$(bash "$SCRIPT_DIR/invoke-model.sh" "$REVIEWER" "$REVIEW_PROMPT" 2>/dev/null)

  if [ -z "$REVIEW_CONTENT" ]; then
    echo "[$(date '+%H:%M:%S')] [contract] WARN round=$CURRENT_ROUND reviewer returned empty, forcing agree" >> "$LOG_DIR/session-log.md"
    break
  fi

  # 리뷰 결과 파싱 + Contract 업데이트
  TMPPY_NEG=$(mktemp /tmp/contract_negotiate_XXXXXX.py)
  cat > "$TMPPY_NEG" << 'PYEOF'
import json, sys, re
from datetime import datetime

contract_file = sys.argv[1]
review_content = sys.argv[2]
current_round = int(sys.argv[3])
max_criteria = int(sys.argv[4])

contract = json.load(open(contract_file, encoding='utf-8'))

# 리뷰 JSON 추출
json_match = re.search(r'\{[\s\S]*"verdict"[\s\S]*\}', review_content)
review = {"verdict": "APPROVE", "issues": [], "missing": []}
if json_match:
    try:
        review = json.loads(json_match.group())
    except Exception:
        pass

verdict = review.get('verdict', 'APPROVE').upper()
issues = review.get('issues', [])
missing = review.get('missing', [])

# 히스토리 기록
contract['history'].append({
    'round': current_round,
    'reviewer_verdict': verdict,
    'issues_count': len(issues),
    'missing_count': len(missing),
    'timestamp': datetime.now().astimezone().isoformat()
})
contract['negotiation_round'] = current_round

if verdict == 'APPROVE' and len(issues) == 0 and len(missing) == 0:
    contract['status'] = 'agreed'
    with open(contract_file, 'w', encoding='utf-8') as f:
        json.dump(contract, f, indent=2, ensure_ascii=False)
    print(json.dumps({"action": "agreed", "round": current_round}))
    sys.exit(0)

# REVISE: issues 반영 + missing 추가
for issue in issues:
    cid = issue.get('criteria_id', '')
    suggestion = issue.get('suggestion', '')
    if suggestion:
        for c in contract['criteria']:
            if c['id'] == cid:
                c['pass_condition'] = suggestion
                break

# missing → 새 criteria 추가
existing_count = len(contract['criteria'])
for i, m in enumerate(missing):
    if existing_count + i + 1 > max_criteria:
        break
    new_id = f"C-{existing_count + i + 1:03d}"
    contract['criteria'].append({
        'id': new_id,
        'feature': m.get('feature', ''),
        'verification': f"Verify: {m.get('reason', '')}",
        'pass_condition': f"{m.get('feature', '')} works as expected"
    })

contract['status'] = 'negotiating'
with open(contract_file, 'w', encoding='utf-8') as f:
    json.dump(contract, f, indent=2, ensure_ascii=False)

print(json.dumps({"action": "revised", "round": current_round, "issues": len(issues), "added": len(missing)}))
PYEOF

  NEG_RESULT=$(python3 "$TMPPY_NEG" "$CONTRACT_FILE" "$REVIEW_CONTENT" "$CURRENT_ROUND" "$MAX_CRITERIA" 2>&1)
  rm -f "$TMPPY_NEG"

  ACTION=$(echo "$NEG_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('action','unknown'))" 2>/dev/null || echo "unknown")
  echo "[$(date '+%H:%M:%S')] [contract] round=$CURRENT_ROUND action=$ACTION" >> "$LOG_DIR/session-log.md"

  if [ "$ACTION" = "agreed" ]; then
    break
  fi
done

# --- Step 3: 합의 실패 시 Claude 판정으로 확정 ---
TMPPY_FINAL=$(mktemp /tmp/contract_finalize_XXXXXX.py)
cat > "$TMPPY_FINAL" << 'PYEOF'
import json, sys
from datetime import datetime

contract_file = sys.argv[1]
contract = json.load(open(contract_file, encoding='utf-8'))

if contract['status'] != 'agreed':
    contract['status'] = 'agreed'
    contract['history'].append({
        'round': contract['negotiation_round'] + 1,
        'reviewer_verdict': 'FORCED_AGREE',
        'issues_count': 0,
        'missing_count': 0,
        'timestamp': datetime.now().astimezone().isoformat(),
        'note': 'Max negotiation rounds reached, Claude forced agreement'
    })
    with open(contract_file, 'w', encoding='utf-8') as f:
        json.dump(contract, f, indent=2, ensure_ascii=False)

print(json.dumps(contract, indent=2, ensure_ascii=False))
PYEOF

FINAL_CONTRACT=$(python3 "$TMPPY_FINAL" "$CONTRACT_FILE" 2>&1)
rm -f "$TMPPY_FINAL"

echo "$FINAL_CONTRACT"

# latest 심볼릭 링크 (또는 복사)
cp "$CONTRACT_FILE" "$CONTRACT_DIR/latest-contract.json" 2>/dev/null

STATUS=$(echo "$FINAL_CONTRACT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")
CRITERIA_COUNT=$(echo "$FINAL_CONTRACT" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('criteria',[])))" 2>/dev/null || echo "0")
echo "[$(date '+%H:%M:%S')] [contract] DONE status=$STATUS criteria=$CRITERIA_COUNT task_id=$TASK_ID" >> "$LOG_DIR/session-log.md"

echo "ORCH_CONTRACT_FILE=$CONTRACT_FILE"
