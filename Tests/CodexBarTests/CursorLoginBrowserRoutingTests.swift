import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CursorLoginBrowserRoutingTests {
    private static let authURL = URL(string: "https://authenticator.cursor.sh/")!
    private static let cometApplicationURL = URL(fileURLWithPath: "/Applications/Comet.app")
    private static let chromeApplicationURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
    private static let handlerApplicationURL = URL(fileURLWithPath: "/Applications/Link Router.app")

    @Test
    func `supported handler is pinned for launch and polling`() {
        let loginURL = Self.authURL
        var discoveryURLs: [URL] = []
        var chooserCalls = 0

        let resolution = CursorLoginBrowserRouter.resolve(
            loginURL: loginURL,
            handlerApplicationURL: Self.cometApplicationURL,
            applicationURLs: {
                discoveryURLs.append($0)
                return [Self.chromeApplicationURL]
            },
            chooseApplication: { _ in
                chooserCalls += 1
                return Self.chromeApplicationURL
            },
            supportsBrowser: Self.supportsFixtureBrowser)

        #expect(resolution == .route(.init(
            launchURL: loginURL,
            browserApplicationURL: Self.cometApplicationURL)))
        #expect(discoveryURLs.isEmpty)
        #expect(chooserCalls == 0)
    }

    @Test
    func `known handler with unavailable cookie source falls back to browser chooser`() {
        var chooserCandidates: [URL] = []
        let resolution = CursorLoginBrowserRouter.resolve(
            loginURL: Self.authURL,
            handlerApplicationURL: Self.cometApplicationURL,
            applicationURLs: { _ in [Self.cometApplicationURL, Self.chromeApplicationURL] },
            chooseApplication: { candidates in
                chooserCandidates = candidates
                return Self.chromeApplicationURL
            },
            supportsBrowser: { applicationURL in
                applicationURL == Self.chromeApplicationURL
            })

        #expect(chooserCandidates == [Self.chromeApplicationURL])
        #expect(resolution == .route(.init(
            launchURL: Self.authURL,
            browserApplicationURL: Self.chromeApplicationURL)))
    }

    @Test
    func `unsupported handler asks for explicit selection of the sole supported application`() {
        let loginURL = Self.authURL
        var discoveryURLs: [URL] = []
        var chooserCalls = 0

        let resolution = CursorLoginBrowserRouter.resolve(
            loginURL: loginURL,
            handlerApplicationURL: Self.handlerApplicationURL,
            applicationURLs: {
                discoveryURLs.append($0)
                return [
                    URL(fileURLWithPath: "/Applications/Unsupported.app"),
                    Self.cometApplicationURL,
                ]
            },
            chooseApplication: { candidates in
                chooserCalls += 1
                #expect(candidates == [Self.cometApplicationURL])
                return Self.cometApplicationURL
            },
            supportsBrowser: Self.supportsFixtureBrowser)

        #expect(resolution == .route(.init(
            launchURL: loginURL,
            browserApplicationURL: Self.cometApplicationURL)))
        #expect(discoveryURLs == [loginURL])
        #expect(chooserCalls == 1)
    }

    @Test
    func `missing handler asks for explicit selection of a sole supported application`() {
        var chooserCandidates: [URL] = []
        let resolution = CursorLoginBrowserRouter.resolve(
            loginURL: Self.authURL,
            handlerApplicationURL: nil,
            applicationURLs: { _ in [Self.chromeApplicationURL] },
            chooseApplication: {
                chooserCandidates = $0
                return Self.chromeApplicationURL
            },
            supportsBrowser: Self.supportsFixtureBrowser)

        #expect(chooserCandidates == [Self.chromeApplicationURL])
        #expect(resolution == .route(.init(
            launchURL: Self.authURL,
            browserApplicationURL: Self.chromeApplicationURL)))
    }

    @Test
    func `multiple supported applications use the explicit selection`() {
        var chooserCandidates: [URL] = []
        let resolution = CursorLoginBrowserRouter.resolve(
            loginURL: Self.authURL,
            handlerApplicationURL: Self.handlerApplicationURL,
            applicationURLs: { _ in [
                Self.chromeApplicationURL,
                Self.cometApplicationURL,
                URL(fileURLWithPath: "/Applications/Unsupported.app"),
                Self.cometApplicationURL,
            ] },
            chooseApplication: {
                chooserCandidates = $0
                return Self.chromeApplicationURL
            },
            supportsBrowser: Self.supportsFixtureBrowser)

        #expect(chooserCandidates == [Self.cometApplicationURL, Self.chromeApplicationURL])
        #expect(resolution == .route(.init(
            launchURL: Self.authURL,
            browserApplicationURL: Self.chromeApplicationURL)))
    }

    @Test
    func `cancelling the explicit chooser with one candidate is distinct from unavailable`() {
        let resolution = CursorLoginBrowserRouter.resolve(
            loginURL: Self.authURL,
            handlerApplicationURL: Self.handlerApplicationURL,
            applicationURLs: { _ in [Self.cometApplicationURL] },
            chooseApplication: { _ in nil },
            supportsBrowser: Self.supportsFixtureBrowser)

        #expect(resolution == .cancelled)
    }

    @Test
    func `no supported application is unavailable without showing a chooser`() {
        var chooserCalls = 0
        let resolution = CursorLoginBrowserRouter.resolve(
            loginURL: Self.authURL,
            handlerApplicationURL: Self.handlerApplicationURL,
            applicationURLs: { _ in [URL(fileURLWithPath: "/Applications/Unsupported.app")] },
            chooseApplication: { _ in
                chooserCalls += 1
                return Self.cometApplicationURL
            },
            supportsBrowser: Self.supportsFixtureBrowser)

        #expect(resolution == .unavailable)
        #expect(chooserCalls == 0)
    }

    @Test
    func `chooser cannot return an application outside the supported candidates`() {
        let resolution = CursorLoginBrowserRouter.resolve(
            loginURL: Self.authURL,
            handlerApplicationURL: Self.handlerApplicationURL,
            applicationURLs: { _ in [Self.cometApplicationURL, Self.chromeApplicationURL] },
            chooseApplication: { _ in URL(fileURLWithPath: "/Applications/Safari.app") },
            supportsBrowser: Self.supportsFixtureBrowser)

        #expect(resolution == .unavailable)
    }

    @Test
    func `candidate labels are stable and disambiguate duplicate application names`() {
        let applications = [
            URL(fileURLWithPath: "/Applications/Comet.app"),
            URL(fileURLWithPath: "/Volumes/Tools/Comet.app"),
            Self.chromeApplicationURL,
        ]

        #expect(CursorLoginBrowserRouter.applicationLabels(applications) == [
            "Comet (/Applications)",
            "Comet (/Volumes/Tools)",
            "Google Chrome",
        ])
    }

    private static func supportsFixtureBrowser(_ applicationURL: URL?) -> Bool {
        applicationURL == self.cometApplicationURL || applicationURL == self.chromeApplicationURL
    }
}
