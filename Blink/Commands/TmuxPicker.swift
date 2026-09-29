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


import SwiftUI
import UIKit


// Presents the tmux session picker over the terminal, the same way `config` presents Settings.
enum TmuxPicker {
  static func present(device: TermDevice, completion: @escaping (TmuxTarget?) -> Void) {
    guard let spaceCtrl = spaceController(for: device) else {
      completion(nil)
      return
    }

    spaceCtrl.currentTerm()?.resignInput()

    let model = TmuxPickerModel(hosts: TmuxHosts.saved, device: device)
    var hosting: UIHostingController<TmuxPickerView>? = nil
    var done = false
    let finish: (TmuxTarget?) -> Void = { target in
      guard !done else { return }
      done = true
      hosting?.dismiss(animated: true) {
        spaceCtrl.focusOnShellAction()
        completion(target)
      }
    }

    hosting = UIHostingController(rootView: TmuxPickerView(model: model, onFinish: finish))
    // Cancel is explicit (button or Esc) so the waiting command always hears back.
    hosting!.isModalInPresentation = true
    spaceCtrl.present(hosting!, animated: true)
    model.refresh()
  }

  private static func spaceController(for device: TermDevice) -> SpaceController? {
    guard let window = device.view?.window else { return nil }
    // On an external display, present on the device's main window instead.
    if let shadowWindow = ShadowWindow.shared, window == shadowWindow {
      return shadowWindow.windowScene?.windows.first?.rootViewController as? SpaceController
    }
    return window.rootViewController as? SpaceController
  }
}


class TmuxPickerModel: ObservableObject {
  struct Host: Identifiable {
    var id: String { name }
    let name: String
    var status: TmuxHostStatus
  }

  @Published var hosts: [Host]
  private let device: TermDevice

  init(hosts: [String], device: TermDevice) {
    self.hosts = hosts.map { Host(name: $0, status: .loading) }
    self.device = device
  }

  var hostNames: [String] { hosts.map(\.name) }

  func refresh() {
    for index in hosts.indices {
      refresh(at: index)
    }
  }

  // Saves the host list. Hosts that are new get looked up; the rest keep their results.
  func setHosts(_ names: [String]) {
    TmuxHosts.saved = names
    let existing = Dictionary(uniqueKeysWithValues: hosts.map { ($0.name, $0) })
    hosts = names.map { existing[$0] ?? Host(name: $0, status: .loading) }
    for (index, name) in names.enumerated() where existing[name] == nil {
      refresh(at: index)
    }
  }

  private func refresh(at index: Int) {
    hosts[index].status = .loading
    let name = hosts[index].name
    TmuxDiscovery.list(host: name, device: device) { [weak self] status in
      guard let self = self,
            let i = self.hosts.firstIndex(where: { $0.name == name })
      else {
        return
      }
      self.hosts[i].status = status
    }
  }

  // Shortcut numbers run across hosts in display order, so ⌘1 is always the first session shown.
  func shortcutNumber(host: String, session: String) -> Int? {
    var n = 0
    for h in hosts {
      guard case .sessions(let sessions) = h.status else { continue }
      for s in sessions {
        n += 1
        if h.name == host && s.name == session {
          return n <= 9 ? n : nil
        }
      }
    }
    return nil
  }
}


struct TmuxPickerView: View {
  @ObservedObject var model: TmuxPickerModel
  let onFinish: (TmuxTarget?) -> Void

  @State private var newSessionHost: String? = nil
  @State private var newSessionName = ""
  @State private var editingHosts = false

  var body: some View {
    NavigationView {
      Group {
        if model.hosts.isEmpty {
          emptyState
        } else {
          sessionList
        }
      }
      .navigationTitle("tmux")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { onFinish(nil) }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
          Button {
            editingHosts = true
          } label: {
            Label("Hosts", systemImage: "server.rack")
          }
          Button {
            model.refresh()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .keyboardShortcut("r", modifiers: .command)
          .disabled(model.hosts.isEmpty)
        }
      }
      .sheet(isPresented: $editingHosts) {
        TmuxHostsEditor(selected: model.hostNames) { names in
          model.setHosts(names)
        }
      }
      .alert("New session on \(newSessionHost ?? "")", isPresented: Binding(
        get: { newSessionHost != nil },
        set: { if !$0 { newSessionHost = nil } }
      )) {
        TextField("Session name", text: $newSessionName)
          .autocapitalization(.none)
          .disableAutocorrection(true)
        Button("Cancel", role: .cancel) { newSessionHost = nil }
        Button("Create") {
          let name = newSessionName.trimmingCharacters(in: .whitespaces)
          if let host = newSessionHost, !name.isEmpty {
            onFinish(TmuxTarget(host: host, session: name))
          }
          newSessionHost = nil
        }
      }
    }
    .navigationViewStyle(.stack)
  }

  private var sessionList: some View {
    List {
      ForEach(model.hosts) { host in
        Section(header: Text(host.name)) {
          hostRows(host)
          Button {
            newSessionName = ""
            newSessionHost = host.name
          } label: {
            Label("New Session", systemImage: "plus")
          }
        }
      }
    }
    .listStyle(.insetGrouped)
  }

  private var emptyState: some View {
    VStack(spacing: 16) {
      Image(systemName: "server.rack")
        .font(.system(size: 44))
        .foregroundColor(.secondary)
      Text("No tmux hosts yet")
        .font(.title3.weight(.semibold))
      Text("Choose the hosts to look for tmux sessions on.")
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
      Button {
        editingHosts = true
      } label: {
        Text("Add Hosts")
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func hostRows(_ host: TmuxPickerModel.Host) -> some View {
    switch host.status {
    case .loading:
      HStack(spacing: 8) {
        ProgressView()
        Text("Looking for sessions…").foregroundColor(.secondary)
      }
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundColor(.secondary)
    case .sessions(let sessions) where sessions.isEmpty:
      Text("No sessions").foregroundColor(.secondary)
    case .sessions(let sessions):
      ForEach(sessions) { session in
        sessionRow(host: host.name, session: session)
      }
    }
  }

  @ViewBuilder
  private func sessionRow(host: String, session: TmuxSession) -> some View {
    let number = model.shortcutNumber(host: host, session: session.name)
    let button = Button {
      onFinish(TmuxTarget(host: host, session: session.name))
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(session.name).font(.body.weight(.semibold)).foregroundColor(.primary)
          Text(detail(session)).font(.caption).foregroundColor(.secondary)
        }
        Spacer()
        if let number = number {
          Text("⌘\(number)").font(.caption.monospaced()).foregroundColor(.secondary)
        }
      }
    }

    if let number = number {
      button.keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
    } else {
      button
    }
  }

  private func detail(_ session: TmuxSession) -> String {
    var parts = ["\(session.windows) window\(session.windows == 1 ? "" : "s")"]
    if session.attached > 0 {
      parts.append("attached")
    }
    if let date = session.lastActivity {
      parts.append(Self.relative.localizedString(for: date, relativeTo: Date()))
    }
    return parts.joined(separator: " · ")
  }

  private static let relative: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
  }()
}


// Chooses which hosts the picker searches: hosts from `config` → Hosts, plus any other name ssh can reach.
struct TmuxHostsEditor: View {
  let onDone: ([String]) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selected: [String]
  @State private var otherHost = ""
  private let blinkHosts: [String]

  init(selected: [String], onDone: @escaping ([String]) -> Void) {
    _selected = State(initialValue: selected)
    self.onDone = onDone
    self.blinkHosts = (BKHosts.all() ?? [])
      .compactMap { ($0 as? BKHosts)?.host }
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  private var otherHosts: [String] {
    selected.filter { !blinkHosts.contains($0) }
  }

  private var trimmedOther: String {
    otherHost.trimmingCharacters(in: .whitespaces)
  }

  var body: some View {
    NavigationView {
      List {
        Section(header: Text("Blink Hosts"),
                footer: Text("From config → Hosts. Discovery never asks for a password, so each host needs a key.")) {
          if blinkHosts.isEmpty {
            Text("No hosts in config yet").foregroundColor(.secondary)
          }
          ForEach(blinkHosts, id: \.self) { host in
            Button {
              toggle(host)
            } label: {
              HStack {
                Text(host).foregroundColor(.primary)
                Spacer()
                if selected.contains(host) {
                  Image(systemName: "checkmark").foregroundColor(.accentColor)
                }
              }
            }
          }
        }

        Section(header: Text("Other Hosts"),
                footer: Text("Any name ssh can reach, such as a Tailscale hostname or user@host.")) {
          ForEach(otherHosts, id: \.self) { host in
            Text(host)
          }
          .onDelete { offsets in
            let removed = offsets.map { otherHosts[$0] }
            selected.removeAll { removed.contains($0) }
          }
          HStack {
            TextField("hostname", text: $otherHost)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .onSubmit(addOther)
            Button("Add", action: addOther)
              .disabled(trimmedOther.isEmpty)
          }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("tmux Hosts")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            onDone(selected)
            dismiss()
          }
        }
      }
    }
    .navigationViewStyle(.stack)
  }

  private func toggle(_ host: String) {
    if let index = selected.firstIndex(of: host) {
      selected.remove(at: index)
    } else {
      selected.append(host)
    }
  }

  private func addOther() {
    let host = trimmedOther
    guard !host.isEmpty, !host.contains(" "), !host.contains("\"") else { return }
    if !selected.contains(host) {
      selected.append(host)
    }
    otherHost = ""
  }
}
