# PostgreSQL statement timeout in Pangolin: disabling JIT

## Summary

The `core-db` container (PostgreSQL 17, `postgres:17-alpine`) was logging
repeated `canceling statement due to statement timeout` errors on the
Pangolin resource lookup query. The fix was to start PostgreSQL with JIT
(just-in-time compilation) disabled:

```yaml
services:
  db:
    image: postgres:17-alpine
    command:
      - postgres
      - -c
      - jit=off
```

## Symptoms

The server log showed errors like:

```
ERROR:  canceling statement due to statement timeout
STATEMENT:  select "resources"."resourceId", ... from "resources"
  left join "resourcePincode" ... inner join "orgs" ...
  where ("resources"."fullDomain" = $1 or ("resources"."wildcard" = $2
  and "resources"."fullDomain" in ($3, $4)))
```

The query is the Pangolin resource lookup. It joins `resources` with
pincode, password, header-auth, and policy tables, plus `orgs`, and it
runs whenever a domain needs to be resolved.

## Investigation

### 1. Initial hypotheses

Before measuring anything, the likely causes were:

- Missing indexes on join or filter columns
- Stale planner statistics
- Lock contention or too many concurrent queries
- Insufficient memory settings (`shared_buffers`, `effective_cache_size`)
- Container CPU or memory limits

Changing the PostgreSQL image version (for example to a Trixie-based
tag) was ruled out, since it would not change the query plan or the
timeout behavior.

### 2. Running EXPLAIN ANALYZE

The query was run inside the container:

```bash
docker exec -it core-db-1 psql -U postgres -d postgres
```

Some issues came up along the way:

- The first attempt failed with `relation "resources" does not exist`
  because the query ran against the default `postgres` database, which
  did not contain the Pangolin tables. Connecting to the database that
  holds the tables resolves this.
- `wildcard` is a `boolean` column, so the condition must be
  `"resources"."wildcard" = true`, not a string comparison.

### 3. Reading the plan

The plan completed with these key numbers:

```
Execution Time: 7585.898 ms
JIT:
  Functions: 102
  Optimization: 4103.646 ms
  Emission:     3128.507 ms
  Inlining:      278.049 ms
  Total:        7532.219 ms
```

The actual work finished at about 7.5 ms into the plan
(`actual time=... 7514.842`). Almost all of the 7.5 seconds was spent
in JIT compilation.

Two further observations:

- Every table scan returned `rows=0` or `rows=1`, while the planner
  estimated hundreds of thousands of rows. The tables are nearly empty,
  so index and memory tuning would not have helped.
- The planner's total cost estimate (about 600,000) exceeded the default
  `jit_above_cost` threshold (100,000), which triggered JIT compilation
  for a query that runs in milliseconds.

## Root cause

The planner decided the query was expensive, because its row estimates
were inflated. That pushed it over `jit_above_cost`, so PostgreSQL
compiled the query with LLVM. For a short lookup, compilation costs far
more than execution, and the total time exceeded `statement_timeout`.

## Fix

Start PostgreSQL with JIT disabled for the whole server. In
`docker-compose.yml`:

```yaml
services:
  core-db:
    image: postgres:17-alpine
    command:
      - postgres
      - -c
      - jit=off
```

Apply it:

```bash
docker compose up -d core-db
```

Verify it took effect:

```bash
docker exec -it core-db-1 psql -U postgres -d postgres -c "SHOW jit;"
```

Expected output: `off`.

## Alternatives considered

| Option | Effect | Why not chosen |
|---|---|---|
| `ALTER DATABASE postgres SET jit = off;` | Disables JIT for one database | Works, but must be re-applied per database and is lost if the database is recreated |
| `ALTER DATABASE postgres SET jit_above_cost = 500000;` | Keeps JIT for very expensive queries | Workaround; relies on inflated estimates staying below the threshold |
| `ANALYZE;` | Refreshes row estimates | Helpful for plan quality, but does not prevent JIT on its own |
| Adding indexes or raising `shared_buffers` | Speeds up scans and caching | Not the bottleneck; the tables are small |
| Changing the image (Trixie, other tags) | Different base OS or minor version | Does not affect the query plan or JIT decision |

## Notes and caveats

- `command:` replaces the image's default command. The official image
  defaults to `postgres`, so this is equivalent. If you add more flags
  later, put them in the same list.
- JIT helps long analytic queries. If such queries are added later,
  re-enable JIT per database:

  ```sql
  ALTER DATABASE postgres SET jit = on;
  ```

  or per session:

  ```sql
  SET jit = on;
  ```

- Running `EXPLAIN ANALYZE` on a query that exceeds `statement_timeout`
  will also be cancelled. Use `SET statement_timeout = '0';` in the
  session first when diagnosing.

## Expected result

Lookups for the Pangolin resource query should complete in a few
milliseconds, and the `canceling statement due to statement timeout`
errors should stop appearing in `core-db-1` logs.

To check, watch the logs:

```bash
docker logs -f core-db-1 | grep -i "statement timeout"
```

No output after a period of normal traffic means the fix is working.
