// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/http;
import ballerina/mime;
import ballerina/url;

// One listener plays both hosts: the core org (`/services/...`) and the Data Cloud tenant endpoint
// (`/api/v1/...`). The token exchange hands out `http://localhost:9090` as the tenant endpoint.
listener http:Listener ep0 = new (9090);

const MOCK_CORE_TOKEN = "core-test-token";
const MOCK_REFRESHED_CORE_TOKEN = "core-refreshed-token";
const MOCK_CLIENT_CREDENTIALS_CORE_TOKEN = "core-client-credentials-token";
const MOCK_CLIENT_ID = "test-client-id";
const MOCK_CLIENT_SECRET = "test-client-secret";
const MOCK_REFRESH_TOKEN = "test-refresh-token";
const MOCK_TENANT_URL = "http://localhost:9090";
const SHORT_LIVED_DATASPACE = "short_lived";
const MALFORMED_RESPONSE_DATASPACE = "malformed_response";
const UNKNOWN_DATASPACE = "unknown_space";
const NOT_SET_UP_DATASPACE = "not_set_up";

// Core tokens the OAuth 2.0 token endpoint has issued and not revoked. `MOCK_CORE_TOKEN` is always valid.
isolated string[] issuedCoreTokens = [];

isolated int exchangeCount = 0;
isolated int oauth2TokenRequestCount = 0;
isolated int runsRequestCount = 0;
isolated string[] validDataCloudTokens = [];
isolated string? lastDataspace = ();

isolated function getExchangeCount() returns int {
    lock {
        return exchangeCount;
    }
}

isolated function getRunsRequestCount() returns int {
    lock {
        return runsRequestCount;
    }
}

isolated function getOauth2TokenRequestCount() returns int {
    lock {
        return oauth2TokenRequestCount;
    }
}

isolated function getLastDataspace() returns string? {
    lock {
        return lastDataspace;
    }
}

isolated function isValidDataCloudToken(string? authorization) returns boolean {
    if authorization is () || !authorization.startsWith("Bearer ") {
        return false;
    }
    string token = authorization.substring(7);
    lock {
        return validDataCloudTokens.indexOf(token) !is ();
    }
}

isolated function isValidCoreToken(string? authorization) returns boolean {
    lock {
        runsRequestCount += 1;
    }
    return authorization is string && authorization.startsWith("Bearer ")
        && isValidSubjectToken(authorization.substring(7));
}

isolated function isValidSubjectToken(string token) returns boolean {
    if token == MOCK_CORE_TOKEN {
        return true;
    }
    lock {
        return issuedCoreTokens.indexOf(token) !is ();
    }
}

isolated function parseForm(string body) returns map<string>|error {
    map<string> form = {};
    foreach string pair in re `&`.split(body) {
        string[] parts = re `=`.split(pair);
        if parts.length() == 2 {
            form[check url:decode(parts[0], "UTF-8")] = check url:decode(parts[1], "UTF-8");
        }
    }
    return form;
}

// Tenant-endpoint error body.
type ErrorResponse record {
    string timestamp?;
    string 'error?;
    string message?;
    string path?;
    string tenantId?;
    string internalErrorCode?;
    record {
        record {|string 'record; string[] causingExceptions;|}[] validationReport?;
    } details?;
};

final ErrorResponse & readonly unauthorizedBody = {
    timestamp: "2026-10-24T10:15:30.123456Z",
    'error: "Unauthorized",
    message: "Token is invalid or expired",
    path: "uri=/api/v1",
    tenantId: "a360/prod/abc123",
    internalErrorCode: "COMMON_ERROR_UNAUTHORIZED"
};

final BulkJob & readonly mockOpenJob = {
    id: "9f8e7d6c-5b4a-3c2d-1e0f-a1b2c3d4e5f6",
    objectName: "customers",
    sourceName: "CustomerOrders",
    operation: "upsert",
    state: "Open",
    contentType: "CSV",
    apiVersion: "v1",
    contentUrl: "/api/v1/ingest/jobs/9f8e7d6c-5b4a-3c2d-1e0f-a1b2c3d4e5f6/batches",
    createdById: "005xx000001Sv6dAAC",
    createdDate: "2026-10-24T10:15:30.123456Z",
    systemModstamp: "",
    retries: 0,
    totalProcessingTime: 0
};

// A closed job no longer has an upload URL; the API returns these fields as null.
isolated function closedJob(string id, BulkJobState state) returns BulkJob {
    BulkJob job = {...mockOpenJob};
    job.id = id;
    job.state = state;
    job.contentUrl = ();
    job.retries = ();
    job.totalProcessingTime = ();
    return job;
}

final QueryResponse & readonly mockProfileRows = {
    data: [
        {
            "ssot__Id__c": "a1b2c3d4-0000-0000-0000-000000000001",
            "ssot__FirstName__c": "Iris",
            "ssot__LastName__c": "Perera"
        }
    ],
    done: true,
    metadata: {
        "ssot__Id__c": {'type: "VARCHAR", placeInOrder: 0},
        "ssot__FirstName__c": {'type: "VARCHAR", placeInOrder: 1},
        "ssot__LastName__c": {'type: "VARCHAR", placeInOrder: 2}
    }
};

final MetadataResponse & readonly mockProfileMetadata = {
    metadata: [
        {
            name: "UnifiedIndividual__dlm",
            displayName: "Unified Individual",
            category: "Profile",
            fields: [
                {name: "ssot__Id__c", displayName: "Unified Individual Id", dataType: "STRING"},
                {name: "ssot__FirstName__c", displayName: "First Name", dataType: "STRING"}
            ],
            indexes: [{fields: [{name: "ssot__Id__c", displayName: "Unified Individual Id", dataType: "STRING"}]}],
            primaryKeys: [{name: "ssot__Id__c", displayName: "Unified Individual Id", indexOrder: "1"}],
            relationships: [
                {
                    fromEntity: "UnifiedIndividual__dlm",
                    toEntity: "ContactPointEmail__dlm",
                    fromEntityAttribute: "ssot__Id__c",
                    toEntityAttribute: "ssot__PartyId__c",
                    cardinality: "ONETOMANY"
                }
            ]
        }
    ]
};

final MetadataResponse & readonly mockInsightMetadata = {
    metadata: [
        {
            name: "IndividualSpend__cio",
            displayName: "Individual Spend",
            dimensions: [{name: "individual_id__c", displayName: "Individual Id", dataType: "STRING"}],
            measures: [{name: "total_spend__c", displayName: "Total Spend", dataType: "NUMBER", rollupable: true}],
            partitionBy: "",
            latestProcessTime: "2026-10-24T09:00:00.00000Z",
            latestSuccessfulProcessTime: "2026-10-24T09:00:00.00000Z"
        }
    ]
};

service / on ep0 {

    // ------------------------------------------------------------------ Core org: OAuth 2.0 token endpoint
    // Like Salesforce, the response carries no `expires_in`.
    resource function post services/oauth2/token(http:Request request) returns http:Ok|http:BadRequest|error {
        lock {
            oauth2TokenRequestCount += 1;
        }
        map<string> form = check parseForm(check request.getTextPayload());
        string? grantType = form["grant_type"];
        string clientId = form["client_id"] ?: "";
        string clientSecret = form["client_secret"] ?: "";
        string|http:HeaderNotFoundError basic = request.getHeader("Authorization");
        if basic is string && basic.startsWith("Basic ") {
            string decoded = check string:fromBytes(check mime:base64Decode(basic.substring(6).toBytes()).ensureType());
            string[] parts = re `:`.split(decoded);
            clientId = parts[0];
            clientSecret = parts.length() > 1 ? parts[1] : "";
        }
        if clientId != MOCK_CLIENT_ID || clientSecret != MOCK_CLIENT_SECRET {
            return <http:BadRequest>{body: {'error: "invalid_client", error_description: "invalid client credentials"}};
        }
        string accessToken;
        int tokenNumber;
        lock {
            tokenNumber = oauth2TokenRequestCount;
        }
        if grantType == "refresh_token" && form["refresh_token"] == MOCK_REFRESH_TOKEN {
            accessToken = string `${MOCK_REFRESHED_CORE_TOKEN}-${tokenNumber}`;
        } else if grantType == "client_credentials" {
            accessToken = string `${MOCK_CLIENT_CREDENTIALS_CORE_TOKEN}-${tokenNumber}`;
        } else {
            return <http:BadRequest>{body: {'error: "invalid_grant", error_description: "authentication failure"}};
        }
        lock {
            issuedCoreTokens.push(accessToken);
        }
        return <http:Ok>{
            body: {
                access_token: accessToken,
                signature: "c2lnbmF0dXJl",
                scope: "cdp_ingest_api cdp_profile_api cdp_query_api api refresh_token",
                instance_url: MOCK_TENANT_URL,
                id: "https://login.salesforce.com/id/00Dxx0000001gPLEAY/005xx000001Sv6dAAC",
                token_type: "Bearer",
                issued_at: "1761300930000"
            }
        };
    }

    // ------------------------------------------------------------------ Core org: Data Cloud token exchange
    // Like Salesforce, a failed exchange is `200 OK` with an OAuth 2.0 error body.
    resource function post services/a360/token(http:Request request) returns http:Ok|error {
        if request.getContentType() != "application/x-www-form-urlencoded" {
            return <http:Ok>{body: {'error: "invalid_request", error_description: "unsupported content type"}};
        }
        map<string> form = check parseForm(check request.getTextPayload());
        if form["grant_type"] != "urn:salesforce:grant-type:external:cdp"
                || form["subject_token_type"] != "urn:ietf:params:oauth:token-type:access_token" {
            return <http:Ok>{body: {'error: "unsupported_grant_type", error_description: "grant type not supported"}};
        }
        string? subjectToken = form["subject_token"];
        if subjectToken is () || !isValidSubjectToken(subjectToken) {
            return <http:Ok>{body: {'error: "invalid_request", error_description: "invalid subject token"}};
        }
        string? dataspace = form["dataspace"];
        if dataspace == UNKNOWN_DATASPACE {
            return <http:Ok>{body: {'error: "invalid_dataspace", error_description: "data space not found"}};
        }
        if dataspace == NOT_SET_UP_DATASPACE {
            // An org whose Data Cloud isn't set up yet gets a token but no tenant endpoint.
            return <http:Ok>{body: {access_token: "dc-token-no-tenant", instance_url: (), token_type: "Bearer",
                issued_token_type: "urn:ietf:params:oauth:token-type:jwt", expires_in: 7199}};
        }
        if dataspace == MALFORMED_RESPONSE_DATASPACE {
            return <http:Ok>{body: {token_type: "Bearer"}};
        }
        string dataCloudToken;
        lock {
            exchangeCount += 1;
            dataCloudToken = string `dc-token-${exchangeCount}`;
        }
        lock {
            lastDataspace = dataspace;
        }
        lock {
            validDataCloudTokens.push(dataCloudToken);
        }
        return <http:Ok>{
            body: {
                access_token: dataCloudToken,
                instance_url: MOCK_TENANT_URL,
                token_type: "Bearer",
                issued_token_type: "urn:ietf:params:oauth:token-type:jwt",
                expires_in: dataspace == SHORT_LIVED_DATASPACE ? 1 : 7199
            }
        };
    }

    // Test-only: invalidates every core token the token endpoint issued so far, as if the sessions had expired.
    resource function post test/revoke\-core() {
        lock {
            issuedCoreTokens = [];
        }
    }

    // Test-only: invalidates every Data Cloud token issued so far, as if they had expired server side.
    resource function post test/revoke() {
        lock {
            validDataCloudTokens = [];
        }
    }

    // ------------------------------------------------------------------ Tenant: streaming ingestion
    resource function post api/v1/ingest/sources/[string sourceName]/[string objectName](
            @http:Header {name: "Authorization"} string? authorization, @http:Payload IngestRecords payload)
            returns http:Accepted|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        return <http:Accepted>{body: {accepted: true}};
    }

    resource function delete api/v1/ingest/sources/[string sourceName]/[string objectName](
            @http:Header {name: "Authorization"} string? authorization, @http:Payload DeleteRecordsRequest payload)
            returns http:Accepted|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        return <http:Accepted>{body: {accepted: true}};
    }

    resource function post api/v1/ingest/sources/[string sourceName]/[string objectName]/actions/test(
            @http:Header {name: "Authorization"} string? authorization, @http:Payload IngestRecords payload)
            returns http:Accepted|http:BadRequest|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        foreach IngestRecord rec in payload.data {
            if rec["customer_id"] !is string {
                ErrorResponse body = {
                    timestamp: "2026-10-24T10:15:30.123456Z",
                    'error: "Bad Request",
                    message: "Bad Request: JSON is properly formatted but has a mismatch with Schema.",
                    path: string `uri=/api/v1/ingest/sources/${sourceName}/${objectName}/actions/test`,
                    tenantId: "a360/prod/abc123",
                    internalErrorCode: "COMMON_ERROR_GENERIC",
                    details: {
                        validationReport: [
                            {'record: rec.toJsonString(), causingExceptions: ["#/customer_id: expected type: String"]}
                        ]
                    }
                };
                return <http:BadRequest>{body};
            }
        }
        return <http:Accepted>{body: {accepted: true}};
    }

    // ------------------------------------------------------------------ Tenant: bulk ingestion
    resource function post api/v1/ingest/jobs(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload map<json> payload) returns http:Created|http:BadRequest|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        // The API's JSON key is `object`; `objectName` is only the Ballerina field name.
        json objectName = payload["object"];
        json operation = payload["operation"];
        if objectName !is string || payload.hasKey("objectName") || (operation != "upsert" && operation != "delete") {
            return <http:BadRequest>{body: {message: string `unexpected job request: ${payload.toJsonString()}`}};
        }
        BulkJob job = {...mockOpenJob};
        job.objectName = objectName;
        job.sourceName = payload["sourceName"].toString();
        job.operation = operation == "upsert" ? "upsert" : "delete";
        return <http:Created>{body: job};
    }

    resource function get api/v1/ingest/jobs(@http:Header {name: "Authorization"} string? authorization,
            http:Request request) returns BulkJobList|http:BadRequest|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        // `states` is a comma-separated list (`style: form, explode: false`).
        if request.rawPath.includes("states=") && !request.rawPath.includes("states=Open,UploadComplete") {
            return <http:BadRequest>{body: {message: string `unexpected states filter: ${request.rawPath}`}};
        }
        return {data: [mockOpenJob, closedJob("1a2b3c4d", "JobComplete")]};
    }

    resource function get api/v1/ingest/jobs/[string jobId](
            @http:Header {name: "Authorization"} string? authorization) returns BulkJob|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        BulkJob job = {...mockOpenJob};
        job.id = jobId;
        return job;
    }

    resource function patch api/v1/ingest/jobs/[string jobId](
            @http:Header {name: "Authorization"} string? authorization, @http:Payload UpdateBulkJobStateRequest payload)
            returns BulkJob|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        return closedJob(jobId, payload.state);
    }

    resource function delete api/v1/ingest/jobs/[string jobId](
            @http:Header {name: "Authorization"} string? authorization) returns http:NoContent|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        return http:NO_CONTENT;
    }

    resource function put api/v1/ingest/jobs/[string jobId]/batches(
            @http:Header {name: "Authorization"} string? authorization, http:Request request)
            returns http:Accepted|http:BadRequest|http:Unauthorized|error {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        if request.getContentType() != "text/csv" || !(check request.getTextPayload()).startsWith("customer_id,") {
            return <http:BadRequest>{body: {message: "expected a CSV file with a header row"}};
        }
        return <http:Accepted>{body: {accepted: true}};
    }

    // ------------------------------------------------------------------ Tenant: profile
    resource function get api/v1/profile/metadata(@http:Header {name: "Authorization"} string? authorization)
            returns MetadataResponse|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        return mockProfileMetadata;
    }

    resource function get api/v1/profile/metadata/[string dataModelName](
            @http:Header {name: "Authorization"} string? authorization) returns MetadataResponse|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        return mockProfileMetadata;
    }

    resource function get api/v1/profile/[string dataModelName](
            @http:Header {name: "Authorization"} string? authorization, http:Request request)
            returns QueryResponse|http:BadRequest|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        // `fields` is a comma-separated list (`style: form, explode: false`); the listener would split it, so the
        // raw query is checked.
        string query = request.rawPath;
        if !query.includes("filters=%5Bssot__FirstName__c%3DIris%5D")
                || (query.includes("fields=") && !query.includes("fields=ssot__Id__c,ssot__FirstName__c"))
                || query.includes("orderBy=")
                || (query.includes("orderby=") && !query.includes("orderby=ssot__FirstName__c%20ASC")) {
            return <http:BadRequest>{body: {message: string `unexpected query: ${request.rawPath}`}};
        }
        return mockProfileRows;
    }

    resource function get api/v1/profile/[string dataModelName]/[string id](
            @http:Header {name: "Authorization"} string? authorization, string? searchKey = ())
            returns QueryResponse|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        return mockProfileRows;
    }

    resource function get api/v1/profile/[string dataModelName]/[string id]/[string childDataModelName](
            @http:Header {name: "Authorization"} string? authorization) returns QueryResponse|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        return {
            data: [
                {
                    "ssot__FirstName__c": "Iris",
                    [childDataModelName]: {ssot__EmailAddress__c: "iris@example.com", "ssot__Id__c": "cpe-001"}
                }
            ],
            done: true,
            metadata: {}
        };
    }

    resource function get api/v1/profile/[string dataModelName]/[string id]/calculated\-insights/[string ciName](
            @http:Header {name: "Authorization"} string? authorization, string? timeGranularity = ())
            returns QueryResponse|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        return {
            data: [{"ssot__FirstName__c": "Iris", [ciName]: {individual_id__c: id, total_spend__c: 1250.5}}],
            done: true,
            metadata: {}
        };
    }

    // ------------------------------------------------------------------ Tenant: calculated insights
    resource function get api/v1/insight/metadata(@http:Header {name: "Authorization"} string? authorization)
            returns MetadataResponse|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        return mockInsightMetadata;
    }

    resource function get api/v1/insight/metadata/[string ciName](
            @http:Header {name: "Authorization"} string? authorization) returns MetadataResponse|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        return mockInsightMetadata;
    }

    resource function get api/v1/insight/calculated\-insights/[string ciName](
            @http:Header {name: "Authorization"} string? authorization, string? dimensions = (),
            string? measures = (), int? 'limit = ()) returns json|http:Unauthorized {
        if !isValidDataCloudToken(authorization) {
            return <http:Unauthorized>{body: unauthorizedBody};
        }
        return {
            data: [{individual_id__c: "a1b2c3d4-0000-0000-0000-000000000001", total_spend__c: 1250.5}],
            done: true,
            metadata: {individual_id__c: {'type: "VARCHAR"}, total_spend__c: {'type: "DECIMAL"}},
            arrowStream: ()
        };
    }

    // ------------------------------------------------------------------ Core org: Connect REST runs
    resource function get services/data/v62\.0/ssot/identity\-resolutions(
            @http:Header {name: "Authorization"} string? authorization) returns json|http:Unauthorized {
        if !isValidCoreToken(authorization) {
            return <http:Unauthorized>{body: [{errorCode: "INVALID_SESSION_ID", message: "Session expired or invalid"}]};
        }
        return {
            identityResolutions: [
                {
                    id: "1irXX0000000001AAA",
                    label: "Individual Ruleset",
                    developerName: (),
                    configurationType: "individual",
                    objectApiName: "Individual",
                    dataSpaceName: "default",
                    doesRunAutomatically: true,
                    lastJobStatus: "SUCCESS",
                    lastJobCompleted: "2026-10-24T08:00:00.000Z",
                    matchRules: [{label: "Exact Email"}],
                    reconciliationRules: []
                }
            ]
        };
    }

    resource function post services/data/v62\.0/ssot/identity\-resolutions/[string identityResolution]/actions/run\-now(
            @http:Header {name: "Authorization"} string? authorization) returns http:Ok|http:Unauthorized {
        if !isValidCoreToken(authorization) {
            return <http:Unauthorized>{body: [{errorCode: "INVALID_SESSION_ID", message: "Session expired or invalid"}]};
        }
        return <http:Ok>{body: {resultCode: "SuccessfullySubmittedIdentityResolutionJobRunRequest"}};
    }

    resource function post services/data/v62\.0/ssot/calculated\-insights/[string apiName]/actions/run(
            @http:Header {name: "Authorization"} string? authorization) returns http:Created|http:Unauthorized {
        if !isValidCoreToken(authorization) {
            return <http:Unauthorized>{body: [{errorCode: "INVALID_SESSION_ID", message: "Session expired or invalid"}]};
        }
        return <http:Created>{body: {errors: [], success: true}};
    }
}
