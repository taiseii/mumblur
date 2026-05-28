// MumblurCore/Sources/MumblurCore/Storage/MigrationsV1.swift
import GRDB

extension DatabaseMigrator {
    mutating func registerV1() {
        registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE profile (
                    id              TEXT PRIMARY KEY,
                    name            TEXT NOT NULL,
                    language        TEXT,
                    model_id        TEXT NOT NULL,
                    initial_prompt  TEXT,
                    created_at      INTEGER NOT NULL CHECK(created_at >= 0),
                    updated_at      INTEGER NOT NULL CHECK(updated_at >= created_at),
                    deleted_at      INTEGER          CHECK(deleted_at IS NULL OR deleted_at >= created_at)
                );
                CREATE UNIQUE INDEX idx_profile_name_nocase
                    ON profile(name COLLATE NOCASE) WHERE deleted_at IS NULL;

                CREATE TABLE vocab_term (
                    id              INTEGER PRIMARY KEY,
                    profile_id      TEXT NOT NULL REFERENCES profile(id) ON DELETE CASCADE,
                    term            TEXT NOT NULL,
                    UNIQUE(profile_id, term)
                );

                CREATE TABLE replacement_rule (
                    id              INTEGER PRIMARY KEY,
                    profile_id      TEXT NOT NULL REFERENCES profile(id) ON DELETE CASCADE,
                    pattern         TEXT NOT NULL,
                    replacement     TEXT NOT NULL,
                    is_regex        INTEGER NOT NULL DEFAULT 0 CHECK(is_regex IN (0,1)),
                    case_sensitive  INTEGER NOT NULL DEFAULT 0 CHECK(case_sensitive IN (0,1)),
                    word_boundary   INTEGER NOT NULL DEFAULT 1 CHECK(word_boundary IN (0,1)),
                    sort_order      INTEGER NOT NULL DEFAULT 0 CHECK(sort_order >= 0)
                );
                CREATE INDEX idx_replacement_rule_profile_sort
                    ON replacement_rule(profile_id, sort_order, id);

                CREATE TABLE transcript (
                    id                      INTEGER PRIMARY KEY,
                    profile_id              TEXT REFERENCES profile(id) ON DELETE RESTRICT,
                    profile_name_snapshot   TEXT,
                    prompt_snapshot         TEXT,
                    started_at              INTEGER NOT NULL CHECK(started_at >= 0),
                    duration_ms             INTEGER NOT NULL CHECK(duration_ms >= 0),
                    model_id                TEXT NOT NULL,
                    language                TEXT,
                    raw_text                TEXT NOT NULL,
                    final_text              TEXT NOT NULL,
                    audio_rel_path          TEXT,
                    audio_bytes             INTEGER,
                    audio_sha256            TEXT,
                    sample_rate_hz          INTEGER,
                    channels                INTEGER,
                    pcm_encoding            TEXT,
                    CHECK (
                        (audio_rel_path IS NULL AND audio_bytes IS NULL AND audio_sha256 IS NULL
                         AND sample_rate_hz IS NULL AND channels IS NULL AND pcm_encoding IS NULL)
                        OR
                        (audio_rel_path IS NOT NULL AND audio_rel_path <> ''
                         AND audio_bytes IS NOT NULL AND audio_bytes >= 0
                         AND audio_sha256 IS NOT NULL AND length(audio_sha256) = 64
                         AND sample_rate_hz IS NOT NULL AND sample_rate_hz > 0
                         AND channels IS NOT NULL AND channels > 0
                         AND pcm_encoding IS NOT NULL AND pcm_encoding <> '')
                    )
                );
                CREATE INDEX idx_transcript_started_at ON transcript(started_at DESC);
                CREATE INDEX idx_transcript_profile_started_at
                    ON transcript(profile_id, started_at DESC) WHERE profile_id IS NOT NULL;

                CREATE TABLE calibration_run (
                    id                      INTEGER PRIMARY KEY,
                    profile_id              TEXT NOT NULL REFERENCES profile(id) ON DELETE RESTRICT,
                    profile_name_snapshot   TEXT NOT NULL,
                    language_snapshot       TEXT,
                    prompt_snapshot         TEXT,
                    script_id               TEXT NOT NULL,
                    script_hash             TEXT NOT NULL CHECK(script_hash <> ''),
                    scoring_version         TEXT NOT NULL DEFAULT 'wer_v1',
                    started_at              INTEGER NOT NULL CHECK(started_at >= 0),
                    completed_at            INTEGER CHECK(completed_at IS NULL OR completed_at >= started_at),
                    model_id                TEXT NOT NULL,
                    eval_raw_wer            REAL CHECK(eval_raw_wer IS NULL OR eval_raw_wer >= 0),
                    eval_final_wer          REAL CHECK(eval_final_wer IS NULL OR eval_final_wer >= 0),
                    notes                   TEXT
                );
                CREATE INDEX idx_calibration_run_profile_script_started_at
                    ON calibration_run(profile_id, script_id, started_at DESC);

                CREATE TABLE calibration_sample (
                    id              INTEGER PRIMARY KEY,
                    run_id          INTEGER NOT NULL REFERENCES calibration_run(id) ON DELETE CASCADE,
                    sample_index    INTEGER NOT NULL,
                    set_role        TEXT NOT NULL CHECK(set_role IN ('mining','eval')),
                    status          TEXT NOT NULL CHECK(status IN ('recorded','transcribed','failed')),
                    ground_truth    TEXT NOT NULL,
                    raw_text        TEXT,
                    final_text      TEXT,
                    raw_wer         REAL CHECK(raw_wer IS NULL OR raw_wer >= 0),
                    final_wer       REAL CHECK(final_wer IS NULL OR final_wer >= 0),
                    error_message   TEXT,
                    duration_ms     INTEGER NOT NULL CHECK(duration_ms >= 0),
                    audio_rel_path  TEXT NOT NULL CHECK(audio_rel_path <> ''),
                    audio_bytes     INTEGER NOT NULL CHECK(audio_bytes >= 0),
                    audio_sha256    TEXT NOT NULL CHECK(length(audio_sha256) = 64),
                    sample_rate_hz  INTEGER NOT NULL CHECK(sample_rate_hz > 0),
                    channels        INTEGER NOT NULL CHECK(channels > 0),
                    pcm_encoding    TEXT NOT NULL CHECK(pcm_encoding <> ''),
                    UNIQUE(run_id, sample_index),
                    CHECK (
                        (status = 'transcribed'
                            AND raw_text IS NOT NULL AND final_text IS NOT NULL
                            AND raw_wer IS NOT NULL AND final_wer IS NOT NULL) OR
                        (status IN ('recorded','failed')
                            AND raw_text IS NULL AND final_text IS NULL
                            AND raw_wer IS NULL AND final_wer IS NULL)
                    )
                );

                CREATE TABLE retention_policy (
                    singleton   INTEGER PRIMARY KEY CHECK(singleton = 1),
                    enabled     INTEGER NOT NULL    CHECK(enabled IN (0,1)),
                    kind        TEXT    NOT NULL    CHECK(kind IN ('days','count')),
                    value       INTEGER NOT NULL    CHECK(value >= 0)
                );
                INSERT INTO retention_policy(singleton, enabled, kind, value) VALUES (1, 0, 'days', 30);

                CREATE TABLE app_setting (
                    key   TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
            """)
        }
    }
}
