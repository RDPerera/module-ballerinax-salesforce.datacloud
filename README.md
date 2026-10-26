# Ballerina Salesforce Data Cloud connector

[![Build](https://github.com/ballerina-platform/module-ballerinax-salesforce.datacloud/actions/workflows/ci.yml/badge.svg)](https://github.com/ballerina-platform/module-ballerinax-salesforce.datacloud/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/ballerina-platform/module-ballerinax-salesforce.datacloud/branch/main/graph/badge.svg)](https://codecov.io/gh/ballerina-platform/module-ballerinax-salesforce.datacloud)
[![Trivy](https://github.com/ballerina-platform/module-ballerinax-salesforce.datacloud/actions/workflows/trivy-scan.yml/badge.svg)](https://github.com/ballerina-platform/module-ballerinax-salesforce.datacloud/actions/workflows/trivy-scan.yml)
[![GraalVM Check](https://github.com/ballerina-platform/module-ballerinax-salesforce.datacloud/actions/workflows/build-with-bal-test-graalvm.yml/badge.svg)](https://github.com/ballerina-platform/module-ballerinax-salesforce.datacloud/actions/workflows/build-with-bal-test-graalvm.yml)
[![GitHub Last Commit](https://img.shields.io/github/last-commit/ballerina-platform/module-ballerinax-salesforce.datacloud.svg)](https://github.com/ballerina-platform/module-ballerinax-salesforce.datacloud/commits/main)
[![GitHub Issues](https://img.shields.io/github/issues/ballerina-platform/ballerina-library/module/salesforce.datacloud.svg?label=Open%20Issues)](https://github.com/ballerina-platform/ballerina-library/labels/module%2Fsalesforce.datacloud)

## Overview

[Salesforce Data Cloud](https://www.salesforce.com/data/) (Data 360) is Salesforce's customer data platform. It ingests data from any source, unifies it into customer profiles through identity resolution, and computes calculated insights on those profiles.

The `ballerinax/salesforce.datacloud` connector offers APIs to connect and interact with the [Data Cloud APIs](https://developer.salesforce.com/docs/data/data-cloud-ref/guide/c360a-api-get-started.htm), enabling operations to stream and bulk-load records with the Ingestion API, read unified profiles with the Profile API, query calculated insights, and trigger identity resolution and calculated insight runs.

Data Cloud serves these APIs from two hosts with two different tokens: the `Runs` operations go to your Salesforce org with its access token, and every other operation goes to the Data Cloud tenant endpoint with a Data Cloud token. The connector takes only your Salesforce org credentials and handles the rest: it exchanges the org's access token for a Data Cloud token, discovers the tenant endpoint, and exchanges again before the token expires.

## Setup guide

To use the Data Cloud connector, you need a Salesforce org with Data Cloud provisioned, and an External Client App (or connected app) that the connector can authenticate with.

### Step 1: Create an External Client App

1. In Salesforce Setup, search for **External Client App Manager** and click **New External Client App**. (A connected app from **App Manager** > **New Connected App** works the same way.)

2. Enter a name and contact email, then under **API (Enable OAuth Settings)** select **Enable OAuth** and set a **Callback URL**, e.g. `https://login.salesforce.com/services/oauth2/success`.

3. Add these OAuth scopes:

   | Scope | Needed for |
   |---|---|
   | `api` | the `Runs` operations (identity resolution and calculated insight runs) |
   | `cdp_ingest_api` | streaming and bulk ingestion |
   | `cdp_profile_api` | profile lookups |
   | `cdp_query_api` | calculated insight queries and metadata |
   | `refresh_token` | getting a refresh token (refresh token grant only) |

4. Leave **Issue JSON Web Token (JWT)-based access tokens for named users** cleared: the Data Cloud token exchange doesn't accept JWT-based access tokens.

5. To use the client credentials grant (recommended for services), also select **Enable Client Credentials Flow**, save, and then under **Policies** set a **Run As** user who has a Data Cloud permission set (e.g. **Data Cloud Admin** or **Data Cloud Architect**).

6. Save the app, then copy its **Consumer Key** and **Consumer Secret** (under **Settings** > **OAuth Settings** > **Consumer Key and Secret**).

### Step 2: Get a refresh token (refresh token grant only)

1. Open this URL in a browser, signed in as a user with a Data Cloud permission set:

   ```
   https://<your-domain>.my.salesforce.com/services/oauth2/authorize?response_type=code&client_id=<consumer-key>&redirect_uri=<callback-url>
   ```

2. Approve access. The browser is redirected to the callback URL with a `code` query parameter.

3. Exchange the code for tokens:

   ```bash
   curl -X POST https://<your-domain>.my.salesforce.com/services/oauth2/token \
     -d grant_type=authorization_code -d code=<code> \
     -d client_id=<consumer-key> -d client_secret=<consumer-secret> -d redirect_uri=<callback-url>
   ```

   The response holds the `refresh_token`.

### Step 3: Prepare Data Cloud for ingestion (ingestion operations only)

1. In Data Cloud Setup, go to **Ingestion API**, click **New**, and name the connector. That name (as shown in the **Ingestion API** list, not the generated API name) is the `sourceName` of the ingestion operations.

2. Upload an OpenAPI schema (YAML) that defines your objects and their fields. The object names are the `objectName` values of the ingestion operations.

3. Create a data stream for each object from the Ingestion API connector, and map it to the data model.

> **Note:** Every field defined in an object's schema must be present in every record you send (send a blank value when there's no data), an update replaces the whole record, and date-times need fractional seconds, e.g. `2026-10-24T10:15:30.000Z`.

## Quickstart

To use the `salesforce.datacloud` connector in your Ballerina application, update the `.bal` file as follows:

### Step 1: Import the module

```ballerina
import ballerinax/salesforce.datacloud;
```

### Step 2: Instantiate a new connector

1. Create a `Config.toml` file with your org's My Domain URL and the credentials obtained above:

    ```toml
    orgUrl = "https://<your-domain>.my.salesforce.com"
    clientId = "<consumer-key>"
    clientSecret = "<consumer-secret>"
    refreshToken = "<refresh-token>"
    ```

2. Create a `datacloud:Client` instance. The service URL is your org's My Domain URL, not the Data Cloud tenant endpoint, which the connector discovers itself:

    ```ballerina
    configurable string orgUrl = ?;
    configurable string clientId = ?;
    configurable string clientSecret = ?;
    configurable string refreshToken = ?;

    final datacloud:Client datacloudClient = check new ({auth: {clientId, clientSecret, refreshToken}}, orgUrl);
    ```

    The connector also accepts the client credentials grant (`{auth: {clientId, clientSecret}}`), the password grant, or an existing org access token (`{auth: {token: accessToken}}`). Token requests go to `<orgUrl>/services/oauth2/token` unless you set `refreshUrl` (refresh token grant) or `tokenUrl` (other grants).

    > **Note:** Salesforce turns on refresh token rotation for new connected and External Client Apps, and then a refresh token can be used only once. The connector keeps the rotated token while it runs, but a refresh token in `Config.toml` stops working after the first run. For services, prefer the client credentials grant (see the setup guide), or turn off rotation in the app's OAuth policies. New orgs also block the username-password flow by default.

    > **Note:** Salesforce token responses carry no expiry, so the connector reuses an org access token for `defaultTokenExpTime` (3600 seconds by default). If Salesforce rejects the token earlier, for example because the org's session timeout is shorter, the connector fetches a new one and retries the call. Setting `defaultTokenExpTime` in the `auth` configuration below the session timeout avoids those extra round trips. A plain access token (`{auth: {token: accessToken}}`) can't be renewed.

    To scope the Data Cloud token to a data space other than the default, pass `dataspace`. To call the `Runs` operations on a specific API version (v57.0 or later), pass `apiVersion` (default `v62.0`):

    ```ballerina
    final datacloud:Client datacloudClient = check new ({auth: {clientId, clientSecret, refreshToken}}, orgUrl,
        apiVersion = "v62.0", dataspace = "<data-space-name>");
    ```

### Step 3: Invoke the connector operation

Now, utilize the available connector operations.

#### Stream records into Data Cloud

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

#### Find a profile by email

```ballerina
public function main() returns error? {
    // Email addresses live on the Contact Point Email object; `ssot__PartyId__c` is the individual's ID.
    datacloud:QueryResponse emails = check datacloudClient->queryProfiles("ssot__ContactPointEmail__dlm",
        filters = "[ssot__EmailAddress__c=alex@example.com]", fields = ["ssot__PartyId__c"]);
    foreach record {} row in emails.data ?: [] {
        datacloud:QueryResponse profile = check datacloudClient->getProfile("ssot__Individual__dlm",
            row["ssot__PartyId__c"].toString());
        io:println(profile.data);
    }
}
```

### Step 4: Run the Ballerina application

```bash
bal run
```

## Examples

The `Salesforce Data Cloud` connector provides practical examples illustrating usage in various scenarios. Explore these [examples](https://github.com/ballerina-platform/module-ballerinax-salesforce.datacloud/tree/main/examples/), covering the following use cases:

1. [Bulk customer load](https://github.com/ballerina-platform/module-ballerinax-salesforce.datacloud/tree/main/examples/bulk-customer-load) — Create a bulk upsert job, upload a CSV file to it, close it, poll it until processing finishes, and delete the finished job.
2. [Customer profile insights](https://github.com/ballerina-platform/module-ballerinax-salesforce.datacloud/tree/main/examples/customer-profile-insights) — Validate and stream a customer record, start an identity resolution run, and find the customer by email to read their profile and calculated insight values.

## Build from the source

### Setting up the prerequisites

1. Download and install Java SE Development Kit (JDK) version 21. You can download it from either of the following sources:

    * [Oracle JDK](https://www.oracle.com/java/technologies/downloads/)
    * [OpenJDK](https://adoptium.net/)

   > **Note:** After installation, remember to set the `JAVA_HOME` environment variable to the directory where JDK was installed.

2. Download and install [Ballerina Swan Lake](https://ballerina.io/).

3. Download and install [Docker](https://www.docker.com/get-started).

   > **Note**: Ensure that the Docker daemon is running before executing any tests.

4. Export Github Personal access token with read package permissions as follows,

    ```bash
    export packageUser=<Username>
    export packagePAT=<Personal access token>
    ```

### Build options

Execute the commands below to build from the source.

1. To build the package:

   ```bash
   ./gradlew clean build
   ```

2. To run the tests:

   ```bash
   ./gradlew clean test
   ```

3. To build the without the tests:

   ```bash
   ./gradlew clean build -x test
   ```

4. To run tests against different environments:

   ```bash
   ./gradlew clean test -Pgroups=<Comma separated groups/test cases>
   ```

5. To debug the package with a remote debugger:

   ```bash
   ./gradlew clean build -Pdebug=<port>
   ```

6. To debug with the Ballerina language:

   ```bash
   ./gradlew clean build -PbalJavaDebug=<port>
   ```

7. Publish the generated artifacts to the local Ballerina Central repository:

    ```bash
    ./gradlew clean build -PpublishToLocalCentral=true
    ```

8. Publish the generated artifacts to the Ballerina Central repository:

   ```bash
   ./gradlew clean build -PpublishToCentral=true
   ```

## Contribute to Ballerina

As an open-source project, Ballerina welcomes contributions from the community.

For more information, go to the [contribution guidelines](https://github.com/ballerina-platform/ballerina-lang/blob/master/CONTRIBUTING.md).

## Code of conduct

All the contributors are encouraged to read the [Ballerina Code of Conduct](https://ballerina.io/code-of-conduct).

## Useful links

* For more information go to the [`salesforce.datacloud` package](https://central.ballerina.io/ballerinax/salesforce.datacloud/latest).
* For example demonstrations of the usage, go to [Ballerina By Examples](https://ballerina.io/learn/by-example/).
* Chat live with us via our [Discord server](https://discord.gg/ballerinalang).
* Post all technical questions on Stack Overflow with the [#ballerina](https://stackoverflow.com/questions/tagged/ballerina) tag.
