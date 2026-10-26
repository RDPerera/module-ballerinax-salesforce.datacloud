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

import ballerina/crypto;
import ballerina/http;
import ballerina/jwt;
import ballerina/time;
import ballerina/url;

// The token URL the generated OAuth2 configs default to. When it is left as is, the connector sends
// token requests to the org's own My Domain instead, which every grant type accepts (client
// credentials accepts nothing else).
const DEFAULT_TOKEN_URL = "https://login.salesforce.com/services/oauth2/token";
const OAUTH2_TOKEN_PATH = "/services/oauth2/token";
const DATA_CLOUD_TOKEN_PATH = "/services/a360/token";
const CDP_GRANT_TYPE = "urn:salesforce:grant-type:external:cdp";
const ACCESS_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:access_token";
const AUTH_HEADER_PREFIX = "Bearer ";
const JWT_BEARER_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:jwt-bearer";
// Salesforce rejects JWT bearer assertions that expire more than 3 minutes after they are issued.
const decimal JWT_ASSERTION_LIFETIME = 180;
// Exchange again this many seconds (at most half the token's lifetime) before the Data Cloud token expires.
const decimal TOKEN_EXPIRY_SKEW = 60;
// OAuth 2.0 errors with which the token exchange rejects the core token (e.g. `invalid subject token`).
final readonly & string[] SUBJECT_TOKEN_ERRORS = ["invalid_request", "invalid_grant", "invalid_token"];
// Assumed lifetime when the exchange response carries no `expires_in`.
const decimal DEFAULT_TOKEN_LIFETIME = 900;

# OAuth 2.0 JWT bearer grant configuration. For every token request the connector signs a new short-lived JWT
# with the private key, whose certificate is uploaded to the External Client App, and exchanges it for an org
# access token.
public type OAuth2JwtBearerGrantConfig record {|
    # Consumer key of the External Client App (the JWT issuer)
    string clientId;
    # Username of the Salesforce user the connector acts as (the JWT subject). The user must be approved for the app
    string username;
    # The private key to sign the JWT with: a PEM key file, or a key in a PKCS#12 keystore
    JwtSigningKeyFile|JwtSigningKeyStore privateKey;
    # Audience of the JWT: `https://login.salesforce.com` for production orgs, `https://test.salesforce.com` for sandboxes
    string audience = "https://login.salesforce.com";
    # Token endpoint. Left at its default, token requests go to the org's own `/services/oauth2/token`
    string tokenUrl = DEFAULT_TOKEN_URL;
    # How long (in seconds) an org access token is reused. Salesforce token responses carry no expiry
    decimal defaultTokenExpTime = 3600;
|};

# A PEM private key file to sign JWT bearer assertions with.
public type JwtSigningKeyFile record {|
    # Path to the PEM private key file
    string keyFile;
    # Password of the private key, if it is encrypted
    string keyPassword?;
|};

# A private key in a PKCS#12 keystore to sign JWT bearer assertions with.
public type JwtSigningKeyStore record {|
    # The keystore
    crypto:KeyStore keyStore;
    # Alias of the private key in the keystore
    string keyAlias;
    # Password of the private key
    string keyPassword;
|};

// The token exchange rejected the core token, which may have expired or been revoked.
type SubjectTokenRejectedError distinct error;

// Response of the Data Cloud token exchange (`POST /services/a360/token`).
type DataCloudTokenResponse record {
    string access_token;
    // Tenant endpoint, observed without a scheme (e.g. `abc123.c360a.salesforce.com`)
    string instance_url;
    int|decimal|string expires_in?;
};

# Write records to Salesforce Data Cloud (Data 360), read unified profiles and calculated insights back,
# and trigger the identity resolution and insight runs that build them.
#
# Data Cloud serves its APIs from two hosts with two different tokens. The `Runs` operations go to the
# core Salesforce org with the core access token. Every other operation goes to the Data Cloud tenant
# endpoint with a Data Cloud token. This client takes the core org credentials only: on the first tenant
# call it exchanges the core token at `POST {serviceUrl}/services/a360/token` for a Data Cloud token and
# the tenant endpoint, caches both, exchanges again shortly before the token expires, and on a `401` from
# the tenant endpoint exchanges again and retries the call once. When the org rejects the core token
# itself, the client fetches a new one from the configured OAuth2 grant and retries once.
public isolated client class Client {
    private final http:Client tokenClient;
    private final CoreAuthConfig & readonly coreAuth;
    private final ConnectionSettings & readonly connectionSettings;
    private final string coreUrl;
    private final string? dataspace;

    // The single source of core tokens, for both the Runs operations and the token exchange. Replaced to
    // force a new token when the org rejects the cached one.
    private http:ClientOAuth2Handler|JwtBearerTokenProvider|string coreTokenProvider;
    private GeneratedClient? coreClient = ();
    private string coreClientToken = "";

    private GeneratedClient? tenantClient = ();
    private string dataCloudToken = "";
    private decimal dataCloudTokenExpiry = 0;

    # Gets invoked to initialize the `connector`.
    #
    # + config - The configurations to be used when initializing the `connector`. `auth` holds the core
    #            Salesforce org credentials (OAuth 2.0 refresh token, client credentials or password grant, or
    #            an access token) of a connected app with the `api`, `cdp_ingest_api`, `cdp_profile_api` and
    #            `cdp_query_api` scopes. If `tokenUrl`/`refreshUrl` is left at its default, token requests go
    #            to `{serviceUrl}/services/oauth2/token`
    # + serviceUrl - URL of the core Salesforce org (its My Domain), e.g. `https://acme.my.salesforce.com`.
    #                Not the Data Cloud tenant endpoint, which is discovered through the token exchange
    # + apiVersion - Salesforce REST API version for the `Runs` operations, e.g. `v62.0`. Needs v57.0 or later
    # + dataspace - Data space to scope the Data Cloud token to. Omit it to use the default data space
    # + return - An error if connector initialization failed
    public isolated function init(ConnectionConfig config, string serviceUrl, string apiVersion = "v62.0",
            string? dataspace = ()) returns error? {
        string orgUrl = toBaseUrl(serviceUrl);
        string version = apiVersion.startsWith("v") ? apiVersion : "v" + apiVersion;
        version = version.includes(".") ? version : version + ".0";
        CoreAuthConfig & readonly coreAuth = resolveTokenUrl(config.auth, orgUrl).cloneReadOnly();
        self.coreAuth = coreAuth;
        self.connectionSettings = toConnectionSettings(config);
        self.tokenClient = check new (orgUrl, toHttpClientConfig(config));
        self.coreUrl = string `${orgUrl}/services/data/${version}`;
        self.dataspace = dataspace;
        // An OAuth2 grant fetches its first token here, so wrong credentials fail at initialization.
        if coreAuth is http:BearerTokenConfig {
            self.coreTokenProvider = coreAuth.token;
        } else if coreAuth is OAuth2JwtBearerGrantConfig {
            JwtBearerTokenProvider provider = check new (coreAuth, toHttpClientConfig(config));
            _ = check provider.getToken();
            self.coreTokenProvider = provider;
        } else {
            http:ClientOAuth2Handler|error provider = trap new (coreAuth);
            if provider is error {
                return error("Failed to get a Salesforce access token from the configured OAuth2 grant.", provider);
            }
            self.coreTokenProvider = provider;
        }
    }

    # Upsert records via streaming ingestion
    #
    # + sourceName - Name of the Ingestion API connector as shown in Data Cloud setup, e.g. `CustomerOrders`
    # + objectName - Object name from the connector's schema
    # + payload - The records to upsert. Every field defined in the object's schema must be present in each record
    # + headers - Headers to be sent with the request
    # + return - Records queued for asynchronous processing
    remote isolated function upsertRecords(string sourceName, string objectName, IngestRecords payload,
            map<string|string[]> headers = {}) returns AcceptedResponse|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        AcceptedResponse|error response = tenant->upsertRecords(sourceName, objectName, payload, headers);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->upsertRecords(sourceName, objectName, payload, headers);
        }
        return response;
    }

    # Delete records by primary key via streaming ingestion
    #
    # + sourceName - Name of the Ingestion API connector as shown in Data Cloud setup, e.g. `CustomerOrders`
    # + objectName - Object name from the connector's schema
    # + payload - The primary keys of the records to delete (max 200)
    # + headers - Headers to be sent with the request
    # + return - Records queued for asynchronous processing
    remote isolated function deleteRecords(string sourceName, string objectName, DeleteRecordsRequest payload,
            map<string|string[]> headers = {}) returns AcceptedResponse|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        AcceptedResponse|error response = tenant->deleteRecords(sourceName, objectName, payload, headers);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->deleteRecords(sourceName, objectName, payload, headers);
        }
        return response;
    }

    # Validate records against the object schema without ingesting them
    #
    # + sourceName - Name of the Ingestion API connector as shown in Data Cloud setup, e.g. `CustomerOrders`
    # + objectName - Object name from the connector's schema
    # + payload - The records to validate
    # + headers - Headers to be sent with the request
    # + return - All records are valid (nothing is stored)
    remote isolated function validateRecords(string sourceName, string objectName, IngestRecords payload,
            map<string|string[]> headers = {}) returns AcceptedResponse|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        AcceptedResponse|error response = tenant->validateRecords(sourceName, objectName, payload, headers);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->validateRecords(sourceName, objectName, payload, headers);
        }
        return response;
    }

    # List bulk ingestion jobs
    #
    # + headers - Headers to be sent with the request
    # + queries - Queries to be sent with the request
    # + return - Jobs
    remote isolated function listBulkJobs(map<string|string[]> headers = {}, *ListBulkJobsQueries queries)
            returns BulkJobList|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        BulkJobList|error response = tenant->listBulkJobs(headers, queries = queries);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->listBulkJobs(headers, queries = queries);
        }
        return response;
    }

    # Create a bulk ingestion job
    #
    # + payload - The job to create
    # + headers - Headers to be sent with the request
    # + return - Job created in the `Open` state
    remote isolated function createBulkJob(CreateBulkJobRequest payload, map<string|string[]> headers = {})
            returns BulkJob|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        BulkJob|error response = tenant->createBulkJob(payload, headers);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->createBulkJob(payload, headers);
        }
        return response;
    }

    # Get a bulk ingestion job's status
    #
    # + jobId - Bulk job ID
    # + headers - Headers to be sent with the request
    # + return - Job info
    remote isolated function getBulkJob(string jobId, map<string|string[]> headers = {}) returns BulkJob|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        BulkJob|error response = tenant->getBulkJob(jobId, headers);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->getBulkJob(jobId, headers);
        }
        return response;
    }

    # Delete a bulk ingestion job
    #
    # + jobId - Bulk job ID
    # + headers - Headers to be sent with the request
    # + return - An error if the job could not be deleted
    remote isolated function deleteBulkJob(string jobId, map<string|string[]> headers = {}) returns error? {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        error? response = tenant->deleteBulkJob(jobId, headers);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->deleteBulkJob(jobId, headers);
        }
        return response;
    }

    # Close (UploadComplete) or abort a bulk ingestion job
    #
    # + jobId - Bulk job ID
    # + payload - The new job state
    # + headers - Headers to be sent with the request
    # + return - Updated job info
    remote isolated function updateBulkJobState(string jobId, UpdateBulkJobStateRequest payload,
            map<string|string[]> headers = {}) returns BulkJob|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        BulkJob|error response = tenant->updateBulkJobState(jobId, payload, headers);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->updateBulkJobState(jobId, payload, headers);
        }
        return response;
    }

    # Upload a CSV file to an open bulk ingestion job
    #
    # + jobId - Bulk job ID
    # + payload - The CSV content. Upsert jobs need a header row matching the object's field names; delete
    #             jobs have no header and the primary key in the first column
    # + headers - Headers to be sent with the request
    # + return - File accepted
    remote isolated function uploadBulkJobData(string jobId, string payload, map<string|string[]> headers = {})
            returns AcceptedResponse|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        AcceptedResponse|error response = tenant->uploadBulkJobData(jobId, payload, headers);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->uploadBulkJobData(jobId, payload, headers);
        }
        return response;
    }

    # Get metadata for all profile data model objects
    #
    # + headers - Headers to be sent with the request
    # + return - Metadata of profile-category DMOs
    remote isolated function listProfileMetadata(map<string|string[]> headers = {}) returns MetadataResponse|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        MetadataResponse|error response = tenant->listProfileMetadata(headers);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->listProfileMetadata(headers);
        }
        return response;
    }

    # Get metadata (fields, indexes, relationships) for one profile data model object
    #
    # + dataModelName - API name of a profile-category DMO, e.g. `UnifiedIndividual__dlm`
    # + headers - Headers to be sent with the request
    # + return - Metadata of the DMO
    remote isolated function getProfileMetadata(string dataModelName, map<string|string[]> headers = {})
            returns MetadataResponse|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        MetadataResponse|error response = tenant->getProfileMetadata(dataModelName, headers);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->getProfileMetadata(dataModelName, headers);
        }
        return response;
    }

    # Query profile records with filters
    #
    # + dataModelName - API name of a profile-category DMO, e.g. `UnifiedIndividual__dlm`
    # + headers - Headers to be sent with the request
    # + queries - Queries to be sent with the request
    # + return - Matching rows
    remote isolated function queryProfiles(string dataModelName, map<string|string[]> headers = {},
            *QueryProfilesQueries queries) returns QueryResponse|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        QueryResponse|error response = tenant->queryProfiles(dataModelName, headers, queries = queries);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->queryProfiles(dataModelName, headers, queries = queries);
        }
        return response;
    }

    # Get a profile record by ID (or by secondary key with `searchKey`)
    #
    # + dataModelName - API name of a profile-category DMO, e.g. `UnifiedIndividual__dlm`
    # + recordId - Record ID, or the value of the field named in `searchKey`
    # + headers - Headers to be sent with the request
    # + queries - Queries to be sent with the request
    # + return - Matching rows
    remote isolated function getProfile(string dataModelName, string recordId, map<string|string[]> headers = {},
            *GetProfileQueries queries) returns QueryResponse|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        QueryResponse|error response = tenant->getProfile(dataModelName, recordId, headers, queries = queries);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->getProfile(dataModelName, recordId, headers, queries = queries);
        }
        return response;
    }

    # Get a profile's related child records
    #
    # + dataModelName - API name of a profile-category DMO, e.g. `UnifiedIndividual__dlm`
    # + recordId - Record ID, or the value of the field named in `searchKey`
    # + childDataModelName - API name of a related child DMO, e.g. `ContactPointEmail__dlm`
    # + headers - Headers to be sent with the request
    # + queries - Queries to be sent with the request
    # + return - Matching rows
    remote isolated function getProfileChildRecords(string dataModelName, string recordId, string childDataModelName,
            map<string|string[]> headers = {}, *GetProfileChildRecordsQueries queries) returns QueryResponse|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        QueryResponse|error response = tenant->getProfileChildRecords(dataModelName, recordId, childDataModelName,
            headers, queries = queries);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->getProfileChildRecords(dataModelName, recordId, childDataModelName, headers, queries = queries);
        }
        return response;
    }

    # Get a calculated insight's values for one profile
    #
    # + dataModelName - API name of a profile-category DMO, e.g. `UnifiedIndividual__dlm`
    # + recordId - Record ID, or the value of the field named in `searchKey`
    # + insightName - API name of the calculated insight, e.g. `IndividualSpend__cio`
    # + headers - Headers to be sent with the request
    # + queries - Queries to be sent with the request
    # + return - Matching rows
    remote isolated function getProfileCalculatedInsight(string dataModelName, string recordId, string insightName,
            map<string|string[]> headers = {}, *GetProfileCalculatedInsightQueries queries)
            returns QueryResponse|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        QueryResponse|error response = tenant->getProfileCalculatedInsight(dataModelName, recordId, insightName, headers,
            queries = queries);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->getProfileCalculatedInsight(dataModelName, recordId, insightName, headers, queries = queries);
        }
        return response;
    }

    # Get metadata (dimensions and measures) for all calculated insights
    #
    # + headers - Headers to be sent with the request
    # + return - Calculated insight metadata
    remote isolated function listCalculatedInsightMetadata(map<string|string[]> headers = {}) returns MetadataResponse|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        MetadataResponse|error response = tenant->listCalculatedInsightMetadata(headers);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->listCalculatedInsightMetadata(headers);
        }
        return response;
    }

    # Get metadata (dimensions and measures) for one calculated insight
    #
    # + insightName - API name of the calculated insight, e.g. `IndividualSpend__cio`
    # + headers - Headers to be sent with the request
    # + return - Calculated insight metadata
    remote isolated function getCalculatedInsightMetadata(string insightName, map<string|string[]> headers = {})
            returns MetadataResponse|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        MetadataResponse|error response = tenant->getCalculatedInsightMetadata(insightName, headers);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->getCalculatedInsightMetadata(insightName, headers);
        }
        return response;
    }

    # Query a calculated insight
    #
    # + insightName - API name of the calculated insight, e.g. `IndividualSpend__cio`
    # + headers - Headers to be sent with the request
    # + queries - Queries to be sent with the request
    # + return - Matching rows
    remote isolated function queryCalculatedInsight(string insightName, map<string|string[]> headers = {},
            *QueryCalculatedInsightQueries queries) returns QueryResponse|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        QueryResponse|error response = tenant->queryCalculatedInsight(insightName, headers, queries = queries);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->queryCalculatedInsight(insightName, headers, queries = queries);
        }
        return response;
    }

    # Run a SQL query
    #
    # + payload - The SQL query. It runs synchronously over data lake objects, data model objects and calculated
    #             insights. Rows come back as arrays of column values ordered by each column's `placeInOrder`
    # + headers - Headers to be sent with the request
    # + return - The first batch of results. When `done` is `false`, get the rest with `getNextSqlQueryBatch`
    remote isolated function querySql(SqlQueryRequest payload, map<string|string[]> headers = {})
            returns SqlQueryResponse|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        SqlQueryResponse|error response = tenant->querySql(payload, headers);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->querySql(payload, headers);
        }
        return response;
    }

    # Get the next batch of SQL query results
    #
    # + nextBatchId - The `nextBatchId` of the previous batch
    # + headers - Headers to be sent with the request
    # + return - The next batch of results
    remote isolated function getNextSqlQueryBatch(string nextBatchId, map<string|string[]> headers = {})
            returns SqlQueryResponse|error {
        [GeneratedClient, string] [tenant, token] = check self.getTenantClient();
        SqlQueryResponse|error response = tenant->getNextSqlQueryBatch(nextBatchId, headers);
        if isUnauthorized(response) {
            [tenant, _] = check self.getTenantClient(token);
            return tenant->getNextSqlQueryBatch(nextBatchId, headers);
        }
        return response;
    }

    # List identity resolution rulesets
    #
    # + headers - Headers to be sent with the request
    # + return - Rulesets
    remote isolated function listIdentityResolutionRulesets(map<string|string[]> headers = {})
            returns IdentityResolutionRulesetList|error {
        [GeneratedClient, string] [core, token] = check self.getCoreClient();
        IdentityResolutionRulesetList|error response = core->listIdentityResolutionRulesets(headers);
        if isUnauthorized(response) {
            string newToken;
            [core, newToken] = check self.getCoreClient(token);
            if newToken != token {
                return core->listIdentityResolutionRulesets(headers);
            }
        }
        return response;
    }

    # Run an identity resolution ruleset now
    #
    # + rulesetId - ID or developer name of the identity resolution ruleset
    # + headers - Headers to be sent with the request
    # + return - Run result
    remote isolated function runIdentityResolutionRuleset(string rulesetId, map<string|string[]> headers = {})
            returns RunResult|error {
        [GeneratedClient, string] [core, token] = check self.getCoreClient();
        RunResult|error response = core->runIdentityResolutionRuleset(rulesetId, headers);
        if isUnauthorized(response) {
            string newToken;
            [core, newToken] = check self.getCoreClient(token);
            if newToken != token {
                return core->runIdentityResolutionRuleset(rulesetId, headers);
            }
        }
        return response;
    }

    # Run a calculated insight now
    #
    # + insightName - API name of the calculated insight, e.g. `IndividualSpend__cio`
    # + headers - Headers to be sent with the request
    # + return - Run started
    remote isolated function runCalculatedInsight(string insightName, map<string|string[]> headers = {})
            returns RunResult|error {
        [GeneratedClient, string] [core, token] = check self.getCoreClient();
        RunResult|error response = core->runCalculatedInsight(insightName, headers);
        if isUnauthorized(response) {
            string newToken;
            [core, newToken] = check self.getCoreClient(token);
            if newToken != token {
                return core->runCalculatedInsight(insightName, headers);
            }
        }
        return response;
    }

    // Returns the tenant-endpoint client and the Data Cloud token it carries, exchanging the core token first
    // when there is no token yet, it is about to expire, or it is `staleToken` (the tenant endpoint rejected it).
    private isolated function getTenantClient(string? staleToken = ())
            returns [GeneratedClient, string]|error {
        lock {
            GeneratedClient? tenantClient = self.tenantClient;
            if tenantClient is GeneratedClient && self.dataCloudToken != staleToken
                    && time:monotonicNow() < self.dataCloudTokenExpiry {
                return [tenantClient, self.dataCloudToken];
            }
            DataCloudTokenResponse tokenResponse = check self.exchangeToken();
            decimal lifetime = toTokenLifetime(tokenResponse?.expires_in);
            ConnectionConfig tenantConfig = {...self.connectionSettings, auth: {token: tokenResponse.access_token}};
            // The previous client (and its connection pool) is dropped; this happens about every two hours.
            GeneratedClient newClient = check new (tenantConfig, toBaseUrl(tokenResponse.instance_url));
            self.tenantClient = newClient;
            self.dataCloudToken = tokenResponse.access_token;
            self.dataCloudTokenExpiry = time:monotonicNow() + lifetime - decimal:min(TOKEN_EXPIRY_SKEW, lifetime / 2);
            return [newClient, tokenResponse.access_token];
        }
    }

    // Exchanges the core Salesforce access token for a Data Cloud token. If the exchange rejects the core token
    // (it may have expired or been revoked before the cache noticed), fetches a new one and tries once more.
    private isolated function exchangeToken() returns DataCloudTokenResponse|error {
        string coreToken = check self.getCoreToken();
        DataCloudTokenResponse|error tokenResponse = self.requestDataCloudToken(coreToken);
        if tokenResponse is SubjectTokenRejectedError {
            string newCoreToken = check self.getCoreToken(coreToken);
            if newCoreToken != coreToken {
                return self.requestDataCloudToken(newCoreToken);
            }
        }
        return tokenResponse;
    }

    // Calls the token exchange. Salesforce reports a failed exchange as `200 OK` with an OAuth 2.0 error body
    // (e.g. `{"error": "invalid_request", "error_description": "invalid subject token"}`), so the body is checked
    // as well as the status.
    private isolated function requestDataCloudToken(string coreToken) returns DataCloudTokenResponse|error {
        http:Response response = check self.postTokenExchange(coreToken);
        json|error payload = response.getJsonPayload();
        if response.statusCode < 200 || response.statusCode >= 300 || payload !is map<json>
                || payload.hasKey("error") {
            string|error responseBody = payload is json ? payload.toJsonString() : response.getTextPayload();
            string message = string `Failed to exchange the Salesforce access token for a Data Cloud token. `
                + string `Status: ${response.statusCode}, body: ${responseBody is string ? responseBody : ""}`;
            json errorCode = payload is map<json> ? payload["error"] : ();
            if response.statusCode == http:STATUS_UNAUTHORIZED
                    || (errorCode is string && SUBJECT_TOKEN_ERRORS.indexOf(errorCode) !is ()) {
                return error SubjectTokenRejectedError(message);
            }
            return error(message);
        }
        if payload["access_token"] is string && payload["instance_url"] !is string {
            return error("The Data Cloud token exchange returned no tenant endpoint (`instance_url`): Data Cloud "
                + "isn't set up in this org yet. Start it from Setup > Data Cloud Setup and try again once it's ready.");
        }
        DataCloudTokenResponse|error tokenResponse = payload.cloneWithType();
        if tokenResponse is error {
            return error(string `Unexpected response from the Data Cloud token exchange: ${payload.toJsonString()}`,
                tokenResponse);
        }
        return tokenResponse;
    }

    private isolated function postTokenExchange(string coreToken) returns http:Response|error {
        string body = string `grant_type=${check url:encode(CDP_GRANT_TYPE, "UTF-8")}`
            + string `&subject_token=${check url:encode(coreToken, "UTF-8")}`
            + string `&subject_token_type=${check url:encode(ACCESS_TOKEN_TYPE, "UTF-8")}`;
        // Like Salesforce's own Data Cloud clients, the data space goes in the query string.
        string path = DATA_CLOUD_TOKEN_PATH;
        string? dataspace = self.dataspace;
        if dataspace is string {
            path += string `?dataspace=${check url:encode(dataspace, "UTF-8")}`;
        }
        http:Request request = new;
        request.setTextPayload(body, "application/x-www-form-urlencoded");
        return self.tokenClient->post(path, request);
    }

    // Returns the core-org client and the core token it carries, rebuilding the client when the token changed
    // or is `rejectedToken` (the org returned `401` for it).
    private isolated function getCoreClient(string? rejectedToken = ()) returns [GeneratedClient, string]|error {
        lock {
            string token = check self.getCoreToken(rejectedToken);
            GeneratedClient? coreClient = self.coreClient;
            if coreClient is GeneratedClient && self.coreClientToken == token {
                return [coreClient, token];
            }
            ConnectionConfig coreConfig = {...self.connectionSettings, auth: {token}};
            GeneratedClient newClient = check new (coreConfig, self.coreUrl);
            self.coreClient = newClient;
            self.coreClientToken = token;
            return [newClient, token];
        }
    }

    // Returns the current core Salesforce access token, fetching or refreshing it for OAuth2 grants. If the
    // cached token is `rejectedToken`, replaces the grant's token cache to fetch a new token. A configured
    // access token can't be renewed and is returned as is.
    private isolated function getCoreToken(string? rejectedToken = ()) returns string|error {
        lock {
            http:ClientOAuth2Handler|JwtBearerTokenProvider|string provider = self.coreTokenProvider;
            if provider is string {
                return provider;
            }
            if provider is JwtBearerTokenProvider {
                JwtBearerTokenProvider jwtProvider = <JwtBearerTokenProvider>provider;
                return jwtProvider.getToken(rejectedToken);
            }
            http:ClientOAuth2Handler oauth2Provider = <http:ClientOAuth2Handler>provider;
            string token = check toAccessToken(oauth2Provider);
            CoreAuthConfig & readonly coreAuth = self.coreAuth;
            if token != rejectedToken || coreAuth is http:BearerTokenConfig || coreAuth is OAuth2JwtBearerGrantConfig {
                return token;
            }
            http:ClientOAuth2Handler|error newProvider = trap new (coreAuth);
            if newProvider is error {
                return error("Failed to fetch a new Salesforce access token from the configured OAuth2 grant.",
                    newProvider);
            }
            self.coreTokenProvider = newProvider;
            return toAccessToken(newProvider);
        }
    }
}

// The `auth` options of `ConnectionConfig`.
type CoreAuthConfig OAuth2ClientCredentialsGrantConfig|OAuth2PasswordGrantConfig|http:BearerTokenConfig
    |OAuth2RefreshTokenGrantConfig|OAuth2JwtBearerGrantConfig;

// The `auth` for an `http:Client` built by `GeneratedClient` (see the post-generation steps in `sanitations.md`).
// `http:Client` has no JWT bearer grant that signs a new assertion per request, so a JWT bearer config maps to no
// `auth`; this client always builds its generated clients with an access token instead.
isolated function toHttpClientAuth(CoreAuthConfig auth) returns http:ClientAuthConfig? {
    return auth is OAuth2JwtBearerGrantConfig ? () : auth;
}

// Fetches org access tokens with the OAuth 2.0 JWT bearer grant, signing a new short-lived assertion for every
// token request, and reuses a token for `defaultTokenExpTime` seconds.
distinct isolated class JwtBearerTokenProvider {
    private final http:Client tokenClient;
    private final OAuth2JwtBearerGrantConfig & readonly config;
    private string token = "";
    private decimal tokenExpiry = 0;

    isolated function init(OAuth2JwtBearerGrantConfig & readonly config, http:ClientConfiguration clientConfig)
            returns error? {
        self.config = config;
        self.tokenClient = check new (config.tokenUrl, clientConfig);
    }

    // Returns the cached token, or a new one when there is none yet, it has expired, or it is `rejectedToken`.
    isolated function getToken(string? rejectedToken = ()) returns string|error {
        lock {
            if self.token != "" && self.token != rejectedToken && time:monotonicNow() < self.tokenExpiry {
                return self.token;
            }
            string assertion = check jwt:issue({
                issuer: self.config.clientId,
                username: self.config.username,
                audience: self.config.audience,
                expTime: JWT_ASSERTION_LIFETIME,
                signatureConfig: {config: self.config.privateKey}
            });
            http:Request request = new;
            request.setTextPayload(string `grant_type=${check url:encode(JWT_BEARER_GRANT_TYPE, "UTF-8")}`
                + string `&assertion=${assertion}`, "application/x-www-form-urlencoded");
            http:Response response = check self.tokenClient->post("", request);
            json|error payload = response.getJsonPayload();
            if response.statusCode < 200 || response.statusCode >= 300 || payload !is map<json>
                    || payload["access_token"] !is string {
                string|error body = payload is json ? payload.toJsonString() : response.getTextPayload();
                return error(string `Failed to get a Salesforce access token with the JWT bearer grant. `
                    + string `Status: ${response.statusCode}, body: ${body is string ? body : ""}`);
            }
            self.token = <string>payload["access_token"];
            self.tokenExpiry = time:monotonicNow() + self.config.defaultTokenExpTime;
            return self.token;
        }
    }
}

isolated function toAccessToken(http:ClientOAuth2Handler provider) returns string|error {
    map<string|string[]> securityHeaders = check provider.getSecurityHeaders();
    string|string[]? authHeader = securityHeaders[http:AUTH_HEADER];
    if authHeader is string && authHeader.startsWith(AUTH_HEADER_PREFIX) {
        return authHeader.substring(AUTH_HEADER_PREFIX.length());
    }
    return error("Failed to obtain the Salesforce access token from the configured OAuth2 grant.");
}

// Points OAuth2 grants still on the default token URL at the org's own token endpoint.
isolated function resolveTokenUrl(CoreAuthConfig auth, string orgUrl) returns CoreAuthConfig {
    string orgTokenUrl = orgUrl + OAUTH2_TOKEN_PATH;
    if auth is OAuth2RefreshTokenGrantConfig && auth.refreshUrl == DEFAULT_TOKEN_URL {
        OAuth2RefreshTokenGrantConfig resolved = {...auth};
        resolved.refreshUrl = orgTokenUrl;
        return resolved;
    }
    if auth is OAuth2ClientCredentialsGrantConfig && auth.tokenUrl == DEFAULT_TOKEN_URL {
        OAuth2ClientCredentialsGrantConfig resolved = {...auth};
        resolved.tokenUrl = orgTokenUrl;
        return resolved;
    }
    if auth is OAuth2PasswordGrantConfig && auth.tokenUrl == DEFAULT_TOKEN_URL {
        OAuth2PasswordGrantConfig resolved = {...auth};
        resolved.tokenUrl = orgTokenUrl;
        return resolved;
    }
    if auth is OAuth2JwtBearerGrantConfig && auth.tokenUrl == DEFAULT_TOKEN_URL {
        OAuth2JwtBearerGrantConfig resolved = {...auth};
        resolved.tokenUrl = orgTokenUrl;
        return resolved;
    }
    return auth;
}

// The connection settings of a `ConnectionConfig` other than `auth`, as plain data so that the client can keep an
// immutable copy to build tenant-endpoint clients from after each token exchange.
type ConnectionSettings record {|
    http:HttpVersion httpVersion;
    http:ClientHttp1Settings http1Settings;
    http:ClientHttp2Settings http2Settings;
    decimal timeout;
    string forwarded;
    http:FollowRedirects followRedirects?;
    http:PoolConfiguration poolConfig?;
    http:CacheConfig cache;
    http:Compression compression;
    http:CircuitBreakerConfig circuitBreaker?;
    http:RetryConfig retryConfig?;
    record {|
        boolean enabled;
        int maxCookiesPerDomain;
        int maxTotalCookieCount;
        boolean blockThirdPartyCookies;
    |} cookieConfig?;
    http:ResponseLimitConfigs responseLimits;
    http:ClientSecureSocket secureSocket?;
    http:ProxyConfig proxy?;
    http:ClientSocketConfig socketConfig;
    boolean validation;
    boolean laxDataBinding;
|};

// Copies the settings of `config` other than `auth`. A persistent cookie handler is an object and can't be
// copied; the tenant endpoint sets no cookies, so it is left out.
isolated function toConnectionSettings(ConnectionConfig config) returns ConnectionSettings & readonly {
    ConnectionSettings settings = {
        httpVersion: config.httpVersion,
        http1Settings: config.http1Settings,
        http2Settings: config.http2Settings,
        timeout: config.timeout,
        forwarded: config.forwarded,
        cache: config.cache,
        compression: config.compression,
        responseLimits: config.responseLimits,
        socketConfig: config.socketConfig,
        validation: config.validation,
        laxDataBinding: config.laxDataBinding
    };
    http:FollowRedirects? followRedirects = config.followRedirects;
    if followRedirects is http:FollowRedirects {
        settings.followRedirects = followRedirects;
    }
    http:PoolConfiguration? poolConfig = config.poolConfig;
    if poolConfig is http:PoolConfiguration {
        settings.poolConfig = poolConfig;
    }
    http:CircuitBreakerConfig? circuitBreaker = config.circuitBreaker;
    if circuitBreaker is http:CircuitBreakerConfig {
        settings.circuitBreaker = circuitBreaker;
    }
    http:RetryConfig? retryConfig = config.retryConfig;
    if retryConfig is http:RetryConfig {
        settings.retryConfig = retryConfig;
    }
    http:CookieConfig? cookieConfig = config.cookieConfig;
    if cookieConfig is http:CookieConfig {
        settings.cookieConfig = {
            enabled: cookieConfig.enabled,
            maxCookiesPerDomain: cookieConfig.maxCookiesPerDomain,
            maxTotalCookieCount: cookieConfig.maxTotalCookieCount,
            blockThirdPartyCookies: cookieConfig.blockThirdPartyCookies
        };
    }
    http:ClientSecureSocket? secureSocket = config.secureSocket;
    if secureSocket is http:ClientSecureSocket {
        settings.secureSocket = secureSocket;
    }
    http:ProxyConfig? proxy = config.proxy;
    if proxy is http:ProxyConfig {
        settings.proxy = proxy;
    }
    return settings.cloneReadOnly();
}

// The connection settings of `config`, without its `auth`.
isolated function toHttpClientConfig(ConnectionConfig config) returns http:ClientConfiguration {
    return {
        httpVersion: config.httpVersion,
        http1Settings: config.http1Settings,
        http2Settings: config.http2Settings,
        timeout: config.timeout,
        forwarded: config.forwarded,
        followRedirects: config.followRedirects,
        poolConfig: config.poolConfig,
        cache: config.cache,
        compression: config.compression,
        circuitBreaker: config.circuitBreaker,
        retryConfig: config.retryConfig,
        cookieConfig: config.cookieConfig,
        responseLimits: config.responseLimits,
        secureSocket: config.secureSocket,
        proxy: config.proxy,
        socketConfig: config.socketConfig,
        validation: config.validation,
        laxDataBinding: config.laxDataBinding
    };
}

// Normalizes a host or URL to a base URL without a trailing slash. A bare host gets HTTPS: the token exchange
// returns the tenant endpoint without a scheme.
isolated function toBaseUrl(string url) returns string {
    string baseUrl = trimTrailingSlash(url.trim());
    return baseUrl.startsWith("https://") || baseUrl.startsWith("http://") ? baseUrl : "https://" + baseUrl;
}

// The token lifetime in seconds, or `DEFAULT_TOKEN_LIFETIME` when `expires_in` is missing or unusable.
isolated function toTokenLifetime(int|decimal|string? expiresIn) returns decimal {
    decimal|error lifetime = expiresIn is string ? decimal:fromString(expiresIn)
        : expiresIn is int ? <decimal>expiresIn : expiresIn ?: DEFAULT_TOKEN_LIFETIME;
    return lifetime is decimal && lifetime > 0d ? lifetime : DEFAULT_TOKEN_LIFETIME;
}

isolated function trimTrailingSlash(string value) returns string {
    string trimmed = value;
    while trimmed.endsWith("/") {
        trimmed = trimmed.substring(0, trimmed.length() - 1);
    }
    return trimmed;
}

isolated function isUnauthorized(any|error response) returns boolean {
    return response is http:ClientRequestError && response.detail().statusCode == http:STATUS_UNAUTHORIZED;
}
