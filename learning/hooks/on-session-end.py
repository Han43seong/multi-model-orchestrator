"""
Claude Code Hook: 세션 종료 시 학습 시스템 연동
- 세션 로그 저장
- 사용자 선호도 추론 + 프로필 갱신

환경변수:
  CLAUDE_SESSION_ID   — 현재 세션 ID
  CLAUDE_PROJECT      — 프로젝트 경로
"""

import json
import os
import sys
import subprocess
from datetime import datetime

# learning_db.py 경로
LEARNING_DIR = os.path.expanduser("~/.claude/orchestration/learning")
LEARNING_DB = os.path.join(LEARNING_DIR, "learning_db.py")

def get_session_info():
    """환경변수에서 세션 정보 수집"""
    return {
        "session_id": os.environ.get("CLAUDE_SESSION_ID", f"sess-{datetime.now().strftime('%Y%m%d-%H%M%S')}"),
        "project": os.environ.get("CLAUDE_PROJECT", os.path.basename(os.getcwd())),
    }

def store_session(info, summary="", topics=None):
    """세션 로그를 DB에 저장"""
    topics = topics or []
    cmd = [
        sys.executable, LEARNING_DB, "session-store",
        "--session-id", info["session_id"],
        "--project", info["project"],
        "--summary", summary,
        "--topics", ",".join(topics) if topics else "",
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return json.loads(result.stdout) if result.stdout.strip() else {"error": result.stderr}
    except Exception as e:
        return {"error": str(e)}

def update_profile(user_id, preferences=None, patterns=None, expertise=None):
    """사용자 프로필 갱신"""
    cmd = [
        sys.executable, LEARNING_DB, "profile-update",
        "--user", user_id,
        "--preferences", json.dumps(preferences or {}),
        "--patterns", json.dumps(patterns or {}),
        "--expertise", json.dumps(expertise or {}),
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return json.loads(result.stdout) if result.stdout.strip() else {"error": result.stderr}
    except Exception as e:
        return {"error": str(e)}

def analyze_session(transcript):
    """세션 내용을 분석하여 요약, 토픽, 선호도 추출 (stdin으로 받은 transcript 기반)"""
    # 간단한 키워드 기반 토픽 추출
    topic_keywords = {
        "docker": "docker", "fastapi": "fastapi", "react": "react",
        "typescript": "typescript", "python": "python", "postgresql": "postgresql",
        "git": "git", "api": "api", "deploy": "deployment", "debug": "debugging",
        "test": "testing", "ci/cd": "cicd", "security": "security",
        "orchestration": "orchestration", "harness": "harness",
        "vr": "vr", "unity": "unity", "rag": "rag",
    }
    text_lower = transcript.lower()
    topics = [v for k, v in topic_keywords.items() if k in text_lower]
    topics = list(set(topics))[:10]

    # 요약: 첫 200자 + 토픽
    summary = transcript[:200].replace("\n", " ").strip()
    if len(transcript) > 200:
        summary += "..."

    return {
        "summary": summary,
        "topics": topics,
    }

def main():
    # stdin에서 hook 데이터 읽기
    transcript = ""
    try:
        if not sys.stdin.isatty():
            transcript = sys.stdin.read()
    except Exception:
        pass

    info = get_session_info()
    user_id = os.environ.get("USER", os.environ.get("USERNAME", "default"))

    # 세션 분석
    analysis = analyze_session(transcript) if transcript else {"summary": "", "topics": []}

    # 세션 저장
    sess_result = store_session(info, analysis["summary"], analysis["topics"])

    # 프로필 갱신 (토픽에서 패턴 추출)
    if analysis["topics"]:
        prof_result = update_profile(
            user_id=user_id,
            patterns={"recent_topics": analysis["topics"]},
        )
    else:
        prof_result = {"action": "skipped", "reason": "no topics"}

    result = {
        "hook": "on-session-end",
        "session": sess_result,
        "profile": prof_result,
        "timestamp": datetime.now().isoformat()
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))

if __name__ == "__main__":
    main()
