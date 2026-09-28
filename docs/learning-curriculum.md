# Initial learning curriculum

[Plan](../PLAN.md) · [Choices mockup](mockups/M15-learning-choices.png) · [Lesson formats](features/F06-lesson-experience.md)

F05 targets 8 complete lessons per topic, 40 total. The table is the authoring brief; Go, Java, and System Design are authored and reviewed in catalog version 2 (eight lessons each); Performance and Security still have only their original starter lessons and await their own authoring steps. Every lesson needs stable id/objectiveKey, canonical concept IDs, difficulty, time estimate, explanation, worked example, exercise, reference answer and self-check criteria. Begin at intermediate level with optional basics; do not infer mastery from the user's experience.

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

Review scope: documentation/API and example-contract review; no Go compiler or executable sample suite is part of the packaged Swift resource. The remaining 16 Performance and Security lessons need equivalent per-lesson reviews in their authoring steps.

## Java content review (catalog version 2)

Assume Java 21 LTS and its standard library for Java lessons unless noted. Parameterized tests assume JUnit Jupiter 5.10 with `junit-jupiter-params`; transaction scope assumes Spring Framework 6.1 proxy-mode declarative transactions and one transactional database. All eight Java concepts have no prerequisites: four can be selected immediately and four distinct eligible reserves remain. Each example was checked against the stated API contract and its exercise/reference answer reviewed for technical consistency. These are teaching examples in an offline JSON resource, not compiled Java source.

| Lesson ID / objective key | Primary documentation consulted | Review outcome |
| --- | --- | --- |
| `java.concurrency.task-lifecycle.v1` / `java.concurrency.task-lifecycle` | [JDK 21 Thread.startVirtualThread](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/lang/Thread.html#startVirtualThread(java.lang.Runnable)), [virtual threads](https://docs.oracle.com/en/java/javase/21/core/virtual-threads.html), [Semaphore](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/Semaphore.html) | Checked that interruption is cooperative, task ownership needs a join/cancellation boundary, and scarce service concurrency is limited with permits, not a virtual-thread pool. |
| `java.collections.key-contract.v1` / `java.collections.key-contract` | [HashMap](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/HashMap.html), [Object.hashCode](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/lang/Object.html#hashCode()), [List.copyOf](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/List.html#copyOf(java.util.Collection)) | Checked collision versus equality, changed-key lookup risk, and a defensive snapshot alternative; no iteration-order or thread-safety guarantee is implied. |
| `java.testing.case-design.v1` / `java.testing.case-design` | [JUnit 5.10 parameterized tests](https://docs.junit.org/5.10.2/user-guide/#writing-tests-parameterized-tests), [CsvSource](https://docs.junit.org/5.10.2/api/org.junit.jupiter.params/org/junit/jupiter/params/provider/CsvSource.html) | Checked five scalar boundary rows, required params dependency, and a separate contract-dependent invalid-input assertion. |
| `java.jvm.profile-interpretation.v1` / `java.jvm.profile-interpretation` | [JDK Flight Recorder guide](https://docs.oracle.com/en/java/javase/21/jfapi/flight-recorder-api-programmers-guide.pdf), [jcmd JFR.start](https://docs.oracle.com/en/java/javase/21/docs/specs/man/jcmd.html) | Checked that sampled stacks and allocation/GC events are distinct evidence; answer requires warmup, comparable workload and before/after latency, not a claimed causal diagnosis. |
| `java.io.resource-ownership.v1` / `java.io.resource-ownership` | [Java try-with-resources](https://docs.oracle.com/javase/tutorial/essential/exceptions/tryResourceClose.html), [AutoCloseable](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/lang/AutoCloseable.html), [Files.newBufferedReader](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/nio/file/Files.html#newBufferedReader(java.nio.file.Path)) | Retained original ID and code boundary; reviewed reverse close order, suppression, and that only the newly opened reader is closed on read failure. |
| `java.language.value-boundaries.v1` / `java.language.value-boundaries` | [record classes](https://docs.oracle.com/en/java/javase/21/language/records.html), [List.copyOf](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/List.html#copyOf(java.util.Collection)) | Checked compact-constructor defensive copying, source/accessor mutation tests and shallow-versus-deep immutability limitation. |
| `java.concurrency.shutdown.v1` / `java.concurrency.shutdown` | [ExecutorService shutdown, awaitTermination and shutdownNow](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/ExecutorService.html) | Checked two bounded waits, interrupted-caller flag restoration and that terminated is not equivalent to every task succeeding. |
| `java.spring.transaction-scope.v1` / `java.spring.transaction-scope` | [Spring 6.1 declarative transactions](https://docs.spring.io/spring-framework/reference/6.1/data-access/transaction/declarative/annotations.html), [rollback rules](https://docs.spring.io/spring-framework/reference/6.1/data-access/transaction/declarative/rolling-back.html) | Checked proxy self-invocation, unchecked versus checked rollback defaults and atomic local order/outbox writes; external email needs duplicate-safe retries. |

Java review scope is API and example-contract review, not running a Java compiler or integration test. The remaining 16 Performance and Security lessons await equivalent per-lesson reviews.

## System Design content review (catalog version 2)

Assumptions: these are technology-neutral scenarios, not vendor-specific SLA guarantees. Numeric capacities and deadlines are exercise inputs, not production defaults. Eight independent concepts have no prerequisites, so four choices and four distinct reserves are eligible without inventing completion records. Each exercise, reference response, and rubric was reviewed against the cited primary protocol or provider documentation; designs must state their consistency and external-side-effect limits. Examples are teaching material, not an operational runbook or integration-tested implementation.

| Lesson ID / objective key | Primary documentation consulted | Review outcome |
| --- | --- | --- |
| `design.api.rate-limit-consistency.v1` / `design.api.rate-limit-consistency` | [RFC 6585 §4 (429)](https://www.rfc-editor.org/rfc/rfc6585#section-4), [RFC 9110 Retry-After](https://www.rfc-editor.org/rfc/rfc9110#section-10.2.3) | Corrected the worked example: capacity five permits an initial burst of five, then one refill per 12 seconds (average five/minute), not a hard five-attempt cap in any rolling minute. Checked authenticated key and cross-replica atomicity; separate local buckets allow an initial burst of fifteen across three replicas, and outage fallback may overshoot. A strict rolling-window limit would require a different policy; the 429 response does not claim an exact retry time. |
| `design.queues.delivery-guarantees.v1` / `design.queues.delivery-guarantees` | [Amazon SQS at-least-once delivery](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/standard-queues-at-least-once-delivery.html), [AWS prescriptive guidance: transactional outbox](https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/transactional-outbox.html) | Checked crash-after-send redelivery and atomic order/outbox intent; broker acknowledgement and provider acceptance are not user receipt or an exactly-once guarantee. |
| `design.reliability.retry-budget.v1` / `design.reliability.retry-budget` | [AWS Builders' Library: timeouts, retries and backoff with jitter](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/), [RFC 9110 §9.2.2](https://www.rfc-editor.org/rfc/rfc9110#section-9.2.2) | Checked 3×3×3 leaf amplification and remaining-deadline logic; uncertain writes need a stable idempotency contract or reconciliation, not automatic retry. |
| `design.cache.freshness.v1` / `design.cache.freshness` | [AWS Builders' Library: caching challenges](https://aws.amazon.com/builders-library/caching-challenges-and-strategies/), [Redis cache-aside](https://redis.io/docs/latest/develop/use/patterns/cache-aside/) | Checked read-before-write/late-fill invalidation race and separated tolerant display reads from authoritative checkout; TTL alone is not a serialization guarantee. |
| `design.api.deduplicate-writes.v1` / `design.api.deduplicate-writes` | [Stripe idempotent requests](https://docs.stripe.com/api/idempotent_requests), [AWS prescriptive guidance: idempotency](https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/idempotency.html) | Retained starter ID and teaching payload; reviewed scoped unique claim, payload conflict and lost-response replay. Provider idempotency depends on provider contract and retention; local database commit cannot atomically commit a remote charge. |
| `design.queues.bounded-load.v1` / `design.queues.bounded-load` | [AWS Builders' Library: avoiding queue backlogs](https://aws.amazon.com/builders-library/avoiding-insurmountable-queue-backlogs/), [RFC 6585 §4](https://www.rfc-editor.org/rfc/rfc6585#section-4) | Checked 150 − 100 = 50 jobs/s deficit and 500 / 50 = 10 seconds from empty; rejected jobs are not acknowledged as durably accepted. |
| `design.storage.partition-key.v1` / `design.storage.partition-key` | [DynamoDB partition key best practices](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-partition-key-design.html), [Bigtable schema design](https://cloud.google.com/bigtable/docs/schema-design) | Checked hot-tenant bucketing and read fan-out; merged timestamps need a tie-breaker and no global transaction/order is inferred from sharding. |
| `design.reliability.recovery-plan.v1` / `design.reliability.recovery-plan` | [AWS Well-Architected: disaster recovery](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/plan-for-disaster-recovery-dr.html), [Google Cloud disaster recovery planning](https://cloud.google.com/architecture/dr-scenarios-planning-guide) | Checked eight-minute replica lag violates five-minute RPO absent recovered logs; fencing, measured restore and external payment reconciliation are part of the drill. |

System Design review scope is scenario arithmetic, architecture tradeoffs, and reference/rubric consistency against cited documentation; no live queue, database, provider, or failover drill was executed. Performance and Security await their own review steps.
