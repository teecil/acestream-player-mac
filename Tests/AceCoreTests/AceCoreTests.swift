@testable import AceCore
import XCTest

final class LinkParserTests: XCTestCase {
    private let id = "0123456789abcdef0123456789abcdef01234567"

    func testAcestreamScheme() {
        XCTAssertEqual(try LinkParser.parse("acestream://\(id)").get(), .contentID(id))
        XCTAssertEqual(try LinkParser.parse("  acestream://\(id.uppercased())/ \n").get(), .contentID(id))
    }

    func testLinkInsideText() {
        XCTAssertEqual(try LinkParser.parse("Матч тут: acestream://\(id) — смотрите!").get(), .contentID(id))
    }

    func testBareID() {
        XCTAssertEqual(try LinkParser.parse(id).get(), .contentID(id))
        XCTAssertEqual(try LinkParser.parse("\"\(id)\"").get(), .contentID(id))
    }

    func testRejectsWrongLength() {
        XCTAssertEqual(LinkParser.parse("acestream://\(id)ff").failureValue, .unsupported)
        XCTAssertEqual(LinkParser.parse(String(id.dropLast())).failureValue, .unsupported)
    }

    func testEmptyAndGarbage() {
        XCTAssertEqual(LinkParser.parse("   ").failureValue, .empty)
        XCTAssertEqual(LinkParser.parse("https://example.com/page").failureValue, .unsupported)
        XCTAssertEqual(LinkParser.parse("hello").failureValue, .unsupported)
    }

    func testEngineURLs() {
        XCTAssertEqual(try LinkParser.parse("http://127.0.0.1:6878/ace/getstream?id=\(id)").get(), .contentID(id))
        XCTAssertEqual(try LinkParser.parse("http://127.0.0.1:6878/ace/getstream?infohash=\(id)").get(), .infohash(id))
    }

    func testMagnet() {
        XCTAssertEqual(try LinkParser.parse("magnet:?xt=urn:btih:\(id)&dn=x").get(), .infohash(id))
        let base32 = "magnet:?xt=urn:btih:ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        XCTAssertEqual(try LinkParser.parse(base32).get(), .magnet(base32))
    }

    func testTorrentURL() throws {
        let url = "https://example.com/files/stream.acelive"
        XCTAssertEqual(try LinkParser.parse(url).get(), .torrentURL(URL(string: url)!))
    }

    func testQueryEncodingEscapesReservedCharacters() {
        let q = QueryEncoding.encode([("magnet", "magnet:?xt=urn:btih:abc&dn=a b+c")])
        XCTAssertEqual(q, "magnet=magnet%3A%3Fxt%3Durn%3Abtih%3Aabc%26dn%3Da%20b%2Bc")
    }
}

final class EngineJSONTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:16878")!

    func testParseSessionRebasesURLs() throws {
        let json = """
        {"response": {"playback_url": "http://127.0.0.1:6878/ace/r/abc/def",
                      "stat_url": "http://127.0.0.1:6878/ace/stat/abc/def",
                      "command_url": "http://127.0.0.1:6878/ace/cmd/abc/def",
                      "infohash": "abc", "is_live": 1}, "error": null}
        """
        let s = try EngineJSON.parseSession(Data(json.utf8), rebasingTo: base)
        XCTAssertEqual(s.playbackURL.absoluteString, "http://127.0.0.1:16878/ace/r/abc/def")
        XCTAssertEqual(s.statURL.absoluteString, "http://127.0.0.1:16878/ace/stat/abc/def")
        XCTAssertEqual(s.commandURL.absoluteString, "http://127.0.0.1:16878/ace/cmd/abc/def")
        XCTAssertTrue(s.isLive)
    }

    func testParseSessionError() {
        let json = #"{"response": null, "error": "failed to load content"}"#
        XCTAssertThrowsError(try EngineJSON.parseSession(Data(json.utf8), rebasingTo: base)) { error in
            XCTAssertEqual(error as? EngineAPIError, .engine("failed to load content"))
        }
    }

    func testParseStats() throws {
        let json = #"{"response": {"status": "dl", "peers": 12, "speed_down": 850, "downloaded": 1048576}, "error": null}"#
        let stats = try EngineJSON.parseStats(Data(json.utf8))
        XCTAssertEqual(stats, EngineStats(status: "dl", peers: 12, speedDown: 850, downloaded: 1_048_576))
    }

    func testParseVersion() throws {
        let json = #"{"result": {"code": 3017000, "platform": "android", "version": "3.2.17"}, "error": null}"#
        XCTAssertEqual(try EngineJSON.parseVersion(Data(json.utf8)), "3.2.17")
    }

    func testMalformed() {
        XCTAssertThrowsError(try EngineJSON.parseStats(Data("<html>".utf8)))
    }
}

final class MachOAndDockerTests: XCTestCase {
    func testThinARM64() {
        let header = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01])
        XCTAssertEqual(MachOArch.cpuTypes(header: header), [MachOArch.cpuARM64])
    }

    func testUniversal() {
        var d = Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2])
        d += Data([0x01, 0, 0, 0x07]) + Data(count: 16) // x86_64 entry
        d += Data([0x01, 0, 0, 0x0C]) + Data(count: 16) // arm64 entry
        XCTAssertEqual(MachOArch.cpuTypes(header: d), [MachOArch.cpuARM64, MachOArch.cpuX86_64])
    }

    func testPullProgress() {
        var p = PullProgress()
        p.feed("v3.2.17-fix: Pulling from jopsis/acestream")
        p.feed("a1b2c3d4e5f6: Pulling fs layer")
        p.feed("0123456789ab: Pulling fs layer")
        p.feed("a1b2c3d4e5f6: Pull complete")
        XCTAssertEqual(p.fraction, 0.5)
        p.feed("0123456789ab: Already exists")
        XCTAssertEqual(p.fraction, 1)
    }

    func testPullFailureClassification() {
        XCTAssertEqual(DockerPullFailure.classify("toomanyrequests: You have reached your pull rate limit"), .rateLimited)
        XCTAssertEqual(DockerPullFailure.classify("dial tcp: lookup registry-1.docker.io: no such host"), .network)
        XCTAssertEqual(DockerPullFailure.classify("no matching manifest for linux/arm64/v8"), .platformUnsupported)
        XCTAssertEqual(DockerPullFailure.classify("write /var/lib: no space left on device"), .diskFull)
    }

    func testShellQuote() {
        XCTAssertEqual(ShellQuote.sh("/Volumes/My App/it's"), "'/Volumes/My App/it'\\''s'")
        XCTAssertEqual(ShellQuote.appleScript(#"a "b" \c"#), #""a \"b\" \\c""#)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}

final class VersionTests: XCTestCase {
    func testComparison() {
        XCTAssertTrue(Version.isNewer("v1.2.1", than: "1.2.0"))
        XCTAssertTrue(Version.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(Version.isNewer("2.0", than: "1.99.99"))
        XCTAssertFalse(Version.isNewer("v1.2.0", than: "1.2.0"))
        XCTAssertFalse(Version.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(Version.isNewer("1.1.4", than: "1.2.0"))
    }

    func testClean() {
        XCTAssertEqual(Version.clean("v1.2.0"), "1.2.0")
        XCTAssertEqual(Version.clean(" 1.2.0\n"), "1.2.0")
    }
}
