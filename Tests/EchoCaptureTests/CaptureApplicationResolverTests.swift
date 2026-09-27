import XCTest
@testable import EchoCapture

final class CaptureApplicationResolverTests: XCTestCase {
    private func app(_ pid: Int32, _ id: String?, _ path: String?, regular: Bool = true) -> CaptureApplicationIdentity {
        CaptureApplicationIdentity(pid: pid, bundleID: id, name: id ?? "Application", bundlePath: path, isRegular: regular)
    }
    func testBraveHelperWithoutRunningApplicationMapsToRegularBrowser() {
        let brave = app(1, "com.brave.Browser", "/Applications/Brave Browser.app")
        let helper = app(2, "com.brave.Browser.helper", "/Applications/Brave Browser.app/Contents/Helpers/Helper.app", regular: false)
        XCTAssertEqual(CaptureApplicationResolver.owner(pid: 3, bundleID: "com.brave.Browser.helper", executablePath: nil, applications: [helper, brave]), brave)
    }
    func testSharedWebKitHelpersNeverAttributeToOtherAppsOrMerge() {
        let zoom = app(1, "us.zoom.xos", "/Applications/zoom.us.app")
        let drive = app(2, "com.google.drivefs", "/Applications/Google Drive.app")
        let zoomGPU = app(3, "com.apple.WebKit.GPU", "/System/WebKit/GPU.xpc", regular: false)
        let driveGPU = app(4, "com.apple.WebKit.GPU", "/System/WebKit/GPU.xpc", regular: false)
        for pid in [Int32(3), 4] {
            XCTAssertNil(CaptureApplicationResolver.owner(pid: pid, bundleID: "com.apple.WebKit.GPU", executablePath: "/System/WebKit/GPU.xpc/Contents/MacOS/GPU", applications: [zoom, drive, zoomGPU, driveGPU]))
        }
    }
    func testZoomCaphostBelongsToEnclosingAppDespiteDifferentBundleNamespace() {
        let zoom = app(1, "us.zoom.xos", "/Applications/zoom.us.app")
        XCTAssertEqual(CaptureApplicationResolver.owner(pid: 2, bundleID: "us.zoom.caphost", executablePath: "/Applications/zoom.us.app/Contents/Frameworks/caphost.app/Contents/MacOS/caphost", applications: [zoom]), zoom)
    }
    func testExactRegularFixtureIsSelectableAndDaemonIsNot() {
        let fixture = app(1, "com.example.Fixture", "/Project/Fixture.app")
        let daemon = app(2, "com.apple.audiomxd", nil, regular: false)
        XCTAssertEqual(CaptureApplicationResolver.owner(pid: 1, bundleID: "com.example.Fixture", executablePath: nil, applications: [fixture, daemon]), fixture)
        XCTAssertNil(CaptureApplicationResolver.owner(pid: 2, bundleID: "com.apple.audiomxd", executablePath: nil, applications: [fixture, daemon]))
    }
    func testNamespaceAndPathBoundariesDoNotWidenToSimilarlyNamedApps() {
        let brave = app(1, "com.brave.Browser", "/Applications/Brave Browser.app")
        XCTAssertNil(CaptureApplicationResolver.owner(pid: 2, bundleID: "com.brave.BrowserOther", executablePath: "/Applications/Brave Browser.app.other/helper", applications: [brave]))
    }
    func testAmbiguousRegularNamespaceIsOmitted() {
        let outer = app(1, "com.example.App", "/Applications/One.app")
        let distinct = app(2, "com.example.App.Other", "/Applications/Two.app")
        XCTAssertNil(CaptureApplicationResolver.owner(pid: 3, bundleID: "com.example.App.Other.helper", executablePath: nil, applications: [outer, distinct]))
    }
}
