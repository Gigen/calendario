import CalendarDomain
import Foundation
import Testing

struct NormalizationTests {
    let cal = makeCalendar()

    @Test func allDayEndFromEventKitInclusiveForm() {
        let end = Normalization.allDayExclusiveEnd(start: cal.date(2026, 10, 5), end: cal.date(2026, 10, 5, 23, 59, 59), calendar: cal)
        #expect(end == cal.date(2026, 10, 6))
    }

    @Test func allDayEndAlreadyExclusiveIsKept() {
        let end = Normalization.allDayExclusiveEnd(start: cal.date(2026, 10, 5), end: cal.date(2026, 10, 7), calendar: cal)
        #expect(end == cal.date(2026, 10, 7))
    }

    @Test func allDayEndWithZeroLengthBecomesOneDay() {
        let end = Normalization.allDayExclusiveEnd(start: cal.date(2026, 10, 5), end: cal.date(2026, 10, 5), calendar: cal)
        #expect(end == cal.date(2026, 10, 6))
    }

    @Test func allDayEndAcrossDSTChange() {
        let end = Normalization.allDayExclusiveEnd(start: cal.date(2026, 10, 25), end: cal.date(2026, 10, 25, 23, 59, 59), calendar: cal)
        #expect(end == cal.date(2026, 10, 26))
    }

    @Test(arguments: [
        ("mailto:Ana@Example.com", "ana@example.com"),
        ("mailto:bob%40example.com", "bob@example.com"),
        ("mailto:carl@example.com?subject=hi", "carl@example.com"),
        ("dana@example.org", "dana@example.org"),
    ])
    func emailFromMailto(input: String, expected: String) {
        #expect(Normalization.email(fromMailto: input) == expected)
    }

    @Test func emailFromNonEmailURL() {
        #expect(Normalization.email(fromMailto: "urn:uuid:1234-5678") == nil)
        #expect(Normalization.email(fromMailto: "mailto:") == nil)
    }

    @Test(arguments: [
        ("iCloud", SourceKind.iCloud),
        ("someone@icloud.com", .iCloud),
        ("Google", .google),
        ("me@gmail.com", .google),
        ("Fastmail", .calDAV),
        ("me@company.com", .calDAV), // could be Workspace; refined once the account is connected
    ])
    func calDAVSourceKind(title: String, expected: SourceKind) {
        #expect(Normalization.calDAVSourceKind(title: title) == expected)
    }
}
