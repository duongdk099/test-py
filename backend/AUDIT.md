# Backend System Audit — API Météo InfoClimat

**Date:** 2026-03-02  
**Scope:** Django/DRF backend (`backend/`)  
**Environment tested:** Local dev — Python 3.14, PostgreSQL 18 (local) + TimescaleDB Docker container

---

## Step 1 — Endpoint Test Results

### Server startup

| Step                                                  | Result     | Notes                                                                                                                              |
| ----------------------------------------------------- | ---------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `uv sync --extra dev`                                 | ⚠️ Exit 1  | Python 3.14 incompatibility with some packages (runtime still works)                                                               |
| `uv run python manage.py migrate`                     | ⚠️ Partial | Migration `0001_initial` applied OK; `0002_timescaledb_hypertables` fails on plain PostgreSQL — **TimescaleDB extension required** |
| `uv run python manage.py migrate weather 0002 --fake` | ✅         | Workaround to bypass TimescaleDB locally                                                                                           |
| `uv run python manage.py runserver 8000`              | ✅         | Server starts successfully                                                                                                         |

### Root cause of migration failure

A local PostgreSQL 18 instance runs on `127.0.0.1:5432` and intercepts all `localhost` connections before Docker's port-forwarded TimescaleDB container (mapped on `0.0.0.0:5432`). When both processes share port 5432, the local engine — which has no TimescaleDB extension — handles every Django connection.

### API endpoints

| Endpoint                                                                                                     | Method | HTTP Status | Result                                       |
| ------------------------------------------------------------------------------------------------------------ | ------ | ----------- | -------------------------------------------- |
| `/api/v1/stations/`                                                                                          | GET    | **200**     | ✅ Empty list (no data seeded)               |
| `/api/v1/stations/?departement=75`                                                                           | GET    | **200**     | ✅ Filtering works                           |
| `/api/v1/stations/999/`                                                                                      | GET    | **404**     | ✅ Correct not-found response                |
| `/api/v1/horaire/`                                                                                           | GET    | **200**     | ✅ Empty list                                |
| `/api/v1/horaire/latest/`                                                                                    | GET    | **200**     | ✅ Custom action accessible                  |
| `/api/v1/horaire/?station_code=75114001`                                                                     | GET    | **200**     | ✅ Filtering works                           |
| `/api/v1/quotidien/`                                                                                         | GET    | **200**     | ✅ Empty list                                |
| `/api/v1/temperature/national-indicator?date_start=2024-01-01&date_end=2024-03-31&granularity=month`         | GET    | **200**     | ✅ Fake data service responds                |
| `/api/v1/temperature/national-indicator?date_start=2024-01-01&date_end=2024-03-31` _(missing `granularity`)_ | GET    | **400**     | ✅ Validation error with structured response |
| `/api/schema/`                                                                                               | GET    | **200**     | ✅ OpenAPI JSON schema                       |
| `/api/docs/`                                                                                                 | GET    | **200**     | ✅ Swagger UI rendered                       |
| `/admin/`                                                                                                    | GET    | **200**     | ✅ Django admin login page                   |

**All 12 endpoints pass their expected HTTP status checks.**

### Test suite

```
uv run pytest weather/tests/ -v
32 passed, 3 warnings in 0.34s
```

| Category                                  | Tests   | Result                                 |
| ----------------------------------------- | ------- | -------------------------------------- |
| Unit — fake data generator                | 8       | ✅ All pass                            |
| Unit — query serializer validation        | 21      | ✅ All pass                            |
| Integration — national indicator endpoint | 3       | ✅ All pass                            |
| ⚠️ Staticfiles directory missing          | warning | Django warning on test run (non-fatal) |

---

## Step 2 — System Audit Checklist

### 1. Code Quality

#### What's missing

- **No type hints** on service layer functions (`service.py`, `views.py`). Function signatures accept plain `str` / `int` without type annotations, making refactoring risky.
- **`AUTH_PASSWORD_VALIDATORS = []`** in `config/settings.py` — Django admin password accepts any string (empty list disables all validators).
- **No request/response logging middleware** — no visibility into traffic patterns or slow queries in development.
- **Large management command** — `populate_weather_data.py` is 354 lines. It mixes orchestration, clear logic, and generation calls. No unit tests cover it.
- **DJ001 warning suppressed** — `.pre-commit-config.yaml` passes `--ignore=DJ001` to ruff, silencing the valid Django warning about `null=True` on `CharField` fields (`htn`, `htx` in `Quotidienne` model). The issue exists but is hidden.

#### What's manual vs automated

| Task                                   | Status                    |
| -------------------------------------- | ------------------------- |
| Linting (ruff)                         | ✅ Automated (pre-commit) |
| Code formatting (ruff-format)          | ✅ Automated (pre-commit) |
| Import sorting (isort via ruff)        | ✅ Automated              |
| Notebook output stripping (nbstripout) | ✅ Automated              |
| Type checking (mypy/pyright)           | ❌ Not configured         |
| SAST / security scanning (bandit)      | ❌ Not configured         |

#### Potential failure points

- Suppressed lint rules mask schema design issues that could cause issues at the ORM or DB level.
- Lack of type hints on the service layer makes refactoring the national indicator pipeline opaque.
- No coverage of `populate_weather_data` means data generation bugs could silently corrupt the dev dataset.

---

### 2. Testing

#### What's missing

- **No tests for the three DB-backed ViewSets** (`StationViewSet`, `HoraireTempsReelViewSet`, `QuotidienneViewSet`) — these cover the majority of the API surface.
- **No filter tests** — query parameters like `?departement=75`, `?date_after=...`, `?station_code=X` are untested.
- **No test for the `latest/` custom action** on `HoraireTempsReelViewSet`.
- **No tests for `populate_weather_data`** management command.
- **Coverage threshold not enforced** — `pytest-cov` is declared as a dev dependency but `tox.ini` does not invoke `--cov` or set a minimum threshold.
- **`factory-boy` declared but not used** — listed in `dev` extras, not referenced in any test file.
- **No load / performance tests** — no benchmarks for TimescaleDB time-range queries under real data volumes.

#### What's manual vs automated

| Task                     | Status                       |
| ------------------------ | ---------------------------- |
| Unit tests               | ✅ Automated (pytest)        |
| Integration tests        | ✅ Automated (pytest-django) |
| Coverage measurement     | ❌ Not configured            |
| Coverage enforcement     | ❌ Not configured            |
| Load / performance tests | ❌ Not configured            |
| Mutation testing         | ❌ Not configured            |

#### Potential failure points

- A schema change to `HoraireTempsReel` or `Station` models would not be caught by any existing test.
- The three main DB ViewSets could silently regress on filtering logic.
- No guaranteed confidence level — current coverage is likely below 40% of the code that touches the DB.

---

### 3. Deployment Process

#### What's missing

- **No wait-for-db logic** in `entrypoint.sh` — the script runs `migrate` immediately on container start without waiting for TimescaleDB to be ready. The `healthcheck` in `docker-compose.yml` handles this at the Docker level, but if `entrypoint.sh` is invoked outside Docker it will fail.
- **Gunicorn command not documented** — `entrypoint.sh` ends with `exec "$@"`, meaning the gunicorn command must be passed as an argument (e.g., via `CMD` in Dockerfile), but neither the `Dockerfile` nor the README shows what that command looks like.
- **No `Makefile` / `justfile`** — common tasks (`migrate`, `runserver`, `populate_weather_data`, `test`) must be memorised or found from the README.
- **Port conflict scenario undocumented** — no note in the README that a local PostgreSQL on port 5432 will shadow Docker's TimescaleDB.
- **No migration rollback strategy** — `0002_timescaledb_hypertables` is `atomic = False`; a partial failure leaves the schema in an unknown state with no documented recovery path.
- **No staging environment** — the project only distinguishes `DEBUG=True` (dev) vs `DEBUG=False` (production). No mid-tier environment is documented.

#### What's manual vs automated

| Task                                       | Status                              |
| ------------------------------------------ | ----------------------------------- |
| DB migrations (container startup)          | ✅ Automated (entrypoint.sh)        |
| Static file collection (container startup) | ✅ Automated (entrypoint.sh)        |
| Data seeding                               | ❌ Manual (`populate_weather_data`) |
| Docker image build                         | ❌ Manual (no CI trigger)           |
| Docker image push/deploy                   | ❌ Manual                           |
| Environment configuration                  | ❌ Manual (copy `.env.example`)     |

#### Potential failure points

- `entrypoint.sh` has no retry on DB connection — race conditions can crash the container on first boot.
- `.env.example` still contains insecure placeholder values (`DEBUG=true`, `SECRET_KEY=django-insecure-*`), making it easy to deploy them accidentally.
- No pinned base image digest in `Dockerfile` — upstream Python or Gunicorn image updates could introduce breaking changes.

---

### 4. Monitoring

#### What's missing

- **No health check endpoint** — there is no `/health/` or `/ping/` route. The only way to verify the service is alive is to hit a real API endpoint (which requires a DB connection).
- **No structured logging** — `settings.py` has no `LOGGING` configuration. Django uses its default logger; output format is unstructured text, incompatible with log aggregators.
- **No error tracking** — no Sentry or equivalent integration. Unhandled exceptions are logged to `stderr` silently in production.
- **No metrics** — no Prometheus/StatsD endpoint. There is no visibility into request rates, response times, or DB query durations.
- **No APM** — no distributed tracing (OpenTelemetry, Datadog, etc.).
- **No uptime alerting** — no external health checker or alerting rule defined.

#### What's manual vs automated

| Task                   | Status                 |
| ---------------------- | ---------------------- |
| Error detection        | ❌ Manual (check logs) |
| Performance monitoring | ❌ None                |
| Uptime monitoring      | ❌ None                |
| Log aggregation        | ❌ None                |
| Alerting               | ❌ None                |

#### Potential failure points

- An exception in `compute_national_indicator` that is caught and returns HTTP 500 would go completely unnoticed in production.
- TimescaleDB time-bucket queries on large datasets can degrade silently — no slow-query alerting.
- Service restarts are invisible unless the user checks Docker logs manually.

---

### 5. Security

#### What's missing

- **Insecure `SECRET_KEY` default** — both `.env` and `.env.example` ship with `django-insecure-change-this-in-production`. Django will warn at startup but the application still runs.
- **`DEBUG=True` in `.env.example`** — if a developer forgets to change this before deploying, the full traceback with local variables is exposed in HTTP responses.
- **Empty `AUTH_PASSWORD_VALIDATORS`** — the admin user can be created with any password, including empty strings.
- **No API rate limiting** — `REST_FRAMEWORK` settings define no throttle classes. The API is open to scraping or denial-of-service.
- **No authentication on API endpoints** — `NationalIndicatorAPIView` explicitly sets `authentication_classes = []` and `permission_classes = []`. The other ViewSets inherit DRF defaults (no authentication by default). This is acceptable for public data but is undocumented.
- **No dependency vulnerability scanning** — no `pip-audit`, no `safety`, no GitHub Dependabot configured.
- **No secrets detection** — pre-commit has no `detect-secrets` hook. A developer could accidentally commit credentials.
- **DB credentials in plain `.env`** — no vault / secret manager integration.

#### What's manual vs automated

| Task                          | Status            |
| ----------------------------- | ----------------- |
| Dependency vulnerability scan | ❌ Not configured |
| Secrets detection in commits  | ❌ Not configured |
| SAST (bandit)                 | ❌ Not configured |
| HTTPS enforcement             | ❌ Not documented |
| Rate limiting                 | ❌ Not configured |

#### Potential failure points

- Default insecure secret key accidentally deployed.
- Admin UI exposed without brute-force protection (no `django-axes` or similar).
- Unthrottled endpoints can be hammered to inflate DB query load.

---

### 6. Documentation

#### What's missing

- **No CONTRIBUTING.md** — no guide for new developers on branching strategy, PR process, or test requirements.
- **No architecture diagram** — the relationship between TimescaleDB, Django, the national indicator service, and the fake data layer is only discoverable by reading code.
- **`NationalIndicatorAPIView` uses fake data with no roadmap** — the endpoint comment says _"Implémentation mock (sans BDD)"_ but there is no documented plan or interface for plugging in real data.
- **No API versioning policy** — the API is at `v1` but there is no documented strategy for introducing `v2` or deprecating fields.
- **No CHANGELOG.md** — no history of breaking changes or feature additions.
- **No production deployment guide** — the README only covers local development.

#### What's manual vs automated

| Task                                   | Status                                                                                                 |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| OpenAPI spec generation                | ✅ Automated (drf-spectacular)                                                                         |
| OpenAPI spec validation against target | ❌ `openapi/target-specs/openapi.yaml` exists but no CI step validates it matches the generated schema |
| README maintenance                     | ❌ Manual                                                                                              |
| Changelog                              | ❌ None                                                                                                |

#### Potential failure points

- New developers will likely run into the TimescaleDB port conflict because it is not mentioned in the README.
- The `openapi/target-specs/openapi.yaml` can drift from the actual API undetected.

---

## Step 3 — Top 5 Issues and Improvement Plan

### Issue 1 — Local development requires TimescaleDB and fails silently on port conflicts

**Priority:** High — blocks every new developer from running the backend locally.

| Horizon                | Action                                                                                                                                                                                                                                                                           |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Short-term fix**     | Add a note in `README.md` about the port 5432 conflict. Document the `--fake` migration workaround. Add a `wait-for-it` or `pg_isready` check in `entrypoint.sh`.                                                                                                                |
| **Long-term solution** | Introduce a `TIMESCALEDB_ENABLED` env variable. Wrap migration `0002` operations in a conditional check so the migration is a no-op (but passes) on plain PostgreSQL. Provide a `docker-compose.override.yml` that exposes TimescaleDB on a non-conflicting port (e.g., `5433`). |
| **Tools/technologies** | `wait-for-it.sh` or `pg_isready` loop in entrypoint; Django `RunPython` conditional in migration; `docker-compose.override.yml`                                                                                                                                                  |

---

### Issue 2 — No CI/CD pipeline

**Priority:** High — every quality gate (tests, lint, build) is manual.

| Horizon                | Action                                                                                                                                                                            |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Short-term fix**     | Add a GitHub Actions workflow (`.github/workflows/ci.yml`) that runs `ruff check`, `pytest --cov=. --cov-fail-under=60` and Docker image build on every push and pull request.    |
| **Long-term solution** | Add a CD pipeline that publishes the Docker image to GHCR on merge to `main` and deploys to a staging environment automatically. Add `pip-audit` and `bandit` as security checks. |
| **Tools/technologies** | GitHub Actions, `docker/build-push-action`, `pypa/gh-action-pip-audit`, `bandit`                                                                                                  |

---

### Issue 3 — Missing tests for DB-backed ViewSets (< ~40% coverage)

**Priority:** High — the three main ViewSets have zero test coverage.

| Horizon                | Action                                                                                                                                                                                                                                                        |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Short-term fix**     | Add `pytest.mark.django_db` integration tests for `StationViewSet` (list, retrieve, filters), `HoraireTempsReelViewSet` (list, latest, date filters), and `QuotidienneViewSet` (list, date filters). Use `factory-boy` (already declared) to create fixtures. |
| **Long-term solution** | Enforce a coverage minimum of 80% via `pytest-cov --cov-fail-under=80` in CI. Add property-based tests (Hypothesis) for serializer validation edge cases.                                                                                                     |
| **Tools/technologies** | `pytest-django`, `factory-boy`, `pytest-cov`, `hypothesis`                                                                                                                                                                                                    |

---

### Issue 4 — No monitoring or health check endpoint

**Priority:** Medium — production failures are invisible.

| Horizon                | Action                                                                                                                                                                                                         |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Short-term fix**     | Add a `/health/` endpoint that returns `{"status": "ok", "db": "ok"/"error"}` by executing a lightweight DB query (`SELECT 1`). Configure structured JSON logging in `settings.py` using `python-json-logger`. |
| **Long-term solution** | Integrate Sentry for error tracking. Add `django-prometheus` to expose a `/metrics` endpoint for Prometheus scraping. Define alert rules for error rate > 1% and P95 latency > 500ms.                          |
| **Tools/technologies** | `sentry-sdk[django]`, `django-prometheus`, `python-json-logger`, Grafana + Prometheus                                                                                                                          |

---

### Issue 5 — Security gaps (no rate limiting, insecure defaults, no secrets scanning)

**Priority:** Medium — not exploited yet but represents real risk at any scale.

| Horizon                | Action                                                                                                                                                                                                                                                                                   |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Short-term fix**     | Add `AnonRateThrottle` and `UserRateThrottle` to `REST_FRAMEWORK["DEFAULT_THROTTLE_CLASSES"]`. Restore `AUTH_PASSWORD_VALIDATORS` to Django defaults. Add `detect-secrets` to pre-commit. Rotate the `SECRET_KEY` in `.env` to a securely generated value.                               |
| **Long-term solution** | Integrate a secrets manager (e.g., HashiCorp Vault, AWS Secrets Manager) for DB credentials and secret key. Add `django-axes` for admin brute-force protection. Run `pip-audit` in CI on every dependency change. Document the intended authentication model for future write endpoints. |
| **Tools/technologies** | DRF throttling, `django-axes`, `detect-secrets`, `pip-audit`, HashiCorp Vault or equivalent                                                                                                                                                                                              |

---

## Appendix — Quick Fix Summary

| #   | File                       | Change                                                                                                  |
| --- | -------------------------- | ------------------------------------------------------------------------------------------------------- |
| 1   | `config/settings.py`       | Restore `AUTH_PASSWORD_VALIDATORS` to Django defaults                                                   |
| 2   | `config/settings.py`       | Add `LOGGING` config with JSON formatter                                                                |
| 3   | `config/settings.py`       | Add `DEFAULT_THROTTLE_CLASSES` and `DEFAULT_THROTTLE_RATES` to `REST_FRAMEWORK`                         |
| 4   | `config/urls.py`           | Add `/health/` endpoint                                                                                 |
| 5   | `entrypoint.sh`            | Add `pg_isready` wait loop before `migrate`                                                             |
| 6   | `.pre-commit-config.yaml`  | Remove `--ignore=DJ001`; fix the underlying model fields instead                                        |
| 7   | `weather/models.py`        | Replace `null=True` with `default=""` on `CharField` fields in `Quotidienne`                            |
| 8   | `.env.example`             | Add comment warning that `DEBUG` must be `false` and `SECRET_KEY` must be changed before any deployment |
| 9   | `pyproject.toml`           | Add `sentry-sdk`, `python-json-logger`, `django-prometheus` to dependencies                             |
| 10  | `.github/workflows/ci.yml` | Create CI workflow (ruff + pytest + docker build)                                                       |
