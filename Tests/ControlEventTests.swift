import XCTest
@testable import QuickTerm

/// Phase 4: the event stream.
///
/// This group guards four things, each of them a trap an agent really does walk into:
/// 1. `seq` is monotonic and **moves on every mutation** — it is the only answer to "is the
///    snapshot I am holding stale?";
/// 2. `poll --since` returns **exactly** the batch that was missed (not one event already seen,
///    and not one event short);
/// 3. rapid-fire changes coalesce into a single event (one reflow must not produce five
///    layout.changed);
/// 4. **no event ever carries the output of a pane**.
@MainActor
final class ControlEventTests: XCTestCase {
    private var harness: ControlHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
    }

    override func tearDown() {
        harness?.cleanup()
        harness = nil
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval = 0.25) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Structural events only. A real shell runs in the test host: the title and the OSC 7 pwd can
    /// change on their own at any moment, none of which the case did, and letting them in only
    /// makes the assertions flaky
    private static let structural = "pane.opened,pane.closed,layout.changed,workspace.changed,focus.changed"

    // MARK: seq

    /// `seq` moves forward on every successful mutation, and **only** forward.
    /// If it stands still, an agent keeps making decisions off a stale snapshot without ever
    /// noticing
    func testSeqAdvancesOnEveryMutationAndNeverGoesBackwards() throws {
        let controller = try harness.controller
        var seen = [harness.seq]

        try harness.newTerminal()
        seen.append(harness.seq)

        let target = controller.model.activeIndex == 0 ? 2 : 1
        try harness.run("workspace.goto", args: ["index": .int(target)])
        seen.append(harness.seq)

        // One that does not touch the layout (a process-wide setting): no typed event covers it,
        // and seq still has to move. Read the current value first and then flip it, otherwise
        // "it was already that value" turns into a no-op and the case stops testing this at all
        let get = try harness.run("app.get", args: ["key": .string("gaps")])
        let now = get.data?["settings"]?.arrayValue?.first?.objectValue?["value"]?.stringValue ?? "on"
        let flipped = now == "on" ? "off" : "on"
        try harness.run("app.set", args: ["key": .string("gaps"), "value": .string(flipped)])
        seen.append(harness.seq)
        try harness.run("app.set", args: ["key": .string("gaps"), "value": .string(now)])
        seen.append(harness.seq)

        for (a, b) in zip(seen, seen.dropFirst()) {
            XCTAssertLessThan(a, b, "every mutation that lands has to advance seq: \(seen)")
        }
    }

    /// With several screens, seq is still **one** ruler: a change on the second screen advances
    /// the same counter, and a single `events poll` picks up events from both screens (an agent
    /// does not have to poll once per screen)
    func testSeqIsMonotonicAcrossScreens() throws {
        let app = harness.app
        let primary = try harness.controller
        let mark = harness.seq
        let second = app.newScreen(on: NSScreen.main)
        spin(0.4)
        defer {
            if app.controllers.contains(where: { $0 === second }) { app.closeScreen(second) }
            primary.window?.makeKeyAndOrderFront(nil)
            spin(0.3)
        }

        let afterOpen = harness.seq
        XCTAssertGreaterThan(afterOpen, mark, "opening a screen has to advance seq")

        let events = harness.events(since: mark)
        XCTAssertTrue(events.contains { $0.type == ControlEventType.screenOpened.rawValue },
                      "opening a screen has to emit screen.opened: \(events.map(\.type))")
        XCTAssertTrue(events.contains { $0.screen == second.screenIndex + 1 },
                      "events from the second screen have to show up in the same stream")

        // Events from both screens share one seq: strictly increasing globally, never two events
        // carrying the same number
        let seqs = events.map(\.seq)
        XCTAssertEqual(seqs, seqs.sorted(), "events come in ascending seq order")
        XCTAssertEqual(Set(seqs).count, seqs.count, "seq is globally unique (two screens are not two rulers)")
    }

    // MARK: poll

    /// `poll --since` returns exactly **the batch that was missed**: not one event that has
    /// already been seen (an agent would process it twice), and not one missed event short
    func testPollSinceReturnsExactlyTheMissedBatch() throws {
        let mark = harness.seq
        try harness.newTerminal()
        harness.spin(0.1)

        let first = try poll(since: mark, timeout: "0", types: Self.structural)
        XCTAssertFalse(first.events.isEmpty, "the first poll has to pick up the batch we just produced")
        XCTAssertTrue(first.events.allSatisfy { $0.seq > mark }, "never return events from before since")
        let cursor = first.seq
        XCTAssertLessThanOrEqual(try XCTUnwrap(first.events.last?.seq), cursor,
                                 "the seq that comes back is the cursor to hand to the next --since")
        let firstSeqs = first.events.map(\.seq)

        // Poll again with the same cursor: nothing should come back (duplicate delivery is the
        // hardest class of agent bug to track down)
        let empty = try poll(since: cursor, timeout: "0", types: Self.structural)
        XCTAssertTrue(empty.events.isEmpty,
                      "anything already seen must not come back a second time: \(empty.events.map(\.seq))")
        XCTAssertEqual(empty.timedOut, true, "no new events is a timedOut, not an error")

        // Change something again: only this round comes back, with no old event mixed in
        try harness.newTerminal()
        harness.spin(0.3)
        let second = try poll(since: cursor, timeout: "0", types: Self.structural)
        XCTAssertFalse(second.events.isEmpty)
        XCTAssertTrue(second.events.allSatisfy { $0.seq > cursor },
                      "no event from the first batch may leak into the second")
        XCTAssertTrue(Set(second.events.map(\.seq)).isDisjoint(with: Set(firstSeqs)),
                      "the two batches must not overlap at all")
    }

    /// `--types` returns only the kinds asked for; `--limit` caps the batch
    func testPollFiltersByTypeAndLimit() throws {
        let mark = harness.seq
        try harness.newTerminal()
        harness.spin(0.1)
        let filtered = try poll(since: mark, timeout: "0", types: "pane.opened")
        XCTAssertTrue(filtered.events.allSatisfy { $0.type == ControlEventType.paneOpened.rawValue },
                      "not a single event outside --types may come back: \(filtered.events.map(\.type))")

        let capped = try poll(since: mark, timeout: "0", limit: 1)
        XCTAssertLessThanOrEqual(capped.events.count, 1)
    }

    /// **Regression: when `--limit` truncates a batch, the cursor that comes back only reaches the
    /// last event that was actually delivered.**
    ///
    /// It used to always return the global seq, so you got "here is 1 event, and by the way you
    /// have now seen through event N" — the ones in between were never delivered and were never
    /// flagged by `missed` either (`missed` only covers events pushed out of the ring, and here
    /// the ring dropped nothing). Chasing the returned seq poll after poll has to lose **nothing
    /// and duplicate nothing**
    func testALimitedPollNeverSkipsPastUndeliveredEvents() throws {
        let mark = harness.seq
        try harness.newTerminal()
        try harness.newTerminal()
        try harness.newTerminal()
        harness.spin(0.4)
        ControlEventBus.shared.flush()

        let all = try poll(since: mark, timeout: "0", types: Self.structural)
        XCTAssertGreaterThan(all.events.count, 2, "this case needs several events before truncation can be observed at all")
        XCTAssertNil(all.truncated, "nothing was truncated, so truncated must not be set")
        XCTAssertEqual(all.seq, harness.seq, "with nothing truncated the cursor is simply the global seq")

        // Take one event at a time and chase it along using the cursor that comes back
        var collected: [Int] = []
        var cursor = mark
        var sawTruncated = false
        for _ in 0...(all.events.count + 1) {
            let one = try poll(since: cursor, timeout: "0", types: Self.structural, limit: 1)
            guard let event = one.events.first else {
                XCTAssertEqual(one.timedOut, true, "having caught up means a timedOut")
                break
            }
            XCTAssertEqual(one.events.count, 1)
            if one.truncated == true {
                sawTruncated = true
                XCTAssertEqual(one.seq, event.seq,
                               "on truncation the cursor has to be pinned to the last event "
                               + "actually delivered, not to the global seq")
            } else {
                // The last batch: there really is nothing undelivered behind it, so the cursor
                // may jump straight to the global seq
                XCTAssertGreaterThanOrEqual(one.seq, event.seq)
            }
            collected.append(event.seq)
            cursor = one.seq
        }
        XCTAssertTrue(sawTruncated,
                      "chasing a multi-event batch one at a time has to hit truncation along the way")
        XCTAssertEqual(collected, all.events.map(\.seq),
                       "chasing one at a time has to land exactly on the batch a single full poll "
                       + "returns: nothing lost, nothing repeated")
    }

    /// The stream behaves the same way: `events follow --limit 1` must not drop the rest of what
    /// one scan produced, and must not sit there waiting for the next change before it pushes on
    func testFollowWithATinyLimitStillDeliversEverything() throws {
        let connection: UInt64 = 4343
        defer { harness.runner.connectionDidClose(connection) }
        var received: [ControlEvent] = []
        let peer = ControlSocket.Peer(fd: -1, uid: getuid(), pid: getpid(),
                                      processName: "xctest", connectionID: connection)
        let request = ControlRequest(id: "f1", cmd: "events.follow",
                                     args: ["limit": .int(1),
                                            "types": .string(Self.structural)])
        harness.runner.handle(request, peer: peer) { response in
            guard let data = try? ControlJSON.line(response),
                  let reply = try? ControlJSON.decoder.decode(ControlReply.self, from: data),
                  let payload = reply.data,
                  let encoded = try? ControlJSON.encoder.encode(payload),
                  let decoded = try? ControlJSON.decoder.decode(ControlEventsPayload.self, from: encoded)
            else { return }
            XCTAssertLessThanOrEqual(decoded.events.count, 1, "--limit 1 means one event per batch")
            received += decoded.events
        }
        let mark = harness.seq
        try harness.newTerminal()
        harness.spin(0.4)
        ControlEventBus.shared.flush()

        let expected = try poll(since: mark, timeout: "0", types: Self.structural).events.map(\.seq)
        XCTAssertGreaterThan(expected.count, 1, "creating one pane produces at least two structural events")
        XCTAssertEqual(received.filter { $0.seq > mark }.map(\.seq), expected,
                       "one event per batch still has to push out everything that scan found")
    }

    /// Anything unrecognized errors out; it is never quietly treated as a default
    func testPollRejectsBadArguments() throws {
        let bad = try harness.run("events.poll", args: ["types": .string("pane.exploded")])
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertNotNil(bad.error?.candidates, "the types we do recognize have to be listed")

        let badTimeout = try harness.run("events.poll", args: ["timeout": .string("in a bit")])
        XCTAssertFalse(badTimeout.ok)
        XCTAssertEqual(badTimeout.error?.code, ControlErrorCode.badRequest.rawValue)

        let negative = try harness.run("events.poll", args: ["since": .int(-1), "timeout": .string("0")])
        XCTAssertFalse(negative.ok)
    }

    /// A read command does not accept `--dry-run` (a read changes nothing to begin with)
    func testPollRefusesMutationFlags() throws {
        let reply = try harness.run("events.poll", args: [ControlCommandTable.Flag.dryRun: .bool(true)])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
    }

    // MARK: Coalescing

    /// N layout assignments inside one reflow should produce **one** layout.changed.
    /// Without coalescing, a single `spec apply` can fill an agent's context with five copies of
    /// the same fact
    func testRapidLayoutChangesCoalesce() throws {
        let controller = try harness.controller
        try harness.newTerminal()
        try harness.newTerminal()
        harness.spin(0.3)

        let index = controller.model.activeIndex
        guard case .scrolling(var strip) = controller.model.layouts[index], !strip.columns.isEmpty else {
            throw XCTSkip("the current workspace is not scrolling, or it has no columns")
        }
        let mark = harness.seq
        // Five changes back to back within one run-loop turn: coalescing is implemented as
        // "scan once per turn"
        for width in [0.30, 0.32, 0.34, 0.36, 0.38] {
            strip.columns[0].widthFactor = width
            controller.model.layouts[index] = .scrolling(strip)
        }
        harness.spin(0.3)

        let layoutEvents = harness.events(since: mark)
            .filter { $0.type == ControlEventType.layoutChanged.rawValue
                && $0.workspace == index + 1 && $0.screen == controller.screenIndex + 1 }
        XCTAssertEqual(layoutEvents.count, 1,
                       "five assignments should coalesce into one layout.changed, got \(layoutEvents.count)")
    }

    /// Nothing changed means not a single event (a no-op absolute set must not pollute the
    /// stream)
    func testNoChangeProducesNoEvents() throws {
        let controller = try harness.controller
        let index = controller.model.activeIndex
        try harness.run("workspace.goto", args: ["index": .int(index + 1)])
        let mark = harness.seq
        ControlEventBus.shared.flush()
        let structural = harness.events(since: mark).filter {
            $0.type != ControlEventType.paneTitleChanged.rawValue
                && $0.type != ControlEventType.paneCwdChanged.rawValue
        }
        XCTAssertEqual(structural.count, 0, "no change means no events: \(structural.map(\.type))")
    }

    // MARK: Never carries output

    /// **These are all the fields an event may carry, and none of them is, or may ever be, the
    /// output of a pane.**
    /// This case is structural: the moment anyone adds an `output` / `text` / `scrollback` field to
    /// `ControlEvent`, it goes red. Pushing shell output onto the socket hands over passwords,
    /// tokens and ssh session contents verbatim
    func testNoEventEverCarriesPaneOutput() throws {
        let populated = ControlEvent(
            seq: 1, ts: "t", type: .paneTitleChanged, screen: 1, screenID: "S", workspace: 2,
            pane: "t7", paneID: "P", kind: "terminal", layout: "scrolling",
            title: "title", cwd: "/tmp", redacted: true)
        let data = try ControlJSON.encoder.encode(populated)
        let object = try XCTUnwrap(
            try ControlJSON.decoder.decode(JSONValue.self, from: data).objectValue)
        XCTAssertEqual(Set(object.keys),
                       ["seq", "ts", "type", "screen", "screenID", "workspace",
                        "pane", "paneID", "kind", "layout", "title", "cwd", "redacted"],
                       "the event field list is closed: no field carrying pane output may appear")

        // The type list is closed as well: no output / scrollback / bell kinds
        XCTAssertEqual(Set(ControlEventType.allCases.map(\.rawValue)),
                       ["pane.opened", "pane.closed", "focus.changed", "workspace.changed",
                        "layout.changed", "screen.opened", "screen.closed",
                        "pane.title.changed", "pane.cwd.changed"])

        // Now for real: create a pane, change the layout, switch workspaces — not one event may
        // contain a large blob of text
        let mark = harness.seq
        try harness.newTerminal()
        harness.spin(0.3)
        for event in harness.events(since: mark) {
            let encoded = String(decoding: try ControlJSON.encoder.encode(event), as: UTF8.self)
            XCTAssertFalse(encoded.contains("\\u001B"), "no escape sequence may appear in an event: \(encoded)")
            XCTAssertLessThan(encoded.count, 2048, "events are structural and must not carry big chunks of text: \(encoded)")
        }
    }

    /// The title / cwd of a browser pane gets redacted by the same rule `state` uses.
    /// Miss this one and `pane.title.changed` becomes a side channel around `expose-browser`
    func testBrowserMetadataIsRedactedForTokenlessCallers() {
        let event = ControlEvent(seq: 9, ts: "t", type: .paneTitleChanged, screen: 1, workspace: 1,
                                 pane: "b3", kind: "browser",
                                 title: "Private Bank - Account Overview", cwd: "/Users/danny")
        let redacted = ControlEventBus.redact(event)
        XCTAssertEqual(redacted.title, ControlEvent.redactedPlaceholder)
        XCTAssertEqual(redacted.cwd, ControlEvent.redactedPlaceholder)
        XCTAssertEqual(redacted.redacted, true,
                       "say so when something was redacted, or the caller thinks the title really "
                       + "is <redacted>")
        XCTAssertEqual(redacted.pane, "b3", "the handle is not a secret: redaction covers content only")
    }

    // MARK: follow

    /// The stream really pushes, and **stops the moment the peer walks away**.
    /// Without that stop, the server keeps writing to an already-closed fd until the app quits
    func testFollowStreamsAndStopsWhenTheClientGoesAway() throws {
        let connection: UInt64 = 4242
        var batches: [ControlEventsPayload] = []
        let peer = ControlSocket.Peer(fd: -1, uid: getuid(), pid: getpid(),
                                      processName: "xctest", connectionID: connection)
        let request = ControlRequest(id: "f1", cmd: "events.follow")
        harness.runner.handle(request, peer: peer) { response in
            guard let data = try? ControlJSON.line(response),
                  let reply = try? ControlJSON.decoder.decode(ControlReply.self, from: data),
                  let payload = reply.data,
                  let encoded = try? ControlJSON.encoder.encode(payload),
                  let decoded = try? ControlJSON.decoder.decode(ControlEventsPayload.self, from: encoded)
            else { return }
            batches.append(decoded)
        }
        XCTAssertEqual(batches.count, 1, "one batch comes back at registration time (empty is "
                       + "fine) so the caller knows which seq to start from")
        XCTAssertEqual(batches[0].follow, true)
        XCTAssertEqual(ControlEventBus.shared.followerCount, 1)

        try harness.newTerminal()
        harness.spin(0.3)
        XCTAssertGreaterThan(batches.count, 1, "new events have to be pushed through")
        XCTAssertFalse(batches.dropFirst().flatMap(\.events).isEmpty)

        // The peer walks away
        harness.runner.connectionDidClose(connection)
        XCTAssertEqual(ControlEventBus.shared.followerCount, 0, "closing the connection has to tear the stream down")
        let after = batches.count
        try harness.newTerminal()
        harness.spin(0.3)
        XCTAssertEqual(batches.count, after, "not one event may be pushed after the teardown")
    }

    /// Too many streams at once gets refused (each one holds a connection open) and points the
    /// caller at poll
    func testTooManyFollowersIsRefused() throws {
        var ids: [UInt64] = []
        defer { for id in ids { harness.runner.connectionDidClose(id) } }
        for index in 0..<ControlEventLimits.maxFollowers {
            let id = UInt64(9000 + index)
            ids.append(id)
            let peer = ControlSocket.Peer(fd: -1, uid: getuid(), pid: getpid(),
                                          processName: "xctest", connectionID: id)
            harness.runner.handle(ControlRequest(id: "f", cmd: "events.follow"), peer: peer) { _ in }
        }
        let peer = ControlSocket.Peer(fd: -1, uid: getuid(), pid: getpid(),
                                      processName: "xctest", connectionID: 9999)
        var response: ControlResponse?
        harness.runner.handle(ControlRequest(id: "f", cmd: "events.follow"), peer: peer) { response = $0 }
        let reply = try ControlJSON.decoder.decode(
            ControlReply.self, from: try ControlJSON.line(try XCTUnwrap(response)))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.busy.rawValue)
        XCTAssertTrue(reply.error?.hint?.contains("poll") ?? false,
                      "it has to point at the one an agent should be using instead")
    }

    // MARK: Long polling

    /// An event arriving while a long poll is parked returns immediately, without waiting the
    /// timeout out
    func testLongPollWakesUpOnTheNextEvent() throws {
        var payload: ControlEventsPayload?
        ControlEventBus.shared.poll(since: harness.seq, limit: ControlEventLimits.maxBatch,
                                    types: [ControlEventType.paneOpened.rawValue],
                                    exposesBrowser: true, timeout: 5) { payload = $0 }
        XCTAssertNil(payload, "no events yet, so it should still be parked")
        try harness.newTerminal()
        harness.spin(0.3)
        let got = try XCTUnwrap(payload, "a new event has to wake it up right away instead of burning the full 5 seconds")
        XCTAssertFalse(got.events.isEmpty)
        XCTAssertNil(got.timedOut)
    }

    /// On expiry it returns an empty batch flagged `timedOut` (**not an error**: the agent simply
    /// polls again with the same seq)
    func testLongPollTimesOutWithAnEmptyBatch() throws {
        var payload: ControlEventsPayload?
        ControlEventBus.shared.poll(since: harness.seq, limit: 10,
                                    types: [ControlEventType.screenClosed.rawValue],
                                    exposesBrowser: true, timeout: 0.2) { payload = $0 }
        harness.spin(0.6)
        let got = try XCTUnwrap(payload)
        XCTAssertTrue(got.events.isEmpty)
        XCTAssertEqual(got.timedOut, true)
    }

    // MARK: Command table

    /// Both commands in the events group have to be `read` class (they change nothing) and both
    /// have to be in the command table
    func testEventCommandsAreDeclaredAsReads() {
        let verbs = ControlCommandTable.commands(inGroup: "events")
        XCTAssertEqual(verbs.map(\.verb).sorted(), ["follow", "poll"])
        for spec in verbs {
            XCTAssertEqual(spec.cls, .read, "\(spec.cli) changes nothing, so it has to be read class")
            XCTAssertFalse(spec.honorsMutationFlags, "a read command must not accept --dry-run")
            XCTAssertFalse(spec.examples.isEmpty, "the help for every command has to end with EXAMPLES")
        }
        // describe hands over the event type table: an agent reads it once at the start of a
        // session and is done
        let document = ControlDescribeDocument.make(cliVersion: "t", appVersion: "t",
                                                    socket: nil, mode: "ask")
        XCTAssertEqual(Set(document.events.map(\.type)),
                       Set(ControlEventType.allCases.map(\.rawValue)))
        XCTAssertEqual(document.phase, 5)
    }

    // MARK: Helpers

    private func poll(since: Int, timeout: String, types: String? = nil,
                      limit: Int? = nil) throws -> ControlEventsPayload {
        var args: [String: JSONValue] = ["since": .int(since), "timeout": .string(timeout)]
        if let types { args["types"] = .string(types) }
        if let limit { args["limit"] = .int(limit) }
        let reply = try harness.run("events.poll", args: args)
        XCTAssertTrue(reply.ok, "poll failed: \(String(describing: reply.error))")
        let data = try XCTUnwrap(reply.data)
        let encoded = try ControlJSON.encoder.encode(data)
        return try ControlJSON.decoder.decode(ControlEventsPayload.self, from: encoded)
    }
}
