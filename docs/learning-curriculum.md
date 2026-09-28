# Initial learning curriculum

[Plan](../PLAN.md) · [Choices mockup](mockups/M15-learning-choices.png) · [Lesson formats](features/F06-lesson-experience.md)

F05 targets 8 complete lessons per topic, 40 total. The table is the authoring brief; Go is authored and reviewed in catalog version 2 (eight lessons), while Java, System Design, Performance, and Security still have only their original starter lessons and await their own authoring steps. Every lesson needs stable id/objectiveKey, canonical concept IDs, difficulty, time estimate, explanation, worked example, exercise, reference answer and self-check criteria. Begin at intermediate level with optional basics; do not infer mastery from the user's experience.

| Topic | Lesson brief | Format | Objective / concept |
| --- | --- | --- | --- |
| Go | Context cancellation | Learn | go.concurrency.cancel-work |
| Go | Table-driven tests | Code | go.testing.case-design |
| Go | Small interfaces | Design | go.interfaces.consumer-contract |
| Go | Benchmarking Go | Question | go.performance.comparable-benchmarks |
| Go | Goroutine leak diagnosis | Code | go.concurrency.leak-diagnosis |
| Go | Channel ownership | Learn | go.concurrency.channel-close-owner |
| Go | Error wrapping | Code | go.errors.preserve-context |
| Go | HTTP timeouts | Design | go.network.deadline-boundaries |
| Java | Virtual thread lifecycle | Learn | java.concurrency.task-lifecycle |
| Java | HashMap tradeoffs | Question | java.collections.key-contract |
| Java | Parameterized tests | Code | java.testing.case-design |
| Java | JVM profiling | Learn | java.jvm.profile-interpretation |
| Java | Resource cleanup | Code | java.io.resource-ownership |
| Java | Immutability | Design | java.language.value-boundaries |
| Java | Executor shutdown | Code | java.concurrency.shutdown |
| Java | Spring transaction boundaries | Design | java.spring.transaction-scope |
| System Design | Rate limiter | Design | design.api.rate-limit-consistency |
| System Design | Notification delivery | Design | design.queues.delivery-guarantees |
| System Design | Retry policies | Question | design.reliability.retry-budget |
| System Design | Cache invalidation | Learn | design.cache.freshness |
| System Design | API idempotency | Design | design.api.deduplicate-writes |
| System Design | Backpressure | Learn | design.queues.bounded-load |
| System Design | Data partitioning | Design | design.storage.partition-key |
| System Design | Failure recovery | Question | design.reliability.recovery-plan |
| Performance | N+1 query diagnosis | Code | perf.database.query-count |
| Performance | CPU profile reading | Learn | perf.cpu.hot-path |
| Performance | Allocation analysis | Question | perf.memory.allocations |
| Performance | Latency budgets | Design | perf.network.tail-latency |
| Performance | Index a query | Code | perf.database.index-access |
| Performance | Cache measurement | Question | perf.cache.hit-rate-tradeoff |
| Performance | Load-test design | Design | perf.testing.representative-load |
| Performance | Pool saturation | Learn | perf.concurrency.queueing |
| Security | JWT validation | Question | security.auth.token-validation |
| Security | Authorization checks | Code | security.api.object-access |
| Security | Secret storage | Learn | security.secrets.lifecycle |
| Security | API threat model | Design | security.design.trust-boundaries |
| Security | Input validation | Code | security.input.boundary-validation |
| Security | Session expiry | Design | security.auth.session-lifecycle |
| Security | Dependency updates | Question | security.dependencies.risk-review |
| Security | Audit logging | Learn | security.observability.safe-audit |

Authoring rules: use original examples, show one principal objective per lesson, distinguish language/library-version assumptions, and verify technical examples against primary documentation at authoring time. Never import snippets solely because the AI produced them. The 40 titles may evolve; stable IDs and objective keys must not change with a cosmetic rename.

## Go content review (catalog version 2)

Assumption for all Go lessons: Go 1.22 or later, standard-library APIs unless explicitly noted. `go.performance.comparable-benchmarks` mentions the optional `benchstat` analysis tool; the exercises require no external package. All eight concepts have no prerequisites, so four initial choices can be filled without completing work and four distinct eligible reserves remain. Exercises and answers were reviewed for the stated contract and primary API semantics; they are explanatory examples, not executable code shipped by the app. Fingerprints are computed from explanation, worked example, exercise, reference answer, and each ordered self-check criterion by the catalog validator; they do not cover title or objective metadata.

| Lesson ID / objective key | Primary documentation consulted | Review outcome |
| --- | --- | --- |
| `go.concurrency.cancel-work.v1` / `go.concurrency.cancel-work` | [context](https://pkg.go.dev/context), [net/http Request.Context](https://pkg.go.dev/net/http#Request.Context) | Retained original ID and example; verified derived cancellation signals rather than killing the worker, and a selectable send avoids waiting on a departed receiver. |
| `go.testing.case-design.v1` / `go.testing.case-design` | [testing and subtests](https://pkg.go.dev/testing#hdr-Subtests_and_Sub_benchmarks), [Go 1.22 loop variables](https://go.dev/blog/loopvar-preview) | Checked named cases and `t.Run` usage; reference covers five clamp partitions and does not promise behavior for unsupported inverted bounds. |
| `go.interfaces.consumer-contract.v1` / `go.interfaces.consumer-contract` | [interface types](https://go.dev/ref/spec#Interface_types), [method sets](https://go.dev/ref/spec#Method_sets), [Go interface guidance](https://go.dev/wiki/CodeReviewComments#interfaces) | Checked implicit method-set satisfaction and consumer-owned minimal interface; design answer includes a concrete-type alternative. |
| `go.performance.comparable-benchmarks.v1` / `go.performance.comparable-benchmarks` | [testing benchmarks](https://pkg.go.dev/testing#hdr-Benchmarks), [go test flags](https://pkg.go.dev/cmd/go#hdr-Testing_flags), [benchstat](https://pkg.go.dev/golang.org/x/perf/cmd/benchstat) | Checked `b.N`, `ResetTimer`, `-benchmem` and repeated measurement; reference distinguishes latency from allocations and rejects unequal timed work. |
| `go.concurrency.leak-diagnosis.v1` / `go.concurrency.leak-diagnosis` | [context](https://pkg.go.dev/context), [goroutine profiles](https://pkg.go.dev/runtime/pprof), [pipelines and cancellation](https://go.dev/blog/pipelines) | Checked that cancellation needs an explicit selectable send; answer avoids brittle global goroutine-count assertions and closing a live sender's channel. |
| `go.concurrency.channel-close-owner.v1` / `go.concurrency.channel-close-owner` | [Go spec: Close](https://go.dev/ref/spec#Close), [pipelines](https://go.dev/blog/pipelines), [sync.WaitGroup](https://pkg.go.dev/sync#WaitGroup) | Checked multi-producer close only after `Wait`, with context for early consumer exit; receiver-initiated close is rejected. |
| `go.errors.preserve-context.v1` / `go.errors.preserve-context` | [errors.Is](https://pkg.go.dev/errors#Is), [fmt.Errorf](https://pkg.go.dev/fmt#Errorf), [os.ReadFile](https://pkg.go.dev/os#ReadFile) | Checked `%w` retains error identity for `errors.Is`; answer does not log file contents or turn a failed read into success. |
| `go.network.deadline-boundaries.v1` / `go.network.deadline-boundaries` | [net/http Client and Transport](https://pkg.go.dev/net/http#Client), [NewRequestWithContext](https://pkg.go.dev/net/http#NewRequestWithContext), [Request.Context](https://pkg.go.dev/net/http#Request.Context), [context.WithTimeout](https://pkg.go.dev/context#WithTimeout) | Checked parent request context propagation, deferred cancel and body close on successful `Do`; answer separates overall timeout from transport phase limits. |

Review scope: documentation/API and example-contract review; no Go compiler or executable sample suite is part of the packaged Swift resource. The remaining 32 lessons need equivalent per-lesson reviews in their authoring steps.
