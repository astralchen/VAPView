import Testing
import Foundation
@testable import VAPView

@Suite("VAPPlayer events")
struct VAPPlayerEventTests {
    @Test @MainActor func stopSynchronouslyDeliversOneDidStopForActivePlayback() async {
        let player = VAPPlayer()
        var receivedEvents: [VAPEvent] = []

        player.play(
            VAPPlaybackConfiguration(source: "/nonexistent/stop-event.mp4", playsAudio: false)
        ) { event in
            receivedEvents.append(event)
        }

        player.stop()

        #expect(Self.didStopFrames(in: receivedEvents) == [0])

        await Task.yield()

        #expect(Self.didStopFrames(in: receivedEvents) == [0])
    }

    @Test @MainActor func pauseDoesNotEmitDidStop() async {
        let player = VAPPlayer()
        var receivedEvents: [VAPEvent] = []

        player.play(
            VAPPlaybackConfiguration(source: "/nonexistent/pause-event.mp4", playsAudio: false)
        ) { event in
            receivedEvents.append(event)
        }

        player.pause()
        await Task.yield()

        #expect(Self.didStopFrames(in: receivedEvents).isEmpty)

        player.stop()
    }

    @Test @MainActor func stopAfterPauseDeliversOneDidStop() async {
        let player = VAPPlayer()
        var receivedEvents: [VAPEvent] = []

        player.play(
            VAPPlaybackConfiguration(source: "/nonexistent/paused-stop-event.mp4", playsAudio: false)
        ) { event in
            receivedEvents.append(event)
        }

        player.pause()
        player.stop()

        #expect(Self.didStopFrames(in: receivedEvents) == [0])

        await Task.yield()

        #expect(Self.didStopFrames(in: receivedEvents) == [0])
    }

    @Test @MainActor func replacingPlaybackThroughVAPViewDoesNotEmitDidStop() async {
        let view = VAPView()
        var firstPlaybackEvents: [VAPEvent] = []
        var secondPlaybackEvents: [VAPEvent] = []

        view.play(source: "/nonexistent/replacement-first.mp4", playsAudio: false) { event in
            firstPlaybackEvents.append(event)
        }
        view.play(source: "/nonexistent/replacement-second.mp4", playsAudio: false) { event in
            secondPlaybackEvents.append(event)
        }

        await Task.yield()

        #expect(Self.didStopFrames(in: firstPlaybackEvents).isEmpty)
        #expect(Self.didStopFrames(in: secondPlaybackEvents).isEmpty)

        view.stop()
    }

    @Test @MainActor func stopThroughVAPViewDeliversDidStopForActivePlayback() async {
        let view = VAPView()
        var receivedEvents: [VAPEvent] = []

        view.play(source: "/nonexistent/vapview-stop-event.mp4", playsAudio: false, eventHandler: { event in
            receivedEvents.append(event)
        })

        view.stop()

        #expect(Self.didStopFrames(in: receivedEvents) == [0])

        await Task.yield()

        #expect(Self.didStopFrames(in: receivedEvents) == [0])
    }

    @Test @MainActor func stopAfterTerminalFailureDoesNotEmitDidStop() async {
        let player = VAPPlayer()
        var receivedEvents: [VAPEvent] = []

        player.play(
            VAPPlaybackConfiguration(source: "/nonexistent/terminal-failure.mp4", playsAudio: false)
        ) { event in
            receivedEvents.append(event)
        }

        let receivedFailure = await Self.waitUntil {
            Self.containsDidFail(in: receivedEvents)
        }
        #expect(receivedFailure)

        player.stop()

        #expect(Self.didStopFrames(in: receivedEvents).isEmpty)
    }

    @Test @MainActor func didStopHandlerCanStartNewPlaybackWithoutLosingNewHandler() async {
        let player = VAPPlayer()
        var oldHandlerReceivedStop = false
        var newHandlerEvents: [VAPEvent] = []

        player.play(
            VAPPlaybackConfiguration(source: "/nonexistent/reentrant-first.mp4", playsAudio: false)
        ) { event in
            guard case .didStop = event else { return }
            oldHandlerReceivedStop = true
            player.play(
                VAPPlaybackConfiguration(source: "/nonexistent/reentrant-second.mp4", playsAudio: false)
            ) { newEvent in
                newHandlerEvents.append(newEvent)
            }
        }

        player.stop()

        #expect(oldHandlerReceivedStop)

        let newHandlerReceivedFailure = await Self.waitUntil {
            Self.containsDidFail(in: newHandlerEvents)
        }
        #expect(newHandlerReceivedFailure)
    }

    private static func didStopFrames(in events: [VAPEvent]) -> [Int] {
        events.compactMap { event in
            guard case .didStop(let lastFrame) = event else { return nil }
            return lastFrame
        }
    }

    private static func containsDidFail(in events: [VAPEvent]) -> Bool {
        events.contains { event in
            guard case .didFail = event else { return false }
            return true
        }
    }

    @MainActor
    private static func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: () -> Bool
    ) async -> Bool {
        let sleepNanoseconds: UInt64 = 10_000_000
        let attempts = max(1, Int(timeoutNanoseconds / sleepNanoseconds))

        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
        }

        return condition()
    }
}
