import CameraTransport
import Foundation
import Testing
@testable import AppUI

// Auto-import's once-per-connection state (backlog section 14): a USB connection from appearance to disappearance, a
// Wi-Fi connection one Browse visit.

@Suite("Auto-import: once per connection")
struct AutoImportArmsTests {
    let usb = CameraDescriptor(id: .init(rawValue: "usb"), name: "ILCE-7CM2", mode: .usb(.mtp))
    let wifi = CameraDescriptor(id: .init(rawValue: "wifi"), name: "ILCE-7CM2", mode: .wifi(.cameraNetwork))
    let offline = CameraDescriptor(id: .init(rawValue: "offline-1"), name: "ILCE-7CM2", mode: .wifi(.cameraNetwork))

    func notOffline(_ id: CameraDescriptor.ID) -> Bool { false }

    @Test func aUSBAppearanceArmsUndecidedAndAWiFiOneNever() {
        var arms = AutoImportArms()
        let r1 = arms.connected(usb)
        #expect(r1)
        #expect(arms.state(of: usb.id) == .undecided)
        let r2 = arms.connected(wifi)
        #expect(!r2)
        #expect(arms.state(of: wifi.id) == nil)
        #expect(arms.undecided == [usb.id])
        #expect(arms.waiting.isEmpty)
    }

    @Test func aDisappearanceEndsTheConnectionAndAReplugArmsAgain() {
        var arms = AutoImportArms()
        _ = arms.connected(usb)
        arms.decided(usb.id, .on)
        _ = arms.beginDeciding(usb.id)
        arms.finishDeciding(usb.id, .ended(.started))
        arms.disconnected(usb.id)
        #expect(arms.state(of: usb.id) == nil)
        let r3 = arms.connected(usb)
        #expect(r3)
        #expect(arms.state(of: usb.id) == .undecided)
    }

    @Test func decidedOnWaitsAndOffEnds() {
        var arms = AutoImportArms()
        _ = arms.connected(usb)
        arms.decided(usb.id, .on)
        #expect(arms.state(of: usb.id) == .waiting)
        #expect(arms.waiting == [usb.id])
        // Only an undecided connection is decided.
        arms.decided(usb.id, .off)
        #expect(arms.state(of: usb.id) == .waiting)
        let other = CameraDescriptor(id: .init(rawValue: "usb-2"), name: "Untitled", mode: .usb(.massStorage))
        _ = arms.connected(other)
        arms.decided(other.id, .noName)
        #expect(arms.state(of: other.id) == .ended(.off(.noName)))
    }

    @Test func beginDecidingIsTrueOnceUntilFinished() {
        var arms = AutoImportArms()
        _ = arms.connected(usb)
        let r4 = arms.beginDeciding(usb.id)
        #expect(r4)   // undecided: a listing may decide it
        let r5 = arms.beginDeciding(usb.id)
        #expect(!r5)
        #expect(arms.state(of: usb.id) == .deciding)
        arms.finishDeciding(usb.id, .waiting)
        let r6 = arms.beginDeciding(usb.id)
        #expect(r6)
        arms.finishDeciding(usb.id, .ended(.jobRunning))
        let r7 = arms.beginDeciding(usb.id)
        #expect(!r7)
        // Finishing from anything but deciding changes nothing.
        arms.finishDeciding(usb.id, .waiting)
        #expect(arms.state(of: usb.id) == .ended(.jobRunning))
        let r8 = arms.beginDeciding(wifi.id)
        #expect(!r8)
    }

    @Test func aWiFiVisitStartsWhenItsCameraIsOpenedAndEndsWhenItIsLeft() {
        var arms = AutoImportArms()
        let r9 = arms.pathChanged(to: [wifi], isOffline: notOffline)
        #expect(r9.isEmpty)
        #expect(arms.state(of: wifi.id) == .waiting)
        _ = arms.beginDeciding(wifi.id)
        arms.finishDeciding(wifi.id, .ended(.started))
        // The same path again is the same visit: not armed again.
        _ = arms.pathChanged(to: [wifi], isOffline: notOffline)
        #expect(arms.state(of: wifi.id) == .ended(.started))
        // Left: the visit ends, and nothing is said about it.
        let r10 = arms.pathChanged(to: [], isOffline: notOffline)
        #expect(r10.isEmpty)
        #expect(arms.state(of: wifi.id) == nil)
        // A new visit.
        _ = arms.pathChanged(to: [wifi], isOffline: notOffline)
        #expect(arms.state(of: wifi.id) == .waiting)
        // An offline Browse's camera is never armed.
        _ = arms.pathChanged(to: [offline], isOffline: { $0 == offline.id })
        #expect(arms.state(of: offline.id) == nil)
        #expect(arms.state(of: wifi.id) == nil)
        // Nor is a USB camera's Browse a visit.
        _ = arms.pathChanged(to: [usb], isOffline: notOffline)
        #expect(arms.state(of: usb.id) == nil)
    }

    @Test func leavingAShownUSBArmEndsItButANeverShownOneWaits() {
        var arms = AutoImportArms()
        _ = arms.connected(usb)
        arms.decided(usb.id, .on)
        let other = CameraDescriptor(id: .init(rawValue: "usb-2"), name: "ILCE-7M4", mode: .usb(.mtp))
        _ = arms.connected(other)
        arms.decided(other.id, .on)
        // Another camera's Browse opened and left: this one was never shown, so it still waits.
        _ = arms.pathChanged(to: [other], isOffline: notOffline)
        let r11 = arms.pathChanged(to: [], isOffline: notOffline)
        #expect(r11 == [other.id])
        #expect(arms.state(of: other.id) == .ended(.leftBrowse))
        #expect(arms.state(of: usb.id) == .waiting)
        // Shown, then left while the card is being decided.
        _ = arms.pathChanged(to: [usb], isOffline: notOffline)
        let r12 = arms.beginDeciding(usb.id)
        #expect(r12)
        let r13 = arms.pathChanged(to: [], isOffline: notOffline)
        #expect(r13 == [usb.id])
        #expect(arms.state(of: usb.id) == .ended(.leftBrowse))
        arms.finishDeciding(usb.id, .ended(.started))
        #expect(arms.state(of: usb.id) == .ended(.leftBrowse))
    }

    @Test func anEndedArmStaysEndedUntilTheConnectionEnds() {
        var arms = AutoImportArms()
        _ = arms.connected(usb)
        arms.decided(usb.id, .on)
        _ = arms.pathChanged(to: [usb], isOffline: notOffline)
        arms.end(usb.id, .requestTookIt)
        arms.end(usb.id, .choosingFiles)
        #expect(arms.state(of: usb.id) == .ended(.requestTookIt))
        // Leaving after it ended says nothing, and coming back changes nothing.
        let r14 = arms.pathChanged(to: [], isOffline: notOffline)
        #expect(r14.isEmpty)
        _ = arms.pathChanged(to: [usb], isOffline: notOffline)
        #expect(arms.state(of: usb.id) == .ended(.requestTookIt))
        let r15 = arms.beginDeciding(usb.id)
        #expect(!r15)
        arms.disconnected(usb.id)
        #expect(arms.state(of: usb.id) == nil)
    }

    @Test func aCardReadWhileAwayIsTakenOnceAndOnlyWhileWaiting() {
        var arms = AutoImportArms()
        let first = CameraDescriptor(id: .init(rawValue: "usb-1"), name: "Camera", mode: .usb(.mtp))
        let second = CameraDescriptor(id: .init(rawValue: "usb-2"), name: "Camera", mode: .usb(.mtp))
        let armedFirst = arms.connected(first), armedSecond = arms.connected(second)
        #expect(armedFirst && armedSecond)
        arms.decided(first.id, .on)
        arms.decided(second.id, .on)
        let none = arms.takeReadWhileAway()
        #expect(none.isEmpty)                            // waiting, but nothing was read while away
        arms.readWhileAway(first.id)
        let taken = arms.takeReadWhileAway(), takenAgain = arms.takeReadWhileAway()
        #expect(taken == [first.id])
        #expect(takenAgain.isEmpty)                      // once
        arms.readWhileAway(second.id)
        arms.end(second.id, .jobRunning)
        let afterEnd = arms.takeReadWhileAway()
        #expect(afterEnd.isEmpty)                        // an ended arm isn't decided again
        arms.readWhileAway(second.id)                    // nor marked once ended
        let markedEnded = arms.takeReadWhileAway()
        #expect(markedEnded.isEmpty)
    }
}
