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

-- Security events. Ban/unban activity from the host Fail2ban layer (which drives
-- nftables). A custom Fail2ban action appends one JSON line per event to a file
-- under $JOHNCLOUD_ROOT; Vector's `file` source tails it and inserts here via the
-- same jsonb_populate_record convention (columns mirror the JSON keys the action
-- emits; omitted keys land NULL; no serial PK). The NOT NULL columns below are the
-- keys the action ALWAYS writes (both on ban and unban).
CREATE TABLE IF NOT EXISTS security_events (
    timestamp TIMESTAMPTZ NOT NULL,   -- event time (UTC), stamped by the action
    action    TEXT        NOT NULL,   -- 'ban' | 'unban'
    jail      TEXT        NOT NULL,   -- Fail2ban jail name (<name>)
    ip        TEXT        NOT NULL,   -- offender (<ip>)
    failures  INTEGER,                -- <failures> (ban only; NULL on unban)
    family    TEXT,                   -- inet4 / inet6
    port      TEXT,                   -- <port>  (ban only)
    protocol  TEXT,                   -- <protocol> (ban only)
    bantime   INTEGER                 -- <bantime> seconds (ban only)
);
CREATE INDEX IF NOT EXISTS security_events_time_idx ON security_events (timestamp DESC);
CREATE INDEX IF NOT EXISTS security_events_ip_idx   ON security_events (ip);
CREATE INDEX IF NOT EXISTS security_events_jail_idx ON security_events (jail, timestamp DESC);

-- Geo/ASN resolution for banned IPs. Unlike the tables above (fed by Vector's
-- postgres sink), this one is written by the geoip-sync loader, which periodically
-- resolves the distinct IPs seen in security_events against the GeoLite2 City + ASN
-- mmdb that core/geoipupdate already maintains, and upserts a flat row per IP. It is
-- therefore free to carry a real primary key and DEFAULTs. Only banned IPs are
-- stored (a tiny set), so the view below joins by equality on ip instead of a CIDR
-- range containment (which Postgres cannot index without the ip4r extension).
CREATE TABLE IF NOT EXISTS geoip_lookup (
    ip           TEXT PRIMARY KEY,
    country_code TEXT,
    country_name TEXT,
    city         TEXT,
    latitude     DOUBLE PRECISION,
    longitude    DOUBLE PRECISION,
    asn          INTEGER,
    asn_org      TEXT,
    resolved_at  TIMESTAMPTZ NOT NULL DEFAULT now()   -- last mmdb resolution
);

-- Ban/unban events enriched with geo for dashboards (e.g. a Grafana Geomap over the
-- latitude/longitude columns). LEFT JOIN so events whose ip is not yet resolved
-- still appear, with NULL geo.
CREATE OR REPLACE VIEW security_events_geo AS
SELECT e.*,
       g.country_code, g.country_name, g.city,
       g.latitude, g.longitude, g.asn, g.asn_org
FROM security_events e
LEFT JOIN geoip_lookup g USING (ip);

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
