# Messages and resilience

Adapted from the BPSE `se-architecture/references/messaging.md` checklist (see
`sdlc/SOURCES.md`). Use it when an A### introduces asynchronous exchanges.

Define producer, consumer, data owner, schema/version and compatibility. A
consumer does not read another service's private database without an explicit
contract.

State the effective delivery guarantee. For "at least once", define the
idempotency key, the retention period and how duplicates are handled. State the
ordering that is needed and the behavior on an old or unknown message.

A database transaction and a publication are not atomic by default: consider an
outbox when losing a message between the two is unacceptable. Plan
acknowledgement after durable processing, bounded retries with backoff, error
classification, a quarantine queue and controlled replay. Never promise an
external effect exactly once without a mechanism that guarantees it.

Define timeout, backpressure, saturation, lag and failure metrics, and
correlation without sensitive data. Test duplicates, a crash before and after
acknowledgement, an unavailable provider, reversed order, an invalid message and
recovery. A broker alone does not isolate failures completely.

Each of these tests is a `T###` of the P### that implements the consumer or the
producer.
