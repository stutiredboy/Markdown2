import AppKit
import Carbon
import Foundation

@MainActor
public protocol AppActivationManaging: AnyObject {
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var isActive: Bool { get }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy)
    func unhide()
    func orderVisibleWindowsFront()
    func activateIgnoringOtherApps()
}

@MainActor
public final class NSApplicationActivationManager: AppActivationManaging {
    private let application: NSApplication

    public init(application: NSApplication = .shared) {
        self.application = application
    }

    public var activationPolicy: NSApplication.ActivationPolicy {
        application.activationPolicy()
    }

    public var isActive: Bool {
        application.isActive
    }

    public func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        application.setActivationPolicy(policy)
    }

    public func unhide() {
        application.unhide(nil)
    }

    public func orderVisibleWindowsFront() {
        for window in application.windows where window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
    }

    public func activateIgnoringOtherApps() {
        var process = ProcessSerialNumber(
            highLongOfPSN: 0,
            lowLongOfPSN: UInt32(kCurrentProcess)
        )
        TransformProcessType(&process, UInt32(kProcessTransformToForegroundApplication))

        NSRunningApplication.current.activate(options: .activateAllWindows)
        application.activate()
    }
}

@MainActor
public struct LaunchActivationController {
    public typealias Scheduler = @MainActor (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void

    private let manager: AppActivationManaging
    private let scheduler: Scheduler

    public init(
        manager: AppActivationManaging = NSApplicationActivationManager(),
        scheduler: @escaping Scheduler = LaunchActivationController.defaultScheduler
    ) {
        self.manager = manager
        self.scheduler = scheduler
    }

    public func activateAfterLaunch() {
        activateNow()

        // The retries exist because SwiftUI may create the main window slightly
        // after launch, leaving the app behind other windows. Once the app has
        // actually become frontmost we must stop re-activating it — otherwise a
        // later retry steals focus back from whatever app the user switched to,
        // which is the "window-grabbing" bug users see right after launch.
        let state = ActivationRetryState()
        for delay in Self.retryDelays {
            scheduler(delay) {
                guard !state.isFinished else { return }

                if manager.isActive {
                    state.isFinished = true
                    return
                }

                activateNow()
            }
        }
    }

    public func activateNow() {
        if manager.activationPolicy != .regular {
            manager.setActivationPolicy(.regular)
        }

        manager.unhide()
        manager.activateIgnoringOtherApps()
        manager.orderVisibleWindowsFront()
        manager.activateIgnoringOtherApps()
    }

    @MainActor
    private final class ActivationRetryState {
        var isFinished = false
    }

    public static let retryDelays: [TimeInterval] = [0.15, 0.6, 1.2, 2.5, 5.0]

    public static func defaultScheduler(
        delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                action()
            }
        }
    }
}
