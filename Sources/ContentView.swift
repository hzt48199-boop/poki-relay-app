import SwiftUI

struct ContentView: View {
    @StateObject private var manager = RelayManager()
    @State private var authtag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PokiRelay")
                .font(.title2)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 4) {
                Text("AUTHTAG")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("AUTHTAG from the box", text: $authtag)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            ReadOnlyRow(label: "Identifier", value: RelayManager.identifier)
            ReadOnlyRow(label: "Box", value: RelayManager.boxHost)
            ReadOnlyRow(label: "Port", value: String(RelayManager.port))

            Button {
                if manager.isRunning {
                    manager.stop()
                } else {
                    manager.start(authtag: authtag.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } label: {
                Text(manager.isRunning ? "Stop" : "Start")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(manager.isRunning ? .red : .green)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(manager.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: manager.logLines.count) { _ in
                    if let last = manager.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .padding()
    }
}

private struct ReadOnlyRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(6)
        }
    }
}
