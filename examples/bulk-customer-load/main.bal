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

// This example loads customer records into Data Cloud with a bulk ingestion job: it creates an upsert job,
// uploads a CSV file to it, closes the job so that Data Cloud processes the data, polls the job until
// processing finishes, and then deletes the finished job.

import ballerina/io;
import ballerina/lang.runtime;
import ballerinax/salesforce.datacloud;

configurable string orgUrl = ?;
// The consumer key and secret of the External Client App, as an `[auth]` table in Config.toml.
configurable datacloud:OAuth2ClientCredentialsGrantConfig auth = ?;
configurable string sourceName = "CustomerOrders";
configurable string objectName = "customers";
configurable decimal pollIntervalSeconds = 30;
configurable int maxPolls = 40;

public function main() returns error? {
    datacloud:Client datacloudClient = check new ({auth}, orgUrl);

    // Step 1: Create an upsert job for the object
    datacloud:BulkJob job = check datacloudClient->createBulkJob({
        objectName,
        sourceName,
        operation: "upsert"
    });
    string jobId = job.id ?: "";
    io:println(string `Created job ${jobId} (${job.state.toString()})`);

    // Steps 2 to 4 run in `loadAndWait`. If any of them fails, abort the job: Data Cloud allows only one open job
    // per object, so a job left open would block the next run.
    datacloud:BulkJob|error result = loadAndWait(datacloudClient, jobId);
    if result is error {
        datacloud:BulkJob|error aborted = datacloudClient->updateBulkJobState(jobId, {state: "Aborted"});
        io:println(string `Aborted job ${jobId}: ${aborted is error ? aborted.message() : "done"}`);
        return result;
    }

    // Step 5: Delete the finished job. The ingested records stay in Data Cloud.
    check datacloudClient->deleteBulkJob(jobId);
    io:println(string `Deleted job ${jobId}`);
}

function loadAndWait(datacloud:Client datacloudClient, string jobId) returns datacloud:BulkJob|error {
    // Step 2: Upload the CSV file. The header row must match the field names of the object's schema, and
    // date-times need fractional seconds.
    string csv = string `customer_id,email,first_name,last_name,created_at
100000001,alex@example.com,Alex,Perera,2026-10-24T10:15:30.000Z
100000002,sam@example.com,Sam,Fernando,2026-10-24T10:16:02.000Z
`;
    _ = check datacloudClient->uploadBulkJobData(jobId, csv);
    io:println("Uploaded the CSV file");

    // Step 3: Close the job so that Data Cloud starts processing the uploaded data
    datacloud:BulkJob job = check datacloudClient->updateBulkJobState(jobId, {state: "UploadComplete"});
    io:println(string `Job state: ${job.state.toString()}`);

    // Step 4: Poll the job until processing finishes
    foreach int _ in 1 ... maxPolls {
        job = check datacloudClient->getBulkJob(jobId);
        datacloud:BulkJobState? state = job.state;
        io:println(string `Job state: ${state.toString()}`);
        if state == "JobComplete" || state == "Failed" || state == "Aborted" {
            break;
        }
        runtime:sleep(pollIntervalSeconds);
    }
    if job.state != "JobComplete" {
        return error(string `Job ${jobId} did not complete: ${job.state.toString()}`);
    }
    return job;
}
