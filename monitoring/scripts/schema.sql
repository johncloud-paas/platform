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

-- Added by ALTER (not in the CREATE above) so existing databases also gain them --
-- CREATE TABLE IF NOT EXISTS skips an already-existing table, so new columns must
-- be introduced idempotently via ALTER ... ADD COLUMN IF NOT EXISTS.
--   client_ip    — remote client IP, best-effort extracted by Vector (see vector.yaml);
--                  NULL when the line carries none.
--   linked_event — back-reference to the security_events.id whose ban this line
--                  triggered; filled by the link_security_event() trigger below.
ALTER TABLE logs ADD COLUMN IF NOT EXISTS client_ip    TEXT;
ALTER TABLE logs ADD COLUMN IF NOT EXISTS linked_event UUID;
CREATE INDEX IF NOT EXISTS logs_client_ip_time_idx ON logs (client_ip, timestamp DESC);
CREATE INDEX IF NOT EXISTS logs_linked_event_idx   ON logs (linked_event);

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

-- Surrogate key that logs.linked_event points at. This is NOT a serial/DEFAULT key
-- (which the sink can't populate, see the header): Vector emits it as uuid_v4() in the
-- fail2ban_parse transform, so the sink supplies it like any other column. Added via
-- ALTER so existing databases gain it too. UNIQUE (not PRIMARY KEY) because rows that
-- predate the column have id = NULL.
ALTER TABLE security_events ADD COLUMN IF NOT EXISTS id UUID;
CREATE UNIQUE INDEX IF NOT EXISTS security_events_id_uidx ON security_events (id);

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
-- DROP before (re)create: this view selects `e.*`, so adding a column to
-- security_events (e.g. the new `id`) changes its column set in the middle, which
-- CREATE OR REPLACE VIEW rejects ("cannot change name of view column"). Dropping first
-- keeps the migration idempotent on databases whose view predates the new column.
DROP VIEW IF EXISTS security_events_geo;
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

-- Link each ban to the log lines that triggered it --------------------------------
-- Fail2ban records only the offender IP/jail/time, never which lines matched, so the
-- link is reconstructed: a ban's triggering lines are the logs rows for the same IP
-- within the jail's findtime window before the ban. This is a pure join between two
-- tables already in this database, so it runs here as an AFTER INSERT trigger rather
-- than in a Python loader (geoip-sync stays Python only because it reads an external
-- mmdb file; this has no external input). The failures precede the ban, so the matching
-- logs rows are already present when the ban row lands.
--
-- One logs.linked_event column (not a join table): a line links to at most one ban
-- (first-ban-wins via `linked_event IS NULL`). True many-to-many would need a join
-- table, but it only matters when the same IP is banned in overlapping findtime windows
-- (recidive excluded) — rare and benign. The match is heuristic (1s ban-timestamp
-- granularity; container apps expose the client IP only if they log X-Forwarded-For).
CREATE OR REPLACE FUNCTION link_security_event() RETURNS trigger AS $$
DECLARE findtime int;
BEGIN
  -- Only bans with a known id; unbans and recidive (bans off fail2ban's own log,
  -- not app lines) have nothing to link.
  IF NEW.action <> 'ban' OR NEW.id IS NULL OR NEW.jail = 'recidive' THEN
    RETURN NEW;
  END IF;
  -- Per-jail findtime window, mirroring monitoring/fail2ban/jail.template.local.
  findtime := CASE NEW.jail
                WHEN 'traefik-4xx' THEN 120   -- jail overrides [DEFAULT] findtime
                ELSE 600                      -- [DEFAULT] F2B_FINDTIME (10m)
              END;
  UPDATE logs l SET linked_event = NEW.id
  WHERE l.linked_event IS NULL                               -- first ban wins
    AND (l.client_ip = NEW.ip OR l.message LIKE '%' || NEW.ip || '%')
    AND l.timestamp BETWEEN NEW.timestamp - make_interval(secs => findtime)
                        AND NEW.timestamp;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- DROP + CREATE (rather than CREATE OR REPLACE TRIGGER, unsupported on PG < 14) keeps
-- the re-apply idempotent.
DROP TRIGGER IF EXISTS trg_link_security_event ON security_events;
CREATE TRIGGER trg_link_security_event
  AFTER INSERT ON security_events
  FOR EACH ROW EXECUTE FUNCTION link_security_event();

-- Convenience view: each ban joined to the log lines it was linked to.
CREATE OR REPLACE VIEW security_event_log_lines AS
SELECT e.id        AS security_event_id,
       e.timestamp AS ban_time,
       e.jail,
       e.ip,
       l.timestamp AS log_time,
       l.container,
       l.severity,
       l.message
FROM security_events e
JOIN logs l ON l.linked_event = e.id;
