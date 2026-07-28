---
name: nextbi-analytics-contracts
description: Use when working in the NextBI analytics contracts repo — adding or editing an OpenAPI REST spec or a Kafka message contract, understanding contract versioning/publishing, fixing Spectral/oasdiff/markdownlint failures, or wiring a generated contract JAR into a service. Covers repo layout, artifact coordinates, the auto-versioning hook, naming conventions, and doc-vs-reality gotchas.
---

# NextBI Analytics Contracts

The analytics contracts repo is the **single source of truth** for NextBI platform contracts: REST APIs (OpenAPI 3.x) and Kafka messages (also OpenAPI 3.0.1 YAML — see gotchas). Gradle generates Kotlin/Java classes from every contract, packages them into JARs, and publishes them to the internal Nexus. Services depend on those JARs for typed inter-service calls. Docs-as-code: every change goes through a branch + merge request + review; rules are enforced by Spectral, oasdiff, markdownlint, lychee, and a versioning hook.

> Infra endpoints (Nexus, GitLab) are referenced as placeholders below — use the real internal URLs from your environment / repo config.

Stack: Java 21, Kotlin 2.0.21, Gradle 8.14, Spring Boot 3.2.5 BOM. Codegen via the in-house `org.nextbi.openapi-generator-plugin`. Docs in Russian; identifiers/field names/code in English.

## Repository layout

```text
docs/
  microservices/<namespace>/<service>/
    api/rest/openapi.yaml          # REST contract (the codegen input)
    readme.md                      # service doc entry point (per CONVENTIONS.md)
    assets/                        # diagrams (PlantUML/Mermaid text, not images)
  microservices/<namespace>/common/openapi/schemas/
    _index.yaml                    # shared schemas, pulled in via relative $ref
    enum/ object/ param/           # excluded from codegen resources, referenced by specs
  kafka/<namespace>/<topic.name>/
    <topic.name>.yaml              # Kafka contract, OpenAPI 3.0.1 with `paths: {}`
```

Namespaces: `nextbi`, `platform`. Each REST service owns one `openapi.yaml`; each Kafka topic owns one `<topic>.yaml`.

## Artifact coordinates

**REST** (`docs/microservices/<ns>/<service>/api/rest/openapi.yaml`):
- groupId `ru.nextbi.rest-api`, artifactId `{namespace}-{service}` (e.g. `{namespace}-core-<name>-service`)
- version from `info.version`; generated package `ru.{namespace}.rest_api.{service_name}`

**Kafka** (`docs/kafka/<ns>/<topic>/<topic>.yaml`):
- groupId `ru.nextbi.kafka`, artifactId `{topic_name}` (the topic-dir name)
- version from `info.version`

## Adding / editing a contract

1. Create the directory for the service/topic exactly at the path above.
2. Put an OpenAPI 3.x `openapi.yaml` (REST) or `<topic>.yaml` (Kafka, `paths: { }` + `components.schemas`) with `info.title` and `info.version`.
3. Model schemas following the naming rules below — new specs must pass Spectral at **error** severity.
4. **Do not set or bump the version by hand.** The pre-commit hook does it (see Versioning).
5. Reference shared types with a relative `$ref` into `common/openapi/schemas/` (e.g. `../../../common/openapi/schemas/object/Pageable.yaml`), don't redefine them.
6. Update the service `readme.md` if the change is user-visible; delete schemas that lose all `$ref`s in the same MR (orphans pollute codegen).

## Naming conventions (CONVENTIONS.md §2, enforced by Spectral)

- **No technical suffixes** on schema names: `Dto`, `DTO`, `Info`, `Data`, `Model`, `Object`, `Enum`, `Type`. Write `Backup`, not `BackupDto`; `RestoreMethod`, not `RestoreMethodEnum`.
- Schema names: **UpperCamelCase** nouns (`BackupTask`, `RecoveryPoint`).
- Field names: **camelCase** (`compositionType`, `createdAt`).
- Enum values: **UPPER_SNAKE_CASE** (`FULL_SYSTEM`, `USER_DATA_ONLY`).
- `operationId`: **camelCase verb phrase**, required and unique per file (`createBackup`, `listRecoveryPoints`).
- Every schema, field, and operation has a **Russian `description`** (what it means in the domain, not a restatement of the name); add `example` for non-obvious formats.

## Versioning — never edit versions manually

Handled by `contracts-versioning-plugin` + a git **pre-commit** hook (installed on first `./gradlew assemble`):
- On each commit the hook runs `bumpChangedVersions`: every staged contract gets **PATCH + 1**.
- The target `MAJOR.MINOR` comes from `contracts.version` in `gradle.properties`.
- If a file's `MAJOR.MINOR` already matches → PATCH++ (`2.1.2` → `2.1.3`). If it's from a previous cycle → reset to `X.Y.1` (`2.0.5` → `2.1.1`).
- SemVer: MAJOR = breaking API change, MINOR = backward-compatible feature, PATCH = non-contract fix. `MAJOR.MINOR` tracks the platform release; two prior releases stay supported (`release/1.2.x`, `release/1.1.x`).

**Releases** run from CI (manual trigger on `develop`): `create-minor-release` / `create-major-release` → Vercraft cuts `release/X.Y.x` and runs `bumpAllVersions` (freeze all contracts to `X.Y.0` on the release branch; move `develop` to `X.(Y+1).0` and update `contracts.version`).

## Commands

| Command | What it does |
|---|---|
| `./gradlew assemble` | Generate classes + JARs, install the versioning pre-commit hook |
| `./gradlew build` | Full build (CI passes `-PcheckOutBranch=...`) |
| `./gradlew publish` | Publish JARs to Nexus — CI only, and only from `develop` / `release/*`; skips if the exact version already exists |
| `./gradlew publishToMavenLocal` | Publish to local `~/.m2` for a service to test-consume |
| `./gradlew spotlessApply` | Format (ktlint for `*.gradle.kts`, flexmark for service markdown) |
| `./gradlew lintDocs` | Spectral + markdownlint + lychee, each via the `docs-lint` Docker image |
| `./gradlew bumpChangedVersions` | PATCH-bump staged contracts (the hook calls this) |
| `./gradlew bumpAllVersions` | Freeze/advance all versions (release automation calls this) |

## Automated checks (hook = local safety net, CI = final arbiter)

- **Spectral** (`.spectral.yaml`): the `nextbi-*` naming rules above. New specs at **error**; legacy specs are listed in the `overrides` block and downgraded to **warn** until cleaned. Do **not** add new files to that override list.
- **oasdiff** (`diff:breaking`): compares each changed REST spec against `develop` for breaking changes. It builds a full `git worktree` (at `.oasbase`) because specs use relative `$ref`s into `common/` that break if a single file is diffed in isolation.
- **markdownlint-cli2**, **lychee** (internal links offline in CI, external links signal-only), **spotless/flexmark** markdown formatting.
- CI stages: `lint → build → publish → release → deploy`. A red pipeline blocks the MR. Some checks are currently `allow_failure` (legacy cleanup in progress) — treat them as blocking anyway for new work.

## Consuming a contract in a service

`settings.gradle.kts`:

```kotlin
dependencyResolutionManagement {
    repositories {
        maven {
            url = uri("<internal-nexus-maven-url>/repository/maven-nextbi-common/")
            isAllowInsecureProtocol = true
        }
    }
}
```

`build.gradle.kts`:

```kotlin
implementation("ru.nextbi.rest-api:{namespace}-core-<name>-service:1.2.0")
implementation("ru.nextbi.kafka:<topic_name>:1.2.0")
```

The first is the REST contract JAR, the second the Kafka contract JAR.

## Doc-vs-reality gotchas

- **Kafka contracts are OpenAPI 3.0.1 YAML**, not JSON Schema as `readme.md` states. They have `paths: { }` and define messages under `components.schemas`; the version lives in `info.version`, not a root `version` field. They also sit under `docs/kafka/<namespace>/<topic>/`, one level deeper than the readme's `docs/kafka/<topic>/`.
- **Legacy REST specs still use `Dto` suffixes** and are in the Spectral warn-override list. Do not copy their style — new/edited schemas must be suffix-free and clean.
- **`common/**` is excluded from codegen resources** (`build.gradle.kts` `sourceSets`) but is still referenced via relative `$ref`. This is why oasdiff needs the full base worktree.
- **Custom mustache templates** live in `src/main/openapi-templates/` (reactive / SSE response wrapping); wired only for the specific service that needs them.
- **Branching**: work on feature branches → `develop`; releases live on `release/X.Y.x`. Publish happens only from `develop` and `release/*`.
- Local working docs under `docs/superpowers/` are git-ignored (plans/specs) — not part of the published contracts.
