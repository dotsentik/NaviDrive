import Testing

@Suite("Cloud link hosts (SEC-019)")
struct LinkHostsTests {
    @Test func googleHosts() {
        #expect(LinkHosts.isGoogle("drive.google.com"))
        #expect(LinkHosts.isGoogle("docs.google.com"))
        #expect(LinkHosts.isGoogle("google.com"))
        #expect(LinkHosts.isGoogle("DRIVE.Google.COM"))
        #expect(LinkHosts.isGoogle("lh3.googleusercontent.com"))
    }

    @Test func lookalikeGoogleHostsAreRejected() {
        #expect(!LinkHosts.isGoogle("evilgoogle.com"))
        #expect(!LinkHosts.isGoogle("drive.evilgoogle.com"))
        #expect(!LinkHosts.isGoogle("google.com.evil.example"))
        #expect(!LinkHosts.isGoogle("notgoogleusercontent.com"))
    }

    @Test func dropboxHosts() {
        #expect(LinkHosts.isDropbox("dropbox.com"))
        #expect(LinkHosts.isDropbox("www.dropbox.com"))
        #expect(LinkHosts.isDropbox("db.tt"))
        #expect(!LinkHosts.isDropbox("evildropbox.com"))
        #expect(!LinkHosts.isDropbox("dropbox.com.evil.example"))
        #expect(!LinkHosts.isDropbox("x.db.tt"))
    }

    @Test func onlyWebSchemes() {
        #expect(LinkHosts.isWebScheme("https"))
        #expect(LinkHosts.isWebScheme("HTTP"))
        #expect(!LinkHosts.isWebScheme("javascript"))
        #expect(!LinkHosts.isWebScheme("file"))
        #expect(!LinkHosts.isWebScheme(nil))
    }
}
