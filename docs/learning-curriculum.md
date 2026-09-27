# Initial learning curriculum

[Plan](../PLAN.md) · [Choices mockup](mockups/M15-learning-choices.png) · [Lesson formats](features/F06-lesson-experience.md)

V1 ships 8 complete lessons per topic, 40 total. The following are authoring briefs, not finished teaching content. Each must be written and reviewed before the F05 acceptance gate passes. Every lesson needs stable id/objectiveKey, canonical concept IDs, difficulty, time estimate, explanation, worked example, exercise, reference answer and self-check criteria. Begin at intermediate level with optional basics; do not infer mastery from the user's experience.

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
