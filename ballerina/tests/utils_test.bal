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

import ballerina/test;

// Unit tests for the query serialization helpers in utils.bal.

@test:Config {
    groups: ["mock_tests"]
}
isolated function testGetSerializedArrayStyles() {
    string[] ids = ["a", "b c"];
    test:assertEquals(getSerializedArray("ids", ids), "ids=a&ids=b%20c");
    test:assertEquals(getSerializedArray("ids", ids, FORM, false), "ids=a,b%20c");
    test:assertEquals(getSerializedArray("ids", ids, SPACEDELIMITED, false), "ids=a%20b%20c");
    test:assertEquals(getSerializedArray("ids", ids, PIPEDELIMITED, false), "ids=a|b%20c");
    test:assertEquals(getSerializedArray("ids", ids, DEEPOBJECT, true), "ids[]=a&ids[]=b%20c");
    test:assertEquals(getSerializedArray("ids", []), "");
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testGetDeepObjectStyleRequest() {
    // Arrays are typed, as in the generated query records.
    string[] tags = ["vip", "new"];
    record {}[] orders = [{"id": 1}, {"id": 2}];
    record {} filter = {"name": "Alex", "tags": tags, "address": {"city": "Colombo"}, "orders": orders};
    test:assertEquals(getDeepObjectStyleRequest("filter", filter),
        "filter[name]=Alex&filter[tags][][]=vip&filter[tags][][]=new&filter[address][city]=Colombo"
            + "&filter[orders][0][id]=1&filter[orders][1][id]=2");
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testGetFormStyleRequest() {
    int[] ids = [1, 2];
    record {} filter = {"name": "Alex Perera", "ids": ids, "address": {"city": "Colombo"}};
    test:assertEquals(getFormStyleRequest("filter", filter), "name=Alex%20Perera&ids=1&ids=2&city=Colombo");
    record {} contact = {"name": "Alex Perera", "address": {"city": "Colombo"}};
    test:assertEquals(getFormStyleRequest("contact", contact, false), "name,Alex%20Perera,city,Colombo");
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testGetSerializedRecordArray() {
    record {}[] rows = [{"id": 1}, {"id": 2}];
    test:assertEquals(getSerializedRecordArray("rows", rows), "id=1,id=2");
    test:assertEquals(getSerializedRecordArray("rows", rows, FORM, false), "rows=id,1,id,2");
    test:assertEquals(getSerializedRecordArray("rows", rows, DEEPOBJECT), "rows[0][id]=1&rows[1][id]=2");
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testGetEncodedUri() {
    test:assertEquals(getEncodedUri("a b&c=d"), "a%20b%26c%3Dd");
    test:assertEquals(getEncodedUri(42), "42");
}

@test:Config {
    groups: ["mock_tests"]
}
isolated function testGetPathForQueryParam() returns error? {
    test:assertEquals(check getPathForQueryParam({}), "");
    // Nil values are left out.
    test:assertEquals(check getPathForQueryParam({"limit": 10, "offset": (), "orderBy": "name ASC"}),
        "?limit=10&orderBy=name%20ASC");
    string[] ids = ["a", "b"];
    test:assertEquals(check getPathForQueryParam({"ids": ids}, {"ids": {style: FORM, explode: false}}), "?ids=a,b");
    test:assertEquals(check getPathForQueryParam({"ids": ids}), "?ids=a&ids=b");
    test:assertEquals(check getPathForQueryParam({"filter": {"name": "Alex"}}, {"filter": {style: DEEPOBJECT}}),
        "?filter[name]=Alex");
    test:assertEquals(check getPathForQueryParam({"filter": {"name": "Alex"}}), "?name=Alex");
    // Values of any other shape are sent as their string form.
    test:assertEquals(check getPathForQueryParam({"matrix": [[1, 2]]}), "?matrix=[[1,2]]");
}
