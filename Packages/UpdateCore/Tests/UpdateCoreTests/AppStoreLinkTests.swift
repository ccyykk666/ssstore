import XCTest
@testable import UpdateCore

final class AppStoreLinkTests: XCTestCase {
    func testStoreLinksAndDeepLinkRoundTrip() throws {
        let link = try XCTUnwrap(AppStoreLink.parse("https://apps.apple.com/cn/app/微信/id414478124?l=en&at=affiliate"))
        XCTAssertEqual(link.appID, 414478124)
        XCTAssertEqual(link.country, "CN")
        XCTAssertEqual(AppStoreLink(url: link.deepLink), link)
        XCTAssertEqual(link.storeURL.absoluteString, "https://apps.apple.com/cn/app/id414478124")
        XCTAssertEqual(AppStoreLink.parse("https://itunes.apple.com/us/app/name/id123")?.country, "US")
    }

    func testSharedTextAndCountrylessLink() throws {
        let link = try XCTUnwrap(AppStoreLink.parse("看看这个应用 https://apps.apple.com/app/id414478124"))
        XCTAssertNil(link.country)
        XCTAssertEqual(link.appID, 414478124)
        let query = try XCTUnwrap(URLComponents(url: link.lookupURL(country: "US"), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "id", value: "414478124")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "country", value: "US")))
    }

    func testRejectsUnrelatedHostsAndInvalidIdentifiers() {
        for url in ["https://apps.apple.com.evil.example/cn/app/id123", "https://example.com/cn/app/id123",
                    "https://apps.apple.com/cn/app/id0", "https://apps.apple.com/cn/app/id-1",
                    "https://apps.apple.com/cn/app/id123abc", "https://apps.apple.com/cn/app/id9999999999999999999999",
                    "https://apps.apple.com/cn/app/id123/other", "ssstore://app?id=123&country=../../../",
                    "ssstore://other?id=123", "file:///cn/app/id123"] {
            XCTAssertNil(AppStoreLink.parse(url), url)
        }
    }
}
