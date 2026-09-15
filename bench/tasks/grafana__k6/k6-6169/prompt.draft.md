# DRAFT — write prompt.md from this by hand; this file is never shown to an agent

## PR #6169 Migrate k6 cloud run --local-execution to provisioning API (merged 2026-07-22T13:44:36Z)

> **Supersedes #6068.** Same change, rebased onto latest `master` to build on the recently-merged cloudapi cleanups (#6149, #6151, #6159) and adapt to the SDK's new `int64` resource IDs. It lives on a fresh branch because force-pushing the rebased history to the original branch tripped the "require verified signatures" rule on pre-existing **unsigned `master` commits** pulled in by the rebase — all commits on this branch are signed. See #6068 for the earlier review discussion.

## What?

Migrate `k6 cloud run --local-execution` from the legacy v1 API (`POST /v1/tests`, derived metrics URL, `POST /v1/tests/{id}` for end-of-test) to the new v6 cloud + provisioning APIs.

The new flow:
1. `POST /cloud/v6/projects/{id}/load_tests` (or 409 → find-by-name) to ensure the load_test exists.
2. `POST /provisioning/v1/load_tests/{id}/start_local_execution` returns the test_run_id, an optional presigned S3 archive upload URL, runtime config (metrics push URL, scoped test_run_token, secrets endpoint), and the details page URL.
3. Optional `PUT` to the presigned S3 URL (skipped when `--no-archive-upload` is set).
4. Poll `GET /cloud/v6/test_runs/{id}` until status is `initializing`.
5. Stream metrics to the runtime_config's push_url with `Authorization: Bearer <test_run_token>`.
6. `POST /provisioning/v1/test_runs/{id}/notify` on test completion with the `script_execution_completed` event and an optional mapped error code.

A new `internal/cloudapi/provisioning` package owns the orchestration (`ProvisionLocalExecution` composes `CreateOrFindLoadTest` + `StartLocalExecution` + optional `UploadArchive` + `WaitForTestRunReady`). `cloudapi.Config` gains internal-only `MetricsPushURL` and `TestRunToken` fields, populated by `cmd/outputs_cloud.go` and consumed by the cloud Output. `output/cloud/expv2` gets an additive sibling constructor (`newMetricsClientWithURL`) and two setters on `expv2.Output` so the cloud Output can override the metrics URL + HTTP client without disturbing existing callers.

`k6 run --out cloud` (path B) is **unchanged** — still on the legacy v1 API. The PushRefID flow is also **unchanged** — `K6_CLOUD_PUSH_REF_ID` still short-circuits to the legacy derived metrics URL with no v6 or provisioning calls.

Threshold evaluation moves backend-side, so the new flow no longer sends threshold results in the end-of-test signal. The notify body carries `error.code` mapped from k6 abort reasons (8036 for user/script-abort, 8035 for script-error, 8034 for timeout/output-failure; `null` for clean completion or thresholds-after-test-end).

The migration is broken into 17 atomic commits, each individually buildable + lintable + green under `make check`, designed to be reviewable one at a time.

## Why?

Backend is moving the local-execution path to a new provisioning architecture. This brings async archive upload (no synchronous backend strain on large archives), per-test scoped tokens replacing the long-lived k6 token at the metrics ingest, pre-execution config from the API (push URL, secrets config), and a path to queue support — the backend currently rejects when over quota, but eventually it will queue and wait without aborting the run.

The cloud-execution path (`k6 cloud run` without `--local-execution`) was migrated to v6 starting with #5465; local-execution is the remaining piece. Per the design constraint, `k6 run --out cloud` is left on v1 in this PR — it's used by `k6-cloud-testcoordinator` and `k6-operator`, and migrating those services needs separate backend work. PushRefID stays on v1 for the same reason (preserved by #5814's short-circuit).

## Checklist

- [x] I have performed a self-review of my code.
- [ ] I have commented on my code, particularly in hard-to-understand areas.
- [x] I have added tests for my changes.
- [x] I have run linter and tests locally (`make check`) and all pass.

## Related PR(s)/Issue(s)

- Supersedes #6068 (rebased onto latest `master`; moved to a signed branch).
- Reuses the merged cloudapi cleanups: #6149 (remove dead `internal/cloudapi/v6/config.go`), #6151 (consume the SDK's retry-body-reset fix and drop the `bodyResetTransport` workaround — this branch now does the same in the `provisioning` client via `k6cloud.NewConfiguration()`), #6159 (shared 401/403 `httperr` classification). The `grafana/k6-cloud-openapi-client-go` SDK is now pinned on `master` (via #6151); this branch drops its own dep bump and adapts to the `int64` resource-ID types that SDK revision introduced.
- v6 cloud-execution migration precedent: #5465 introduced the v6 client; subsequent PRs incrementally migrated cmd's cloud-execution path.
- Earlier `cloud run --local-execution` work: #5814 (PushRefID short-circuit), preserved by this PR.
- Backend coordination: k6-cloud#4091 (provisioning endpoint), k6-cloud#4092 (notify endpoint), k6-cloud#4228 (script optional on LoadTestsCreate).


## Files (code)

- cloudapi/config.go
- internal/cloudapi/clientcfg/clientcfg.go
- internal/cloudapi/provisioning/api.go
- internal/cloudapi/provisioning/client.go
- internal/cloudapi/provisioning/doc.go
- internal/cloudapi/provisioning/errors.go
- internal/cloudapi/provisioning/http_client.go
- internal/cloudapi/provisioning/notify.go
- internal/cloudapi/provisioning/provision.go
- internal/cloudapi/provisioning/test/server.go
- internal/cloudapi/v6/api.go
- internal/cloudapi/v6/client.go
- internal/cmd/outputs_cloud.go
- internal/output/cloud/output.go
- output/cloud/expv2/metrics_client.go
- output/cloud/expv2/output.go

## Hidden tests

- cloudapi/config_test.go
- internal/cloudapi/provisioning/api_test.go
- internal/cloudapi/provisioning/client_test.go
- internal/cloudapi/provisioning/errors_test.go
- internal/cloudapi/provisioning/http_client_test.go
- internal/cloudapi/provisioning/notify_test.go
- internal/cloudapi/provisioning/provision_test.go
- internal/cloudapi/v6/api_test.go
- internal/cmd/outputs_cloud_test.go
- internal/cmd/tests/cmd_cloud_run_test.go
- internal/output/cloud/output_test.go
- output/cloud/expv2/metrics_client_test.go
- output/cloud/expv2/output_test.go

## Test functions

- TestBuildConfigFromRuntimeConfig
- TestBuildConfigFromRuntimeConfig_AggregationMinSamplesIgnored
- TestBuildConfigFromRuntimeConfig_InvalidDurationLogsWarning
- TestBuildConfigFromRuntimeConfig_NilFieldsLeftUnset
- TestCheckResponse
- TestCloudOutputDescription
- TestCloudOutputRequireScriptName
- TestCloudRunCommandIncompatibleFlags
- TestCloudRunLocalExecution
- TestCloudRunLocalExecutionNoCloudSecrets
- TestCloudRunWithArchive
- TestConfigApply
- TestConfig_Apply_MergesNewFields
- TestConfig_NewFieldsNotPickedUpByEnvconfig
- TestConfig_NewFieldsRoundTripThroughJSON
- TestCreateOrFindLoadTest
- TestCreateOrFindLoadTest_ConflictFallsBackToFindByName
- TestCreateOrFindLoadTest_ConflictWithNoMatchReturnsError
- TestCreateOrFindLoadTest_NonConflictHTTPErrorReturned
- TestDeriveMetricsURL
- TestDeriveMetricsURL_EmptyTestRunID
- TestDeriveMetricsURL_MissingV1Suffix
- TestFetchTest
- TestGetConsolidatedConfig
- TestHTTPClient
- TestHTTPClient_ContextCancelStopsRetryWait
- TestHTTPClient_NilVDoesNotDecode
- TestHTTPClient_NoRetryOn4xx
- TestHTTPClient_RequestBodyReplayedOnRetry
- TestHTTPClient_RetriesOn5xx
- TestK6CloudRun
- TestListLoadTests
- TestListProjects
- TestMapTestErrorToNotifyCode
- TestMetricsClientPush
- TestMetricsClientPushUnexpectedStatus
- TestNew
- TestNewClient
- TestNewMetricsClientWithURL
- TestNewMetricsClientWithURL_EmptyURLReturnsError
- TestNewOutputNameResolution
- TestNewWithConfigOverwritten
- TestNotifyTestRunCompleted
- TestNotifyTestRunCompleted_4xxResponseReturnsError
- TestNotifyTestRunCompleted_5xxRetried
- TestNotifyTestRunCompleted_WithErrorInRequestBody
- TestOutputAddMetricSamples
- TestOutputCollectSamples
- TestOutputCreateTestWithConfigOverwrite
- TestOutputFlushRequestMetadatasAbort
- TestOutputFlushRequestMetadatasConcurrently
- TestOutputFlushRequestMetadatasStop
- TestOutputFlushTicks
- TestOutputFlushWorkersAbort
- TestOutputFlushWorkersStop
- TestOutputGetStatusRun
- TestOutputHandleFlushError
- TestOutputHandleFlushErrorMultipleTimes
- TestOutputPeriodicInvoke
- TestOutputProxyAddMetricSamples
- TestOutputSetTestRunID
- TestOutputSetTestRunStopCallback
- TestOutputSetters_OverrideMetricsClientAndURL
- TestOutputStartVersionError
- TestOutputStartVersionedOutputV1Error
- TestOutputStartVersionedOutputV2
- TestOutputStartWithTestRunID
- TestOutputStart_ProvisioningMode
- TestOutputStart_PushRefIDStillTakesPrecedence
- TestOutputStopCancelsStuckFlush
- TestOutputStopWithTestError
- TestOutputStopWithTestError_ConfigFieldsAloneDoNotInferProvisioningMode
- TestOutputStopWithTestError_ProvisioningMode_NoError
- TestOutputStopWithTestError_ProvisioningMode_WithTestError
- TestOutputStopWithTestError_PushRefID_NoNotifyNoTestFinished
- TestPrintableConfig
- TestProvisionLocalExecution_409ConflictPropagatesToFindByName
- TestProvisionLocalExecution_ArchivePresentButNoUploadURL
- TestProvisionLocalExecution_ErrorAtCreate
- TestProvisionLocalExecution_ErrorAtPolling
- TestProvisionLocalExecution_ErrorAtStart
- TestProvisionLocalExecution_ErrorAtUpload
- TestProvisionLocalExecution_NoArchive
- TestProvisionLocalExecution_WithArchive
- TestResponseError_Error_FormatsStatusAndBody
- TestRetryWithConnectionClose
- TestStartLocalExecution
- TestStartLocalExecution_4xxNotRetried
- TestStartLocalExecution_5xxRetried
- TestStartLocalExecution_NoArchive_ArchiveSizeNull
- TestStartTest
- TestStopTest
- TestUploadArchive
- TestUploadArchive_4xxNotRetried
- TestUploadArchive_RetriesOn5xx
- TestUploadTest
- TestValidateOptions
- TestValidateToken
- TestWaitForTestRunReady
- TestWaitForTestRunReady_AbortedNoHistoryReturnsGenericError
- TestWaitForTestRunReady_AbortedReturnsErrorWithMessage
- TestWaitForTestRunReady_CompletedReturnsError
- TestWaitForTestRunReady_ContextCancellation
- TestWaitForTestRunReady_LogsTransitionsOnce
- TestWaitForTestRunReady_PollsUntilInitializing
- TestWaitForTestRunReady_UnknownStatusKeepsPolling
