// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import Foundation
import Testing

@testable import Iggy

@Suite("User headers")
struct UserHeadersTests {
    @Test func typedValuesRoundTrip() throws {
        let headers: UserHeaders = [
            "raw": try .raw([1, 2, 3]),
            "string": "text",
            "bool": true,
            "int8": .int8(-8),
            "int16": .int16(-16),
            "int32": .int32(-32),
            "int64": -64,
            "int128": .int128(bitPattern: UInt128Value(low: 1, high: 2)),
            "uint8": .uint8(8),
            "uint16": .uint16(16),
            "uint32": .uint32(32),
            "uint64": .uint64(64),
            "uint128": .uint128(UInt128Value(low: 3, high: 4)),
            "float32": .float32(1.25),
            "float64": 2.5,
        ]
        let encoded = HeaderTLV.encode(headers)
        let decoded = try HeaderTLV.decode(encoded[...], skipUnknown: false)
        #expect(decoded == headers)
        #expect(decoded["raw"]?.bytes == [1, 2, 3])
        #expect(decoded["string"]?.stringValue == "text")
        #expect(decoded["bool"]?.boolValue == true)
        #expect(decoded["int8"]?.int8Value == -8)
        #expect(decoded["int16"]?.int16Value == -16)
        #expect(decoded["int32"]?.int32Value == -32)
        #expect(decoded["int64"]?.int64Value == -64)
        #expect(decoded["int128"]?.int128BitPattern == UInt128Value(low: 1, high: 2))
        #expect(decoded["uint8"]?.uint8Value == 8)
        #expect(decoded["uint16"]?.uint16Value == 16)
        #expect(decoded["uint32"]?.uint32Value == 32)
        #expect(decoded["uint64"]?.uint64Value == 64)
        #expect(decoded["uint128"]?.uint128Value == UInt128Value(low: 3, high: 4))
        #expect(decoded["float32"]?.float32Value == 1.25)
        #expect(decoded["float64"]?.float64Value == 2.5)
        #expect(decoded["float64"]?.stringValue == nil)
        #expect(HeaderTLV.encodedSize(headers) == encoded.count)
    }

    @Test func encodingIsSortedByKey() {
        let encoded = HeaderTLV.encode(["b": "2", "a": "1"])
        #expect(encoded == HeaderTLV.encode(["a": "1", "b": "2"]))
        #expect(encoded[5] == UInt8(ascii: "a"))
    }

    @Test func structuralValidation() throws {
        #expect(throws: WireError.self) { try HeaderTLV.validate([0, 1, 0, 0, 0, 42]) }
        #expect(throws: WireError.self) { try HeaderTLV.validate([1, 0, 0, 0, 0]) }
        #expect(throws: WireError.self) { try HeaderTLV.validate([1, 2, 0, 0, 0, 97, 98]) }
        var trailing = HeaderTLV.encode(["k": "v"])
        trailing.append(0xFF)
        #expect(throws: WireError.self) { try HeaderTLV.validate(trailing[...]) }
        #expect(try HeaderTLV.validate([]).isEmpty)
    }

    @Test func unknownKindsAreRejectedOrSkipped() throws {
        var bytes: [UInt8] = [2, 1, 0, 0, 0, UInt8(ascii: "k"), 200, 1, 0, 0, 0, 1]
        #expect(throws: IggyError.self) { try HeaderTLV.decode(bytes[...], skipUnknown: false) }
        #expect(try HeaderTLV.decode(bytes[...], skipUnknown: true).isEmpty)
        bytes += HeaderTLV.encode(["x": "y"])
        #expect(try HeaderTLV.decode(bytes[...], skipUnknown: true) == ["x": "y"])
    }

    @Test func fixedSizeKindsAreChecked() {
        #expect(throws: IggyError.self) { try HeaderValue(kind: .uint32, bytes: [1, 2, 3]) }
        #expect(throws: IggyError.self) { try HeaderKey(kind: .string, bytes: []) }
        #expect(throws: IggyError.self) { try HeaderValue.string(String(repeating: "a", count: 256)) }
    }
}

@Suite("Options block")
struct OptionsBlockTests {
    @Test func rejectsNonStringAndDuplicateKeys() throws {
        let numericKey: [UInt8] = [12, 8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 1, 0, 0, 0, 118]
        #expect(throws: WireError.self) { try OptionsBlock.validate(numericKey[...]) }
        let entry = HeaderTLV.encode(["segment_size": "1 GiB"])
        #expect(throws: WireError.self) { try OptionsBlock.validate((entry + entry)[...]) }
        #expect(try OptionsBlock.validate(entry[...]).count == 1)
    }

    @Test func prefixedBlocksRoundTrip() throws {
        let options: ResourceOptions = ["key": .explicit("value")]
        let block = try OptionsBlock.encode(options)
        var writer = ByteWriter()
        writer.write(UInt32(block.count))
        writer.write(block)
        var reader = ByteReader(writer.bytes)
        let decoded = try OptionsBlock.decode(try OptionsBlock.readPrefixed(from: &reader), explicit: true)
        #expect(decoded == options)
        #expect(reader.isAtEnd)
        var truncated = ByteReader(Array(writer.bytes.dropLast()))
        #expect(throws: WireError.self) { try OptionsBlock.readPrefixed(from: &truncated) }
    }

    @Test func derivedEntriesAreNotSentAndExplicitWinsOnMerge() throws {
        let options: ResourceOptions = ["a": .explicit("1"), "b": .derived("2")]
        let encoded = try OptionsBlock.encode(options)
        #expect(try OptionsBlock.decode(encoded[...], explicit: true) == ["a": .explicit("1")])
        let merged = try OptionsBlock.decodeSplit(explicit: encoded[...], derived: try OptionsBlock.encode(["a": .explicit("9"), "c": .explicit("3")])[...])
        #expect(merged == ["a": .explicit("1"), "c": .derived("3")])
    }

    @Test func limitsAreEnforced() throws {
        var many: ResourceOptions = [:]
        for index in 0...OptionsBlock.maxOptions {
            many["key_\(index)"] = .explicit("v")
        }
        #expect(throws: IggyError(.optionsBlockTooLarge, context: "\(OptionsBlock.maxOptions + 1) entries, maximum \(OptionsBlock.maxOptions)")) {
            try OptionsBlock.encode(many)
        }
        var big: ResourceOptions = [:]
        let value = try HeaderValue.string(String(repeating: "v", count: 255))
        for index in 0..<400 {
            big[String(repeating: "k", count: 250) + String(format: "%05d", index)] = .explicit(value)
        }
        #expect(throws: IggyError.self) { try OptionsBlock.encode(big) }
    }
}

@Suite("Identifiers")
struct IdentifierTests {
    @Test func literalsAndParsing() throws {
        let numeric: Identifier = 7
        let named: Identifier = "orders"
        #expect(numeric.numericValue == 7)
        #expect(named.name == "orders")
        #expect(try Identifier(parsing: "12").numericValue == 12)
        #expect(try Identifier(parsing: "abc").name == "abc")
        #expect(throws: IggyError.self) { try Identifier(named: "") }
        #expect(throws: IggyError.self) { try Identifier(named: String(repeating: "x", count: 256)) }
        #expect("\(numeric) \(named)" == "7 orders")
    }

    @Test func wireRoundTrip() throws {
        for id: Identifier in [1, "my-stream", "café", Identifier(numeric: UInt32.max)] {
            var writer = ByteWriter()
            id.encode(into: &writer)
            var reader = ByteReader(writer.bytes)
            #expect(try Identifier.decode(from: &reader) == id)
        }
        var badKind = ByteReader([0xFF, 4, 1, 0, 0, 0])
        #expect(throws: WireError.self) { try Identifier.decode(from: &badKind) }
        var badLength = ByteReader([1, 3, 1, 0, 0])
        #expect(throws: WireError.self) { try Identifier.decode(from: &badLength) }
    }
}

@Suite("Permissions")
struct PermissionsTests {
    @Test func roundTripWithNestedTopics() throws {
        let permissions = Permissions(
            global: .all,
            streams: [
                3: StreamPermissions(readStream: true, topics: [1: TopicPermissions(readTopic: true), 2: TopicPermissions(sendMessages: true)]),
                1: StreamPermissions(manageStream: true),
            ])
        let encoded = permissions.encode()
        var reader = ByteReader(encoded)
        #expect(try Permissions.decode(from: &reader) == permissions)
        #expect(reader.isAtEnd)
        for cut in 0..<encoded.count {
            var truncated = ByteReader(Array(encoded[..<cut]))
            #expect(throws: WireError.self) { try Permissions.decode(from: &truncated) }
        }
    }

    @Test func globalOnlyIsElevenBytes() {
        #expect(Permissions(global: .all).encode().count == 11)
    }
}

@Suite("Topic options")
struct TopicOptionsTests {
    @Test func durabilityIsAlwaysSentAndRawMayStrengthenIt() throws {
        let defaults = try TopicCreateOptions().toResourceOptions()
        #expect(defaults[TopicOptionKey.durability] == .explicit("replicated"))
        #expect(defaults[TopicOptionKey.consumerOffsetDurability] == .explicit("replicated"))
        let raw = try TopicCreateOptions(raw: [TopicOptionKey.durability: "persisted"]).toResourceOptions()
        #expect(raw[TopicOptionKey.durability] == .explicit("persisted"))
        #expect(throws: IggyError.self) {
            try TopicCreateOptions(durability: .persisted, raw: [TopicOptionKey.durability: "replicated"]).toResourceOptions()
        }
        #expect(throws: IggyError.self) {
            try TopicCreateOptions(raw: [TopicOptionKey.durability: "sometimes"]).toResourceOptions()
        }
    }
}
