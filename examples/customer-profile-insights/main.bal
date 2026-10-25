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

// This example follows a customer from ingestion to insight: it validates a customer record against the
// object's schema, streams it into Data Cloud, starts an identity resolution run, and then finds the customer
// by email and reads their profile and calculated insight values.

import ballerina/io;
import ballerinax/salesforce.datacloud;

configurable string orgUrl = ?;
configurable string clientId = ?;
configurable string clientSecret = ?;
configurable string refreshToken = ?;
configurable string sourceName = "CustomerOrders";
configurable string objectName = "customers";
configurable string customerEmail = "alex@example.com";
configurable string profileObject = "ssot__Individual__dlm";
configurable string insightName = "IndividualSpend__cio";

public function main() returns error? {
    datacloud:Client datacloudClient = check new ({auth: {clientId, clientSecret, refreshToken}}, orgUrl);

    // Step 1: Validate the record against the object's schema. Every schema field must be present.
    datacloud:IngestRecords records = {
        data: [
            {
                "customer_id": "100000001",
                "email": customerEmail,
                "first_name": "Alex",
                "last_name": "Perera",
                "created_at": "2026-10-24T10:15:30.000Z"
            }
        ]
    };
    _ = check datacloudClient->validateRecords(sourceName, objectName, records);
    io:println("The record matches the object's schema");

    // Step 2: Stream the record in. Data Cloud processes streamed records about every 3 minutes.
    _ = check datacloudClient->upsertRecords(sourceName, objectName, records);
    io:println("Queued the record for ingestion");

    // Step 3: Start the first identity resolution ruleset, so that the record is unified into a profile
    datacloud:IdentityResolutionRulesetList rulesets = check datacloudClient->listIdentityResolutionRulesets();
    datacloud:IdentityResolutionRuleset[] rulesetList = rulesets.rulesets ?: [];
    if rulesetList.length() > 0 {
        datacloud:IdentityResolutionRuleset ruleset = rulesetList[0];
        datacloud:RunResult run = check datacloudClient->runIdentityResolutionRuleset(ruleset.id ?: "");
        io:println(string `Identity resolution '${ruleset.label.toString()}': ${run.resultCode.toString()}`);
    }

    // Step 4: Find the customer by email. Email addresses live on the Contact Point Email object, whose
    // `ssot__PartyId__c` is the ID of the individual it belongs to.
    datacloud:QueryResponse emails = check datacloudClient->queryProfiles("ssot__ContactPointEmail__dlm",
        filters = string `[ssot__EmailAddress__c=${customerEmail}]`, fields = ["ssot__PartyId__c"]);
    record {}[] emailRows = emails.data ?: [];
    if emailRows.length() == 0 {
        io:println("No profile yet; run the example again once ingestion and identity resolution have finished");
        return;
    }
    string profileId = emailRows[0]["ssot__PartyId__c"].toString();

    // Step 5: Read the customer's profile
    datacloud:QueryResponse profile = check datacloudClient->getProfile(profileObject, profileId);
    foreach record {} row in profile.data ?: [] {
        io:println(string `Profile ${profileId}: ${row.toJsonString()}`);
    }

    // Step 6: Read the calculated insight values for the profile. They are nested under the insight's name.
    datacloud:QueryResponse insight = check datacloudClient->getProfileCalculatedInsight(profileObject, profileId,
        insightName);
    foreach record {} row in insight.data ?: [] {
        io:println(string `${insightName}: ${row[insightName].toJsonString()}`);
    }
}
