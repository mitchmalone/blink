import XCTest
@testable import Blink

final class SessionLifecycleTests: XCTestCase {
  func testSuspensionSurvivesSnapshotExtraction() {
    let device = TermDevice()
    let params = Blink.MCPParams()
    let moshParams = Blink.MoshParams()
    params.childSessionParams = moshParams
    let session = MCPSession(device: device, andParams: params)!
    let mosh = BlinkMosh(mcpSession: session, device: device, andParams: moshParams)!
    defer {
      mosh.stream.close()
      session.stream.close()
      device.close()
    }

    XCTAssertFalse(mosh.didSuspend)
    let snapshot = Data([1, 2, 3])
    mosh.onStateEncoded(snapshot)

    // MCPSessionPayload moves the snapshot out before the child finishes.
    // Its absence must not turn suspension into an exit/picker/prompt.
    XCTAssertEqual(params.takeEncodedState(), snapshot)
    XCTAssertFalse(params.hasEncodedState())
    XCTAssertTrue(mosh.didSuspend)
  }

  func testCommandHandoffSkipsPromptAndIsConsumedOnce() {
    let device = PromptRecordingDevice()
    let session = HandoffRecordingSession(device: device, andParams: Blink.MCPParams())!
    defer {
      session.stream.close()
      device.close()
    }

    session.enqueueCommand(afterExit: "mosh example -- tmux")
    session.runCommand("")
    drain(session)

    XCTAssertEqual(session.commands, ["mosh example -- tmux"])
    XCTAssertEqual(session.skipHistory, [true])
    XCTAssertTrue(device.prompts.isEmpty)

    // Once the handoff is consumed, returning to the shell still works.
    session.runCommand("")
    drain(session)
    XCTAssertEqual(session.commands.count, 1)
    XCTAssertEqual(device.prompts, ["blink> "])
  }

  private func drain(_ session: MCPSession) {
    let drained = expectation(description: "Command queue drained")
    session.cmdQueue.async { drained.fulfill() }
    wait(for: [drained], timeout: 5)
  }
}

private final class PromptRecordingDevice: TermDevice {
  var prompts: [String] = []

  override func prompt(_ prompt: String!, secure: Bool, shell: Bool) {
    prompts.append(prompt)
  }
}

private final class HandoffRecordingSession: MCPSession {
  var commands: [String] = []
  var skipHistory: [Bool] = []

  override func enqueueCommand(_ cmd: String!, skipHistoryRecord: Bool) {
    commands.append(cmd)
    skipHistory.append(skipHistoryRecord)
  }

  func runCommand(_ command: String) {
    super.enqueueCommand(command, skipHistoryRecord: true)
  }
}
