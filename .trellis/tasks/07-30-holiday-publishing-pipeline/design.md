# Design: holiday data publishing pipeline

## Stages

`fetch/input -> adapter decode -> normalize -> validate -> compare -> review gate -> canonical encode -> sign -> publish artifacts`

Adapters return typed candidates plus source id, URL/reference, observed revision/time, and input digest. They cannot emit canonical records directly.

The comparator requires one official authoritative record for each publishable date. Third-party differences become blocking diagnostics. A checked review document links the selected result to the official notice and reviewer decision.

## Canonical bytes

Use one encoder implementation and lock it with golden bytes. Object keys sort lexicographically; arrays sort by stable domain keys; timestamps are UTC `YYYY-MM-DDTHH:mm:ssZ`; strings use the documented JSON escaping; output has no BOM or trailing newline. The signature covers exact manifest bytes.

The detached envelope is deterministic JSON containing `algorithm`, `keyID`, `manifestRevision`, `manifestSHA256`, and base64 signature. Production signing reads a private-key path or CI secret at execution time only. Test fixtures use a committed test key clearly marked non-production.

## Publication

Artifacts are immutable by revision. A separately delivered current pointer may identify the latest revision, but clients still enforce signature and monotonic revision. Pipeline output includes a human-readable provenance report for review; that report is not client runtime input.
