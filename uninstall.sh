#!/bin/bash
# uninstall.sh — Multi-Model Orchestrator 제거
# Usage: bash uninstall.sh
#
# 제거 대상:
#   ~/.claude/orchestration/
#   ~/.claude/commands/ 내 오케스트레이션 커맨드

set -euo pipefail

TARGET_ORCH="$HOME/.claude/orchestration"
TARGET_CMD="$HOME/.claude/commands"

echo "=== Multi-Model Orchestrator 제거 ==="
echo ""

# orchestration 디렉토리
if [ -d "$TARGET_ORCH" ]; then
  echo "삭제: $TARGET_ORCH"
  rm -rf "$TARGET_ORCH"
  echo "  [OK]"
else
  echo "  $TARGET_ORCH 없음 (이미 제거됨)"
fi

# commands
COMMANDS=(
  delegate.md parallel.md sequential.md adversarial.md
  consensus.md orchestrate.md plan.md experiment.md
)

echo ""
echo "삭제: 슬래시 커맨드"
for CMD in "${COMMANDS[@]}"; do
  if [ -f "$TARGET_CMD/$CMD" ]; then
    rm -f "$TARGET_CMD/$CMD"
    echo "  [OK] $CMD"
  fi
done

echo ""
echo "=== 제거 완료 ==="
echo ""
echo "~/.claude/CLAUDE.md에서 오케스트레이션 관련 내용을 수동으로 제거하세요."
echo "프로젝트의 .orchestration/ 디렉토리(런타임 데이터)는 유지됩니다."
