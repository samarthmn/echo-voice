import XCTest
@testable import EchoIntelligence

private final class OllamaStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url, let client else { return }
        Self.requests.append(request)
        do {
            let (response, data) = try handler(request)
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: data)
            client.urlProtocolDidFinishLoading(self)
        } catch {
            client.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class OllamaNotesTests: XCTestCase {
    func testDiscoveryKeepsOnlyLocalTextGenerationModels() throws {
        let payload = Data(#"""
        {"models":[
          {"name":"qwen3:4b","model":"qwen3:4b","size":2500,"digest":"abc","details":{"family":"qwen3"}},
          {"name":"nomic-embed-text:latest","model":"nomic-embed-text:latest","size":100,"digest":"def","details":{"family":"nomic-bert"}},
          {"name":"gpt-oss:cloud","model":"gpt-oss:cloud","size":0,"digest":"ghi","details":{"family":"gptoss"}},
          {"name":"gpt-oss:120b-cloud","model":"gpt-oss:120b-cloud","size":9000,"digest":"jkl","details":{"family":"gptoss"}},
          {"name":"meeting-notes","model":"meeting-notes","size":9000,"digest":"mno","remote_model":"gpt-oss:120b","remote_host":"https://ollama.com","details":{"family":"gptoss"}}
        ]}
        """#.utf8)
        let models = try OllamaNotesClient.compatibleModels(from: payload)
        XCTAssertEqual(models.map(\.name), ["qwen3:4b"])
        XCTAssertEqual(models.first?.digest, "abc")
        XCTAssertFalse(OllamaNotesClient.runsLocally(["capabilities": ["completion"], "remote_model": "gpt-oss:120b", "model_info": ["general.architecture": "gptoss"]]))
        XCTAssertFalse(OllamaNotesClient.runsLocally(["capabilities": ["completion"]]))
        XCTAssertFalse(OllamaNotesClient.runsLocally(["capabilities": ["completion"], "model_info": [String: Any]()]))
        XCTAssertFalse(OllamaNotesClient.runsLocally(["capabilities": ["completion"], "remote_host": ["https://ollama.com"], "model_info": ["general.architecture": "gptoss"]]))
        XCTAssertTrue(OllamaNotesClient.runsLocally(["capabilities": ["completion"], "remote_model": "", "remote_host": "  ", "model_info": ["general.architecture": "qwen3"]]))
        XCTAssertTrue(OllamaNotesClient.runsLocally(["capabilities": ["completion"], "model_info": ["general.architecture": "qwen3"]]))
        XCTAssertTrue(OllamaNotesClient.cloudTag("gpt-oss:cloud"))
        XCTAssertTrue(OllamaNotesClient.cloudTag("gpt-oss:120b-cloud"))
        XCTAssertFalse(OllamaNotesClient.cloudTag("meeting-notes"))
    }

    func testCloudBackedModelIsRejectedBeforeAnyTranscriptIsSent() async throws {
        OllamaStub.requests = []
        OllamaStub.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.path.hasSuffix("/api/tags") {
                let body = Data(#"{"models":[{"name":"meeting-notes","model":"meeting-notes","size":9000,"digest":"mno","details":{"family":"gptoss"}}]}"#.utf8)
                return (response, body)
            }
            if url.path.hasSuffix("/api/show") {
                let body = Data(#"{"remote_model":"gpt-oss:120b","remote_host":"https://ollama.com","capabilities":["completion"],"model_info":{"general.architecture":"gptoss"}}"#.utf8)
                return (response, body)
            }
            if url.path.hasSuffix("/api/chat") { return (response, Data(#"{"message":{"content":"should-not-run"}}"#.utf8)) }
            throw URLError(.badURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStub.self]
        let client = OllamaNotesClient(session: URLSession(configuration: configuration))
        let listed = try await client.models()
        XCTAssertTrue(listed.isEmpty)
        do {
            _ = try await client.chat(model: .init(name: "meeting-notes", digest: "mno", size: 9000), evidence: "[e1] private transcript", repair: false)
            XCTFail("cloud model was accepted")
        } catch OllamaNotesError.unsupportedModel {}
        XCTAssertFalse(OllamaStub.requests.contains { $0.url?.path.hasSuffix("/api/chat") == true })
    }

    func testMissingAndInvalidLocalityMetadataAreRejectedBeforeChat() async throws {
        OllamaStub.requests = []
        OllamaStub.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.path.hasSuffix("/api/tags") {
                return (response, Data(#"{"models":[{"name":"alias","model":"alias","size":9000,"digest":"mno","details":{"family":"gptoss"}}]}"#.utf8))
            }
            if url.path.hasSuffix("/api/show") {
                return (response, Data(#"{"capabilities":["completion"],"remote_host":{"url":"https://ollama.com"}}"#.utf8))
            }
            if url.path.hasSuffix("/api/chat") { return (response, Data(#"{"message":{"content":"[e1] private transcript should-not-run"}}"#.utf8)) }
            throw URLError(.badURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStub.self]
        let client = OllamaNotesClient(session: URLSession(configuration: configuration))
        let listed = try await client.models()
        XCTAssertTrue(listed.isEmpty)
        do {
            _ = try await client.chat(model: .init(name: "alias", digest: "mno", size: 9000), evidence: "[e1] private transcript", repair: false)
            XCTFail("unknown locality was accepted")
        } catch OllamaNotesError.unsupportedModel {}
        XCTAssertFalse(OllamaStub.requests.contains { $0.url?.path.hasSuffix("/api/chat") == true })
    }

    func testModelThatBecomesRemoteAfterDiscoveryIsRejectedBeforeChat() async throws {
        final class ShowCount: @unchecked Sendable { var value = 0 }
        let shows = ShowCount()
        OllamaStub.requests = []
        OllamaStub.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.path.hasSuffix("/api/tags") {
                return (response, Data(#"{"models":[{"name":"alias","model":"alias","size":9000,"digest":"mno","details":{"family":"gptoss"}}]}"#.utf8))
            }
            if url.path.hasSuffix("/api/show") {
                shows.value += 1
                let body = shows.value == 1
                    ? Data(#"{"capabilities":["completion"],"model_info":{"general.architecture":"qwen3"}}"#.utf8)
                    : Data(#"{"remote_model":"gpt-oss:120b","remote_host":"https://ollama.com","capabilities":["completion"],"model_info":{"general.architecture":"qwen3"}}"#.utf8)
                return (response, body)
            }
            if url.path.hasSuffix("/api/chat") { return (response, Data(#"{"message":{"content":"[e1] private transcript should-not-run"}}"#.utf8)) }
            throw URLError(.badURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStub.self]
        let client = OllamaNotesClient(session: URLSession(configuration: configuration))
        let listed = try await client.models()
        XCTAssertEqual(listed.map(\.name), ["alias"])
        do {
            _ = try await client.chat(model: listed[0], evidence: "[e1] private transcript", repair: false)
            XCTFail("remote revalidation was accepted")
        } catch OllamaNotesError.unsupportedModel {}
        XCTAssertFalse(OllamaStub.requests.contains { $0.url?.path.hasSuffix("/api/chat") == true })
    }

    func testConfirmedLocalModelCanGenerateNotes() async throws {
        OllamaStub.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.path.hasSuffix("/api/tags") {
                return (response, Data(#"{"models":[{"name":"qwen3:4b","model":"qwen3:4b","size":2500,"digest":"abc","details":{"family":"qwen3"}}]}"#.utf8))
            }
            if url.path.hasSuffix("/api/show") {
                return (response, Data(#"{"capabilities":["completion"],"model_info":{"general.architecture":"qwen3"}}"#.utf8))
            }
            if url.path.hasSuffix("/api/chat") {
                return (response, Data(#"{"message":{"content":"{\"summary\":[]}"}}"#.utf8))
            }
            throw URLError(.badURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStub.self]
        let client = OllamaNotesClient(session: URLSession(configuration: configuration))
        let listed = try await client.models()
        XCTAssertEqual(listed.map(\.name), ["qwen3:4b"])
        let content = try await client.chat(model: listed[0], evidence: "[e1] hello", repair: false)
        XCTAssertTrue(content.contains("summary"))
    }

    func testChatRequestUsesPinnedModelAndStructuredOutput() throws {
        let request = try OllamaNotesClient.chatRequest(model: .init(name: "qwen3:4b", digest: "abc", size: 2500), evidence: "[e1] hello", repair: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "qwen3:4b")
        XCTAssertEqual(object["stream"] as? Bool, false)
        XCTAssertNotNil(object["format"] as? [String: Any])
        XCTAssertEqual((object["options"] as? [String: Any])?["temperature"] as? Int, 0)
    }
}
