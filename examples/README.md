# Examples

The WSO2 Salesforce Data 360 (Data Cloud) Connector provides practical examples illustrating usage in various scenarios.

| Example | Description |
|---------|-------------|
| [`bulk-customer-load`](./bulk-customer-load) | Creates a bulk upsert job, uploads a CSV file to it, closes it, polls it until processing finishes, and deletes the finished job |
| [`customer-profile-insights`](./customer-profile-insights) | Validates and streams a customer record, starts an identity resolution run, and finds the customer by email to read their profile and calculated insight values |

## Prerequisites

1. Create an External Client App with the client credentials flow as described in the [setup guide](../README.md#setup-guide), and set up an Ingestion API connector and data stream for the object the examples load.

2. Build and push the connector to your local Ballerina repository:

    ```bash
    cd ../ballerina
    bal pack && bal push --repository=local
    ```

3. For each example, create a `Config.toml` in the example directory with the required credentials:

    ```toml
    orgUrl = "https://<your-domain>.my.salesforce.com"
    clientId = "<consumer-key>"
    clientSecret = "<consumer-secret>"
    ```

## Running an example

Execute the following commands to build an example from the source:

* To build an example:

    ```bash
    bal build
    ```

* To run an example:

    ```bash
    bal run
    ```

## Building the examples with the local module

**Warning**: Due to the absence of support for reading local repositories for single Ballerina files, the Bala of the module is manually written to the central repository as a workaround. Consequently, the bash script may modify your local Ballerina repositories.

Execute the following commands to build all the examples against the changes you have made to the module locally:

* To build all the examples:

    ```bash
    ./build.sh build
    ```

* To run all the examples:

    ```bash
    ./build.sh run
    ```
