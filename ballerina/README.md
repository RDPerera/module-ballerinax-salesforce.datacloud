[![GitHub Last Commit](https://img.shields.io/github/last-commit/ballerina-platform/module-ballerinax-salesforce.datacloud.svg)](https://github.com/ballerina-platform/module-ballerinax-salesforce.datacloud/commits/main)
[![GitHub Issues](https://img.shields.io/github/issues/ballerina-platform/ballerina-library/module/salesforce.datacloud.svg?label=Open%20Issues)](https://github.com/ballerina-platform/ballerina-library/labels/module%2Fsalesforce.datacloud)

## Overview

[Salesforce Data 360 (Data Cloud)](https://www.salesforce.com/data/) is Salesforce's customer data platform. It ingests data from any source, unifies it into customer profiles through identity resolution, and computes calculated insights on those profiles.

The WSO2 Salesforce Data 360 (Data Cloud) Connector offers APIs to connect and interact with the [Data 360 APIs](https://developer.salesforce.com/docs/data/data-cloud-ref/guide/c360a-api-get-started.htm), enabling operations to stream and bulk-load records with the Ingestion API, read unified profiles with the Profile API, query calculated insights, run SQL queries with the Query API, and trigger identity resolution and calculated insight runs.

Data 360 serves these APIs from two hosts with two different tokens: the `Runs` operations go to your Salesforce org with its access token, and every other operation goes to the Data 360 tenant endpoint with a Data 360 token. The connector takes only your Salesforce org credentials and handles the rest: it exchanges the org's access token for a Data 360 token, discovers the tenant endpoint, and exchanges again before the token expires.

### Key features

- Stream records into Data 360, delete them by primary key, and validate them against the object's schema before ingesting
- Load large data sets with bulk ingestion jobs: create a job, upload CSV files, close or abort it, and track it to completion
- Look up unified profiles and their related records, and read profile and calculated insight metadata
- Query calculated insights and read an insight's values for a single profile
- Run ANSI SQL queries over Data 360 objects and page through the results
- Start identity resolution and calculated insight runs on demand
- Authenticate with your Salesforce org credentials only: the connector obtains and renews the Data 360 token itself

## Setup guide

To use the WSO2 Salesforce Data 360 (Data Cloud) Connector, you need a Salesforce org with Data 360, and an External Client App that the connector can authenticate with.

### Step 1: Turn on Data 360

1. In Salesforce Setup, search for **Data Cloud Setup** (shown as **Data 360 Setup** in newer orgs). If Data 360 isn't set up yet, click **Get Started** and wait until provisioning finishes, which can take up to an hour.

2. Make sure the user the connector acts as has a Data 360 permission set, e.g. **Data Cloud Admin** or **Data Cloud Architect**.

### Step 2: Create an External Client App

1. In Setup, search for **External Client App Manager** and click **New External Client App**. Enter a name and a contact email.

   <img src=https://raw.githubusercontent.com/ballerina-platform/module-ballerinax-salesforce.datacloud/main/docs/setup/resources/create-external-client-app.png alt="Create an External Client App" style="border:1px solid #000000; width:80%">

2. Expand **API (Enable OAuth Settings)**, select **Enable OAuth**, and set a **Callback URL**, e.g. `https://login.salesforce.com/services/oauth2/success`. Add these OAuth scopes:

   | Scope | Needed for |
   |---|---|
   | `api` | the `Runs` operations (identity resolution and calculated insight runs) |
   | `cdp_ingest_api` | streaming and bulk ingestion |
   | `cdp_profile_api` | profile lookups |
   | `cdp_query_api` | SQL queries, and calculated insight queries and metadata |
   | `refresh_token, offline_access` | getting a refresh token (refresh token grant only) |

   <img src=https://raw.githubusercontent.com/ballerina-platform/module-ballerinax-salesforce.datacloud/main/docs/setup/resources/oauth-settings.png alt="OAuth settings and scopes" style="border:1px solid #000000; width:80%">

3. Under **Flow Enablement**, select **Enable Client Credentials Flow** (recommended for services). Under **Security**, leave **Issue JSON Web Token (JWT)-based access tokens for named users** cleared: the Data 360 token exchange doesn't accept JWT-based access tokens.

   New apps always require PKCE and rotate refresh tokens (each refresh token can be used only once); these settings can't be changed. The connector keeps the rotated token while it runs, but a refresh token saved in configuration stops working after one run, so prefer the client credentials grant for anything that restarts.

   <img src=https://raw.githubusercontent.com/ballerina-platform/module-ballerinax-salesforce.datacloud/main/docs/setup/resources/flow-and-security-settings.png alt="Flow enablement and security settings" style="border:1px solid #000000; width:80%">

4. Click **Create**. For the client credentials grant, open the app's **Policies** tab, click **Edit**, and under **OAuth Policies** select **Enable Client Credentials Flow** and set **Run As** to the user from Step 1.

5. On the app's **Settings** tab, under **OAuth Settings**, click **Consumer Key and Secret**, verify your identity, and copy both values.

   <img src=https://raw.githubusercontent.com/ballerina-platform/module-ballerinax-salesforce.datacloud/main/docs/setup/resources/consumer-key-and-secret-button.png alt="Open the consumer key and secret" style="border:1px solid #000000; width:80%">

   <img src=https://raw.githubusercontent.com/ballerina-platform/module-ballerinax-salesforce.datacloud/main/docs/setup/resources/consumer-key-and-secret.png alt="Copy the consumer key and secret" style="border:1px solid #000000; width:80%">

### Step 3: Get a refresh token (refresh token grant only)

Skip this step if you use the client credentials grant.

1. Create a PKCE verifier and challenge:

   ```bash
   VERIFIER=$(openssl rand -base64 64 | tr -d '\n=' | tr '+/' '-_' | cut -c1-64)
   CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary | openssl base64 | tr -d '\n=' | tr '+/' '-_')
   ```

2. Open this URL in a browser, signed in as the user from Step 1, and click **Allow**. The browser is redirected to the callback URL with a `code` query parameter.

   ```
   https://<your-domain>.my.salesforce.com/services/oauth2/authorize?response_type=code&client_id=<consumer-key>&redirect_uri=<callback-url>&code_challenge=<CHALLENGE>&code_challenge_method=S256
   ```

3. Exchange the code for tokens within a few minutes, in the same terminal:

   ```bash
   curl -X POST https://<your-domain>.my.salesforce.com/services/oauth2/token \
     -d grant_type=authorization_code --data-urlencode code=<code> \
     -d client_id=<consumer-key> -d client_secret=<consumer-secret> -d redirect_uri=<callback-url> \
     -d code_verifier="$VERIFIER"
   ```

   The response holds the `refresh_token`.

### Step 4: Prepare Data 360 for ingestion (ingestion operations only)

1. In Data 360 Setup, go to **Ingestion API**, click **New**, and name the connector. That name (as shown in the **Ingestion API** list, not the generated API name) is the `sourceName` of the ingestion operations.

2. Upload an OpenAPI schema (YAML) that defines your objects and their fields. The object names are the `objectName` values of the ingestion operations.

3. Create a data stream for each object from the Ingestion API connector, and map it to the data model.

> **Note:** Every field defined in an object's schema must be present in every record you send (send a blank value when there's no data), an update replaces the whole record, and date-times need fractional seconds, e.g. `2026-10-24T10:15:30.000Z`.

## Quickstart

To use the WSO2 Salesforce Data 360 (Data Cloud) Connector in your Ballerina application, update the `.bal` file as follows:

### Step 1: Import the module

```ballerina
import ballerinax/salesforce.datacloud;
```

### Step 2: Instantiate a new connector

1. Create a `Config.toml` file with your org's My Domain URL and the app's consumer key and secret:

    ```toml
    orgUrl = "https://<your-domain>.my.salesforce.com"
    clientId = "<consumer-key>"
    clientSecret = "<consumer-secret>"
    ```

2. Create a `datacloud:Client` instance with the client credentials grant. The service URL is your org's My Domain URL, not the Data 360 tenant endpoint, which the connector discovers itself:

    ```ballerina
    configurable string orgUrl = ?;
    configurable string clientId = ?;
    configurable string clientSecret = ?;

    final datacloud:Client datacloudClient = check new ({auth: {clientId, clientSecret}}, orgUrl);
    ```

    The connector also accepts the refresh token grant (`{auth: {clientId, clientSecret, refreshToken}}`), the password grant, or an existing org access token (`{auth: {token: accessToken}}`). Token requests go to `<orgUrl>/services/oauth2/token` unless you set `refreshUrl` (refresh token grant) or `tokenUrl` (other grants).

    > **Note:** New apps rotate refresh tokens, so a refresh token can be used only once. The connector keeps the rotated token while it runs, but a refresh token in `Config.toml` stops working after the first run. New orgs also block the username-password flow by default. For services, use the client credentials grant.

    > **Note:** Salesforce token responses carry no expiry, so the connector reuses an org access token for `defaultTokenExpTime` (3600 seconds by default). If Salesforce rejects the token earlier, for example because the org's session timeout is shorter, the connector fetches a new one and retries the call. Setting `defaultTokenExpTime` in the `auth` configuration below the session timeout avoids those extra round trips. A plain access token (`{auth: {token: accessToken}}`) can't be renewed.

    To scope the Data 360 token to a data space other than the default, pass `dataspace`. To call the `Runs` operations on a specific API version (v57.0 or later), pass `apiVersion` (default `v62.0`):

    ```ballerina
    final datacloud:Client datacloudClient = check new ({auth: {clientId, clientSecret}}, orgUrl,
        apiVersion = "v62.0", dataspace = "<data-space-name>");
    ```

### Step 3: Invoke the connector operation

Now, utilize the available connector operations.

#### Stream records into Data 360

```ballerina
public function main() returns error? {
    datacloud:AcceptedResponse response = check datacloudClient->upsertRecords("CustomerOrders", "customers", {
        data: [
            {
                "customer_id": "100000001",
                "email": "alex@example.com",
                "first_name": "Alex",
                "last_name": "Perera",
                "created_at": "2026-10-24T10:15:30.000Z"
            }
        ]
    });
    io:println(response.accepted);
}
```

### Step 4: Run the Ballerina application

```bash
bal run
```

## Examples

The WSO2 Salesforce Data 360 (Data Cloud) Connector provides practical examples illustrating usage in various scenarios. Explore these [examples](https://github.com/ballerina-platform/module-ballerinax-salesforce.datacloud/tree/main/examples/), covering the following use cases:

1. [Bulk customer load](https://github.com/ballerina-platform/module-ballerinax-salesforce.datacloud/tree/main/examples/bulk-customer-load) — Create a bulk upsert job, upload a CSV file to it, close it, poll it until processing finishes, and delete the finished job.
2. [Customer profile insights](https://github.com/ballerina-platform/module-ballerinax-salesforce.datacloud/tree/main/examples/customer-profile-insights) — Validate and stream a customer record, start an identity resolution run, and find the customer by email to read their profile and calculated insight values.
