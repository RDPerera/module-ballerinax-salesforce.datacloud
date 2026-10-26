# Tests

The test suite covers all 23 operations of the WSO2 Salesforce Data 360 (Data Cloud) Connector: streaming ingestion (`upsertRecords`, `deleteRecords`, `validateRecords`), bulk ingestion (`createBulkJob`, `listBulkJobs`, `getBulkJob`, `uploadBulkJobData`, `updateBulkJobState`, `deleteBulkJob`), profiles (`listProfileMetadata`, `getProfileMetadata`, `queryProfiles`, `getProfile`, `getProfileChildRecords`, `getProfileCalculatedInsight`), calculated insights (`listCalculatedInsightMetadata`, `getCalculatedInsightMetadata`, `queryCalculatedInsight`), SQL queries (`querySql`, `getNextSqlQueryBatch`), and runs (`listIdentityResolutionRulesets`, `runIdentityResolutionRuleset`, `runCalculatedInsight`).

It also covers authentication: the exchange of the org token for a Data Cloud token and its reuse, the refresh token, client credentials and JWT bearer grants against the org's own token endpoint (the mock verifies each signed JWT assertion), exchanging again before the token expires and after the tenant endpoint rejects it (for every tenant operation), the `dataspace` parameter, errors from invalid credentials, a failed token renewal or a malformed exchange response, and the query serialization helpers (`tests/utils_test.bal`).

## Running Tests

```bash
bal test
```

The test suite uses a mock server (`tests/mock_service.bal`) that plays both the Salesforce org (OAuth 2.0 token endpoint, Data Cloud token exchange, Connect REST runs) and the Data Cloud tenant endpoint, and checks the token on every request, so no real credentials are required.

To run the read-only tests against a live Data Cloud org instead, set the following environment variables:

```bash
export IS_LIVE_SERVER=true
export SF_ORG_URL=https://<your-domain>.my.salesforce.com
export SF_CLIENT_ID=<consumer-key>
export SF_CLIENT_SECRET=<consumer-secret>
export SF_REFRESH_TOKEN=<refresh-token>   # omit to use the client credentials grant
bal test --groups live_tests
```
