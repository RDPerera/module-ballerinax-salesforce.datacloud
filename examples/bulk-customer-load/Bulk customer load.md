# Bulk customer load

This example loads customer records into Salesforce Data 360 (Data Cloud) with a bulk ingestion job: it creates an upsert job, uploads a CSV file to it, closes the job so that Data 360 processes the data, polls the job until processing finishes, and then deletes the finished job.

## Prerequisites

- Ballerina Swan Lake 2201.12.x or later
- A Data 360 org with an Ingestion API connector whose schema defines the object (here `customers` with the fields `customer_id`, `email`, `first_name`, `last_name` and `created_at`), and a data stream for it. See the [setup guide](../../README.md#setup-guide).
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
  ```

## Run the example

```bash
bal run
```
