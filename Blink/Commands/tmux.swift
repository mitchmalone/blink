//////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2025 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
////////////////////////////////////////////////////////////////////////////////


import Foundation
import Combine
import ArgumentParser
import BlinkConfig
import SSH
import ios_system


struct TmuxCommand: NonStdIOCommand {
  static var configuration = CommandConfiguration(
    commandName: "tmux",
    abstract: "Pick a tmux session on your hosts and attach to it over mosh",
    discussion: """
    tmux                 Open the session picker. Add hosts from its Hosts button.
    tmux beebee/main     Attach directly over mosh, creating the session if needed.
    tmux beebee/main --ssh   The same over ssh, for when mosh can't get through.
    tmux --list          Print the sessions on your tmux hosts.
    """
  )

  @OptionGroup var verboseOptions: VerboseOptions
  var io = NonStdIO.standard

  @Flag(name: .shortAndLong, help: "Print the sessions instead of opening the picker.")
  var list: Bool = false

  @Flag(help: "Attach with ssh instead of mosh.")
  var ssh: Bool = false

  @Argument(help: "host/session to attach to directly.")
  var target: String?

  func validate() throws {
    if let target = target, TmuxTarget(parsing: target) == nil {
      throw ArgumentParser.ValidationError("Expected host/session. Hosts are managed from the picker: run tmux on its own.")
    }
  }

  func run() throws {
    let session = Unmanaged<MCPSession>.fromOpaque(thread_context).takeUnretainedValue()

    if let target = target.flatMap(TmuxTarget.init(parsing:)) {
      let transport: TmuxTransport = ssh ? .ssh : .mosh
      try TmuxAttach.enqueue(TmuxTarget(host: target.host, session: target.session, transport: transport), on: session)
      return
    }

    if list {
      let hosts = TmuxHosts.saved
      guard !hosts.isEmpty else {
        throw CommandError(message: "No tmux hosts yet. Run tmux and add them from the Hosts button.")
      }
      printSessions(on: hosts, using: session.device)
      return
    }

    let semaphore = DispatchSemaphore(value: 0)
    var picked: TmuxTarget? = nil
    DispatchQueue.main.async {
      TmuxPicker.present(device: session.device) { target in
        picked = target
        semaphore.signal()
      }
    }
    semaphore.wait()

    if let picked = picked {
      try TmuxAttach.enqueue(picked, on: session)
    } else {
      // Cancelling the picker means staying at the prompt from now on.
      session.sessionParams.returnCommand = nil
    }
  }

  private func printSessions(on hosts: [String], using device: TermDevice) {
    let group = DispatchGroup()
    var results: [String: TmuxHostStatus] = [:]
    let lock = NSLock()

    for host in hosts {
      group.enter()
      TmuxDiscovery.list(host: host, device: device, callbackQueue: .global()) { status in
        lock.lock()
        results[host] = status
        lock.unlock()
        group.leave()
      }
    }
    group.wait()

    for host in hosts {
      print("\(host):")
      switch results[host] ?? .loading {
      case .loading:
        print("  (no answer)")
      case .failed(let message):
        print("  error: \(message)")
      case .sessions(let sessions, let mosh) where sessions.isEmpty:
        print("  no sessions\(mosh ? "" : " (no mosh-server, ssh fallback)")")
      case .sessions(let sessions, let mosh):
        if !mosh {
          print("  (no mosh-server, ssh fallback)")
        }
        for s in sessions {
          print("  \(s.name)  \(s.windows) window\(s.windows == 1 ? "" : "s")\(s.attached > 0 ? "  (attached)" : "")")
        }
      }
    }
  }
}

@_cdecl("tmux_main")
public func tmux_main(argc: Int32, argv: Argv) -> Int32 {
  setvbuf(thread_stdin, nil, _IONBF, 0)
  setvbuf(thread_stdout, nil, _IONBF, 0)
  setvbuf(thread_stderr, nil, _IONBF, 0)

  let io = NonStdIO.standard
  io.out = OutputStream(file: thread_stdout)
  io.err = OutputStream(file: thread_stderr)

  return TmuxCommand.main(Array(argv.args(count: argc)[1...]), io: io)
}


// MARK: - Model

// mosh is preferred: it roams and survives sleep. ssh is the fallback for hosts
// without mosh-server, or when UDP is blocked.
enum TmuxTransport {
  case mosh
  case ssh
}

struct TmuxTarget: Equatable {
  let host: String
  let session: String
  let transport: TmuxTransport

  init(host: String, session: String, transport: TmuxTransport = .mosh) {
    self.host = host
    self.session = session
    self.transport = transport
  }

  // host/session
  init?(parsing arg: String) {
    guard let slash = arg.firstIndex(of: "/") else { return nil }
    let host = String(arg[..<slash])
    let session = String(arg[arg.index(after: slash)...])
    guard !host.isEmpty, !session.isEmpty else { return nil }
    self.init(host: host, session: session)
  }
}

struct TmuxSession: Identifiable, Hashable {
  var id: String { name }
  let name: String
  let windows: Int
  let attached: Int
  let lastActivity: Date?
}

enum TmuxHostStatus {
  case loading
  // mosh: whether the host has a mosh-server Blink can start.
  case sessions([TmuxSession], mosh: Bool)
  case failed(String)
}

enum TmuxHosts {
  private static let key = "tmuxHosts"

  static var saved: [String] {
    get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    set { UserDefaults.standard.set(newValue, forKey: key) }
  }
}


// MARK: - Remote commands

enum TmuxShell {
  static let listMarker = "__BLINK_TMUX__"
  static let statusMarker = "__BLINK_TMUX_RC__"
  static let moshMarker = "__BLINK_MOSH__"

  static func quote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  // Run through a login shell so tmux installed outside the default PATH
  // (Homebrew on macOS) is found. Markers fence the output from shell profile noise.
  //
  // The mosh-server check runs first, outside the login shell, because that is
  // where Blink's mosh looks: ~/.local/blink/mosh-server, then the plain PATH.
  // Everything is wrapped in sh -c so it parses whatever the login shell is.
  static var listCommand: String {
    let mosh = "if test -x ~/.local/blink/mosh-server || command -v mosh-server >/dev/null 2>&1; " +
      "then echo \(moshMarker)1; else echo \(moshMarker)0; fi"
    let format = "#{session_windows}|#{session_attached}|#{session_activity}|#{session_name}"
    let script = "echo \(listMarker); tmux list-sessions -F \(quote(format)) 2>&1; echo \(statusMarker)$?"
    return "sh -c \(quote("\(mosh); exec ${SHELL:-sh} -lc \(quote(script))"))"
  }

  // No double quotes: the whole command travels as one double-quoted argument.
  static func attachCommand(session: String) -> String {
    "sh -c \(quote("exec ${SHELL:-sh} -lc \(quote("exec tmux new -A -s \(quote(session))"))"))"
  }

  static func parse(_ output: String) -> TmuxHostStatus {
    let lines = output
      .replacingOccurrences(of: "\r", with: "")
      .components(separatedBy: "\n")

    guard let start = lines.firstIndex(of: listMarker),
          let end = lines[start...].firstIndex(where: { $0.hasPrefix(statusMarker) }),
          let status = Int(lines[end].dropFirst(statusMarker.count))
    else {
      return .failed("Unexpected output from host")
    }

    let body = lines[(start + 1)..<end].filter { !$0.isEmpty }
    // Assume mosh when the check is missing, which keeps today's behaviour.
    let mosh = lines.first(where: { $0.hasPrefix(moshMarker) }).map { $0.hasSuffix("1") } ?? true

    if status == 0 {
      return .sessions(body.compactMap(parseSession), mosh: mosh)
    }
    if status == 127 {
      return .failed("tmux not found on the host")
    }
    let message = body.joined(separator: " ")
    // No server (or no socket yet) just means no sessions.
    if message.contains("no server running") || message.contains("error connecting to") {
      return .sessions([], mosh: mosh)
    }
    return .failed(message.isEmpty ? "tmux exited with \(status)" : message)
  }

  private static func parseSession(_ line: String) -> TmuxSession? {
    let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
    guard fields.count == 4,
          let windows = Int(fields[0]),
          let attached = Int(fields[1])
    else {
      return nil
    }
    let activity = TimeInterval(fields[2]).map { Date(timeIntervalSince1970: $0) }
    return TmuxSession(name: String(fields[3]), windows: windows, attached: attached, lastActivity: activity)
  }
}


// MARK: - Discovery

enum TmuxDiscovery {
  // Lists sessions on one host without ever prompting. Each host runs on its own
  // thread and run loop, the same way SSH commands do.
  static func list(host alias: String,
                   device: TermDevice,
                   timeout: TimeInterval = 10,
                   callbackQueue: DispatchQueue = .main,
                   completion: @escaping (TmuxHostStatus) -> Void) {
    let thread = Thread {
      let status = listOnCurrentThread(host: alias, device: device, timeout: timeout)
      callbackQueue.async { completion(status) }
    }
    thread.name = "tmux-discovery-\(alias)"
    thread.start()
  }

  private static func listOnCurrentThread(host alias: String, device: TermDevice, timeout: TimeInterval) -> TmuxHostStatus {
    let hostName: String
    let config: SSHClientConfig
    do {
      // Accept user@host, the same as ssh and mosh do.
      var content: [String: Any] = [:]
      var hostAlias = alias
      if let at = alias.lastIndex(of: "@") {
        content["user"] = String(alias[..<at])
        hostAlias = String(alias[alias.index(after: at)...])
      }
      let resolved = try BKConfig().resolveHost(alias: hostAlias, extending: try BKSSHHost(content: content))
      hostName = resolved.hostName
      config = try SSHClientConfigProvider.config(host: resolved.host, using: device, interactive: false)
    } catch {
      return .failed(describe(error))
    }

    let runLoop = CFRunLoopGetCurrent()
    var status: TmuxHostStatus = .failed("Timed out")
    var finished = false

    var cancellable: AnyCancellable? = SSHClient.dial(hostName, with: config)
      .flatMap { $0.requestExec(command: TmuxShell.listCommand) }
      .flatMap { $0.read(max: 1 << 20) }
      .sink(
        receiveCompletion: { completion in
          if case .failure(let error) = completion {
            status = .failed(describe(error))
          }
          finished = true
          CFRunLoopStop(runLoop)
        },
        receiveValue: { data in
          status = TmuxShell.parse(String(decoding: data as AnyObject as! Data, as: UTF8.self))
        })

    if !finished {
      let timer = Timer(timeInterval: timeout, repeats: false) { _ in CFRunLoopStop(runLoop) }
      RunLoop.current.add(timer, forMode: .default)
      SSHClient.run()
      timer.invalidate()
    }

    cancellable?.cancel()
    cancellable = nil
    return status
  }

  private static func describe(_ error: Error) -> String {
    if let error = error as? SSHError {
      switch error {
      case .authFailed:
        return "Needs auth: add a key for this host (ssh-copy-id)"
      default:
        return error.description
      }
    }
    if let error = error as? CommandError {
      return error.message
    }
    return error.localizedDescription
  }
}


// MARK: - Attach

enum TmuxAttach {
  // Hands off to Blink's own mosh or ssh command once this command returns, so
  // the connection is saved and restored like any other session.
  static func enqueue(_ target: TmuxTarget, on session: MCPSession) throws {
    // The remote command travels as one double-quoted argument.
    guard !target.host.contains("\""), !target.host.contains(" "), !target.session.contains("\"") else {
      throw CommandError(message: "Host and session names can't contain double quotes or (for hosts) spaces.")
    }
    let remote = TmuxShell.attachCommand(session: target.session)
    // Detaching (or exiting) tmux brings the picker back, including after the
    // app was killed and the mosh session restored. Cancelling it clears this.
    session.sessionParams.returnCommand = "tmux"

    let cmd: String
    switch target.transport {
    case .mosh:
      cmd = "mosh \(target.host) -- \"\(remote)\""
    case .ssh:
      cmd = "ssh -t \(target.host) -- \"\(remote)\""
    }
    session.cmdQueue.async {
      session.enqueueCommand(cmd, skipHistoryRecord: true)
    }
  }
}
