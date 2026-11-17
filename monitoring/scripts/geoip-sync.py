#!/usr/bin/env python3
"""geoip-sync — resolve banned IPs to geo/ASN from the local GeoLite2 mmdb.

Periodically reads the distinct IPs in ``monitoring.security_events``, looks each up
in the GeoLite2 City + ASN databases that the ``core`` stack's ``geoipupdate``
service already maintains on disk, and upserts one flat row per IP into
``geoip_lookup``. Runs as a long-lived container in the monitoring stack.

Re-resolving every cycle keeps the table in sync when ``geoipupdate`` rewrites the
mmdb (the banned-IP set is tiny, so a full pass is cheap), and re-opening the
databases each cycle picks up the refreshed files without a restart.

Configuration (environment):
    MONITORING_DB_PASSWORD   password for the ``monitoring`` role (required)
    GEOIP_SYNC_INTERVAL      seconds between passes (default 3600)
    GEOIP_CITY_DB            City mmdb path (default /geoip/GeoLite2-City.mmdb)
    GEOIP_ASN_DB             ASN mmdb path  (default /geoip/GeoLite2-ASN.mmdb)
    MONITORING_DB_HOST/PORT/NAME/USER   connection overrides (sensible defaults)
"""
import os
import sys
import time

import maxminddb
import psycopg

CITY_DB = os.environ.get("GEOIP_CITY_DB", "/geoip/GeoLite2-City.mmdb")
ASN_DB = os.environ.get("GEOIP_ASN_DB", "/geoip/GeoLite2-ASN.mmdb")
INTERVAL = int(os.environ.get("GEOIP_SYNC_INTERVAL", "3600"))

DSN = "host={host} port={port} dbname={db} user={user} password={pw}".format(
    host=os.environ.get("MONITORING_DB_HOST", "core-db-1"),
    port=os.environ.get("MONITORING_DB_PORT", "5432"),
    db=os.environ.get("MONITORING_DB_NAME", "monitoring"),
    user=os.environ.get("MONITORING_DB_USER", "monitoring"),
    pw=os.environ["MONITORING_DB_PASSWORD"],
)

UPSERT = """
INSERT INTO geoip_lookup
    (ip, country_code, country_name, city,
     latitude, longitude, asn, asn_org, resolved_at)
VALUES
    (%(ip)s, %(country_code)s, %(country_name)s, %(city)s,
     %(latitude)s, %(longitude)s, %(asn)s, %(asn_org)s, now())
ON CONFLICT (ip) DO UPDATE SET
    country_code = EXCLUDED.country_code,
    country_name = EXCLUDED.country_name,
    city         = EXCLUDED.city,
    latitude     = EXCLUDED.latitude,
    longitude    = EXCLUDED.longitude,
    asn          = EXCLUDED.asn,
    asn_org      = EXCLUDED.asn_org,
    resolved_at  = now();
"""


def log(msg):
    print(f"[geoip-sync] {msg}", flush=True)


def resolve(ip, city_reader, asn_reader):
    """Return geo/ASN fields for ip; anything the mmdb lacks lands as None."""
    row = {
        "ip": ip,
        "country_code": None,
        "country_name": None,
        "city": None,
        "latitude": None,
        "longitude": None,
        "asn": None,
        "asn_org": None,
    }
    try:
        city = city_reader.get(ip)
    except (ValueError, TypeError):
        city = None  # not a valid IP address
    if city:
        country = city.get("country") or {}
        row["country_code"] = country.get("iso_code")
        row["country_name"] = (country.get("names") or {}).get("en")
        row["city"] = ((city.get("city") or {}).get("names") or {}).get("en")
        loc = city.get("location") or {}
        row["latitude"] = loc.get("latitude")
        row["longitude"] = loc.get("longitude")
    try:
        asn = asn_reader.get(ip)
    except (ValueError, TypeError):
        asn = None
    if asn:
        row["asn"] = asn.get("autonomous_system_number")
        row["asn_org"] = asn.get("autonomous_system_organization")
    return row


def sync_once(conn, city_reader, asn_reader):
    with conn.cursor() as cur:
        cur.execute("SELECT DISTINCT ip FROM security_events")
        ips = [r[0] for r in cur.fetchall()]
    if not ips:
        log("no IPs in security_events yet")
        return
    rows = [resolve(ip, city_reader, asn_reader) for ip in ips]
    with conn.cursor() as cur:
        cur.executemany(UPSERT, rows)
    conn.commit()
    with_coords = sum(1 for r in rows if r["latitude"] is not None)
    log(f"resolved {with_coords}/{len(rows)} IP(s) with coordinates")


def main():
    for path in (CITY_DB, ASN_DB):
        if not os.path.exists(path):
            log(f"FATAL: mmdb not found: {path} (is core/geoipupdate running?)")
            sys.exit(1)
    log(f"starting; interval={INTERVAL}s city={CITY_DB} asn={ASN_DB}")
    while True:
        try:
            with maxminddb.open_database(CITY_DB) as city_reader, \
                 maxminddb.open_database(ASN_DB) as asn_reader, \
                 psycopg.connect(DSN) as conn:
                sync_once(conn, city_reader, asn_reader)
        except Exception as exc:  # keep the loop alive across transient errors
            log(f"cycle failed: {exc!r}")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
