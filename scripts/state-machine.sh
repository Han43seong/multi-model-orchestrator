#!/bin/bash
# state-machine.sh — v6 상태 머신: 상태 전이 관리
# Usage:
#   state-machine.sh init <plan_file> [execution_id]     — 새 실행 초기화 (DRAFT)
#   state-machine.sh transition <event> [--retry-category <functional|structural>] [--target-state <state>]
#   state-machine.sh status                               — 현재 상태 출력
#   state-machine.sh history                              — 전이 이력 출력
#
# 상태: DRAFT → REVIEW → APPROVED → IMPLEMENTING → VERIFYING → RETRYING → ESCALATED → COMPLETED / ROLLED_BACK
# Obsidian 동기화: 단방향 (시스템 → Obsidian)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.json"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
STATE_FILE="$PROJECT_ROOT/.orchestration/state.json"
LOG_DIR="$PROJECT_ROOT/.orchestration/results"

mkdir -p "$(dirname "$STATE_FILE")" "$LOG_DIR" 2>/dev/null

ACTION="${1:-}"
shift

# --- 임시 Python 파일 (MSYS 우회) ---
TMPPY=$(mktemp /tmp/state_machine_XXXXXX.py)
trap "rm -f '$TMPPY'" EXIT INT TERM

cat > "$TMPPY" << 'PYEOF'
import json, os, sys
from datetime import datetime, timezone, timedelta

action = sys.argv[1]
state_file = sys.argv[2]
config_file = sys.argv[3]
args = sys.argv[4:]  # 나머지 인자

config = json.load(open(config_file, encoding='utf-8'))
sm_cfg = config.get('state_machine', {})
valid_states = sm_cfg.get('valid_states', [])
terminal_states = sm_cfg.get('terminal_states', ['COMPLETED', 'ROLLED_BACK'])
retry_limits = sm_cfg.get('retry_limits', {'micro': 2, 'structural': 1})

# 전이 테이블: (현재상태, 이벤트) → 다음상태
TRANSITIONS = {
    (None, 'plan_created'):             'DRAFT',
    ('DRAFT', 'plan_submitted'):        'REVIEW',
    ('REVIEW', 'plan_approved'):        'APPROVED',
    ('REVIEW', 'plan_revised'):         'DRAFT',
    ('APPROVED', 'impl_started'):       'IMPLEMENTING',
    ('IMPLEMENTING', 'impl_completed'): 'VERIFYING',
    ('VERIFYING', 'eval_passed'):       'COMPLETED',
    ('VERIFYING', 'eval_retry'):        'RETRYING',
    ('VERIFYING', 'eval_escalated'):    'ESCALATED',
    ('VERIFYING', 'eval_rollback'):     'ROLLED_BACK',
    ('RETRYING', 'impl_completed'):     'VERIFYING',
    ('RETRYING', 'retry_limit_reached'): 'ESCALATED',
    ('ESCALATED', 'plan_approved'):     'APPROVED',
    ('ESCALATED', 'eval_rollback'):     'ROLLED_BACK',
    ('ROLLED_BACK', 'plan_created'):    'DRAFT',
}

# 방어 규칙: (현재상태, 이벤트) → 거부 사유
BLOCKED = {
    ('DRAFT', 'impl_started'):        '승인 없이 구현 시작 금지',
    ('IMPLEMENTING', 'eval_passed'):  '구현 중 직접 완료 불가 (VERIFYING 거쳐야 함)',
    ('ROLLED_BACK', 'impl_started'):  '롤백 후 직접 구현 불가 (새 계획 필요)',
}

def now_iso():
    return datetime.now().astimezone().isoformat()

def load_state():
    if os.path.exists(state_file):
        return json.load(open(state_file, encoding='utf-8'))
    return None

def save_state(state):
    with open(state_file, 'w', encoding='utf-8') as f:
        json.dump(state, f, indent=2, ensure_ascii=False)

def obsidian_sync(state):
    """단방향: 시스템 상태 → Obsidian 문서 status 반영"""
    plan_file = state.get('plan_file', '')
    if not plan_file:
        return
    current = state.get('current_state', '')
    status_map = {
        'DRAFT': 'draft', 'REVIEW': 'review', 'APPROVED': 'approved',
        'IMPLEMENTING': 'in-progress', 'VERIFYING': 'in-progress',
        'RETRYING': 'in-progress', 'ESCALATED': 'review',
        'COMPLETED': 'completed', 'ROLLED_BACK': 'rolled-back'
    }
    obs_status = status_map.get(current, 'draft')
    try:
        import subprocess
        subprocess.run(
            ['cmd.exe', '//c', f'obsidian property:set name=status value={obs_status} path={plan_file}'],
            capture_output=True, timeout=10
        )
    except Exception:
        pass  # Obsidian 동기화 실패는 무시

# === INIT ===
if action == 'init':
    plan_file = args[0] if args else ''
    exec_id = args[1] if len(args) > 1 else f'exec-{datetime.now().strftime("%Y%m%d-%H%M%S")}'

    state = {
        'execution_id': exec_id,
        'current_state': 'DRAFT',
        'previous_state': None,
        'retry_count': {'micro': 0, 'structural': 0},
        'retry_limits': retry_limits,
        'history': [
            {'from': None, 'to': 'DRAFT', 'event': 'plan_created', 'at': now_iso()}
        ],
        'plan_file': plan_file,
        'obsidian_sync': 'one-way'
    }
    save_state(state)
    obsidian_sync(state)
    print(json.dumps({'status': 'ok', 'state': 'DRAFT', 'execution_id': exec_id}, ensure_ascii=False))
    sys.exit(0)

# === STATUS ===
if action == 'status':
    state = load_state()
    if not state:
        print(json.dumps({'error': 'no state file'}, ensure_ascii=False))
        sys.exit(1)
    print(json.dumps({
        'current_state': state['current_state'],
        'previous_state': state.get('previous_state'),
        'execution_id': state.get('execution_id'),
        'retry_count': state.get('retry_count'),
        'plan_file': state.get('plan_file')
    }, ensure_ascii=False))
    sys.exit(0)

# === HISTORY ===
if action == 'history':
    state = load_state()
    if not state:
        print(json.dumps({'error': 'no state file'}, ensure_ascii=False))
        sys.exit(1)
    for h in state.get('history', []):
        print(f"  {h.get('from','(none)')} → {h['to']}  [{h['event']}]  {h['at']}")
    sys.exit(0)

# === TRANSITION ===
if action == 'transition':
    event = args[0] if args else ''
    retry_category = None
    target_state = None

    i = 1
    while i < len(args):
        if args[i] == '--retry-category' and i + 1 < len(args):
            retry_category = args[i + 1]
            i += 2
        elif args[i] == '--target-state' and i + 1 < len(args):
            target_state = args[i + 1]
            i += 2
        else:
            i += 1

    if not event:
        print(json.dumps({'error': 'event required'}, ensure_ascii=False))
        sys.exit(1)

    state = load_state()
    if not state:
        print(json.dumps({'error': 'no state file, run init first'}, ensure_ascii=False))
        sys.exit(1)

    current = state['current_state']

    # user_override: 임의 상태 강제 전이
    if event == 'user_override':
        if not target_state or target_state not in valid_states:
            print(json.dumps({'error': f'user_override requires valid --target-state, got: {target_state}'}, ensure_ascii=False))
            sys.exit(1)
        state['previous_state'] = current
        state['current_state'] = target_state
        state['history'].append({'from': current, 'to': target_state, 'event': 'user_override', 'at': now_iso()})
        save_state(state)
        obsidian_sync(state)
        print(json.dumps({'status': 'ok', 'from': current, 'to': target_state, 'event': 'user_override', 'warning': 'manual override'}, ensure_ascii=False))
        sys.exit(0)

    # COMPLETED 상태에서는 user_override 외 모든 이벤트 거부
    if current in terminal_states:
        print(json.dumps({'error': f'terminal state {current}, only user_override allowed'}, ensure_ascii=False))
        sys.exit(1)

    # 방어 규칙
    block_key = (current, event)
    if block_key in BLOCKED:
        print(json.dumps({'error': f'blocked: {BLOCKED[block_key]}', 'current': current, 'event': event}, ensure_ascii=False))
        sys.exit(1)

    # 전이 테이블 조회
    trans_key = (current, event)
    if trans_key not in TRANSITIONS:
        print(json.dumps({'error': f'invalid transition: {current} + {event}', 'current': current, 'event': event}, ensure_ascii=False))
        sys.exit(1)

    next_state = TRANSITIONS[trans_key]

    # eval_retry 시 retry 카운터 증가
    if event == 'eval_retry':
        if retry_category == 'structural':
            state['retry_count']['structural'] += 1
        else:
            state['retry_count']['micro'] += 1

        # limit 초과 체크
        micro_over = state['retry_count']['micro'] > state['retry_limits']['micro']
        struct_over = state['retry_count']['structural'] > state['retry_limits']['structural']
        if micro_over or struct_over:
            # retry_limit_reached → ESCALATED
            next_state = 'ESCALATED'
            event = 'retry_limit_reached'

    state['previous_state'] = current
    state['current_state'] = next_state
    state['history'].append({'from': current, 'to': next_state, 'event': event, 'at': now_iso()})
    save_state(state)
    obsidian_sync(state)

    result = {'status': 'ok', 'from': current, 'to': next_state, 'event': event}
    if event == 'retry_limit_reached':
        result['warning'] = 'retry limit exceeded, auto-escalated'
    print(json.dumps(result, ensure_ascii=False))
    sys.exit(0)

print(json.dumps({'error': f'unknown action: {action}', 'usage': 'init|transition|status|history'}, ensure_ascii=False))
sys.exit(1)
PYEOF

# --- 인자 전달 ---
python3 "$TMPPY" "$ACTION" "$STATE_FILE" "$CONFIG_FILE" "$@"
PY_EXIT=$?

# 세션 로그
if [ "$ACTION" = "transition" ]; then
  echo "[$(date '+%H:%M:%S')] [state-machine] $ACTION $* (exit:$PY_EXIT)" >> "$LOG_DIR/session-log.md"
fi

exit $PY_EXIT
