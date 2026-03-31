"""
Claude Code Hook: 세션 시작 시 학습 시스템 연동
- 사용자 프로필 로드 → 컨텍스트 주입용 텍스트 출력
- 현재 작업과 유사한 스킬 검색 → scaffold 제공

환경변수:
  CLAUDE_PROJECT      — 프로젝트 경로
  CLAUDE_TASK         — 현재 태스크 설명 (있으면)
"""

import json
import os
import sys
import subprocess

LEARNING_DIR = os.path.expanduser("~/.claude/orchestration/learning")
LEARNING_DB = os.path.join(LEARNING_DIR, "learning_db.py")

def run_learning_cmd(args):
    """learning_db.py 실행"""
    cmd = [sys.executable, LEARNING_DB] + args
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if result.stdout.strip():
            return json.loads(result.stdout)
    except Exception:
        pass
    return None

def load_profile():
    """사용자 프로필 로드"""
    user_id = os.environ.get("USER", os.environ.get("USERNAME", "default"))
    return run_learning_cmd(["profile-load", "--user", user_id])

def search_relevant_skills(task_description):
    """현재 작업과 유사한 스킬 검색"""
    if not task_description:
        return None
    return run_learning_cmd(["skill-search", "--query", task_description, "--top", "3", "--threshold", "0.4"])

def format_profile_context(profile):
    """프로필을 컨텍스트 텍스트로 변환"""
    if not profile or "error" in profile:
        return ""

    lines = ["[User Profile]"]
    prefs = profile.get("preferences", {})
    if prefs:
        lines.append(f"Preferences: {json.dumps(prefs, ensure_ascii=False)}")
    expertise = profile.get("expertise", {})
    if expertise:
        strong = expertise.get("strong", [])
        learning = expertise.get("learning", [])
        if strong:
            lines.append(f"Strong: {', '.join(strong)}")
        if learning:
            lines.append(f"Learning: {', '.join(learning)}")
    patterns = profile.get("patterns", {})
    if patterns:
        lines.append(f"Patterns: {json.dumps(patterns, ensure_ascii=False)}")

    return "\n".join(lines)

def format_skill_scaffold(search_result):
    """검색된 스킬을 scaffold 텍스트로 변환"""
    if not search_result or not search_result.get("results"):
        return ""

    lines = ["[Relevant Skills from Past Experience]"]
    for skill in search_result["results"]:
        lines.append(f"\n### {skill['name']} (similarity: {skill['similarity']})")
        lines.append(f"Description: {skill['description']}")
        steps = skill.get("steps", [])
        if steps:
            if isinstance(steps, str):
                steps = json.loads(steps)
            for i, step in enumerate(steps, 1):
                lines.append(f"  {i}. {step}")

    return "\n".join(lines)

def main():
    task = os.environ.get("CLAUDE_TASK", "")

    # 프로필 로드
    profile = load_profile()
    profile_ctx = format_profile_context(profile)

    # 스킬 검색 (태스크가 있으면)
    skill_ctx = ""
    if task:
        skills = search_relevant_skills(task)
        skill_ctx = format_skill_scaffold(skills)

    # 결과 출력
    output = {
        "hook": "on-session-start",
        "profile_context": profile_ctx,
        "skill_scaffold": skill_ctx,
        "has_profile": bool(profile and "error" not in profile),
        "has_skills": bool(skill_ctx),
    }
    print(json.dumps(output, indent=2, ensure_ascii=False))

if __name__ == "__main__":
    main()
