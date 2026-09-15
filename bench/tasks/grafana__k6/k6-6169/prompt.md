## Context
`k6 cloud run --local-execution` runs a test on the local machine while streaming
metrics to Grafana Cloud k6. Today that path still uses the legacy v1 cloud API to
create the test run, derive the metrics push URL and report the end of the test. The
cloud-execution path already moved to the v6 API. This task moves local execution to
the v6 cloud API plus the new provisioning API, leaving every other cloud path as is.

## Requirement
- New flow for `--local-execution`: ensure the load test exists via
  `POST /cloud/v6/projects/{project_id}/load_tests` (on a 409 conflict, find the
  existing one by name); then `POST /provisioning/v1/load_tests/{id}/start_local_execution`,
  which returns the test-run id, an optional presigned archive upload URL, a runtime
  config (metrics push URL, a test-run-scoped token, a secrets endpoint) and the
  details-page URL; upload the archive with a `PUT` to the presigned URL unless
  `--no-archive-upload` is given; poll `GET /cloud/v6/test_runs/{id}` until the run
  reports `initializing`; stream metrics to the runtime config's push URL with
  `Authorization: Bearer <test-run token>`; on completion `POST
  /provisioning/v1/test_runs/{id}/notify` with a `script_execution_completed` event.
- The notify body carries an error code mapped from how k6 stopped: 8036 for a user or
  script abort, 8035 for a script error, 8034 for a timeout or output failure, and null
  for a clean finish or thresholds that failed only after the test ended. Threshold
  results are no longer sent at end of test.
- A dedicated package under `internal/cloudapi` owns this orchestration: an HTTP client
  for the provisioning endpoints with typed errors (401/403 classified the way the
  existing v6 client does it), the runtime-config types, and one function that composes
  create-or-find, start, optional upload and wait-until-ready. It also provides a fake
  provisioning server for tests, alongside the package.
- The cloud output must be able to use a metrics push URL and a per-run HTTP client
  supplied by the caller instead of deriving them from the legacy configuration; the
  cloud configuration gains internal-only fields for the push URL and the test-run
  token, populated by the command layer and consumed by the output.
- Unchanged: `k6 run --out cloud` stays on the v1 API; `K6_CLOUD_PUSH_REF_ID` still
  short-circuits to the legacy derived metrics URL with no v6 or provisioning calls;
  `--no-cloud-secrets`, `--secret-source`, `--linger`, `--exit-on-running` and log
  streaming keep their behaviour.
- Resource ids from the cloud SDK are `int64`; the SDK already pinned in `go.mod` has
  everything needed (no dependency changes).

## Constraints
- Go; no new module dependencies; follow the conventions of the existing v6 client and
  of the cloud output package; keep existing exported APIs source-compatible.
- `gofmt`-clean and `go vet ./...` clean.

## Tests
These test files were added or updated in this checkout and currently fail; make them
pass without modifying them, and keep `go test ./...` green (browser tests are not part
of the suite here): `cloudapi/config_test.go`,
`internal/cloudapi/provisioning/api_test.go`, `internal/cloudapi/provisioning/client_test.go`,
`internal/cloudapi/provisioning/errors_test.go`, `internal/cloudapi/provisioning/http_client_test.go`,
`internal/cloudapi/provisioning/notify_test.go`, `internal/cloudapi/provisioning/provision_test.go`,
`internal/cloudapi/v6/api_test.go`, `internal/cmd/outputs_cloud_test.go`,
`internal/cmd/tests/cmd_cloud_run_test.go`, `internal/output/cloud/output_test.go`,
`output/cloud/expv2/metrics_client_test.go`, `output/cloud/expv2/output_test.go`.

## Deliverable
Leave the changes uncommitted in the working tree. Do not create commits, branches
or tags.
