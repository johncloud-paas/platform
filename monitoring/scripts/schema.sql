-- schema.sql — monitoring database schema (no TimescaleDB).
--
-- Applied by configure-monitoring.sh against the `monitoring` database, connected
-- as the `monitoring` role (so the tables are owned by it and Vector, which also
-- logs in as `monitoring`, can INSERT without extra grants).
--
-- Column names deliberately mirror the fields Vector emits. Vector's `postgres`
-- sink inserts rows with `jsonb_populate_record`: event fields map to columns by
-- name, unmatched fields are ignored, and table-level DEFAULTs are NOT applied
-- (a field Vector omits lands as NULL). Hence every NOT NULL column below must be
-- a field Vector always sends, and there is no identity/serial primary key (the
-- sink supplies every column, so a generated key would receive NULL and fail).

-- Container logs. Deliverable fields: container, timestamp, criticity, message.
CREATE TABLE IF NOT EXISTS logs (
    timestamp  TIMESTAMPTZ NOT NULL,
    container  TEXT        NOT NULL,
    severity   TEXT        NOT NULL,   -- criticity, derived from the message in Vector
    message    TEXT        NOT NULL,
    stream     TEXT,                   -- stdout / stderr
    image      TEXT,
    labels     JSONB                   -- Docker container labels
);
CREATE INDEX IF NOT EXISTS logs_timestamp_idx      ON logs (timestamp DESC);
CREATE INDEX IF NOT EXISTS logs_container_time_idx ON logs (container, timestamp DESC);
CREATE INDEX IF NOT EXISTS logs_severity_idx       ON logs (severity);

-- Metrics. Columns mirror Vector's metric-event JSON shape; exactly one of the
-- value columns (counter/gauge/...) is populated per row depending on metric kind.
CREATE TABLE IF NOT EXISTS metrics (
    timestamp            TIMESTAMPTZ NOT NULL,
    name                 TEXT        NOT NULL,
    namespace            TEXT,
    tags                 JSONB,
    kind                 TEXT,
    interval_ms          INTEGER,
    counter              JSONB,
    gauge                JSONB,
    "set"                JSONB,
    distribution         JSONB,
    aggregated_histogram JSONB,
    aggregated_summary   JSONB,
    sketch               JSONB
);
CREATE INDEX IF NOT EXISTS metrics_name_time_idx ON metrics (name, timestamp DESC);
CREATE INDEX IF NOT EXISTS metrics_timestamp_idx ON metrics (timestamp DESC);
CREATE INDEX IF NOT EXISTS metrics_tags_idx      ON metrics USING GIN (tags);

-- Convenience view: flat numeric value for the common counter/gauge cases.
CREATE OR REPLACE VIEW metric_samples AS
SELECT timestamp,
       name,
       namespace,
       tags,
       kind,
       COALESCE((counter ->> 'value')::double precision,
                (gauge   ->> 'value')::double precision) AS value
FROM metrics;
