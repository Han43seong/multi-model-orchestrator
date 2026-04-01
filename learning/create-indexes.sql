-- 벡터 인덱스 생성 (데이터 100건 이상 시 실행)
-- Usage: docker exec orch-learning-db psql -U orch -d orchestration -f /tmp/create-indexes.sql
-- 또는: python3 learning_db.py create-indexes

-- Skills 벡터 인덱스
DO $$
BEGIN
    IF (SELECT COUNT(*) FROM skills WHERE embedding IS NOT NULL) >= 100 THEN
        IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_skills_embedding_ivfflat') THEN
            CREATE INDEX idx_skills_embedding_ivfflat ON skills
                USING ivfflat (embedding vector_cosine_ops) WITH (lists = 10);
            RAISE NOTICE 'Created ivfflat index on skills.embedding';
        ELSE
            RAISE NOTICE 'Index idx_skills_embedding_ivfflat already exists';
        END IF;
    ELSE
        RAISE NOTICE 'Skills with embeddings: % (need 100+)', (SELECT COUNT(*) FROM skills WHERE embedding IS NOT NULL);
    END IF;
END $$;

-- Session logs 벡터 인덱스
DO $$
BEGIN
    IF (SELECT COUNT(*) FROM session_logs WHERE embedding IS NOT NULL) >= 100 THEN
        IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_sessions_embedding_ivfflat') THEN
            CREATE INDEX idx_sessions_embedding_ivfflat ON session_logs
                USING ivfflat (embedding vector_cosine_ops) WITH (lists = 10);
            RAISE NOTICE 'Created ivfflat index on session_logs.embedding';
        ELSE
            RAISE NOTICE 'Index idx_sessions_embedding_ivfflat already exists';
        END IF;
    ELSE
        RAISE NOTICE 'Sessions with embeddings: % (need 100+)', (SELECT COUNT(*) FROM session_logs WHERE embedding IS NOT NULL);
    END IF;
END $$;
