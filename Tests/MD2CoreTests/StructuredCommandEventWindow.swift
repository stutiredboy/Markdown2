// Native event runner for asynchronous command contract regressions.
// Tests alone own the NSApplication.run boundary and their native windows.
import AppKit
import CoreFoundation
import XCTest

@MainActor
class StructuredCommandEventWindow: NSWindow {
    private let probeScalarBase: UInt32 = 0xE000
    private var probeWindowNumber = 0
    private var observation: Any?
    private var observedSteps: [Int] = []
    private(set) var observedKeyEventCount = 0
    private(set) var markerWindowMismatches: [Int] = []
    private(set) var deliveredSteps: [Int] = []
    private(set) var otherKeyCodes: [UInt16] = []
    var onProbeStep: (@MainActor (Int) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // This is calibration only. It always passes the NSEvent onward, including
    // the test's marker events, so every product local monitor can receive it.
    func installProbeObservation() {
        precondition(observation == nil)
        probeWindowNumber = windowNumber
        observedSteps.removeAll()
        observedKeyEventCount = 0
        markerWindowMismatches.removeAll()
        deliveredSteps.removeAll()
        otherKeyCodes.removeAll()
        observation = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if let self {
                    self.observedKeyEventCount += 1
                    if let step = self.probeStep(in: event) {
                        self.observedSteps.append(step)
                    } else if self.probeScalarStep(in: event) != nil {
                        self.markerWindowMismatches.append(event.windowNumber)
                    } else {
                        self.otherKeyCodes.append(event.keyCode)
                    }
                }
            }
            return event
        }
    }

    func removeProbeObservation() {
        if let observation { NSEvent.removeMonitor(observation) }
        observation = nil
        onProbeStep = nil
    }

    func enqueueProbeStep(_ step: Int) throws {
        // No CGEvent posting, global input or activation occurs here. The real
        // key NSEvent is queued only inside this test process for this window.
        precondition((0..<256).contains(step))
        precondition(windowNumber == probeWindowNumber)
        // The earlier long UUID marker did not match in a separate native
        // calibration. One BMP private-use scalar identifies a step;
        // the captured test-window number supplies its ownership boundary.
        let characters = String(try XCTUnwrap(UnicodeScalar(probeScalarBase + UInt32(step))))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: probeWindowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: 0))
        NSApp.postEvent(event, atStart: false)
    }

    override func sendEvent(_ event: NSEvent) {
        guard let step = probeStep(in: event) else {
            super.sendEvent(event)
            return
        }
        // The step runs in native window dispatch, after NSApplication's local
        // monitors; it no longer runs inside an earlier, consuming monitor.
        guard observedSteps.contains(step) else {
            XCTFail("probe event \(step) reached the window without its passthrough monitor observation")
            return
        }
        deliveredSteps.append(step)
        onProbeStep?(step)
    }

    private func probeStep(in event: NSEvent) -> Int? {
        guard event.type == .keyDown, event.windowNumber == probeWindowNumber else { return nil }
        return probeScalarStep(in: event)
    }

    private func probeScalarStep(in event: NSEvent) -> Int? {
        guard let characters = event.characters, characters.unicodeScalars.count == 1,
              let scalar = characters.unicodeScalars.first,
              scalar.value >= probeScalarBase, scalar.value < probeScalarBase + 256 else { return nil }
        return Int(scalar.value - probeScalarBase)
    }

    func ownsProbeEvent(_ event: NSEvent) -> Bool { probeStep(in: event) != nil }
}

/// Common runner for the independent suites. Work executes only from native
/// window dispatch. The original test bodies choose when a step has completed.
/// A pre-run-created manager stays pre-run; only event posting is deferred until
/// NSApp is running and the original test window is active/key. Reuse that same
/// source window so the marker harness does not steal its first responder.
@MainActor
enum StructuredCommandEventRunner {
    typealias Step = @MainActor (_ idleEntries: Int, _ next: @escaping @MainActor () -> Void) throws -> Void

    static func run(_ steps: [Step], alreadyQueued: Bool = false) throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        guard !NSApp.isRunning else { throw RunnerError("requires an independent NSApplication.run boundary") }
        let state = try RunState(steps: steps, alreadyQueued: alreadyQueued)
        defer { state.cleanup() }
        try state.start()
        NSApp.run()
        if let failure = state.failure { throw failure }
        XCTAssertEqual(state.index, steps.count)
    }

    private struct RunnerError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor private final class RunState {
        let steps: [Step]
        let alreadyQueued: Bool
        private(set) var index = 0
        private(set) var failure: Error?
        private var idleEntries = 0
        private var finished = false
        private var timer: Timer?
        private var bootstrap: Timer?
        private var readinessObservations: [NSObjectProtocol] = []
        private var deliveryStarted = false
        private var idleObserver: CFRunLoopObserver?
        private var currentWindow: StructuredCommandEventWindow!
        private var connectedWindows: [StructuredCommandEventWindow] = []
        private var createdWindows: [StructuredCommandEventWindow] = []

        init(steps: [Step], alreadyQueued: Bool) throws {
            self.steps = steps
            self.alreadyQueued = alreadyQueued
            if let key = NSApp.keyWindow {
                guard let own = key as? StructuredCommandEventWindow else {
                    throw RunnerError("an unrelated window owns native focus; refusing to replace it")
                }
                connect(own)
            } else {
                let visible = NSApp.windows.compactMap { $0 as? StructuredCommandEventWindow }.filter(\.isVisible)
                if visible.count == 1, let own = visible.first {
                    // During launch a visible source window may not be key yet.
                    // Wait for its normal activation instead of stealing focus
                    // with a second window before NSApplication.run has begun.
                    connect(own)
                } else if visible.isEmpty {
                    makeCarrierWindow()
                } else {
                    throw RunnerError("multiple visible test windows make event ownership ambiguous")
                }
            }
        }

        private func connect(_ window: StructuredCommandEventWindow) {
            precondition(window.onProbeStep == nil)
            currentWindow = window
            connectedWindows.append(window)
            window.installProbeObservation()
            window.onProbeStep = { [weak self] step in self?.receive(step) }
        }

        private func makeCarrierWindow() {
            let window = StructuredCommandEventWindow(contentRect: NSRect(x: 140, y: 140, width: 200, height: 100),
                                             styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Independent Undo event carrier"
            window.isReleasedWhenClosed = false
            createdWindows.append(window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            connect(window)
        }

        func start() throws {
            idleObserver = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.idleEntries += 1 }
            }
            if let idleObserver { CFRunLoopAddObserver(CFRunLoopGetMain(), idleObserver, .commonModes) }
            let timeout = Timer(timeInterval: 20, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.fail(RunnerError("native event probe timed out: running=\(NSApp.isRunning), active=\(NSApp.isActive), key=\(NSApp.keyWindow === self.currentWindow), visible=\(self.currentWindow.isVisible), number=\(self.currentWindow.windowNumber), ownPID=\(ProcessInfo.processInfo.processIdentifier), frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1), console=\(Self.consoleState()), rawKeys=\(self.currentWindow.observedKeyEventCount), delivered=\(self.currentWindow.deliveredSteps), markerWindowMismatches=\(self.currentWindow.markerWindowMismatches)"))
                }
            }
            timer = timeout
            RunLoop.main.add(timeout, forMode: .common)
            readinessObservations = [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.beginDeliveryWhenReady() }
                }
            }
            // Post the batch only once the real app loop is running and the
            // test window is active/key. This zero-time bootstrap does not
            // advance individual test steps or insert an idle between them.
            let bootstrap = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, NSApp.isRunning else { return }
                    // A prior test restored its activation policy after run()
                    // returned. Establish this test's focus after the new app
                    // loop starts, before posting its one initial event batch.
                    NSApp.activate(ignoringOtherApps: true)
                    self.currentWindow.makeKeyAndOrderFront(nil)
                    self.beginDeliveryWhenReady()
                }
            }
            self.bootstrap = bootstrap
            RunLoop.main.add(bootstrap, forMode: .common)
        }

        private func beginDeliveryWhenReady() {
            guard !finished, !deliveryStarted, NSApp.isRunning, NSApp.isActive,
                  currentWindow.isVisible, NSApp.keyWindow === currentWindow else { return }
            deliveryStarted = true
            do {
                if alreadyQueued {
                    for step in 0...steps.count { try enqueue(step) }
                } else {
                    try enqueue(0)
                }
            } catch { fail(error) }
        }

        private static func consoleState() -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
            process.arguments = ["-n", "Root", "-d1", "-a"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let users = root["IOConsoleUsers"] as? [[String: Any]] else { return "unavailable" }
                return users.map { user in
                    "locked=\(user["CGSSessionScreenIsLocked"] ?? false),onConsole=\(user["kCGSSessionOnConsoleKey"] ?? false),loginDone=\(user["kCGSessionLoginDoneKey"] ?? false)"
                }.joined(separator: ";")
            } catch { return "unavailable" }
        }

        private func enqueue(_ step: Int) throws {
            guard !finished else { return }
            // A source-window-close test still needs its unchanged verification
            // step. Continue on an empty test-owned carrier; never resurrect the
            // source, its first responder, its session or its paste controller.
            if !currentWindow.isVisible {
                guard !alreadyQueued else {
                    throw RunnerError("an already-queued scenario closed its event window")
                }
                if let key = NSApp.keyWindow, !connectedWindows.contains(where: { $0 === key }) {
                    throw RunnerError("an unrelated window acquired focus after test window close")
                }
                makeCarrierWindow()
            }
            guard NSApp.keyWindow === currentWindow else {
                throw RunnerError("the test event window lost key status")
            }
            try currentWindow.enqueueProbeStep(step)
        }

        private func receive(_ step: Int) {
            guard !finished else { return }
            guard step == index else { fail(RunnerError("native probe event order changed")); return }
            guard index < steps.count else { finish(); return }
            let executing = index
            let next: @MainActor () -> Void = { [weak self] in
                guard let self, !self.finished, self.index == executing else { return }
                self.index += 1
                if !self.alreadyQueued {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        do { try self.enqueue(self.index) }
                        catch { self.fail(error) }
                    }
                }
            }
            do {
                try steps[index](idleEntries, next)
                if alreadyQueued, index == executing {
                    fail(RunnerError("queued scenario used an asynchronous step"))
                }
            } catch { fail(error) }
        }

        private func fail(_ error: Error) {
            if failure == nil { failure = error }
            finish()
        }

        private func finish() {
            guard !finished else { return }
            finished = true
            NSApp.stop(nil)
            let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                subtype: 0x4D34, data1: 0, data2: 0)!
            NSApp.postEvent(wake, atStart: false)
        }

        func cleanup() {
            for window in connectedWindows where !window.otherKeyCodes.isEmpty {
                print("Native event harness non-marker key codes: \(window.otherKeyCodes)")
            }
            timer?.invalidate(); timer = nil
            bootstrap?.invalidate(); bootstrap = nil
            for token in readinessObservations { NotificationCenter.default.removeObserver(token) }
            readinessObservations.removeAll()
            if let idleObserver {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), idleObserver, .commonModes)
                CFRunLoopObserverInvalidate(idleObserver)
            }
            idleObserver = nil
            // On a failed queued scenario, remove only this runner's pending
            // marker keys. Do not dispatch other input or let markers fall into
            // an NSTextView after its temporary window handler is removed.
            var unrelated: [NSEvent] = []
            while let event = NSApp.nextEvent(matching: .keyDown, until: Date(), inMode: .default, dequeue: true) {
                if !connectedWindows.contains(where: { $0.ownsProbeEvent(event) }) { unrelated.append(event) }
            }
            for event in unrelated.reversed() { NSApp.postEvent(event, atStart: true) }
            for window in connectedWindows { window.removeProbeObservation() }
            for window in createdWindows { window.orderOut(nil); window.close() }
            connectedWindows.removeAll(); createdWindows.removeAll()
        }
    }
}
