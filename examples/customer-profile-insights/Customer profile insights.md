# Customer profile insights

This example follows a customer from ingestion to insight: it validates a customer record against the object's schema, streams it into Salesforce Data Cloud, starts an identity resolution run, and then finds the customer by email and reads their profile and calculated insight values.

Streamed records are processed about every 3 minutes and identity resolution runs asynchronously, so the profile lookup finds the new customer only once both have finished. Run the example again after a few minutes to see the profile.

## Prerequisites

- Ballerina Swan Lake 2201.12.x or later
- A Data Cloud org with an Ingestion API connector and data stream for the object (here `customers`), mapped to the Individual data model, an identity resolution ruleset, and a calculated insight on the profile (here `IndividualSpend__cio`). See the [setup guide](../../README.md#setup-guide).
- Push the connector to the local repository:
  ```bash
  cd ../../ballerina
  bal pack && bal push --repository=local
  ```
- Create a `Config.toml` in this directory:
  ```toml
  orgUrl = "https://<your-domain>.my.salesforce.com"
  clientId = "<consumer-key>"
  clientSecret = "<consumer-secret>"
  sourceName = "CustomerOrders"
  objectName = "customers"
  customerEmail = "alex@example.com"
  profileObject = "ssot__Individual__dlm"
  insightName = "IndividualSpend__cio"
  ```

## Run the example

```bash
bal run
```
