#!/bin/bash
# invoke-model.sh — Unified Advisor model dispatcher (v6)
# Usage: invoke-model.sh [options] <alias> <prompt>
# Example: invoke-model.sh opus "리뷰해줘"
#          invoke-model.sh --policy-check --context review --failure-mode functional --phase A codex "리뷰해줘"
#          invoke-model.sh --force codex "반드시 실행"
#
# Options (v6):
#   --policy-check    should-invoke.sh로 호출 여부 판단 후 실행
#   --force           정책 무시, 무조건 실행
#   --context <ctx>   호출 컨텍스트 (review, debug, implementation 등)
#   --failure-mode <m> 실패 유형 (functional, structural, both, none)
#   --phase <p>       리뷰 Phase (A, B, C)
#
# 옵션 없으면 v5 동작 그대로 (무조건 실행)
#
# Aliases: opus, codex, gemini
# 모든 모델은 Advisor 전용 (tools=none, 텍스트 응답만)
#
# Environment variables:
#   ORCH_OUTPUT_FILE — 결과를 이 파일에 저장 (stdout 캡처 문제 우회)
#   ORCH_LOG_DIR     — 로그 디렉토리

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/../models.env" ] && source "$SCRIPT_DIR/../models.env"

# --- v6 옵션 파싱 ---
POLICY_CHECK=false
FORCE=false
CONTEXT=""
FAILURE_MODE="none"
PHASE="A"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy-check)  POLICY_CHECK=true; shift ;;
    --force)         FORCE=true; shift ;;
    --context)       CONTEXT="$2"; shift 2 ;;
    --failure-mode)  FAILURE_MODE="$2"; shift 2 ;;
    --phase)         PHASE="$2"; shift 2 ;;
    -*)              shift ;;  # 미지원 옵션 무시
    *)               break ;;  # alias 시작
  esac
done

ALIAS="$1"
PROMPT="${2:-}"
LOG_BASE="${ORCH_LOG_DIR:-$PWD/.orchestration/results}"
mkdir -p "$LOG_BASE" 2>/dev/null
LOG_DIR="$(cd "$LOG_BASE" 2>/dev/null && pwd)"

if [ -z "$ALIAS" ] || [ -z "$PROMPT" ]; then
  echo "Error: alias and prompt are required" >&2
  echo "Usage: invoke-model.sh [options] <alias> <prompt>" >&2
  echo "Aliases: opus, codex, gemini" >&2
  exit 1
fi

# --- v6 정책 체크 (--force > --policy-check > 기본) ---
if [ "$FORCE" = true ]; then
  # --force: 정책 무시, 무조건 실행
  if [ -n "$LOG_DIR" ]; then
    echo "[$(date '+%H:%M:%S')] [$ALIAS] FORCE invoke (policy bypassed)" >> "$LOG_DIR/session-log.md"
  fi
elif [ "$POLICY_CHECK" = true ]; then
  # --policy-check: should-invoke.sh 호출
  POLICY_RESULT=$(bash "$SCRIPT_DIR/should-invoke.sh" "$ALIAS" "$CONTEXT" "$FAILURE_MODE" "$PHASE" 2>&1)
  POLICY_EXIT=$?
  if [ $POLICY_EXIT -ne 0 ]; then
    # SKIP
    if [ -n "$LOG_DIR" ]; then
      echo "[$(date '+%H:%M:%S')] [$ALIAS] SKIPPED by policy: $POLICY_RESULT" >> "$LOG_DIR/session-log.md"
    fi
    echo "$POLICY_RESULT" >&2
    exit 2  # exit 2 = skipped by policy (구분용)
  fi
  # INVOKE — 계속 진행
  if [ -n "$LOG_DIR" ]; then
    echo "[$(date '+%H:%M:%S')] [$ALIAS] POLICY INVOKE: $POLICY_RESULT" >> "$LOG_DIR/session-log.md"
  fi
fi
# 옵션 없으면 v5 동작: 무조건 실행

# --- Agent prompt injection ---
PROMPTS_DIR="$SCRIPT_DIR/../prompts"
get_agent_prompt_file() {
  case "$1" in
    codex)         echo "$PROMPTS_DIR/debugger.md" ;;
    gemini)        echo "$PROMPTS_DIR/researcher.md" ;;
    opus)          echo "$PROMPTS_DIR/code-reviewer.md" ;;
    *)             echo "" ;;
  esac
}

AGENT_FILE=$(get_agent_prompt_file "$ALIAS")
if [ -n "$AGENT_FILE" ] && [ -f "$AGENT_FILE" ]; then
  AGENT_SYSTEM=$(cat "$AGENT_FILE")
  FULL_PROMPT="${AGENT_SYSTEM}

---

${PROMPT}"
else
  FULL_PROMPT="$PROMPT"
fi

# --- Log start ---
if [ -n "$LOG_DIR" ]; then
  echo "[$(date '+%H:%M:%S')] [$ALIAS] START: ${PROMPT:0:80}..." >> "$LOG_DIR/session-log.md"
fi

# --- Dispatch (파일 기반 출력) ---
RESULT_TMPFILE=$(mktemp /tmp/orch_result_XXXXXX.txt)
cleanup_result() { rm -f "$RESULT_TMPFILE" 2>/dev/null; }
trap cleanup_result EXIT INT TERM

dispatch_to_file() {
  local MODEL_ALIAS="$1"
  local MODEL_PROMPT="$2"
  local OUT_FILE="$3"

  case "$MODEL_ALIAS" in
    opus)
      bash "$SCRIPT_DIR/invoke-claude.sh" "opus" "$MODEL_PROMPT" > "$OUT_FILE" 2>"${OUT_FILE}.err"
      ;;
    codex)
      bash "$SCRIPT_DIR/invoke-codex.sh" "${CODEX_MODEL:-gpt-5.3-codex}" "$MODEL_PROMPT" > "$OUT_FILE" 2>"${OUT_FILE}.err"
      ;;
    gemini)
      bash "$SCRIPT_DIR/invoke-gemini.sh" "${GEMINI_MODEL:-gemini-3-pro-preview}" "$MODEL_PROMPT" > "$OUT_FILE" 2>"${OUT_FILE}.err"
      ;;
    *)
      echo "Unknown model alias: $MODEL_ALIAS" >&2
      echo "Available: opus, codex, gemini" >&2
      return 1
      ;;
  esac
}

DISPATCH_EXIT=0
dispatch_to_file "$ALIAS" "$FULL_PROMPT" "$RESULT_TMPFILE" || DISPATCH_EXIT=$?

# --- 결과 파일 크기 계산 ---
RESULT_SIZE=$(wc -c < "$RESULT_TMPFILE" 2>/dev/null || echo "0")

# --- Log end ---
if [ -n "$LOG_DIR" ]; then
  echo "[$(date '+%H:%M:%S')] [$ALIAS] DONE (${RESULT_SIZE} bytes)" >> "$LOG_DIR/session-log.md"
fi

# --- 출력: ORCH_OUTPUT_FILE이 지정되면 파일로, 아니면 stdout ---
OUTPUT_FILE="${ORCH_OUTPUT_FILE:-}"
if [ -n "$OUTPUT_FILE" ]; then
  cp "$RESULT_TMPFILE" "$OUTPUT_FILE"
else
  cat "$RESULT_TMPFILE"
fi

exit $DISPATCH_EXIT
