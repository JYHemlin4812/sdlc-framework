# Contract — <service or event>

Version: <contract version> | Known consumers: <list>
Schema file: <path in the repository> | Fixed by: <P###>

## Need and boundary
Business capability, data owner and allowed operations.

## Access
Authentication, authorization on the resource, relevant limits.

## Operation
HTTP method and path, or event name and version.
Input schema: fields, types, constraints and unknown fields.
Separate output schema: public data only.
Fictitious valid and invalid examples.

## Results and errors
Statuses, stable public errors, no internal details.
For deferred processing: acceptance, tracking, failure and expiry.

## Compatibility and reliability
Affected consumers, migration, idempotence, timeout and retry when relevant.

## Verification
Link to the OpenAPI / JSON Schema / message contract; integration and contract
tests (T###).
