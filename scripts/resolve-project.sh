#!/usr/bin/env bash
# resolve-project.sh — Project Mapping Layer
# 현재 작업 디렉토리에서 canonical project name을 결정하고
# 공용 Vault 내 대응 경로를 반환한다.
#
# Usage:
#   bash resolve-project.sh                    # 자동 해석
#   bash resolve-project.sh --project rag      # 명시적 override
#   bash resolve-project.sh --list             # 등록된 프로젝트 목록
#
# Output (JSON):
#   { "canonical_name", "vault_path", "plans_path", "project_plan", "resolved_by", "sub_project" }

set -euo pipefail

CONFIG="$HOME/.claude/orchestration/project-map.json"
TMPPY=$(mktemp /tmp/resolve-project-XXXXXX.py)
trap "rm -f $TMPPY" EXIT

[ -f "$CONFIG" ] || { echo "ERROR: project-map.json not found at $CONFIG" >&2; exit 1; }

# ─── Main Logic (Python) ───

cat > "$TMPPY" << 'PYEOF'
import json, sys, os, fnmatch, subprocess

config_path = os.path.expanduser("~/.claude/orchestration/project-map.json")
with open(config_path, encoding="utf-8") as f:
    config = json.load(f)

vault_root = config["vault_root"]
projects = config["projects"]
fallback = config["fallback"]

cwd = os.getcwd().replace("\\", "/")
dirname = os.path.basename(cwd)

# Parse args
args = sys.argv[1:]
explicit = None
mode = "resolve"
i = 0
while i < len(args):
    if args[i] in ("--project", "-p"):
        explicit = args[i+1]; i += 2
    elif args[i] in ("--list", "-l"):
        mode = "list"; i += 1
    else:
        i += 1

# ─── List mode ───
if mode == "list":
    print("등록된 프로젝트:")
    for p in projects:
        aliases = ", ".join(p["match"].get("aliases", []))
        repos = ", ".join(p["match"].get("repo_names", []))
        print(f"  {p['canonical_name']:20s} aliases=[{aliases}]  repos=[{repos}]")
    sys.exit(0)

# ─── Resolution ───

def get_git_repo_name():
    try:
        url = subprocess.check_output(
            ["git", "remote", "get-url", "origin"],
            stderr=subprocess.DEVNULL, text=True
        ).strip()
        return os.path.basename(url).replace(".git", "")
    except Exception:
        return None

def find_by_alias(alias):
    a = alias.lower()
    for p in projects:
        if a == p["canonical_name"].lower():
            return p
        if a in [x.lower() for x in p["match"].get("aliases", [])]:
            return p
    return None

def find_by_repo_name(repo):
    for p in projects:
        if repo in p["match"].get("repo_names", []):
            return p
    return None

def find_by_directory(dname):
    for p in projects:
        for pattern in p["match"].get("directory_patterns", []):
            if fnmatch.fnmatch(dname, pattern) or fnmatch.fnmatch(dname.lower(), pattern.lower()):
                return p
    return None

def get_sub_project(proj, dname, repo):
    subs = proj.get("sub_projects", {})
    for key, val in subs.items():
        if key == dname or key == repo:
            return val
    return None

def read_local_project_json():
    path = os.path.join(cwd, ".claude", "project.json")
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f).get("project", "")
    return ""

def read_claude_md_project():
    path = os.path.join(cwd, "CLAUDE.md")
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith("project:"):
                    return line.split(":", 1)[1].strip()
    return ""

# ─── Priority chain ───

resolved = None
resolved_by = None

# 1. Explicit override
if explicit:
    resolved = find_by_alias(explicit)
    if resolved:
        resolved_by = "explicit_override"
    else:
        print(f"ERROR: Unknown project alias: {explicit}", file=sys.stderr)
        sys.exit(1)

# 2. Local .claude/project.json
if not resolved:
    local_proj = read_local_project_json()
    if local_proj:
        resolved = find_by_alias(local_proj)
        if resolved:
            resolved_by = "local_project_json"

# 3. CLAUDE.md project: field
if not resolved:
    claude_proj = read_claude_md_project()
    if claude_proj:
        resolved = find_by_alias(claude_proj)
        if resolved:
            resolved_by = "claude_md_project_field"

# 4. Git remote repo name
repo_name = get_git_repo_name()
if not resolved and repo_name:
    resolved = find_by_repo_name(repo_name)
    if resolved:
        resolved_by = "git_remote_repo_name"

# 5. Directory basename
if not resolved:
    resolved = find_by_directory(dirname)
    if resolved:
        resolved_by = "directory_basename"

# 6. Fallback
if not resolved:
    print(f"⚠ 프로젝트를 식별할 수 없습니다.", file=sys.stderr)
    print(f"  작업 디렉토리: {cwd}", file=sys.stderr)
    print(f"  fallback: {fallback['mode']} → {fallback['draft_path']}", file=sys.stderr)
    result = {
        "canonical_name": "_UNRESOLVED",
        "vault_root": vault_root,
        "vault_path": fallback["draft_path"],
        "plans_path": fallback["draft_path"],
        "project_plan": None,
        "resolved_by": f"fallback_{fallback['mode']}",
        "sub_project": None
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))
    sys.exit(1)

# ─── Output ───

vp = resolved["vault_path"]
sub = get_sub_project(resolved, dirname, repo_name or "")

result = {
    "canonical_name": resolved["canonical_name"],
    "vault_root": vault_root,
    "vault_path": vp,
    "plans_path": f"{vp}/Plans",
    "project_plan": f"{vp}/00_ProjectPlan.md",
    "resolved_by": resolved_by,
    "sub_project": sub
}
print(json.dumps(result, indent=2, ensure_ascii=False))
PYEOF

python3 "$TMPPY" "$@"
