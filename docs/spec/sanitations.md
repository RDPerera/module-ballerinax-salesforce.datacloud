_Author_:  Dilan Perera \
_Created_: 2026/10/25 \
_Updated_: 2026/10/25 \
_Edition_: Swan Lake

# Sanitation for OpenAPI specification

This document records the sanitation done on top of the source OpenAPI specification for Salesforce Data Cloud.
Salesforce publishes no OpenAPI specification for these APIs, so the source specification was written by hand from the
[Data Cloud Reference Guide](https://developer.salesforce.com/docs/data/data-cloud-ref/guide/c360a-api-get-started.htm) (v62.0) and the
[Connect REST API reference](https://developer.salesforce.com/docs/data/connectapi/references/spec), and checked against a
live Data Cloud org.
These changes are done in order to improve the overall usability, and as workarounds for some known language limitations.

1. Flatten and align the specification
- **Original**: Inline object schemas under `ObjectMetadata`, `ErrorResponse` and `SalesforceErrors`; parameters without explicit `style`/`explode`.
- **Updated**: Ran `bal openapi flatten` and `bal openapi align`. Inline schemas became named schemas (`ObjectMetadataIndexes`, `ObjectMetadataPrimaryKeys`, `ObjectMetadataRelationships`, `ErrorResponseDetails`, `ErrorResponseDetailsValidationReport`, `SalesforceErrorsInner`), and parameters got explicit serialization.
- **Reason**: Generates named record types instead of anonymous inline records.

2. Replace the two bearer security schemes with one OAuth 2.0 scheme
- **Original**: Two `http` `bearer` schemes: `dataCloudToken` (global) for the tenant-endpoint operations and `coreToken` for the `Runs` operations.
- **Updated**: A single `OAuth2` scheme with the `authorizationCode` (with `refreshUrl`), `clientCredentials` and `password` flows and the token URL `https://login.salesforce.com/services/oauth2/token`, applied globally. The per-operation `security` of the `Runs` operations was removed.
- **Reason**: Both tokens derive from the Salesforce org credentials: the core token is the org's OAuth 2.0 access token and the Data Cloud token is obtained by exchanging it. With one OAuth 2.0 scheme the generated `ConnectionConfig.auth` accepts the refresh token, client credentials and password grants and a plain access token (`http:BearerTokenConfig`), so users configure only the org credentials. The hand-written `Client` (see below) uses them directly for the `Runs` operations and exchanges them for the Data Cloud token. When `tokenUrl`/`refreshUrl` is left at this default, the client sends token requests to the org's own `<serviceUrl>/services/oauth2/token` instead, which every grant accepts (client credentials accepts nothing else).

3. Remove the `ids` query parameter of `deleteRecords`
- **Original**: `DELETE /api/v1/ingest/sources/{sourceName}/{objectName}` took the IDs either in an optional `ids` query parameter or in an optional JSON body, but not both.
- **Updated**: Removed the `ids` query parameter and made the `DeleteRecordsRequest` body required.
- **Reason**: The generator makes the optional body a required parameter, so a query parameter would always be sent together with the body, which the API rejects. Sending the IDs in the body always works.

4. Add and reword schema and field descriptions
- **Original**: Many schemas and fields had no description; schema, operation and response descriptions recorded test observations (`Observed live (2026-10-24)`, `left permissive`) or wrapped code spans over line breaks; and `info.description` described the two replaced bearer schemes and the folder the specification came from.
- **Updated**: Added descriptions to every schema and field, reworded the observation notes as API behavior, and replaced `info.description` with a summary of the APIs and how they are authenticated. Fields that are `$ref`s were wrapped in `allOf` to carry a description.
- **Reason**: The descriptions become the API docs of the generated records; wrapped code spans produced documentation warnings.

5. Rename operations, types and parameters to human-friendly names
- **Original**: Several names were ambiguous or inconsistent: bulk job operations and types didn't say they were bulk ingestion jobs (`createJob`, `JobInfo`), calculated insights were called both `Insight` and `CalculatedInsight`, the list-all and get-one metadata operations were `getProfileMetadata`/`getProfileMetadataByName`, the same kinds of values had different or cryptic parameter names (`ciName`, `apiName`, `identityResolution`, `id`), some schemas had generic or generated names (`Record`, `ObjectMetadataIndexes`), and some fields needed quoted identifiers or broke camel case (`'object`, `'type`, `orderby`).
- **Updated**:

  | Kind | Original | Updated |
  |---|---|---|
  | Operation | `createJob`, `listJobs`, `getJob`, `deleteJob`, `updateJobState`, `uploadJobData` | `createBulkJob`, `listBulkJobs`, `getBulkJob`, `deleteBulkJob`, `updateBulkJobState`, `uploadBulkJobData` |
  | Operation | `getProfileMetadata` (all objects), `getProfileMetadataByName` | `listProfileMetadata`, `getProfileMetadata` |
  | Operation | `getInsightMetadata` (all insights), `getInsightMetadataByName` | `listCalculatedInsightMetadata`, `getCalculatedInsightMetadata` |
  | Operation | `listIdentityResolutions`, `runIdentityResolution` | `listIdentityResolutionRulesets`, `runIdentityResolutionRuleset` |
  | Schema | `JobInfo`, `JobList`, `JobState`, `JobOperation`, `CreateJobRequest`, `UpdateJobStateRequest` | `BulkJob`, `BulkJobList`, `BulkJobState`, `BulkJobOperation`, `CreateBulkJobRequest`, `UpdateBulkJobStateRequest` |
  | Schema | `Record` | `IngestRecord` |
  | Schema | `ObjectMetadataIndexes`, `ObjectMetadataPrimaryKeys`, `ObjectMetadataRelationships` | `ObjectIndex`, `PrimaryKeyField`, `ObjectRelationship` |
  | Schema | `IdentityResolutionList` | `IdentityResolutionRulesetList` |
  | Schema | `ErrorResponseDetailsValidationReport`, `SalesforceErrorsInner` | `ValidationReportEntry`, `SalesforceError` |
  | Path parameter | `ciName`, `apiName` | `insightName` |
  | Path parameter | `identityResolution` | `rulesetId` |
  | Path parameter | `id` | `recordId` |
  | Field (`x-ballerina-name`) | `object` of `BulkJob` and `CreateBulkJobRequest` | `objectName` |
  | Field (`x-ballerina-name`) | `type` of `FieldMetadata` | `dataType` |
  | Field (`x-ballerina-name`) | `identityResolutions` of `IdentityResolutionRulesetList` | `rulesets` |
  | Query parameter (`x-ballerina-name`) | `orderby` | `orderBy` |

- **Reason**: Makes each operation and type say what it is and keeps one name per concept. `ErrorResponse` and its parts, `ValidationReportEntry` and `SalesforceError` describe error bodies only, so the generator leaves them out of the package (error bodies are available in the `body` of the returned `http:ClientRequestError` detail); they are renamed in the specification for consistency. Renaming operationIds, schemas and path parameters changes only the generated Ballerina names; the `x-ballerina-name` extension keeps the API's JSON keys and query parameter names on the wire (`@jsondata:Name`, `@http:Query`).

6. Exchange the org token for a Data Cloud token in a hand-written client
- **Change**: `ballerina/client.bal` wraps two `GeneratedClient` instances. One targets the core org (`<serviceUrl>/services/data/<apiVersion>`) with the current core access token and serves the `Runs` operations. The other targets the Data Cloud tenant endpoint and serves every other operation. On the first tenant call the client exchanges the org access token at `POST <serviceUrl>/services/a360/token` (`grant_type=urn:salesforce:grant-type:external:cdp`, `subject_token=<org token>`, `subject_token_type=urn:ietf:params:oauth:token-type:access_token`, with `dataspace` as a query parameter when configured, as Salesforce's own Data Cloud clients send it), builds the tenant client from the returned `instance_url` (prefixing `https://`, since it comes without a scheme) and `access_token`, and caches it. It exchanges again 60 seconds (at most half the token's lifetime) before `expires_in` runs out, and when the tenant endpoint returns `401` it exchanges again and retries the call once. The core token comes from a single OAuth 2.0 grant shared by the exchange and the `Runs` client, so each grant is fetched once and a rotated refresh token stays in one place. When the org rejects the core token (a `401` from a `Runs` operation, or an exchange that answers `401` or an OAuth 2.0 `invalid_request`, `invalid_grant` or `invalid_token` error), the client fetches a new one from the OAuth 2.0 grant and retries once; a configured plain access token can't be renewed, so the call is not repeated. The exchange reports failures as `200 OK` with an OAuth 2.0 error body, so the client checks the body as well as the status. In an org whose Data Cloud isn't set up yet, the exchange returns a token without an `instance_url`; the client reports that as such.
- **Reason**: Data Cloud serves its APIs from two hosts with two tokens, and the tenant host is known only after the token exchange. The generator ignores path-level `servers` and produces one client with one static base URL and auth configuration, and the exchange can't be expressed as an OpenAPI security scheme. See the [Data Cloud authentication guide](https://developer.salesforce.com/docs/atlas.en-us.252.0.c360a_api.meta/c360a_api/c360a_getting_started_with_cdp.htm).

7. Add the Query API v2
- **Original**: The specification covered ingestion, profiles, calculated insights and runs, but not SQL queries.
- **Updated**: Added `POST /api/v2/query` (`querySql`) and `GET /api/v2/query/{nextBatchId}` (`getNextSqlQueryBatch`) under a new `Query` tag, with the `SqlQueryRequest`, `SqlQueryResponse` and `SqlColumn` schemas (`type` exposed as `dataType` with `x-ballerina-name`).
- **Reason**: SQL queries over data lake objects, data model objects and calculated insights are a core Data Cloud capability that Salesforce's own Python and JDBC clients and the MuleSoft connector provide. The request and response shapes were taken from a live Data Cloud org: rows are arrays of column values ordered by each column's `placeInOrder`, `metadata` is keyed by column name, and `nextBatchId` is `null` on the last batch. The asynchronous Query API v3 isn't added: it returns the query ID only in a response header, which the generated client doesn't expose.

8. Add the OAuth 2.0 JWT bearer grant
- **Change**: `ballerina/client.bal` defines `OAuth2JwtBearerGrantConfig` (consumer key, username, private key, audience) as another `ConnectionConfig.auth` option. For every token request the client signs a new JWT that expires within 3 minutes, as Salesforce requires, and posts it to the org's token endpoint with `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`. The resulting token is used for the token exchange and the `Runs` operations like any other org token, including renewal when the org rejects it.
- **Reason**: The JWT bearer flow is the standard certificate-based server-to-server login for Salesforce, supported by the other Data Cloud clients. OpenAPI has no JWT bearer flow, and `http:OAuth2JwtBearerGrantConfig` takes a pre-signed JWT that would expire after 3 minutes, so the grant is implemented in the client and added to the generated `ConnectionConfig` in a post-generation step.

## OpenAPI cli command

The following command generates the raw OpenAPI-derived client. The command should be executed from the repository root directory.
It writes a `client.bal`, so generate into a temporary directory rather than into `ballerina`, where it would overwrite the hand-written `client.bal`.

```bash
bal openapi -i docs/spec/openapi.json -o /tmp/datacloud-gen --mode client --license docs/license.txt --client-methods remote
```

Note: The license year is hardcoded to 2026, change if necessary.

### Post-generation steps

1. Copy the generated `client.bal` to `ballerina/oas_client.bal` and rename its class to `GeneratedClient`
   (`public isolated client class Client {` → `isolated client class GeneratedClient {`). Copy `utils.bal` as-is.
2. In `types.bal`, add `|OAuth2JwtBearerGrantConfig` to the type of `ConnectionConfig.auth` (see item 8).
3. In `oas_client.bal`, replace `{auth: config.auth,` with `{auth: toHttpClientAuth(config.auth),`, so that the
   generated client never hands a JWT bearer config to `http:Client` (see item 8).

`ballerina/client.bal` is a hand-written wrapper around `GeneratedClient` that handles the two hosts and tokens of Data Cloud (see item 6). It is intentionally **not** regenerated.
