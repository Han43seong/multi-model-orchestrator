-- Orchestration Learning System Schema
-- PostgreSQL + pgvector

CREATE EXTENSION IF NOT EXISTS vector;

-- ============================================================
-- Skills: 자율 생성된 경험 레시피
-- ============================================================
CREATE TABLE skills (
    id              SERIAL PRIMARY KEY,
    name            TEXT NOT NULL,
    description     TEXT NOT NULL,
    category        TEXT NOT NULL DEFAULT 'general',
    tags            TEXT[] DEFAULT '{}',
    steps           JSONB NOT NULL DEFAULT '[]',
    key_commands    TEXT[] DEFAULT '{}',
    source_session  TEXT,
    embedding       vector(3072),
    tsv             tsvector,
    status          TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'archived')),
    usage_count     INTEGER NOT NULL DEFAULT 0,
    last_used_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- hnsw: ivfflat과 달리 빈 테이블에서도 생성 가능
-- Note: vector index는 데이터 100건 이상 시 별도 생성 (ivfflat or hnsw with halfvec)
-- CREATE INDEX idx_skills_embedding ON skills USING ivfflat (embedding vector_cosine_ops) WITH (lists = 10);
CREATE INDEX idx_skills_status ON skills (status);
CREATE INDEX idx_skills_category ON skills (category);
CREATE INDEX idx_skills_tags ON skills USING gin (tags);
CREATE INDEX idx_skills_last_used ON skills (last_used_at);
CREATE INDEX idx_skills_tsv ON skills USING gin (tsv);

-- tsv 자동 갱신 트리거
CREATE OR REPLACE FUNCTION skills_tsv_trigger() RETURNS trigger AS $$
BEGIN
    NEW.tsv :=
        setweight(to_tsvector('english', coalesce(NEW.name, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(NEW.description, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(array_to_string(NEW.tags, ' '), '')), 'C');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_skills_tsv
    BEFORE INSERT OR UPDATE OF name, description, tags ON skills
    FOR EACH ROW EXECUTE FUNCTION skills_tsv_trigger();

-- ============================================================
-- Session Logs: 세션 기록 + 검색
-- ============================================================
CREATE TABLE session_logs (
    id              SERIAL PRIMARY KEY,
    session_id      TEXT NOT NULL UNIQUE,
    project         TEXT,
    summary         TEXT,
    tool_calls      INTEGER DEFAULT 0,
    files_changed   INTEGER DEFAULT 0,
    models_used     TEXT[] DEFAULT '{}',
    key_topics      TEXT[] DEFAULT '{}',
    embedding       vector(3072),
    tsv             tsvector,
    raw_log         TEXT,
    started_at      TIMESTAMPTZ,
    ended_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- CREATE INDEX idx_sessions_embedding ON session_logs USING ivfflat (embedding vector_cosine_ops) WITH (lists = 10);
CREATE INDEX idx_sessions_project ON session_logs (project);
CREATE INDEX idx_sessions_ended ON session_logs (ended_at);
CREATE INDEX idx_sessions_tsv ON session_logs USING gin (tsv);

CREATE OR REPLACE FUNCTION sessions_tsv_trigger() RETURNS trigger AS $$
BEGIN
    NEW.tsv :=
        setweight(to_tsvector('english', coalesce(NEW.summary, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(array_to_string(NEW.key_topics, ' '), '')), 'B');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sessions_tsv
    BEFORE INSERT OR UPDATE OF summary, key_topics ON session_logs
    FOR EACH ROW EXECUTE FUNCTION sessions_tsv_trigger();

-- ============================================================
-- User Profiles: 사용자 모델링
-- ============================================================
CREATE TABLE user_profiles (
    id              SERIAL PRIMARY KEY,
    user_id         TEXT NOT NULL UNIQUE,
    preferences     JSONB NOT NULL DEFAULT '{}',
    patterns        JSONB NOT NULL DEFAULT '{}',
    expertise       JSONB NOT NULL DEFAULT '{}',
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- Skill Usage Log: 사용 빈도 추적
-- ============================================================
CREATE TABLE skill_usage_log (
    id              SERIAL PRIMARY KEY,
    skill_id        INTEGER REFERENCES skills(id) ON DELETE CASCADE,
    session_id      TEXT,
    used_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_skill_usage_skill ON skill_usage_log (skill_id);

-- ============================================================
-- Helper Functions
-- ============================================================

-- 스킬 사용 시 usage_count + last_used_at 자동 갱신
CREATE OR REPLACE FUNCTION record_skill_usage(p_skill_id INTEGER, p_session_id TEXT)
RETURNS void AS $$
BEGIN
    UPDATE skills SET
        usage_count = usage_count + 1,
        last_used_at = NOW(),
        updated_at = NOW()
    WHERE id = p_skill_id;

    INSERT INTO skill_usage_log (skill_id, session_id) VALUES (p_skill_id, p_session_id);
END;
$$ LANGUAGE plpgsql;

-- 90일 미사용 스킬 아카이브
CREATE OR REPLACE FUNCTION archive_stale_skills(p_days INTEGER DEFAULT 90)
RETURNS INTEGER AS $$
DECLARE
    archived_count INTEGER;
BEGIN
    UPDATE skills SET
        status = 'archived',
        updated_at = NOW()
    WHERE status = 'active'
      AND (last_used_at IS NULL AND created_at < NOW() - (p_days || ' days')::interval
           OR last_used_at < NOW() - (p_days || ' days')::interval);

    GET DIAGNOSTICS archived_count = ROW_COUNT;
    RETURN archived_count;
END;
$$ LANGUAGE plpgsql;

-- 카테고리당 활성 스킬 상한 적용
CREATE OR REPLACE FUNCTION enforce_category_cap(p_category TEXT, p_cap INTEGER DEFAULT 20)
RETURNS INTEGER AS $$
DECLARE
    excess_count INTEGER;
    archived_count INTEGER := 0;
BEGIN
    SELECT COUNT(*) - p_cap INTO excess_count
    FROM skills
    WHERE category = p_category AND status = 'active';

    IF excess_count > 0 THEN
        UPDATE skills SET
            status = 'archived',
            updated_at = NOW()
        WHERE id IN (
            SELECT id FROM skills
            WHERE category = p_category AND status = 'active'
            ORDER BY usage_count ASC, last_used_at ASC NULLS FIRST
            LIMIT excess_count
        );
        GET DIAGNOSTICS archived_count = ROW_COUNT;
    END IF;

    RETURN archived_count;
END;
$$ LANGUAGE plpgsql;
