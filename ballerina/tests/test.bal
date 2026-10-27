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
import ballerina/lang.runtime;
import ballerina/os;
import ballerina/test;

final boolean isLiveServer = os:getEnv("IS_LIVE_SERVER") == "true";
final string serviceUrl = isLiveServer ? os:getEnv("SF_ORG_URL") : MOCK_TENANT_URL;
final string clientId = isLiveServer ? os:getEnv("SF_CLIENT_ID") : MOCK_CLIENT_ID;
final string clientSecret = isLiveServer ? os:getEnv("SF_CLIENT_SECRET") : MOCK_CLIENT_SECRET;
final string refreshToken = isLiveServer ? os:getEnv("SF_REFRESH_TOKEN") : MOCK_REFRESH_TOKEN;

const SOURCE_NAME = "CustomerOrders";
const OBJECT_NAME = "customers";
const JOB_ID = "9f8e7d6c-5b4a-3c2d-1e0f-a1b2c3d4e5f6";
const PROFILE_DMO = "UnifiedIndividual__dlm";
const PROFILE_ID = "a1b2c3d4-0000-0000-0000-000000000001";
const INSIGHT_NAME = "IndividualSpend__cio";

// Against the mock, the core org credentials are a plain access token. Live, they are a client credentials grant,
// or a refresh token grant when `SF_REFRESH_TOKEN` is set; the token URL defaults to the org's own token endpoint.
final Client datacloud = check new (
    {
        auth: !isLiveServer ? {token: MOCK_CORE_TOKEN}
            : refreshToken == "" ? {clientId, clientSecret} : {clientId, clientSecret, refreshToken}
    },
    serviceUrl
);

// Mock-only clients exercising the other ways of authenticating. OAuth2 grant clients fetch a token while
// initializing, so those are created inside the tests, once the mock service is up.
final Client shortLivedTokenClient = check new ({auth: {token: MOCK_CORE_TOKEN}}, MOCK_TENANT_URL,
    dataspace = SHORT_LIVED_DATASPACE
);
final Client invalidTokenClient = check new ({auth: {token: "not-a-valid-token"}}, MOCK_TENANT_URL);

final IngestRecords & readonly records = {
    data: [
        {
            "customer_id": "100000000",
            "email": "alex@example.com",
            "first_name": "Alex",
            "last_name": "Perera",
            "created_at": "2026-10-24T10:15:30.000Z"
        }
    ]
};

// ---------------------------------------------------------------------------------- Streaming ingestion

@test:Config {
    groups: ["mock_tests"]
}
isolated function testUpsertRecords() returns error? {
    AcceptedResponse response = check datacloud->upsertRecords(SOURCE_NAME, OBJECT_NAME, records);
    test:assertEquals(response.accepted, true);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testDeleteRecords() returns error? {
    AcceptedResponse response = check datacloud->deleteRecords(SOURCE_NAME, OBJECT_NAME, {ids: ["100000000"]});
    test:assertEquals(response.accepted, true);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testValidateRecords() returns error? {
    AcceptedResponse response = check datacloud->validateRecords(SOURCE_NAME, OBJECT_NAME, records);
    test:assertEquals(response.accepted, true);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testValidateRecordsReportsSchemaMismatch() returns error? {
    AcceptedResponse|error response = datacloud->validateRecords(SOURCE_NAME, OBJECT_NAME,
        {data: [{"customer_id": 100000000, "email": "alex@example.com"}]});
    if response !is http:ClientRequestError {
        test:assertFail("Expected an http:ClientRequestError for an invalid record");
    }
    test:assertEquals(response.detail().statusCode, 400);
    ErrorResponse body = check response.detail().body.cloneWithType();
    test:assertEquals(body.internalErrorCode, "COMMON_ERROR_GENERIC");
    test:assertTrue((body.details?.validationReport ?: []).length() == 1);
}

// ---------------------------------------------------------------------------------- Bulk ingestion

@test:Config {
    groups: ["mock_tests"]
}
isolated function testCreateBulkJob() returns error? {
    BulkJob response = check datacloud->createBulkJob({objectName: OBJECT_NAME, sourceName: SOURCE_NAME, operation: "upsert"});
    test:assertEquals(response.state, "Open");
    test:assertEquals(response.objectName, OBJECT_NAME);
    test:assertEquals(response.systemModstamp, "");
}

@test:Config {
    groups: ["live_tests", "mock_tests"]
}
isolated function testListBulkJobs() returns error? {
    BulkJobList response = check datacloud->listBulkJobs(states = ["Open", "UploadComplete"]);
    test:assertTrue(response.data is BulkJob[]);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testListBulkJobsWithNullFields() returns error? {
    BulkJobList response = check datacloud->listBulkJobs();
    BulkJob[] jobs = response.data ?: [];
    test:assertEquals(jobs.length(), 2);
    test:assertEquals(jobs[1].state, "JobComplete");
    test:assertEquals(jobs[1]?.contentUrl, ());
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testGetBulkJob() returns error? {
    BulkJob response = check datacloud->getBulkJob(JOB_ID);
    test:assertEquals(response.id, JOB_ID);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testUploadBulkJobData() returns error? {
    string csv = string `customer_id,email,first_name,last_name
100000000,alex@example.com,Alex,Perera
`;
    AcceptedResponse response = check datacloud->uploadBulkJobData(JOB_ID, csv);
    test:assertEquals(response.accepted, true);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testUpdateBulkJobState() returns error? {
    BulkJob response = check datacloud->updateBulkJobState(JOB_ID, {state: "UploadComplete"});
    test:assertEquals(response.state, "UploadComplete");
    test:assertEquals(response?.contentUrl, ());
    test:assertEquals(response?.retries, ());
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testDeleteBulkJob() returns error? {
    check datacloud->deleteBulkJob(JOB_ID);
}

// ---------------------------------------------------------------------------------- Profile

@test:Config {
    groups: ["live_tests", "mock_tests"]
}
isolated function testListProfileMetadata() returns error? {
    MetadataResponse response = check datacloud->listProfileMetadata();
    test:assertTrue(response.metadata is ObjectMetadata[]);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testGetProfileMetadata() returns error? {
    MetadataResponse response = check datacloud->getProfileMetadata(PROFILE_DMO);
    ObjectMetadata[] metadata = response.metadata ?: [];
    test:assertEquals(metadata[0].name, PROFILE_DMO);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testQueryProfiles() returns error? {
    QueryResponse response = check datacloud->queryProfiles(PROFILE_DMO, filters = "[ssot__FirstName__c=Iris]",
        fields = ["ssot__Id__c", "ssot__FirstName__c"]);
    record {}[] rows = response.data ?: [];
    test:assertEquals(rows.length(), 1);
    test:assertEquals(rows[0]["ssot__FirstName__c"], "Iris");
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testGetProfile() returns error? {
    QueryResponse response = check datacloud->getProfile(PROFILE_DMO, "iris@example.com", searchKey = "ssot__Email__c");
    test:assertEquals(response.done, true);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testGetProfileChildRecords() returns error? {
    QueryResponse response = check datacloud->getProfileChildRecords(PROFILE_DMO, PROFILE_ID,
        "ssot__ContactPointEmail__dlm");
    record {}[] rows = response.data ?: [];
    test:assertTrue(rows[0]["ssot__ContactPointEmail__dlm"] is map<anydata>);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testGetProfileCalculatedInsight() returns error? {
    QueryResponse response = check datacloud->getProfileCalculatedInsight(PROFILE_DMO, PROFILE_ID, INSIGHT_NAME,
        timeGranularity = "DAY");
    record {}[] rows = response.data ?: [];
    test:assertTrue(rows[0][INSIGHT_NAME] is map<anydata>);
}

// ---------------------------------------------------------------------------------- Calculated insights

@test:Config {
    groups: ["live_tests", "mock_tests"]
}
isolated function testListCalculatedInsightMetadata() returns error? {
    MetadataResponse response = check datacloud->listCalculatedInsightMetadata();
    test:assertTrue(response.metadata is ObjectMetadata[]);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testGetCalculatedInsightMetadata() returns error? {
    MetadataResponse response = check datacloud->getCalculatedInsightMetadata(INSIGHT_NAME);
    ObjectMetadata[] metadata = response.metadata ?: [];
    test:assertEquals(metadata[0].name, INSIGHT_NAME);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testQueryCalculatedInsight() returns error? {
    QueryResponse response = check datacloud->queryCalculatedInsight(INSIGHT_NAME,
        dimensions = ["individual_id__c"], measures = ["total_spend__c"], 'limit = 100);
    record {}[] rows = response.data ?: [];
    test:assertEquals(rows[0]["total_spend__c"], 1250.5d);
    test:assertTrue(response.hasKey("arrowStream"));
}

// ---------------------------------------------------------------------------------- Runs (core org)

@test:Config {
    groups: ["live_tests", "mock_tests"]
}
isolated function testListIdentityResolutionRulesets() returns error? {
    IdentityResolutionRulesetList response = check datacloud->listIdentityResolutionRulesets();
    test:assertTrue(response.rulesets is IdentityResolutionRuleset[]);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testRunIdentityResolutionRuleset() returns error? {
    RunResult response = check datacloud->runIdentityResolutionRuleset("1irXX0000000001AAA");
    test:assertEquals(response.resultCode, "SuccessfullySubmittedIdentityResolutionJobRunRequest");
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testRunCalculatedInsight() returns error? {
    RunResult response = check datacloud->runCalculatedInsight(INSIGHT_NAME);
    test:assertEquals(response.success, true);
}

// ---------------------------------------------------------------------------------- Authentication

@test:Config {
    groups: ["mock_tests"]
}
isolated function testDataCloudTokenIsCached() returns error? {
    _ = check datacloud->listProfileMetadata();
    int exchanges = getExchangeCount();
    _ = check datacloud->listCalculatedInsightMetadata();
    _ = check datacloud->getBulkJob(JOB_ID);
    test:assertEquals(getExchangeCount(), exchanges, "The Data Cloud token should be reused until it expires");
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testRefreshTokenGrant() returns error? {
    int tokenRequests = getOauth2TokenRequestCount();
    Client refreshTokenClient = check new ({auth: {clientId, clientSecret, refreshToken}}, MOCK_TENANT_URL + "/");
    MetadataResponse metadata = check refreshTokenClient->listProfileMetadata();
    test:assertTrue(metadata.metadata is ObjectMetadata[]);
    RunResult result = check refreshTokenClient->runCalculatedInsight(INSIGHT_NAME);
    test:assertEquals(result.success, true);
    // The default token URL is replaced with the org's own `/services/oauth2/token`, here the mock, and one
    // token serves both the token exchange and the Runs operations.
    test:assertEquals(getOauth2TokenRequestCount(), tokenRequests + 1);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testClientCredentialsGrant() returns error? {
    int tokenRequests = getOauth2TokenRequestCount();
    Client clientCredentialsClient = check new ({auth: {clientId, clientSecret}}, MOCK_TENANT_URL);
    BulkJob job = check clientCredentialsClient->getBulkJob(JOB_ID);
    test:assertEquals(job.id, JOB_ID);
    IdentityResolutionRulesetList rulesets = check clientCredentialsClient->listIdentityResolutionRulesets();
    test:assertTrue(rulesets.rulesets is IdentityResolutionRuleset[]);
    test:assertEquals(getOauth2TokenRequestCount(), tokenRequests + 1);
}

@test:Config {
    groups: ["mock_tests"],
    dependsOn: [testDataCloudTokenIsCached]
}
isolated function testExchangesAgainOnUnauthorized() returns error? {
    _ = check datacloud->getBulkJob(JOB_ID);
    int exchanges = getExchangeCount();
    http:Client mockControl = check new (MOCK_TENANT_URL);
    http:Response _ = check mockControl->post("/test/revoke", ());

    BulkJob job = check datacloud->getBulkJob(JOB_ID);
    test:assertEquals(job.id, JOB_ID);
    test:assertEquals(getExchangeCount(), exchanges + 1);

    http:Response _ = check mockControl->post("/test/revoke", ());
    check datacloud->deleteBulkJob(JOB_ID);
    test:assertEquals(getExchangeCount(), exchanges + 2);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testExchangesAgainBeforeExpiry() returns error? {
    int exchanges = getExchangeCount();
    _ = check shortLivedTokenClient->listProfileMetadata();
    // The mock issues 1-second tokens for this data space; the client renews them half way through.
    runtime:sleep(1);
    _ = check shortLivedTokenClient->listProfileMetadata();
    test:assertEquals(getExchangeCount(), exchanges + 2);
    test:assertEquals(getLastDataspace(), SHORT_LIVED_DATASPACE);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testDataspaceIsOmittedByDefault() returns error? {
    Client freshClient = check new ({auth: {token: MOCK_CORE_TOKEN}}, MOCK_TENANT_URL);
    _ = check freshClient->listCalculatedInsightMetadata();
    test:assertEquals(getLastDataspace(), ());
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testInvalidCoreToken() returns error? {
    MetadataResponse|error tenantResponse = invalidTokenClient->listProfileMetadata();
    if tenantResponse !is error {
        test:assertFail("Expected the token exchange to fail for an invalid core token");
    }
    test:assertTrue(tenantResponse.message().startsWith("Failed to exchange the Salesforce access token"));
    test:assertTrue(tenantResponse.message().includes("invalid subject token"));

    IdentityResolutionRulesetList|error coreResponse = invalidTokenClient->listIdentityResolutionRulesets();
    if coreResponse !is http:ClientRequestError {
        test:assertFail("Expected an http:ClientRequestError for an invalid core token");
    }
    test:assertEquals(coreResponse.detail().statusCode, 401);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testToBaseUrl() {
    test:assertEquals(toBaseUrl("abc123.c360a.salesforce.com"), "https://abc123.c360a.salesforce.com");
    test:assertEquals(toBaseUrl("https://abc123.c360a.salesforce.com/"), "https://abc123.c360a.salesforce.com");
    test:assertEquals(toBaseUrl(" acme.my.salesforce.com// "), "https://acme.my.salesforce.com");
    test:assertEquals(toBaseUrl("http://localhost:9090"), "http://localhost:9090");
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testApiVersionWithoutPrefix() returns error? {
    Client unprefixedClient = check new ({auth: {token: MOCK_CORE_TOKEN}}, MOCK_TENANT_URL, apiVersion = "62");
    RunResult result = check unprefixedClient->runCalculatedInsight(INSIGHT_NAME);
    test:assertEquals(result.success, true);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testResolveTokenUrl() {
    string orgUrl = "https://acme.my.salesforce.com";
    var refreshGrant = resolveTokenUrl({clientId, clientSecret, refreshToken}, orgUrl);
    test:assertTrue(refreshGrant is OAuth2RefreshTokenGrantConfig);
    if refreshGrant is OAuth2RefreshTokenGrantConfig {
        test:assertEquals(refreshGrant.refreshUrl, orgUrl + "/services/oauth2/token");
    }
    var clientCredentialsGrant = resolveTokenUrl({clientId, clientSecret}, orgUrl);
    if clientCredentialsGrant is OAuth2ClientCredentialsGrantConfig {
        test:assertEquals(clientCredentialsGrant.tokenUrl, orgUrl + "/services/oauth2/token");
    } else {
        test:assertFail("Expected a client credentials grant");
    }
    var passwordGrant = resolveTokenUrl({username: "user@example.com", password: "secret", clientId, clientSecret},
                                        orgUrl);
    if passwordGrant is OAuth2PasswordGrantConfig {
        test:assertEquals(passwordGrant.tokenUrl, orgUrl + "/services/oauth2/token");
    } else {
        test:assertFail("Expected a password grant");
    }
    string sandboxUrl = "https://test.salesforce.com/services/oauth2/token";
    var customGrant = resolveTokenUrl({clientId, clientSecret, refreshToken, refreshUrl: sandboxUrl}, orgUrl);
    if customGrant is OAuth2RefreshTokenGrantConfig {
        test:assertEquals(customGrant.refreshUrl, sandboxUrl);
    } else {
        test:assertFail("Expected a refresh token grant");
    }
    test:assertEquals(resolveTokenUrl({token: "abc"}, orgUrl), {token: "abc"});
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testToTokenLifetime() {
    test:assertEquals(toTokenLifetime(7199), 7199d);
    test:assertEquals(toTokenLifetime(7199.5d), 7199.5d);
    test:assertEquals(toTokenLifetime("7199"), 7199d);
    test:assertEquals(toTokenLifetime(()), DEFAULT_TOKEN_LIFETIME);
    test:assertEquals(toTokenLifetime("two hours"), DEFAULT_TOKEN_LIFETIME);
    test:assertEquals(toTokenLifetime(0), DEFAULT_TOKEN_LIFETIME);
}

@test:Config {
    groups: ["mock_tests"]
}
function testEveryTenantOperationRecoversFromUnauthorized() returns error? {
    Client recoveringClient = check new ({auth: {token: MOCK_CORE_TOKEN}}, MOCK_TENANT_URL);
    http:Client mockControl = check new (MOCK_TENANT_URL);
    string csv = string `customer_id,email
100000000,alex@example.com
`;
    (function () returns any|error)[] operations = [
        function() returns any|error {
            return recoveringClient->upsertRecords(SOURCE_NAME, OBJECT_NAME, records);
        },
        function() returns any|error {
            return recoveringClient->deleteRecords(SOURCE_NAME, OBJECT_NAME, {ids: ["100000000"]});
        },
        function() returns any|error {
            return recoveringClient->validateRecords(SOURCE_NAME, OBJECT_NAME, records);
        },
        function() returns any|error {
            return recoveringClient->listBulkJobs();
        },
        function() returns any|error {
            return recoveringClient->createBulkJob({objectName: OBJECT_NAME, sourceName: SOURCE_NAME, operation: "delete"});
        },
        function() returns any|error {
            return recoveringClient->getBulkJob(JOB_ID);
        },
        function() returns any|error {
            return recoveringClient->deleteBulkJob(JOB_ID);
        },
        function() returns any|error {
            return recoveringClient->updateBulkJobState(JOB_ID, {state: "Aborted"});
        },
        function() returns any|error {
            return recoveringClient->uploadBulkJobData(JOB_ID, csv);
        },
        function() returns any|error {
            return recoveringClient->listProfileMetadata();
        },
        function() returns any|error {
            return recoveringClient->getProfileMetadata(PROFILE_DMO);
        },
        function() returns any|error {
            return recoveringClient->queryProfiles(PROFILE_DMO, filters = "[ssot__FirstName__c=Iris]");
        },
        function() returns any|error {
            return recoveringClient->getProfile(PROFILE_DMO, PROFILE_ID);
        },
        function() returns any|error {
            return recoveringClient->getProfileChildRecords(PROFILE_DMO, PROFILE_ID, "ssot__ContactPointEmail__dlm");
        },
        function() returns any|error {
            return recoveringClient->getProfileCalculatedInsight(PROFILE_DMO, PROFILE_ID, INSIGHT_NAME);
        },
        function() returns any|error {
            return recoveringClient->listCalculatedInsightMetadata();
        },
        function() returns any|error {
            return recoveringClient->getCalculatedInsightMetadata(INSIGHT_NAME);
        },
        function() returns any|error {
            return recoveringClient->queryCalculatedInsight(INSIGHT_NAME);
        },
        function() returns any|error {
            return recoveringClient->querySql({sql: "SELECT customer_id__c FROM CustomerOrders_customers__dll LIMIT 3"});
        },
        function() returns any|error {
            return recoveringClient->getNextSqlQueryBatch("batch-2");
        }
    ];
    // Obtain a first token, so that every operation below starts with one the tenant endpoint then rejects.
    _ = check recoveringClient->listProfileMetadata();
    foreach int i in 0 ..< operations.length() {
        http:Response _ = check mockControl->post("/test/revoke", ());
        int exchanges = getExchangeCount();
        function () returns any|error operation = operations[i];
        any|error result = operation();
        if result is error {
            test:assertFail(string `Operation ${i} failed after its token was rejected: ${result.message()}`);
        }
        test:assertEquals(getExchangeCount(), exchanges + 1, string `Operation ${i} did not exchange again`);
    }
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testConnectionSettingsApplyToEveryHost() returns error? {
    Client configuredClient = check new ({
        auth: {token: MOCK_CORE_TOKEN},
        httpVersion: http:HTTP_1_1,
        timeout: 10,
        followRedirects: {enabled: true, maxCount: 3},
        poolConfig: {maxActiveConnections: 10},
        circuitBreaker: {rollingWindow: {timeWindow: 10, bucketSize: 2}, failureThreshold: 0.5, resetTime: 5},
        retryConfig: {count: 2, interval: 1},
        cookieConfig: {enabled: true},
        secureSocket: {enable: false}
    }, MOCK_TENANT_URL, apiVersion = "v62.0");
    MetadataResponse metadata = check configuredClient->listCalculatedInsightMetadata();
    test:assertTrue(metadata.metadata is ObjectMetadata[]);
    RunResult result = check configuredClient->runIdentityResolutionRuleset("1irXX0000000001AAA");
    test:assertEquals(result.resultCode, "SuccessfullySubmittedIdentityResolutionJobRunRequest");
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testUnsupportedApiVersion() returns error? {
    Client oldVersionClient = check new ({auth: {token: MOCK_CORE_TOKEN}}, MOCK_TENANT_URL, apiVersion = "v56.0");
    RunResult|error result = oldVersionClient->runCalculatedInsight(INSIGHT_NAME);
    test:assertTrue(result is http:ClientRequestError, "The Runs operations should go to the configured API version");
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testMalformedTokenExchangeResponse() returns error? {
    Client malformedClient = check new ({auth: {token: MOCK_CORE_TOKEN}}, MOCK_TENANT_URL,
        dataspace = MALFORMED_RESPONSE_DATASPACE
    );
    MetadataResponse|error response = malformedClient->listProfileMetadata();
    if response !is error {
        test:assertFail("Expected an error for a token exchange response without a token");
    }
    test:assertTrue(response.message().startsWith("Unexpected response from the Data Cloud token exchange"));
}

@test:Config {
    groups: ["mock_tests"]
}
function testRevokedCoreTokenIsRenewedForRuns() returns error? {
    Client renewingClient = check new ({auth: {clientId, clientSecret, refreshToken}}, MOCK_TENANT_URL);
    _ = check renewingClient->listIdentityResolutionRulesets();
    int tokenRequests = getOauth2TokenRequestCount();
    http:Client mockControl = check new (MOCK_TENANT_URL);
    http:Response _ = check mockControl->post("/test/revoke-core", ());

    RunResult result = check renewingClient->runIdentityResolutionRuleset("1irXX0000000001AAA");
    test:assertEquals(result.resultCode, "SuccessfullySubmittedIdentityResolutionJobRunRequest");
    test:assertEquals(getOauth2TokenRequestCount(), tokenRequests + 1);
}

@test:Config {
    groups: ["mock_tests"]
}
function testRevokedCoreTokenIsRenewedForExchange() returns error? {
    Client renewingClient = check new ({auth: {clientId, clientSecret}}, MOCK_TENANT_URL);
    _ = check renewingClient->listCalculatedInsightMetadata();
    int tokenRequests = getOauth2TokenRequestCount();
    http:Client mockControl = check new (MOCK_TENANT_URL);
    http:Response _ = check mockControl->post("/test/revoke-core", ());
    http:Response _ = check mockControl->post("/test/revoke", ());

    // The tenant rejects the Data Cloud token, the exchange rejects the cached core token, and the client
    // fetches a new core token, exchanges it and retries the call.
    MetadataResponse metadata = check renewingClient->listCalculatedInsightMetadata();
    test:assertTrue(metadata.metadata is ObjectMetadata[]);
    test:assertEquals(getOauth2TokenRequestCount(), tokenRequests + 1);
    // The Runs operations use the renewed token as well.
    RunResult result = check renewingClient->runCalculatedInsight(INSIGHT_NAME);
    test:assertEquals(result.success, true);
    test:assertEquals(getOauth2TokenRequestCount(), tokenRequests + 1);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testInvalidOAuth2Credentials() {
    Client|error result = new ({auth: {clientId, clientSecret: "wrong-secret", refreshToken}}, MOCK_TENANT_URL);
    if result !is error {
        test:assertFail("Expected initialization to fail for invalid OAuth2 credentials");
    }
    test:assertTrue(result.message().startsWith("Failed to get a Salesforce access token"));
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testFriendlyNamesUseApiNamesOnTheWire() returns error? {
    // `orderBy` goes out as the API's `orderby` query parameter.
    QueryResponse rows = check datacloud->queryProfiles(PROFILE_DMO, filters = "[ssot__FirstName__c=Iris]",
        orderBy = "ssot__FirstName__c ASC");
    test:assertEquals(rows.done, true);
    // `objectName` goes out as the API's `object` JSON key (the mock rejects anything else) and binds back.
    BulkJob job = check datacloud->createBulkJob({objectName: OBJECT_NAME, sourceName: SOURCE_NAME, operation: "delete"});
    test:assertEquals(job.objectName, OBJECT_NAME);
    test:assertEquals(job.operation, "delete");
    // `dataType` binds from the API's `type` JSON key.
    MetadataResponse metadata = check datacloud->getProfileMetadata(PROFILE_DMO);
    FieldMetadata[] fields = (metadata.metadata ?: [])[0].fields ?: [];
    test:assertEquals(fields[0].dataType, "STRING");
}

@test:Config {
    groups: ["mock_tests"]
}
function testOtherExchangeErrorsKeepTheCoreToken() returns error? {
    Client unknownSpaceClient = check new ({auth: {clientId, clientSecret, refreshToken}}, MOCK_TENANT_URL,
        dataspace = UNKNOWN_DATASPACE);
    int tokenRequests = getOauth2TokenRequestCount();
    MetadataResponse|error response = unknownSpaceClient->listProfileMetadata();
    if response !is error {
        test:assertFail("Expected the token exchange to fail for an unknown data space");
    }
    test:assertTrue(response.message().includes("invalid_dataspace"));
    // Only a rejected core token is worth renewing.
    test:assertEquals(getOauth2TokenRequestCount(), tokenRequests);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testFixedTokenIsNotRetried() returns error? {
    int runsRequests = getRunsRequestCount();
    RunResult|error response = invalidTokenClient->runCalculatedInsight(INSIGHT_NAME);
    test:assertTrue(response is http:ClientRequestError);
    // A plain access token can't be renewed, so the rejected call isn't repeated.
    test:assertEquals(getRunsRequestCount(), runsRequests + 1);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testDataCloudNotSetUp() returns error? {
    Client notSetUpClient = check new ({auth: {token: MOCK_CORE_TOKEN}}, MOCK_TENANT_URL, dataspace = NOT_SET_UP_DATASPACE);
    MetadataResponse|error response = notSetUpClient->listProfileMetadata();
    if response !is error {
        test:assertFail("Expected an error when the exchange returns no tenant endpoint");
    }
    test:assertTrue(response.message().includes("Data Cloud isn't set up in this org yet"));
}

// ---------------------------------------------------------------------------------- SQL queries

@test:Config {
    groups: ["live_tests", "mock_tests"]
}
isolated function testQuerySql() returns error? {
    SqlQueryResponse response = check datacloud->querySql({
        sql: "SELECT ssot__Id__c, ssot__FirstName__c FROM ssot__Individual__dlm LIMIT 1"
    });
    test:assertTrue(response.data is anydata[][]);
    test:assertTrue(response.metadata is record {|SqlColumn...;|});
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testQuerySqlInBatches() returns error? {
    SqlQueryResponse first = check datacloud->querySql({
        sql: "SELECT customer_id__c, first_name__c, total_spend__c FROM CustomerOrders_customers__dll LIMIT 3"
    });
    anydata[][] rows = first.data ?: [];
    test:assertEquals(first.done, false);
    test:assertEquals(rows.length(), 2);
    test:assertEquals(rows[0][1], "Alex");
    test:assertEquals(rows[0][2], 1250.5d);
    record {|SqlColumn...;|} columns = first.metadata ?: {};
    test:assertEquals(columns["total_spend__c"]?.dataType, "DECIMAL");
    test:assertEquals(columns["first_name__c"]?.placeInOrder, 1);

    string? nextBatchId = first?.nextBatchId;
    if nextBatchId is () {
        test:assertFail("Expected a next batch");
    }
    SqlQueryResponse last = check datacloud->getNextSqlQueryBatch(nextBatchId);
    test:assertEquals(last.done, true);
    test:assertEquals(last?.nextBatchId, ());
    anydata[][] lastRows = last.data ?: [];
    test:assertEquals(lastRows[0], ["100000003", "Kim", ()]);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testQuerySqlErrors() returns error? {
    SqlQueryResponse|error badSql = datacloud->querySql({sql: "SELEC nonsense"});
    test:assertTrue(badSql is http:ClientRequestError);
    if badSql is http:ClientRequestError {
        test:assertEquals(badSql.detail().statusCode, 400);
    }
    SqlQueryResponse|error unknownBatch = datacloud->getNextSqlQueryBatch("not-a-batch-id");
    test:assertTrue(unknownBatch is http:ClientRequestError);
    if unknownBatch is http:ClientRequestError {
        test:assertEquals(unknownBatch.detail().statusCode, 404);
    }
}

// ---------------------------------------------------------------------------------- JWT bearer grant

@test:Config {
    groups: ["mock_tests"]
}
function testJwtBearerGrant() returns error? {
    int tokenRequests = getOauth2TokenRequestCount();
    Client jwtClient = check new ({
        auth: {clientId, username: MOCK_JWT_USERNAME, privateKey: {keyFile: "tests/resources/jwt-test-key.pem"}}
    }, MOCK_TENANT_URL);
    MetadataResponse metadata = check jwtClient->listProfileMetadata();
    test:assertTrue(metadata.metadata is ObjectMetadata[]);
    RunResult result = check jwtClient->runCalculatedInsight(INSIGHT_NAME);
    test:assertEquals(result.success, true);
    // One signed assertion serves both the token exchange and the Runs operations, at the org's token endpoint.
    test:assertEquals(getOauth2TokenRequestCount(), tokenRequests + 1);
}

@test:Config {
    groups: ["mock_tests"]
}
function testJwtBearerGrantRenewsRejectedToken() returns error? {
    Client jwtClient = check new ({
        auth: {clientId, username: MOCK_JWT_USERNAME, privateKey: {keyFile: "tests/resources/jwt-test-key.pem"}}
    }, MOCK_TENANT_URL);
    _ = check jwtClient->listIdentityResolutionRulesets();
    int tokenRequests = getOauth2TokenRequestCount();
    http:Client mockControl = check new (MOCK_TENANT_URL);
    http:Response _ = check mockControl->post("/test/revoke-core", ());
    http:Response _ = check mockControl->post("/test/revoke", ());

    // The Runs call gets a 401, the client signs a new assertion, and both hosts work again.
    IdentityResolutionRulesetList rulesets = check jwtClient->listIdentityResolutionRulesets();
    test:assertTrue(rulesets.rulesets is IdentityResolutionRuleset[]);
    MetadataResponse metadata = check jwtClient->listCalculatedInsightMetadata();
    test:assertTrue(metadata.metadata is ObjectMetadata[]);
    test:assertEquals(getOauth2TokenRequestCount(), tokenRequests + 1);
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testJwtBearerGrantRejected() {
    Client|error wrongKey = new ({
        auth: {clientId, username: MOCK_JWT_USERNAME, privateKey: {keyFile: "tests/resources/jwt-other-key.pem"}}
    }, MOCK_TENANT_URL);
    if wrongKey !is error {
        test:assertFail("Expected an assertion signed with an unknown key to be rejected");
    }
    test:assertTrue(wrongKey.message().startsWith("Failed to get a Salesforce access token with the JWT bearer grant"));

    Client|error wrongUser = new ({
        auth: {clientId, username: "someone.else@example.com", privateKey: {keyFile: "tests/resources/jwt-test-key.pem"}}
    }, MOCK_TENANT_URL);
    if wrongUser !is error {
        test:assertFail("Expected an assertion for an unapproved user to be rejected");
    }
    test:assertTrue(wrongUser.message().includes("user hasn't approved this consumer"));
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testResolveJwtBearerTokenUrl() {
    var jwtGrant = resolveTokenUrl({clientId, username: MOCK_JWT_USERNAME, privateKey: {keyFile: "key.pem"}},
        "https://acme.my.salesforce.com");
    if jwtGrant is OAuth2JwtBearerGrantConfig {
        test:assertEquals(jwtGrant?.tokenUrl, "https://acme.my.salesforce.com/services/oauth2/token");
        test:assertEquals(jwtGrant?.audience, "https://login.salesforce.com");
    } else {
        test:assertFail("Expected a JWT bearer grant");
    }
}

@test:Config {
    groups: ["mock_tests"]
}
function testRunCalculatedInsightRetriesWithRenewedToken() returns error? {
    Client renewingClient = check new ({auth: {clientId, clientSecret, refreshToken}}, MOCK_TENANT_URL);
    _ = check renewingClient->listIdentityResolutionRulesets();
    int tokenRequests = getOauth2TokenRequestCount();
    http:Client mockControl = check new (MOCK_TENANT_URL);
    http:Response _ = check mockControl->post("/test/revoke-core", ());

    RunResult result = check renewingClient->runCalculatedInsight(INSIGHT_NAME);
    test:assertEquals(result.success, true);
    test:assertEquals(getOauth2TokenRequestCount(), tokenRequests + 1);
}

@test:Config {
    groups: ["mock_tests"]
}
function testCoreTokenRenewalFails() returns error? {
    Client renewingClient = check new ({auth: {clientId, clientSecret, refreshToken}}, MOCK_TENANT_URL);
    _ = check renewingClient->listIdentityResolutionRulesets();
    http:Client mockControl = check new (MOCK_TENANT_URL);
    http:Response _ = check mockControl->post("/test/revoke-core", ());
    http:Response _ = check mockControl->post("/test/oauth2-unavailable", true);
    RunResult|error result = renewingClient->runIdentityResolutionRuleset("1irXX0000000001AAA");
    http:Response _ = check mockControl->post("/test/oauth2-unavailable", false);

    if result !is error {
        test:assertFail("Expected an error when the org refuses to issue a new token");
    }
    test:assertEquals(result.message(), "Failed to fetch a new Salesforce access token from the configured OAuth2 grant.");
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testConnectionSettingsKeepProxy() {
    ConnectionSettings settings = toConnectionSettings({
        auth: {token: MOCK_CORE_TOKEN},
        proxy: {host: "proxy.example.com", port: 3128}
    });
    test:assertEquals(settings?.proxy?.host, "proxy.example.com");
    test:assertEquals(settings?.proxy?.port, 3128);
}
