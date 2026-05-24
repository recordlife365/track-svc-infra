# LifeMemo — Application Design Document

## 1. Overview

LifeMemo is a personal knowledge management web application that allows users to record daily life memos and ask natural-language questions. When a question is asked, all of the user's memos are loaded as context and passed to an LLM, which answers using that personal information. If the total context grows too large to fit in a single LLM call, a RAG (Retrieval-Augmented Generation) approach will be introduced as a later optimisation.

### Core Capabilities (v1)
- User authentication and account management
- Create, edit, delete, and browse personal memos
- Ask questions in natural language; receive answers grounded in personal memos
- Secure, private — each user's data is isolated

### Planned Capabilities (v2+)
- Mobile frontend (React Native)
- Audio input (speech-to-text transcription)
- Image upload with OCR extraction

---

## 2. High-Level Architecture

```Do 
┌─────────────────────────────────────────────────────────────────┐
│                          Clients                                │
│   React Web App      React Native (v2)    CLI / API consumers   │
└──────────────┬───────────────────────────────────────────────── ┘
               │  HTTPS
               ▼
┌──────────────────────────────┐
│         API Gateway          │  Rate limiting, auth token
│   (Spring Cloud Gateway)     │  validation, routing
└──┬──────────┬────────────┬───┘
   │          │            │
   ▼          ▼            ▼
┌──────┐  ┌────────┐  ┌──────────┐  ┌──────────────┐
│ Auth │  │  Memo  │  │  Query   │  │  Media (v2)  │
│  Svc │  │  Svc   │  │   Svc    │  │    Svc       │
└──┬───┘  └───┬────┘  └────┬─────┘  └──────┬───────┘
   │          │             │  ▲            │
   ▼          ▼             │  │ fetch all  ▼
┌──────┐ ┌────────┐◀────────┘  │ memos    ┌─────────────┐
│ User │ │ Memo   │────────────┘          │  Object     │
│  DB  │ │  DB    │                       │  Storage    │
│(PG)  │ │ (PG)   │                       │ (S3-compat) │
└──────┘ └────────┘                       └─────────────┘
                    ┌─────────────┐
                    │   LLM API   │
                    │ (OpenAI /   │
                    │ Anthropic / │
                    │ self-hosted)│
                    └──────▲──────┘
                           │ full-context prompt
                    ┌──────┴──────┐
                    │  Query Svc  │
                    │  (SSE out)  │
                    └─────────────┘
```

All services communicate over internal Kubernetes cluster networking. External traffic enters only through the API Gateway.

---

## 3. Frontend — React Web Application

### 3.1 Technology Stack

| Concern           | Choice                                    | Notes                                              |
|-------------------|-------------------------------------------|----------------------------------------------------|
| Framework         | React 18 + TypeScript                     | Industry standard                                  |
| Build tool        | Vite                                      | Official React recommendation replacing Create React App |
| State management  | React built-in (useState, useContext)     | No extra library; sufficient for this app's scope  |
| Data fetching     | Axios + useEffect hooks                   | Explicit, easy to read and debug                   |
| Routing           | React Router v6                           | De-facto standard for React SPAs                   |
| UI component lib  | Material UI (MUI)                         | Large, well-documented, widely adopted             |
| Forms             | React Hook Form                           | Lightweight, no schema DSL required                |
| HTTP client       | Axios                                     | Interceptor for JWT refresh                        |
| Auth              | JWT stored in HttpOnly cookie             |                                                    |
| Testing           | Jest + React Testing Library              | Long-established standard; familiar to most teams  |
| E2E testing       | Playwright                                | Cross-browser, actively maintained                 |

### 3.2 Application Pages & Flows

```
/login            — sign in
/register         — create account
/dashboard        — recent memos, quick entry box
/memos            — full memo list with search & filter
/memos/:id        — single memo view / edit
/ask              — conversational Q&A interface
/settings         — account, preferences
```

### 3.3 Memo Entry UI

- Plain textarea (or simple rich-text editor via MUI) — no custom editor library
- Auto-save draft to `localStorage` every 30 s
- Date/time stamp auto-filled, editable

### 3.4 Q&A Interface

- Chat-style UI; user types question, response streams back (SSE)
- Each answer shows source memo snippets used as context
- Conversation history kept client-side per session

### 3.5 Mobile-Readiness (v2 prep)

- MUI's responsive grid works on narrow screens from day one
- React Native app shares the same REST/SSE API — no frontend coupling in backend
- Audio input component in React Native uses device microphone; upload to Media Svc

---

## 4. Backend Microservices — Java

All services are built with **Spring Boot 3.x** (Java 21, virtual threads via Project Loom) and packaged as Docker images.

### 4.1 Auth Service

**Responsibilities:** user registration, login, JWT issuance, token refresh, password reset.

**Stack:** Spring Security, jjwt, Spring Data JPA, PostgreSQL.

**Endpoints:**

| Method | Path                        | Description                                                                                     |
|--------|-----------------------------|-------------------------------------------------------------------------------------------------|
| POST   | `/auth/register`            | Create a new account. Body: `{ email, password }`. Returns the new user's profile.             |
| POST   | `/auth/login`               | Authenticate with email + password. Returns a short-lived JWT access token and sets an HttpOnly refresh-token cookie. |
| POST   | `/auth/refresh`             | Exchange a valid refresh-token cookie for a new access token. Old refresh token is revoked and replaced (rotation). |
| POST   | `/auth/logout`              | Revoke the current refresh token. Client should discard the access token.                       |
| POST   | `/auth/password/reset-request` | Accepts an email address and sends a one-time password-reset link if the account exists.     |
| POST   | `/auth/password/reset`      | Completes the reset flow. Body: `{ token, newPassword }`. Invalidates all existing refresh tokens for the user. |

**Token strategy:**
- Access token: short-lived JWT (15 min), signed with RS256
- Refresh token: opaque UUID stored in DB, long-lived (30 days), rotated on use
- API Gateway validates access token locally (public key); no round-trip to Auth Svc per request

**Data model:**
```
users(id UUID PK, email TEXT UNIQUE, password_hash TEXT,
      created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ)

refresh_tokens(id UUID PK, user_id UUID FK, token_hash TEXT,
               expires_at TIMESTAMPTZ, revoked BOOL)
```

---

### 4.2 Memo Service

**Responsibilities:** CRUD for memos, search, pagination.

**Stack:** Spring Boot, Spring Data JPA, PostgreSQL, Spring Security (reads JWT user claim).

**Endpoints:**

| Method | Path              | Description                                                                                                         |
|--------|-------------------|---------------------------------------------------------------------------------------------------------------------|
| GET    | `/memos`          | Return a paginated list of the authenticated user's memos. Query params: `page` (0-based), `size` (default 20), `q` (full-text search term). Results are ordered newest first. |
| POST   | `/memos`          | Create a new memo. Body: `{ title, body }`. `title` is optional — defaults to the first line of `body` if omitted. Returns the created memo with its assigned `id` and timestamps. |
| GET    | `/memos/:id`      | Fetch a single memo by ID. Returns 404 if the memo does not belong to the authenticated user.                       |
| PUT    | `/memos/:id`      | Replace the title and/or body of an existing memo. Body: `{ title?, body? }`. Returns the updated memo.            |
| DELETE | `/memos/:id`      | Permanently delete a memo. Returns 204 No Content on success.                                                       |

**Data model:**
```
memos(id UUID PK, user_id UUID, title TEXT, body TEXT,
      created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ)
```

---

### 4.3 Query Service

**Responsibilities:** receive natural-language questions, load the user's full memo history as context, call the LLM, stream the answer back.

**Stack:** Spring Boot, LangChain4j (Java LLM framework), Spring WebFlux (reactive for SSE streaming).

**Endpoints:**

| Method | Path             | Description                                                                                                          |
|--------|------------------|----------------------------------------------------------------------------------------------------------------------|
| POST   | `/query`         | Ask a natural-language question. Body: `{ "question": "..." }`. The service fetches all of the user's memos, builds a full-context prompt, and streams the LLM's answer back as Server-Sent Events (SSE). Each SSE event carries one token chunk; a final `[DONE]` event signals completion. |
| GET    | `/query/history` | Return the authenticated user's past questions and answers, ordered newest first. Supports `page` and `size` query params. Each record includes the question, the full answer, the number of memos used as context, and the timestamp. |

**Full-context flow:**
```
1. Receive question + user_id
2. Call Memo Svc: GET /memos (all, no pagination) for this user_id
3. Serialise memos into a single context block (title + body + date, newest first)
4. Build prompt:
     system: "You are a personal assistant. Answer using only the memos below."
     user context: <all memos>
     user question: <question>
5. Call LLM; stream tokens back to client via SSE
6. Persist Q&A record asynchronously
```

**Context size guard:** Before calling the LLM, count approximate tokens (chars / 4). If the total exceeds the model's context limit, truncate older memos and include a note in the prompt that some older history was omitted. This is the natural trigger to introduce RAG in a future version.

**Data model:**
```
qa_history(id UUID PK, user_id UUID, question TEXT,
           answer TEXT, memo_count_used INT,
           created_at TIMESTAMPTZ)
```

**LLM provider abstraction:**

LangChain4j's `ChatLanguageModel` interface lets you swap providers via config:

```yaml
# application.yml
llm:
  provider: openai          # openai | anthropic | ollama | bedrock
  model: gpt-4o
  base-url: ${LLM_BASE_URL}
  api-key: ${LLM_API_KEY}
  max-context-chars: 400000  # ~100k tokens; adjust per model
```

Migrating from OpenAI to a self-hosted model (e.g., via Ollama) requires only a config change.

---

### 4.4 Media Service (v2)

**Responsibilities:** receive file uploads, store in object storage, trigger OCR pipeline, return extracted text to Memo Svc.

**Stack:** Spring Boot, Apache Tika (OCR via Tesseract), MinIO client (S3-compatible).

**Endpoints:**

| Method | Path             | Description                                                                                                                    |
|--------|------------------|--------------------------------------------------------------------------------------------------------------------------------|
| POST   | `/media/upload`  | Upload a file as `multipart/form-data`. Stores the raw file in object storage. If the file is an image or PDF, runs OCR and returns `{ mediaId, extractedText }` synchronously. Caller (Memo Svc) uses `extractedText` as the memo body and stores `mediaId` as a reference. |
| GET    | `/media/:id`     | Redirects (HTTP 302) to a short-lived signed URL for the raw file in object storage. The client follows the redirect to download directly. Returns 404 if the media does not belong to the authenticated user. |
| DELETE | `/media/:id`     | Delete the file from object storage and remove its metadata record. Returns 204 No Content.                                    |

**OCR flow:**
```
1. Upload file → object storage
2. If image/PDF: run Apache Tika + Tesseract OCR → extract text
3. Return extracted text to caller (Memo Svc stores it as memo body)
4. Store mediaId reference in memo for later retrieval
```

**Audio transcription (v2):**
```
1. Upload audio → object storage
2. Call Whisper-compatible API (OpenAI or self-hosted whisper.cpp)
3. Return transcript → Memo Svc creates memo from transcript
```

---

### 4.5 API Gateway

**Technology:** Spring Cloud Gateway (same JVM ecosystem, no extra language).

**Responsibilities:**
- TLS termination (or delegate to ingress controller)
- JWT validation (RS256 public key, local verification — no Auth Svc call)
- Route requests to correct downstream service
- Rate limiting (Redis-backed token bucket per user)
- Request/response logging, correlation ID injection
- CORS headers

**Routing table:**
```
/auth/**   → auth-service:8080
/memos/**  → memo-service:8080
/query/**  → query-service:8080
/media/**  → media-service:8080
```

---

## 5. Cross-Cutting Concerns

### 5.1 Observability & Distributed Tracing

#### Signal stack

| Signal   | Tool                                        |
|----------|---------------------------------------------|
| Logs     | Structured JSON (Logback) → Fluentd → Loki  |
| Metrics  | Micrometer → Prometheus → Grafana           |
| Traces   | OpenTelemetry → Grafana Tempo               |
| Alerting | Grafana Alertmanager                        |

All tools are cloud-agnostic and self-hostable on Kubernetes. Grafana is the single pane of glass — logs (Loki), traces (Tempo), and metrics (Prometheus) are all queryable from one UI and can be correlated by `traceId`.

---

#### Distributed tracing with TraceId

A **traceId** is a single identifier that follows a request as it travels across all services. When a request enters the API Gateway and fans out to Auth Svc, Memo Svc, or Query Svc, every log line written by every service for that request carries the same `traceId`. This makes it possible to reconstruct the full journey of any request from a single search.

**Standard used:** [W3C Trace Context](https://www.w3.org/TR/trace-context/) — the `traceparent` HTTP header carries the `traceId` and `spanId` between services. This is a vendor-neutral standard supported by all major tracing tools.

```
Client
  │
  │  HTTPS request (no traceparent yet)
  ▼
API Gateway  ──generates──▶  traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
  │                                           └──── traceId ────┘ └── spanId ──┘
  │  forwards request + traceparent header
  ├──▶  Memo Svc   (creates child span, logs with same traceId)
  │       └──▶  PostgreSQL query  (child span)
  │
  └──▶  Query Svc  (creates child span, logs with same traceId)
            └──▶  LLM API call   (child span)
```

---

#### Setup in Spring Boot services

Each service adds two dependencies — Micrometer Tracing (Spring's tracing facade) and the OpenTelemetry bridge that exports spans to Tempo:

```xml
<!-- pom.xml -->
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-tracing-bridge-otel</artifactId>
</dependency>
<dependency>
    <groupId>io.opentelemetry.instrumentation</groupId>
    <artifactId>opentelemetry-spring-boot-starter</artifactId>
</dependency>
```

Spring Boot auto-configuration handles the rest:
- Generates a `traceId` on every incoming request (or adopts the one from an incoming `traceparent` header)
- Propagates it automatically on all outbound `RestTemplate` / `WebClient` calls via the `traceparent` header
- Puts `traceId` and `spanId` into the MDC (Mapped Diagnostic Context) so Logback includes them in every log line automatically

```yaml
# application.yml
management:
  tracing:
    sampling:
      probability: 1.0   # 100% in staging; reduce to 0.1 (10%) in production
spring:
  application:
    name: memo-service   # appears as the service name in Tempo
```

---

#### TraceId in structured logs

Every log line is emitted as JSON with `traceId` and `spanId` included automatically by the Logback MDC integration:

```json
{
  "timestamp": "2026-05-09T10:23:45.123Z",
  "level":     "INFO",
  "service":   "memo-service",
  "traceId":   "4bf92f3577b34da6a3ce929d0e0e4736",
  "spanId":    "00f067aa0ba902b7",
  "message":   "Memo created",
  "memoId":    "e3d2a1b0-..."
}
```

Loki indexes the `traceId` field, so searching for a single traceId in Grafana instantly returns all log lines from all services for that request.

---

#### TraceId surfaced to clients

The API Gateway adds the `traceId` as a response header on every request:

```
X-Trace-Id: 4bf92f3577b34da6a3ce929d0e0e4736
```

It is also included in every error response body (see section 5.6). This means:
- A user can copy the `X-Trace-Id` from browser DevTools and send it to support
- An engineer pastes it into Grafana → immediately sees the full distributed trace and all correlated log lines across every service involved in that request

---

#### Querying in Grafana

```
Loki query — find all logs for one request across all services:
  {namespace="lifememo-staging"} | json | traceId="4bf92f3577b34da6a3ce929d0e0e4736"

Tempo — search by traceId to get the full waterfall (which service, how long each span took):
  Explore → Tempo → Search by traceId
```

Grafana's **trace-to-logs** feature links a span in Tempo directly to the matching Loki log lines — one click from a slow span to the exact log output that explains why.

### 5.2 Configuration Management

- Spring Boot reads from environment variables (12-factor)
- Secrets (DB passwords, API keys) stored in **Kubernetes Secrets**, injected as env vars
- Non-secret config in **ConfigMaps**
- For multi-environment config, use **Helm values** per environment

### 5.3 Service-to-Service Communication

- Synchronous REST over HTTP/2 (internal cluster DNS) — the only inter-service call in v1 is Query Svc → Memo Svc to fetch all memos before an LLM call.
- No message broker is needed in v1. One will be introduced when Media Svc (v2) needs to notify Memo Svc of completed OCR/transcription jobs asynchronously.

### 5.4 API Documentation

Each Spring Boot service uses **Springdoc OpenAPI** to generate API documentation automatically from the code. No separate Swagger file is maintained.

**How it works:**
- Add the `springdoc-openapi-starter-webmvc-ui` dependency to each service's `pom.xml`
- Springdoc scans controllers and model classes at startup and builds an OpenAPI 3.0 spec
- Two endpoints are exposed automatically:
  - `/swagger-ui.html` — interactive Swagger UI for exploring and testing the API
  - `/v3/api-docs` — machine-readable OpenAPI JSON spec (can be imported into Postman, Insomnia, etc.)

**Enriching the generated docs with annotations:**
```java
@Operation(summary = "Create a new memo")
@ApiResponse(responseCode = "201", description = "Memo created")
@ApiResponse(responseCode = "401", description = "Not authenticated")
@PostMapping("/memos")
public ResponseEntity<MemoResponse> createMemo(@RequestBody @Valid CreateMemoRequest request) { ... }
```

**Access per environment:**
- Swagger UI is enabled in `staging` and disabled in `production` (controlled via `springdoc.swagger-ui.enabled` in Helm values)
- The `/v3/api-docs` endpoint follows the same toggle so the spec is not publicly exposed in production

**Source of truth:** the generated spec is always in sync with the code. The API descriptions in this design document are high-level intent only — the live Swagger UI in staging is the authoritative API reference once services are implemented.

### 5.5 Security

- All traffic inside the cluster uses mTLS (via a service mesh like **Linkerd** — lightweight, easy to operate)
- User data strictly namespaced by `user_id` in every query — no cross-user leakage
- PII encrypted at rest (PostgreSQL column-level encryption for sensitive fields)
- Input sanitized before LLM prompt to prevent prompt injection

### 5.6 Error Handling Strategy

#### Standard error response format

All services return errors in the same JSON envelope so clients never need service-specific parsing logic:

```json
{
  "timestamp": "2026-05-09T10:23:45Z",
  "status": 400,
  "error": "VALIDATION_ERROR",
  "message": "Request body contains invalid fields",
  "details": [
    { "field": "body", "issue": "must not be blank" }
  ],
  "path": "/memos",
  "traceId": "4bf92f3577b34da6"
}
```

| Field       | Description                                                                 |
|-------------|-----------------------------------------------------------------------------|
| `timestamp` | UTC time the error occurred                                                 |
| `status`    | HTTP status code (mirrors the HTTP response status)                         |
| `error`     | Machine-readable error code in SCREAMING_SNAKE_CASE — safe to use in client logic |
| `message`   | Human-readable summary — for logging and developer debugging                |
| `details`   | Optional list of field-level issues, present on validation errors only      |
| `path`      | Request path that produced the error                                        |
| `traceId`   | OpenTelemetry trace ID — use this to correlate with logs and traces in Grafana |

#### HTTP status code conventions

| Status | When to use                                                               |
|--------|---------------------------------------------------------------------------|
| 400    | Request body fails validation                                             |
| 401    | Missing or expired JWT — client must re-authenticate                      |
| 403    | Authenticated but not authorised (e.g. accessing another user's memo)     |
| 404    | Resource not found or does not belong to the authenticated user           |
| 409    | Conflict (e.g. registering with an email that already exists)             |
| 422    | Request is well-formed but semantically invalid (e.g. LLM context too large to process) |
| 429    | Rate limit exceeded                                                       |
| 500    | Unexpected server error — details are logged server-side, not exposed to the client |
| 503    | Downstream dependency unavailable (e.g. LLM API unreachable)             |

#### Backend — Spring Boot global exception handler

Each service has a single `@RestControllerAdvice` class that catches all exceptions and maps them to the standard envelope. Individual controllers throw domain exceptions; they never build error responses themselves.

```java
@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(MethodArgumentNotValidException.class)
    @ResponseStatus(HttpStatus.BAD_REQUEST)
    public ErrorResponse handleValidation(MethodArgumentNotValidException ex, HttpServletRequest req) {
        List<FieldError> details = ex.getBindingResult().getFieldErrors().stream()
            .map(f -> new FieldError(f.getField(), f.getDefaultMessage()))
            .toList();
        return ErrorResponse.of(400, "VALIDATION_ERROR", "Invalid request", details, req);
    }

    @ExceptionHandler(ResourceNotFoundException.class)
    @ResponseStatus(HttpStatus.NOT_FOUND)
    public ErrorResponse handleNotFound(ResourceNotFoundException ex, HttpServletRequest req) {
        return ErrorResponse.of(404, "NOT_FOUND", ex.getMessage(), req);
    }

    @ExceptionHandler(Exception.class)
    @ResponseStatus(HttpStatus.INTERNAL_SERVER_ERROR)
    public ErrorResponse handleUnexpected(Exception ex, HttpServletRequest req) {
        log.error("Unhandled exception", ex);   // full stack trace to logs only
        return ErrorResponse.of(500, "INTERNAL_ERROR", "An unexpected error occurred", req);
    }
}
```

Key rules:
- **Never expose stack traces or internal details in the response body** — log them server-side and return only the `traceId` so engineers can look them up
- **500 errors are always logged at ERROR level** with the full stack trace
- **4xx errors are logged at WARN level** — they are the client's fault, not the service's

#### API Gateway error handling

The Gateway produces the same JSON envelope for errors it generates itself (expired JWT, rate limit exceeded, routing failure) so the client always receives the same format regardless of which service produced the error.

#### Frontend — React

- Axios interceptor reads the `error` field from the response body and maps known codes to user-facing messages (e.g. `VALIDATION_ERROR` → show inline field errors, `UNAUTHORIZED` → redirect to `/login`)
- Unknown or 5xx errors show a generic toast notification: "Something went wrong. Please try again."
- The `traceId` from the response is logged to the browser console so it can be provided to engineers for debugging

#### LLM / streaming errors (Query Service)

SSE streams cannot return an HTTP error status after the stream has started. If the LLM call fails mid-stream, the service sends a final SSE event with a structured error payload before closing the connection:

```
event: error
data: {"error": "LLM_UNAVAILABLE", "message": "Could not reach the AI service. Please try again."}
```

The frontend listens for the `error` event type and displays it as an inline message in the chat UI.

---

## 6. Data Architecture

### 6.1 Databases

| Service        | Database          | Rationale                                    |
|----------------|-------------------|----------------------------------------------|
| Auth Svc       | PostgreSQL        | Relational, ACID, refresh token management   |
| Memo Svc       | PostgreSQL        | Relational, full-text search (`tsvector`)    |
| Query Svc      | PostgreSQL        | Q&A history only; no vector data in v1       |
| Session cache  | Redis             | Short-lived, fast key-value                  |
| Rate limiting  | Redis             | Atomic counters                              |
| Object storage | MinIO (S3-compat) | Self-hostable S3; swap to AWS S3 via config  |

Query Svc has no dedicated store beyond Q&A history — all personal data lives in Memo Svc's database and is fetched at query time. Introduce pgvector if/when a RAG approach becomes necessary.

### 6.2 Database per Service

Each microservice owns its own schema/database — no shared tables. Services communicate via API or events, never via direct DB access.

### 6.3 Database Lifecycle & Migrations

#### Tool — Liquibase (SQL format)

Each service that owns a database manages its own migrations using Liquibase. SQL-formatted changelogs are used so migrations are plain SQL files with no Liquibase-specific XML or YAML syntax in the migration files themselves.

**Directory layout (per service repo):**
```
src/main/resources/db/
└── changelog/
    ├── db.changelog-master.xml     ← master file; Liquibase reads this first
    └── changes/
        ├── 0001_create_table.sql
        ├── 0002_add_column.sql
        └── 0003_add_index.sql
```

**Master changelog** (`db.changelog-master.xml`) simply includes the SQL files in order:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                   xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog
                   http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-4.27.xsd">

    <includeAll path="db/changelog/changes" relativeToChangelogFile="false"/>

</databaseChangeLog>
```

**Each SQL migration file** uses Liquibase-formatted SQL comments to declare the changeset:
```sql
--liquibase formatted sql

--changeset memo-team:0001 labels:init
CREATE TABLE memos (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL,
    title       TEXT,
    body        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

--rollback DROP TABLE memos;
```

Liquibase tracks applied changesets in a `DATABASECHANGELOG` table it creates automatically on first run.

---

#### Why not run migrations inside the application pod?

In a Kubernetes deployment with multiple replicas, all pods start at the same time. If each pod ran Liquibase on startup they would all attempt to acquire the Liquibase lock simultaneously — causing lock contention, startup failures, or duplicate migrations depending on timing.

The solution is to run migrations in a dedicated **Kubernetes Job** that must complete successfully before any application pod is allowed to start.

---

#### Kubernetes Job + Helm hook pattern

The migration Job is part of each service's Helm chart and is annotated as a **pre-install / pre-upgrade hook**, which causes Helm to run it and wait for it to finish before applying the rest of the chart (the Deployment, Service, etc.).

```
helm upgrade --install memo-service ./helm/memo-service ...
        │
        ├─ Helm detects pre-install hook
        │
        ▼
  Kubernetes Job: memo-db-migrate
  (runs Liquibase update)
        │
        ├─ Job succeeds → Helm continues
        │
        ▼
  Kubernetes Deployment: memo-service
  (application pods start — DB is already up to date)
```

**Example Job manifest** (inside the Helm chart at `helm/templates/db-migrate-job.yaml`):

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "memo-service.fullname" . }}-db-migrate
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-1"
    # Delete the old job before creating a new one;
    # keep failed jobs so logs are available for debugging.
    helm.sh/hook-delete-policy: before-hook-creation
spec:
  backoffLimit: 3          # retry up to 3 times on failure
  activeDeadlineSeconds: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: liquibase
          image: liquibase/liquibase:4.27
          args:
            - --url=jdbc:postgresql://$(DB_HOST):5432/$(DB_NAME)
            - --username=$(DB_USER)
            - --password=$(DB_PASSWORD)
            - --changeLogFile=db/changelog/db.changelog-master.xml
            - update
          env:
            - name: DB_HOST
              valueFrom:
                configMapKeyRef:
                  name: {{ include "memo-service.fullname" . }}-config
                  key: db.host
            - name: DB_NAME
              valueFrom:
                configMapKeyRef:
                  name: {{ include "memo-service.fullname" . }}-config
                  key: db.name
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: {{ include "memo-service.fullname" . }}-secret
                  key: db.user
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ include "memo-service.fullname" . }}-secret
                  key: db.password
```

The application image (Spring Boot) does **not** include Liquibase at all — migrations are the Job's sole responsibility. The application connects to a database that is already at the correct schema version.

#### Sequence on first deploy and on upgrades

```
First deploy
  1. Helm runs the Job → Liquibase creates DATABASECHANGELOG table, applies all changesets
  2. Job completes → Helm deploys the application Deployment
  3. Application pods start against an already-migrated schema

Upgrade (new migration files added)
  1. Helm detects pre-upgrade hook, deletes the previous Job, creates a new one
  2. Liquibase runs → skips already-applied changesets, applies only the new ones
  3. Job completes → Helm rolls out the new application pods

Upgrade (no migration changes)
  1. Liquibase runs → finds no new changesets, exits successfully immediately
  2. Application rolls out as normal

Failed migration
  1. Job fails and retries (backoffLimit: 3)
  2. If all retries fail, Helm aborts — the existing application Deployment is NOT touched
  3. Engineers inspect the Job's logs, fix the migration SQL, push a new release
```

---

## 7. Infrastructure & Deployment

### 7.1 Container Strategy

Every service is packaged as a Docker image:
- Base image: `eclipse-temurin:21-jre-alpine` (small, security-maintained)
- Multi-stage Dockerfile: build stage (Maven) → runtime stage (JRE only)
- Images tagged with Git SHA + semantic version

### 7.2 Kubernetes Architecture

```
cluster
├── namespace: lifememo-staging
│   ├── Deployment: api-gateway        (2 replicas)
│   ├── Deployment: auth-service       (2 replicas)
│   ├── Deployment: memo-service       (2 replicas)
│   ├── Deployment: query-service      (2 replicas)
│   ├── StatefulSet: postgresql
│   └── StatefulSet: redis
└── namespace: lifememo-prod
    └── (same structure, larger replicas, PodDisruptionBudgets)
```

**Ingress:** nginx Ingress Controller with cert-manager for TLS (Let's Encrypt).

**Autoscaling:** HorizontalPodAutoscaler on CPU/RPS metrics for all stateless services.

**Helm:** one Helm chart per service + one umbrella chart. Values files per environment:
```
helm/
├── api-gateway/
├── auth-service/
├── memo-service/
├── query-service/
└── values/
    ├── staging.yaml
    └── production.yaml
```

### 7.3 Cloud Agnosticism

| Concern             | Cloud-agnostic choice                   | AWS equivalent swap  |
|---------------------|-----------------------------------------|----------------------|
| Kubernetes          | Any CNCF-conformant cluster             | EKS                  |
| Object storage      | MinIO (S3-compatible API)               | S3 (same client)     |
| Container registry  | Harbor or Docker Hub                    | ECR                  |
| Secrets             | K8s Secrets + External Secrets Operator | AWS Secrets Manager  |
| DNS                 | External DNS operator                   | Route 53             |
| TLS certs           | cert-manager + Let's Encrypt            | ACM                  |

The application code and Helm charts are identical across providers — only the `values/<env>.yaml` changes (e.g., storage endpoint URL, DNS zone).

---

## 8. CI/CD Pipeline

### 8.1 Pipeline Tool

**GitHub Actions** (cloud-agnostic; can be mirrored to GitLab CI, Jenkins, or Tekton on-cluster if needed).

### 8.2 Pipeline Stages

```
┌──────────┐   ┌──────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│  Build   │──▶│   Test   │──▶│ Docker Build │──▶│   Staging    │──▶│  Production  │
│          │   │          │   │   & Push     │   │   Deploy     │   │   Deploy     │
└──────────┘   └──────────┘   └──────────────┘   └──────────────┘   └──────────────┘
```

**Build stage:**
- `mvn clean package -DskipTests` for all services (parallel jobs)
- Cache Maven local repo via GitHub Actions cache

**Test stage (parallel):**
- Unit tests: `mvn test` (JUnit 5, Mockito)
- Integration tests: `mvn verify` with Testcontainers (spins real PostgreSQL and Redis in Docker)
- Frontend: `vitest run` + `playwright test`
- Static analysis: SpotBugs, OWASP Dependency-Check

**Docker Build & Push:**
- `docker buildx build --platform linux/amd64,linux/arm64`
- Push to container registry with tags: `git-<SHA>` and `staging` / `latest`
- Image vulnerability scan (Trivy) — fail pipeline on CRITICAL CVEs

**Staging Deploy:**
- `helm upgrade --install lifememo-staging helm/umbrella -f values/staging.yaml --set image.tag=git-<SHA>`
- Run smoke tests against staging URL
- Automated rollback if smoke tests fail (`helm rollback`)

**Production Deploy:**
- Triggered manually (or on merge to `main` tag) — requires approval
- Blue/green or rolling update (K8s default rolling)
- Canary option: deploy to 10% of pods, monitor error rate for 5 min, then full rollout

### 8.3 Branch Strategy

```
feature/*  → PR → main
                    │
                    ├── CI runs on every PR (build + test)
                    └── Merge to main → auto-deploy to staging
                                         │
                                     Manual approval
                                         │
                                    Production deploy
```

### 8.4 Example GitHub Actions Workflow (sketch)

```yaml
# .github/workflows/ci-cd.yml
on:
  push:
    branches: [main]
  pull_request:

jobs:
  build-test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        service: [auth-service, memo-service, query-service, api-gateway]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { java-version: '21', distribution: 'temurin' }
      - uses: actions/cache@v4
        with: { path: ~/.m2, key: maven-${{ hashFiles('**/pom.xml') }} }
      - run: mvn verify
        working-directory: backend/${{ matrix.service }}

  docker-push:
    needs: build-test
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with: { registry: ${{ vars.REGISTRY }}, ... }
      - uses: docker/build-push-action@v5
        with:
          push: true
          tags: ${{ vars.REGISTRY }}/lifememo/${{ matrix.service }}:git-${{ github.sha }}

  deploy-staging:
    needs: docker-push
    runs-on: ubuntu-latest
    environment: staging
    steps:
      - uses: azure/setup-helm@v3
      - run: |
          helm upgrade --install lifememo-staging ./helm/umbrella \
            -f ./helm/values/staging.yaml \
            --set global.imageTag=git-${{ github.sha }}

  deploy-prod:
    needs: deploy-staging
    runs-on: ubuntu-latest
    environment: production          # requires manual approval in GitHub
    steps:
      - run: |
          helm upgrade --install lifememo-prod ./helm/umbrella \
            -f ./helm/values/production.yaml \
            --set global.imageTag=git-${{ github.sha }}
```

---

## 9. Future Roadmap

### v2 — Mobile & Audio

| Feature         | Approach                                                          |
|-----------------|-------------------------------------------------------------------|
| Mobile app      | React Native (shares component logic with web via shared packages)|
| Audio capture   | Device microphone → upload WAV/M4A to Media Svc                  |
| Transcription   | Whisper API (OpenAI) or self-hosted `whisper.cpp` via REST shim   |
| Result          | Transcript returned → create memo — same flow as text entry       |

### v3 — Image & OCR

| Feature           | Approach                                                        |
|-------------------|-----------------------------------------------------------------|
| Image upload      | React file picker → Media Svc → MinIO                          |
| OCR               | Apache Tika + Tesseract (Java, self-hostable)                   |
| Structured extract| Pass OCR text + image to Vision-capable LLM for better parsing |
| Storage           | Image stored in MinIO; extracted text + image ref stored in memo|

---

## 10. Repository Structure (multi-repo)

Each team owns one repository. All repos live under the same GitHub organisation and follow the `track-svc-*` naming convention.

```
~/projects/
├── track-svc-api-gateway/       Spring Cloud Gateway
│   ├── src/
│   ├── Dockerfile
│   ├── helm/                    Helm chart for this service
│   └── .github/workflows/       CI/CD pipeline for this service
│
├── track-svc-auth/              Spring Boot — auth & token management
│   ├── src/
│   ├── Dockerfile
│   ├── helm/
│   └── .github/workflows/
│
├── track-svc-memo/              Spring Boot — memo CRUD & search
│   ├── src/
│   ├── Dockerfile
│   ├── helm/
│   └── .github/workflows/
│
├── track-svc-query/             Spring Boot + LangChain4j — Q&A
│   ├── src/
│   ├── Dockerfile
│   ├── helm/
│   └── .github/workflows/
│
├── track-svc-memo-ui/           React web app (mobile TBD)
│   ├── src/
│   ├── Dockerfile               nginx serving the built bundle
│   ├── helm/
│   └── .github/workflows/
│
├── track-svc-media/             (future v2 — not created yet)
│
└── track-svc-infra/             Shared infrastructure — owned by platform/ops team
    ├── helm/
    │   ├── umbrella/            Meta-chart that pulls in all service charts
    │   └── values/
    │       ├── staging.yaml
    │       └── production.yaml
    ├── k8s/                     Cluster-wide manifests (namespaces, RBAC, etc.)
    └── terraform/               Optional: provision the cluster itself
```

### CI/CD ownership

Each service repo contains its own `.github/workflows/ci-cd.yml` that builds, tests, packages, and pushes its Docker image. The `track-svc-infra` repo owns the umbrella Helm chart and the final deployment step — it pulls whichever image tag was published by each service's pipeline and applies it to staging/production.

This keeps deployment control centralised while letting each team ship independently.

---

## 11. Key Design Decisions & Rationale

| Decision                           | Rationale                                                                                       |
|------------------------------------|-------------------------------------------------------------------------------------------------|
| Spring Boot for all backend svcs   | Consistent ecosystem, strong Java 21 + virtual thread support, rich Spring Cloud ecosystem      |
| Full-context over RAG              | Simpler to build and reason about; correct for personal scale where total memo data fits in LLM context window; defer RAG until context limits are actually hit |
| LangChain4j LLM abstraction        | Config-driven provider swap; no vendor lock-in in application code                             |
| No message broker in v1            | Full-context approach removes the need to keep a vector index warm; eliminates Kafka entirely until Media Svc (v2) needs async OCR notification |
| MinIO for object storage           | 100% S3-compatible; run anywhere; zero code change to switch to AWS S3                         |
| Helm for K8s packaging             | Standard, cloud-agnostic; parameterises all env-specific values                                |
| GitHub Actions for CI/CD          | Cloud-agnostic workflow DSL; trivially portable to GitLab CI or self-hosted runners            |
| Testcontainers for integration     | Tests run against real dependencies locally and in CI; no mocking surprises in production       |