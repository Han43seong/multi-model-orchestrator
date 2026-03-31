#!/bin/bash
# install.sh — Multi-Model Orchestrator v6 설치 스크립트
# Usage: bash install.sh
#
# 설치 대상:
#   ~/.claude/orchestration/   (scripts, prompts, config, models.env)
#   ~/.claude/commands/        (8개 슬래시 커맨드)
#
# 기존 파일이 있으면 백업 후 덮어쓰기.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_ORCH="$HOME/.claude/orchestration"
TARGET_CMD="$HOME/.claude/commands"
BACKUP_DIR="$HOME/.claude/orchestration-backup-$(date '+%Y%m%d-%H%M%S')"

# =====================================================
# 1. CLI 도구 검증
# =====================================================
echo "=== CLI 도구 검증 ==="

check_cli() {
  local name="$1"
  local cmd="$2"
  if command -v "$cmd" &>/dev/null; then
    echo "  [OK] $name"
  else
    echo "  [MISSING] $name — 설치 필요: $3"
    MISSING_CLI=true
  fi
}

MISSING_CLI=false
check_cli "Claude" "claude" "npm install -g @anthropic-ai/claude-code"
check_cli "Codex"  "codex"  "npm install -g @openai/codex"
check_cli "Gemini" "gemini" "npm install -g @google/gemini-cli"

# Obsidian CLI (선택)
if command -v obsidian &>/dev/null; then
  echo "  [OK] Obsidian CLI"
else
  echo "  [OPTIONAL] Obsidian CLI — /plan 커맨드에 필요 (Settings > General > CLI > Register)"
fi

if [ "$MISSING_CLI" = true ]; then
  echo ""
  echo "필수 CLI 도구가 누락되었습니다. 설치 후 다시 실행하세요."
  echo "계속 진행하려면 Enter, 중단하려면 Ctrl+C"
  read -r
fi

# =====================================================
# 2. 기존 설정 백업
# =====================================================
if [ -d "$TARGET_ORCH" ]; then
  echo ""
  echo "=== 기존 설정 백업 ==="
  mkdir -p "$BACKUP_DIR"
  cp -r "$TARGET_ORCH" "$BACKUP_DIR/orchestration"
  [ -d "$TARGET_CMD" ] && cp -r "$TARGET_CMD" "$BACKUP_DIR/commands"
  echo "  백업 위치: $BACKUP_DIR"
fi

# =====================================================
# 3. 파일 복사
# =====================================================
echo ""
echo "=== 파일 설치 ==="

# orchestration 디렉토리
mkdir -p "$TARGET_ORCH/scripts" "$TARGET_ORCH/prompts"

echo "  scripts/ (16개)"
cp "$SCRIPT_DIR/scripts/"*.sh "$TARGET_ORCH/scripts/"
chmod +x "$TARGET_ORCH/scripts/"*.sh

echo "  prompts/ (6개)"
cp "$SCRIPT_DIR/prompts/"*.md "$TARGET_ORCH/prompts/"

echo "  config.json"
cp "$SCRIPT_DIR/config.json" "$TARGET_ORCH/"

echo "  models.env"
cp "$SCRIPT_DIR/models.env" "$TARGET_ORCH/"

# project-map.json (없으면 example에서 복사)
if [ ! -f "$TARGET_ORCH/project-map.json" ]; then
  if [ -f "$SCRIPT_DIR/project-map.example.json" ]; then
    echo "  project-map.json (example에서 생성 — 프로젝트에 맞게 수정하세요)"
    cp "$SCRIPT_DIR/project-map.example.json" "$TARGET_ORCH/project-map.json"
  fi
else
  echo "  project-map.json (기존 유지)"
fi

# commands 디렉토리
mkdir -p "$TARGET_CMD"
echo "  commands/ (9개)"
cp "$SCRIPT_DIR/commands/"*.md "$TARGET_CMD/"

# =====================================================
# 4. Learning System (PostgreSQL + pgvector)
# =====================================================
echo ""
echo "=== Learning System 설치 ==="

TARGET_LEARN="$TARGET_ORCH/learning"
mkdir -p "$TARGET_LEARN"

cp "$SCRIPT_DIR/learning/docker-compose.yml" "$TARGET_LEARN/"
cp "$SCRIPT_DIR/learning/init.sql" "$TARGET_LEARN/"
cp "$SCRIPT_DIR/learning/learning_db.py" "$TARGET_LEARN/"

# learning.json (API 키 설정)
if [ ! -f "$TARGET_ORCH/learning.json" ]; then
  if [ -f "$SCRIPT_DIR/learning/learning.example.json" ]; then
    echo ""
    echo "  Gemini API 키를 입력하세요 (임베딩용, https://aistudio.google.com/apikey)."
    echo "  나중에 설정하려면 Enter를 누르세요."
    printf "  GEMINI_API_KEY: "
    read -r GEMINI_KEY
    if [ -n "$GEMINI_KEY" ]; then
      sed "s/YOUR_GEMINI_API_KEY_HERE/$GEMINI_KEY/" "$SCRIPT_DIR/learning/learning.example.json" > "$TARGET_ORCH/learning.json"
      echo "  learning.json 생성 완료"
    else
      cp "$SCRIPT_DIR/learning/learning.example.json" "$TARGET_ORCH/learning.json"
      echo "  learning.json 생성 (API 키를 나중에 수정하세요: ~/.claude/orchestration/learning.json)"
    fi
  fi
else
  echo "  learning.json (기존 유지)"
fi

# Python 의존성
echo ""
echo "  Python 의존성 설치..."
pip install -q psycopg2-binary 2>/dev/null || echo "  [WARN] psycopg2-binary 설치 실패 — pip install psycopg2-binary 수동 실행"

# Docker 확인 + DB 시작
if command -v docker &>/dev/null; then
  echo "  [OK] Docker"
  echo ""
  echo "  Learning DB를 시작하시겠습니까? (Docker Compose)"
  echo "  시작하려면 Enter, 건너뛰려면 n"
  printf "  > "
  read -r START_DB
  if [ "$START_DB" != "n" ]; then
    cd "$TARGET_LEARN" && docker compose up -d 2>/dev/null && cd - >/dev/null
    echo "  Learning DB 시작 완료 (localhost:5433)"
  else
    echo "  건너뜀 — 나중에 실행: cd ~/.claude/orchestration/learning && docker compose up -d"
  fi
else
  echo "  [MISSING] Docker — Learning System에 필요합니다."
  echo "  Docker 설치 후: cd ~/.claude/orchestration/learning && docker compose up -d"
fi

# =====================================================
# 5. 모델 자동 감지
# =====================================================
echo ""
echo "=== 모델 자동 감지 ==="
bash "$TARGET_ORCH/scripts/refresh-models.sh" 2>/dev/null || echo "  (자동 감지 실패 — models.env의 기본값 사용)"

# =====================================================
# 6. 완료 안내
# =====================================================
echo ""
echo "=== 설치 완료 ==="
echo ""
echo "다음 단계:"
echo "  1. ~/.claude/CLAUDE.md에 오케스트레이션 규칙을 추가하세요."
echo "     (참고: claude-md-snippet.md)"
echo ""
echo "  2. /plan, /harness 커맨드를 사용하려면:"
echo "     - Obsidian CLI 등록: Settings > General > CLI > Register"
echo "     - project-map.json을 프로젝트에 맞게 수정"
echo ""
echo "  3. Learning System:"
echo "     - DB 상태 확인: python3 ~/.claude/orchestration/learning/learning_db.py db-status"
echo "     - Gemini API 키 수정: ~/.claude/orchestration/learning.json"
echo ""
echo "  4. Claude Code에서 / 입력 시 9개 커맨드가 표시됩니다:"
echo "     /delegate /parallel /sequential /adversarial"
echo "     /consensus /orchestrate /plan /experiment /harness"
echo ""
echo "  5. 테스트: /delegate codex 안녕하세요"
