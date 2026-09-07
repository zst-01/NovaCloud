# NovaCloud Complete Learning Guide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Produce one beginner-friendly, code-grounded guide covering NovaCloud's complete login-to-database and TraceId flow.

**Architecture:** Expand the existing root `学习文档.md` as the self-contained master guide, organized by vertical user journeys rather than source modules. Keep the existing topic documents as operational references and link them from the master guide.

**Tech Stack:** Markdown, Java 17, Spring Boot MVC, Spring Cloud Gateway WebFlux, Nginx, Docker Compose, Nacos, Redis, MySQL, browser JavaScript

**Spec:** `docs/superpowers/specs/2026-09-07-complete-learning-guide-design.md`

## Global Constraints

- Modify documentation only; do not change runtime behavior.
- Explain every current-state claim from checked-in source, configuration, or `搭建日志.md` evidence.
- Do not expose credentials or live tokens.
- Mark Kafka, Kubernetes, JWT, centralized logging, and span tracing as not implemented.
- Use short code excerpts followed by plain-Chinese explanations.

---

### Task 1: Establish the system map and reading method

**Files:**
- Modify: `学习文档.md`
- Read: `compose.yaml`, `README.md`, `搭建日志.md`

- [x] Replace the old first-lesson-only structure with a master table of contents and current capability boundary.
- [x] Add the complete service/request map and a data-ownership table.
- [x] Add a short guide to reading controllers, filters, configuration, reactive gateways, and ordinary MVC services.
- [x] Verify every listed component exists with `rg --files`.

### Task 2: Document login and session creation

**Files:**
- Modify: `学习文档.md`
- Read: `frontend/app.js`, `infra/nginx/nginx.conf`, both gateway configurations, `AuthProxy.java`, `PlatformClient.java`, `AuthController.java`, `DemoUsers.java`, `SessionStore.java`

- [x] Draw the login request and response sequence.
- [x] Add a code map with exact source paths.
- [x] Explain MySQL BCrypt account storage, `.env` bootstrap password, Redis session JSON, token TTL, and browser-memory token.
- [x] Explain login public-path handling and IP-based Redis rate limiting.
- [x] Cross-check endpoint methods, key prefixes, token format, and TTL against source.

### Task 3: Document authenticated ticket queries and authorization

**Files:**
- Modify: `学习文档.md`
- Read: both `SessionAuth.java` files, `SessionFilter.java`, `TicketProxy.java`, `TicketController.java`, gateway route configuration

- [x] Draw the authenticated ticket-query sequence from browser to MySQL and back.
- [x] Explain the responsibilities of application gateway, application service, platform gateway, and platform service.
- [x] Explain why authorization is repeated at trust boundaries and why client-supplied identity headers are removed.
- [x] Map 400, 401, 403, 404, 429, 503, and 504 to the layer that can produce them.

### Task 4: Document TraceId, Redis, discovery, and operations

**Files:**
- Modify: `学习文档.md`
- Read: Nginx configuration, both gateway `RequestLog.java` files, both service `RequestTraceFilter.java` files, `PlatformClient.java`, `RateLimitFilter.java`, `RedisWindowLimiter.java`, `rate-window.lua`, existing topic guides

- [x] Explain TraceId generation, validation, forwarding, logging, MDC cleanup, and browser display.
- [x] Separate Redis session keys from rate-limit keys and explain TTL/failure behavior.
- [x] Distinguish Docker service-name resolution, Nacos discovery, and configured internal URLs for every hop.
- [x] Add one safe hands-on exercise per topic and link the existing verification scripts.

### Task 5: Add lookup indexes and verify the completed document

**Files:**
- Modify: `学习文档.md`
- Read: all files linked from the completed guide

- [x] Add a question-to-file index and a request-to-log troubleshooting index.
- [x] Add chapter self-check questions and short interview-expression summaries.
- [x] Search for stale statements that say login, Redis, rate limiting, TraceId, or the browser page are not implemented.
- [x] Check that every Markdown file link resolves and every cited source file exists.
- [x] Re-read the guide for beginner vocabulary, current/production boundaries, duplicated sections, and exposed secrets.
