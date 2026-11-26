import Foundation
import XCTest

/// 单目标全链路诊断与常用服务一键连通性的纯逻辑测试。
final class NetDiagLogicTests: XCTestCase {

    func testParseTargetVariants() {
        let domain = NetDiagLogic.parseTarget("api.openai.com")
        XCTAssertEqual(domain?.scheme, "https")
        XCTAssertEqual(domain?.host, "api.openai.com")
        XCTAssertEqual(domain?.port, 443)
        XCTAssertEqual(domain?.path, "/")
        XCTAssertEqual(domain?.isIPLiteral, false)
        XCTAssertEqual(domain?.urlString, "https://api.openai.com/")

        let fullURL = NetDiagLogic.parseTarget("https://github.com/qiaob/baobox_mac?tab=readme")
        XCTAssertEqual(fullURL?.scheme, "https")
        XCTAssertEqual(fullURL?.host, "github.com")
        XCTAssertEqual(fullURL?.port, 443)
        XCTAssertEqual(fullURL?.path, "/qiaob/baobox_mac?tab=readme")

        let localHTTP = NetDiagLogic.parseTarget("127.0.0.1:3000")
        XCTAssertEqual(localHTTP?.scheme, "http")
        XCTAssertEqual(localHTTP?.host, "127.0.0.1")
        XCTAssertEqual(localHTTP?.port, 3000)
        XCTAssertEqual(localHTTP?.isIPLiteral, true)
        XCTAssertEqual(localHTTP?.urlString, "http://127.0.0.1:3000/")

        let tlsAltPort = NetDiagLogic.parseTarget("example.com:8443")
        XCTAssertEqual(tlsAltPort?.scheme, "https")
        XCTAssertEqual(tlsAltPort?.port, 8443)

        let ipv6 = NetDiagLogic.parseTarget("[2606:4700:4700::1111]:443")
        XCTAssertEqual(ipv6?.scheme, "https")
        XCTAssertEqual(ipv6?.host, "2606:4700:4700::1111")
        XCTAssertEqual(ipv6?.port, 443)
        XCTAssertEqual(ipv6?.isIPLiteral, true)
        XCTAssertEqual(ipv6?.urlString, "https://[2606:4700:4700::1111]/")

        XCTAssertNil(NetDiagLogic.parseTarget(""))
        XCTAssertNil(NetDiagLogic.parseTarget("not a host"))
    }

    func testTLSVersionAndCertExpiry() {
        XCTAssertEqual(NetDiagLogic.tlsVersionName(rawValue: 0x0304), "TLS 1.3")
        XCTAssertEqual(NetDiagLogic.tlsVersionName(rawValue: 0x0303), "TLS 1.2")
        XCTAssertNil(NetDiagLogic.tlsVersionName(rawValue: nil))
        XCTAssertNil(NetDiagLogic.tlsVersionName(rawValue: 0x9999))

        let now = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertEqual(NetDiagLogic.daysUntilExpiry(notAfter: now.addingTimeInterval(10.5 * 86_400), now: now), 10)
        XCTAssertEqual(NetDiagLogic.daysUntilExpiry(notAfter: now.addingTimeInterval(-3600), now: now), -1)
    }

    func testExtractCertificateMeta() {
        let expires = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let values: [String: Any] = [
            "notAfter": ["value": NSNumber(value: expires.timeIntervalSinceReferenceDate)],
            "issuer": [
                "value": [
                    ["label": "O", "value": "Example Org"],
                    ["label": "CN", "value": "Example Root CA"],
                ],
            ],
        ]
        let meta = NetDiagLogic.extractCertificateMeta(
            values: values,
            validityKey: "notAfter",
            issuerKey: "issuer",
            commonNameKey: "CN",
            orgKey: "O",
            fallbackIssuer: "Fallback CA"
        )
        XCTAssertEqual(meta.issuer, "Example Root CA")
        XCTAssertEqual(meta.expiresAt?.timeIntervalSinceReferenceDate ?? 0, 800_000_000, accuracy: 0.001)

        // 字典为空时退回证书链第二张的 fallbackIssuer
        let fallback = NetDiagLogic.extractCertificateMeta(values: nil, fallbackIssuer: "mitmproxy")
        XCTAssertEqual(fallback.issuer, "mitmproxy")
        XCTAssertNil(fallback.expiresAt)
    }

    func testClassifyServiceResponse() {
        XCTAssertEqual(NetDiagLogic.classifyServiceResponse(statusCode: 204, headers: [:], bodyPrefix: "", acceptsAuthErrors: false),
                       .reachable(status: 204))
        // OpenAI / Anthropic 不带 key 返回 401 / 405 = 可达
        XCTAssertEqual(NetDiagLogic.classifyServiceResponse(statusCode: 401, headers: [:], bodyPrefix: "", acceptsAuthErrors: true),
                       .reachable(status: 401))
        XCTAssertEqual(NetDiagLogic.classifyServiceResponse(statusCode: 405, headers: [:], bodyPrefix: "", acceptsAuthErrors: true),
                       .reachable(status: 405))
        // 非鉴权站点 401 不算可达
        XCTAssertEqual(NetDiagLogic.classifyServiceResponse(statusCode: 401, headers: [:], bodyPrefix: "", acceptsAuthErrors: false),
                       .unreachable(.other, detail: "HTTP 401"))
        // 地区限制 / Cloudflare 盾 403
        XCTAssertEqual(NetDiagLogic.classifyServiceResponse(statusCode: 403,
                                                            headers: ["cf-mitigated": "challenge"],
                                                            bodyPrefix: "", acceptsAuthErrors: true),
                       .restricted(status: 403))
        XCTAssertTrue(NetDiagLogic.isRestrictedOrChallenged(headers: [:],
                                                            bodyPrefix: #"{"error":{"code":"unsupported_country_region_territory"}}"#))
        XCTAssertEqual(NetDiagLogic.classifyServiceResponse(statusCode: 503, headers: [:], bodyPrefix: "", acceptsAuthErrors: false),
                       .unreachable(.other, detail: "HTTP 503"))
    }

    func testClassifyErrors() {
        XCTAssertEqual(NetDiagLogic.classifyError(URLError(.timedOut)), .timeout)
        XCTAssertEqual(NetDiagLogic.classifyError(URLError(.cannotFindHost)), .dnsFailed)
        XCTAssertEqual(NetDiagLogic.classifyError(URLError(.serverCertificateUntrusted)), .tlsError)
        XCTAssertEqual(NetDiagLogic.classifyError(URLError(.cannotConnectToHost)), .connectionFailed)
    }

    func testBuiltInServicesHaveUniqueIDsAndValidURLs() {
        let services = NetDiagLogic.builtInServices
        XCTAssertGreaterThanOrEqual(services.count, 6)
        XCTAssertEqual(Set(services.map(\.id)).count, services.count)
        for service in services {
            XCTAssertNotNil(NetDiagLogic.parseTarget(service.url), service.id)
        }
    }
}
