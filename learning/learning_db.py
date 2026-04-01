"""
Orchestration Learning System — DB Operations
PostgreSQL + pgvector + OpenAI Embeddings

Usage:
    python learning_db.py <command> [args...]

Commands:
    skill-store     --name "..." --description "..." --category "..." --tags "a,b" --steps '["..."]' --session "..."
    skill-search    --query "..." [--top 3] [--threshold 0.3]
    skill-fts       --query "keyword"
    skill-record    --id N --session "..."
    skill-archive   [--days 90]
    skill-cap       --category "..." [--cap 20]
    skill-dedup     --id N [--threshold 0.95]
    session-store   --session-id "..." --project "..." --summary "..." --topics "a,b" [--tool-calls N] [--files-changed N] [--models "a,b"] [--raw-log "..."]
    session-search  --query "..." [--top 5] [--mode vector|fts|hybrid] [--after "YYYY-MM-DD"] [--before "YYYY-MM-DD"]
    profile-update  --user "..." --preferences '{}' --patterns '{}' --expertise '{}'
    profile-load    --user "..."
    db-status
"""

import json
import os
import sys
import time
from datetime import datetime

import psycopg2
import psycopg2.extras

# --- Config ---
DB_HOST = os.environ.get("ORCH_DB_HOST", "localhost")
DB_PORT = os.environ.get("ORCH_DB_PORT", "5433")
DB_NAME = os.environ.get("ORCH_DB_NAME", "orchestration")
DB_USER = os.environ.get("ORCH_DB_USER", "orch")
DB_PASS = os.environ.get("ORCH_DB_PASS", "orch_local_2026")

def get_conn():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASS
    )

# --- Embedding (Gemini) ---
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")
GEMINI_EMBED_MODEL = os.environ.get("GEMINI_EMBED_MODEL", "gemini-embedding-001")

def get_gemini_key():
    if GEMINI_API_KEY:
        return GEMINI_API_KEY
    # fallback: config file
    cfg_path = os.path.expanduser("~/.claude/orchestration/learning.json")
    if os.path.exists(cfg_path):
        with open(cfg_path, encoding="utf-8") as f:
            return json.load(f).get("gemini_api_key", "")
    return ""

def get_embedding(text: str) -> list:
    import urllib.request
    key = get_gemini_key()
    if not key:
        raise ValueError("GEMINI_API_KEY not set. Export it or add to ~/.claude/orchestration/learning.json")
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_EMBED_MODEL}:embedContent?key={key}"
    data = json.dumps({
        "model": f"models/{GEMINI_EMBED_MODEL}",
        "content": {"parts": [{"text": text[:8000]}]}
    }).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    resp = json.loads(urllib.request.urlopen(req).read())
    return resp["embedding"]["values"]

# --- Skills ---
def skill_store(name, description, category="general", tags=None, steps=None,
                key_commands=None, session=None):
    tags = tags or []
    steps = steps or []
    key_commands = key_commands or []
    embedding = get_embedding(f"{name} {description} {' '.join(tags)}")

    conn = get_conn()
    cur = conn.cursor()

    # 중복 체크 (cosine similarity > 0.95)
    cur.execute("""
        SELECT id, name, 1 - (embedding <=> %s::vector) as similarity
        FROM skills WHERE status = 'active' AND embedding IS NOT NULL
        ORDER BY embedding <=> %s::vector LIMIT 1
    """, (embedding, embedding))
    row = cur.fetchone()

    if row and row[2] > 0.90:
        # 중복: 기존 스킬 갱신
        cur.execute("""
            UPDATE skills SET usage_count = usage_count + 1,
                updated_at = NOW(), last_used_at = NOW()
            WHERE id = %s
        """, (row[0],))
        conn.commit()
        result = {"action": "deduplicated", "existing_id": row[0],
                  "existing_name": row[1], "similarity": round(row[2], 4)}
        cur.close()
        conn.close()
        return result

    cur.execute("""
        INSERT INTO skills (name, description, category, tags, steps, key_commands,
                           source_session, embedding)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s::vector)
        RETURNING id
    """, (name, description, category, tags, json.dumps(steps),
          key_commands, session, embedding))
    skill_id = cur.fetchone()[0]

    # 카테고리 상한 적용
    cur.execute("SELECT enforce_category_cap(%s, 20)", (category,))
    archived = cur.fetchone()[0]

    conn.commit()
    result = {"action": "created", "id": skill_id, "name": name,
              "category": category, "archived_by_cap": archived}
    cur.close()
    conn.close()
    return result

def skill_search(query, top=3, threshold=0.3):
    embedding = get_embedding(query)
    conn = get_conn()
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    start = time.time()
    cur.execute("""
        SELECT id, name, description, category, tags, steps, usage_count,
               1 - (embedding <=> %s::vector) as similarity
        FROM skills
        WHERE status = 'active' AND embedding IS NOT NULL
        ORDER BY embedding <=> %s::vector
        LIMIT %s
    """, (embedding, embedding, top))
    rows = cur.fetchall()
    elapsed_ms = int((time.time() - start) * 1000)

    results = [dict(r) for r in rows if r["similarity"] >= threshold]
    for r in results:
        r["similarity"] = round(r["similarity"], 4)
        if isinstance(r.get("steps"), str):
            r["steps"] = json.loads(r["steps"])

    cur.close()
    conn.close()
    return {"results": results, "elapsed_ms": elapsed_ms, "query": query}

def skill_fts(query):
    conn = get_conn()
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute("""
        SELECT id, name, description, category, tags, usage_count,
               ts_rank(tsv, plainto_tsquery('english', %s)) as rank
        FROM skills
        WHERE status = 'active' AND tsv @@ plainto_tsquery('english', %s)
        ORDER BY rank DESC LIMIT 10
    """, (query, query))
    rows = cur.fetchall()
    results = [dict(r) for r in rows]
    for r in results:
        r["rank"] = round(r["rank"], 4)
    cur.close()
    conn.close()
    return {"results": results, "query": query}

def skill_record_usage(skill_id, session_id=None):
    conn = get_conn()
    cur = conn.cursor()
    cur.execute("SELECT record_skill_usage(%s, %s)", (skill_id, session_id))
    conn.commit()
    cur.close()
    conn.close()
    return {"action": "recorded", "skill_id": skill_id}

def skill_archive_stale(days=90):
    conn = get_conn()
    cur = conn.cursor()
    cur.execute("SELECT archive_stale_skills(%s)", (days,))
    count = cur.fetchone()[0]
    conn.commit()
    cur.close()
    conn.close()
    return {"action": "archive_stale", "archived_count": count, "days": days}

def skill_enforce_cap(category, cap=20):
    conn = get_conn()
    cur = conn.cursor()
    cur.execute("SELECT enforce_category_cap(%s, %s)", (category, cap))
    count = cur.fetchone()[0]
    conn.commit()
    cur.close()
    conn.close()
    return {"action": "enforce_cap", "category": category, "archived_count": count}

def skill_check_dedup(skill_id, threshold=0.95):
    conn = get_conn()
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute("SELECT embedding FROM skills WHERE id = %s", (skill_id,))
    row = cur.fetchone()
    if not row or not row["embedding"]:
        cur.close()
        conn.close()
        return {"error": "skill not found or no embedding"}

    cur.execute("""
        SELECT id, name, 1 - (embedding <=> (SELECT embedding FROM skills WHERE id = %s)) as similarity
        FROM skills
        WHERE status = 'active' AND id != %s AND embedding IS NOT NULL
        ORDER BY embedding <=> (SELECT embedding FROM skills WHERE id = %s)
        LIMIT 5
    """, (skill_id, skill_id, skill_id))
    rows = cur.fetchall()
    duplicates = [{"id": r["id"], "name": r["name"], "similarity": round(r["similarity"], 4)}
                  for r in rows if r["similarity"] >= threshold]
    cur.close()
    conn.close()
    return {"skill_id": skill_id, "duplicates": duplicates, "threshold": threshold}

# --- Sessions ---
def session_store(session_id, project=None, summary=None, topics=None,
                  tool_calls=0, files_changed=0, models=None, raw_log=None):
    topics = topics or []
    models = models or []
    embed_text = f"{summary or ''} {' '.join(topics)}"
    embedding = get_embedding(embed_text) if embed_text.strip() else None

    conn = get_conn()
    cur = conn.cursor()
    cur.execute("""
        INSERT INTO session_logs (session_id, project, summary, tool_calls, files_changed,
                                  models_used, key_topics, embedding, raw_log)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s::vector, %s)
        ON CONFLICT (session_id) DO UPDATE SET
            summary = EXCLUDED.summary,
            tool_calls = EXCLUDED.tool_calls,
            files_changed = EXCLUDED.files_changed,
            models_used = EXCLUDED.models_used,
            key_topics = EXCLUDED.key_topics,
            embedding = EXCLUDED.embedding,
            raw_log = EXCLUDED.raw_log,
            ended_at = NOW()
        RETURNING id
    """, (session_id, project, summary, tool_calls, files_changed,
          models, topics, embedding, raw_log))
    row_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    conn.close()
    return {"action": "stored", "id": row_id, "session_id": session_id}

def session_search(query, top=5, mode="hybrid", after=None, before=None):
    conn = get_conn()
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    date_filter = ""
    params = []
    if after:
        date_filter += " AND ended_at >= %s"
        params.append(after)
    if before:
        date_filter += " AND ended_at <= %s"
        params.append(before)

    results = []
    start = time.time()

    if mode in ("vector", "hybrid"):
        embedding = get_embedding(query)
        cur.execute(f"""
            SELECT id, session_id, project, summary, key_topics, ended_at,
                   1 - (embedding <=> %s::vector) as similarity
            FROM session_logs
            WHERE embedding IS NOT NULL {date_filter}
            ORDER BY embedding <=> %s::vector
            LIMIT %s
        """, [embedding] + params + [embedding, top])
        vec_rows = cur.fetchall()
        for r in vec_rows:
            d = dict(r)
            d["similarity"] = round(d["similarity"], 4)
            d["match_type"] = "vector"
            if d.get("ended_at"):
                d["ended_at"] = d["ended_at"].isoformat()
            results.append(d)

    if mode in ("fts", "hybrid"):
        cur.execute(f"""
            SELECT id, session_id, project, summary, key_topics, ended_at,
                   ts_rank(tsv, plainto_tsquery('english', %s)) as rank
            FROM session_logs
            WHERE tsv @@ plainto_tsquery('english', %s) {date_filter}
            ORDER BY rank DESC
            LIMIT %s
        """, [query, query] + params + [top])
        fts_rows = cur.fetchall()
        seen_ids = {r["id"] for r in results}
        for r in fts_rows:
            if r["id"] not in seen_ids:
                d = dict(r)
                d["rank"] = round(d["rank"], 4)
                d["match_type"] = "fts"
                if d.get("ended_at"):
                    d["ended_at"] = d["ended_at"].isoformat()
                results.append(d)

    elapsed_ms = int((time.time() - start) * 1000)
    cur.close()
    conn.close()
    return {"results": results[:top], "elapsed_ms": elapsed_ms, "mode": mode, "query": query}

# --- User Profiles ---
def profile_update(user_id, preferences=None, patterns=None, expertise=None):
    conn = get_conn()
    cur = conn.cursor()

    # 기존 프로필 로드
    cur.execute("SELECT preferences, patterns, expertise FROM user_profiles WHERE user_id = %s", (user_id,))
    row = cur.fetchone()

    if row:
        # 병합 (덮어쓰기가 아님)
        existing_pref = row[0] or {}
        existing_pat = row[1] or {}
        existing_exp = row[2] or {}

        if preferences:
            existing_pref.update(preferences)
        if patterns:
            existing_pat.update(patterns)
        if expertise:
            existing_exp.update(expertise)

        cur.execute("""
            UPDATE user_profiles SET
                preferences = %s, patterns = %s, expertise = %s, updated_at = NOW()
            WHERE user_id = %s
        """, (json.dumps(existing_pref), json.dumps(existing_pat),
              json.dumps(existing_exp), user_id))
    else:
        cur.execute("""
            INSERT INTO user_profiles (user_id, preferences, patterns, expertise)
            VALUES (%s, %s, %s, %s)
        """, (user_id, json.dumps(preferences or {}),
              json.dumps(patterns or {}), json.dumps(expertise or {})))

    conn.commit()
    cur.close()
    conn.close()
    return {"action": "updated", "user_id": user_id}

def create_indexes():
    conn = get_conn()
    cur = conn.cursor()
    results = {}
    for table, col, idx_name in [
        ("skills", "embedding", "idx_skills_embedding_ivfflat"),
        ("session_logs", "embedding", "idx_sessions_embedding_ivfflat"),
    ]:
        cur.execute(f"SELECT COUNT(*) FROM {table} WHERE {col} IS NOT NULL")
        count = cur.fetchone()[0]
        cur.execute("SELECT 1 FROM pg_indexes WHERE indexname = %s", (idx_name,))
        exists = cur.fetchone() is not None
        if exists:
            results[table] = {"status": "exists", "count": count}
        elif count >= 100:
            cur.execute(f"CREATE INDEX {idx_name} ON {table} USING ivfflat ({col} vector_cosine_ops) WITH (lists = 10)")
            conn.commit()
            results[table] = {"status": "created", "count": count}
        else:
            results[table] = {"status": "skipped", "count": count, "need": 100}
    cur.close()
    conn.close()
    return results

def profile_load(user_id):
    conn = get_conn()
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute("SELECT * FROM user_profiles WHERE user_id = %s", (user_id,))
    row = cur.fetchone()
    cur.close()
    conn.close()
    if row:
        d = dict(row)
        for k in ("updated_at", "created_at"):
            if d.get(k):
                d[k] = d[k].isoformat()
        return d
    return {"error": "user not found", "user_id": user_id}

# --- Status ---
def db_status():
    conn = get_conn()
    cur = conn.cursor()
    stats = {}
    for table in ("skills", "session_logs", "user_profiles", "skill_usage_log"):
        cur.execute(f"SELECT COUNT(*) FROM {table}")
        stats[table] = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM skills WHERE status = 'active'")
    stats["active_skills"] = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM skills WHERE status = 'archived'")
    stats["archived_skills"] = cur.fetchone()[0]
    cur.close()
    conn.close()
    return stats

# --- CLI ---
def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]
    args = {}
    i = 2
    while i < len(sys.argv):
        if sys.argv[i].startswith("--"):
            key = sys.argv[i][2:]
            val = sys.argv[i + 1] if i + 1 < len(sys.argv) else ""
            args[key] = val
            i += 2
        else:
            i += 1

    try:
        if cmd == "skill-store":
            tags = args.get("tags", "").split(",") if args.get("tags") else []
            steps = json.loads(args.get("steps", "[]"))
            cmds = args.get("commands", "").split(",") if args.get("commands") else []
            result = skill_store(
                name=args["name"], description=args["description"],
                category=args.get("category", "general"), tags=tags,
                steps=steps, key_commands=cmds, session=args.get("session"))
        elif cmd == "skill-search":
            result = skill_search(
                query=args["query"],
                top=int(args.get("top", 3)),
                threshold=float(args.get("threshold", 0.3)))
        elif cmd == "skill-fts":
            result = skill_fts(query=args["query"])
        elif cmd == "skill-record":
            result = skill_record_usage(
                skill_id=int(args["id"]), session_id=args.get("session"))
        elif cmd == "skill-archive":
            result = skill_archive_stale(days=int(args.get("days", 90)))
        elif cmd == "skill-cap":
            result = skill_enforce_cap(
                category=args["category"], cap=int(args.get("cap", 20)))
        elif cmd == "skill-dedup":
            result = skill_check_dedup(
                skill_id=int(args["id"]),
                threshold=float(args.get("threshold", 0.95)))
        elif cmd == "session-store":
            topics = args.get("topics", "").split(",") if args.get("topics") else []
            models = args.get("models", "").split(",") if args.get("models") else []
            result = session_store(
                session_id=args["session-id"], project=args.get("project"),
                summary=args.get("summary"), topics=topics,
                tool_calls=int(args.get("tool-calls", 0)),
                files_changed=int(args.get("files-changed", 0)),
                models=models, raw_log=args.get("raw-log"))
        elif cmd == "session-search":
            result = session_search(
                query=args["query"], top=int(args.get("top", 5)),
                mode=args.get("mode", "hybrid"),
                after=args.get("after"), before=args.get("before"))
        elif cmd == "profile-update":
            result = profile_update(
                user_id=args["user"],
                preferences=json.loads(args.get("preferences", "{}")),
                patterns=json.loads(args.get("patterns", "{}")),
                expertise=json.loads(args.get("expertise", "{}")))
        elif cmd == "profile-load":
            result = profile_load(user_id=args["user"])
        elif cmd == "db-status":
            result = db_status()
        elif cmd == "create-indexes":
            result = create_indexes()
        else:
            print(f"Unknown command: {cmd}")
            print(__doc__)
            sys.exit(1)

        print(json.dumps(result, indent=2, ensure_ascii=False, default=str))

    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
