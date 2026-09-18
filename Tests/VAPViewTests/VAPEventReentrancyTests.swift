import Testing
@testable import VAPView

@Suite(.serialized) @MainActor
struct VAPEventReentrancyTests {
    @Test(arguments: [true, false])
    func playFromStopCallbackMustKeepReplacementPlayer(automaticallyDestroys: Bool) {
        let view = VAPView()
        view.automaticallyDestroysPlayerAfterPlayback = automaticallyDestroys
        var replacementStarted = false
        var surfacesInsideCallback = 0
        view.play(source: "/nonexistent/reentrant-old.mp4", playsAudio: false, eventHandler: { event in
            if case .didStop = event {
                replacementStarted = true
                view.play(source: "/nonexistent/reentrant-new.mp4", playsAudio: false)
                surfacesInsideCallback = view.subviews.count
            }
        })
        view.stop()
        #expect(replacementStarted)
        #expect(surfacesInsideCallback > 0)
        #expect(view.subviews.count == surfacesInsideCallback)
        view.stop()
    }
    @Test func stopCallbackCanStopAgainWithoutDuplicateEvents() {
        let view = VAPView()
        view.automaticallyDestroysPlayerAfterPlayback = true
        var stopCount = 0
        view.play(source: "/nonexistent/reentrant-stop.mp4", playsAudio: false, eventHandler: { event in
            if case .didStop = event {
                stopCount += 1
                view.stop()
            }
        })
        view.stop()
        #expect(stopCount == 1)
        #expect(view.subviews.isEmpty)
    }

    @Test func automaticDestructionStillCleansUpWithoutReplacement() {
        let view = VAPView()
        view.automaticallyDestroysPlayerAfterPlayback = true
        view.play(source: "/nonexistent/normal-stop.mp4", playsAudio: false)
        #expect(!view.subviews.isEmpty)
        view.stop()
        #expect(view.subviews.isEmpty)
    }

}
