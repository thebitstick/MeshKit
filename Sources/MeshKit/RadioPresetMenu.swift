import MeshKitCore
import SwiftUI

struct RadioValues {
    var frequencyMHz: Double
    var bandwidthKHz: Double
    var spreadingFactor: Int
    var codingRate: Int

    init?(frequency: String, bandwidth: String, sf: Int, cr: Int) {
        guard let f = Double(frequency), let b = Double(bandwidth) else { return nil }
        self.init(frequencyMHz: f, bandwidthKHz: b, spreadingFactor: sf, codingRate: cr)
    }

    init?(cli: String) {
        let p = cli.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard p.count == 4, let f = Double(p[0]), let b = Double(p[1]), let sf = Int(p[2]), let cr = Int(p[3]) else { return nil }
        self.init(frequencyMHz: f, bandwidthKHz: b, spreadingFactor: sf, codingRate: cr)
    }

    init(frequencyMHz: Double, bandwidthKHz: Double, spreadingFactor: Int, codingRate: Int) {
        self.frequencyMHz = frequencyMHz; self.bandwidthKHz = bandwidthKHz
        self.spreadingFactor = spreadingFactor; self.codingRate = codingRate
    }

    func matches(_ p: RadioPreset) -> Bool {
        p.matches(frequencyMHz: frequencyMHz, bandwidthKHz: bandwidthKHz, spreadingFactor: spreadingFactor, codingRate: codingRate)
    }
}

struct RadioPresetMenu: View {
    @Environment(AppModel.self) private var model
    var current: RadioValues?
    let apply: (RadioPreset) -> Void

    @State private var saving = false
    @State private var newName = ""
    @State private var saveError: String?

    var body: some View {
        Menu {
            ForEach(model.presetsByRegion, id: \.region) { group in
                Menu(group.region) {
                    ForEach(group.presets) { presetButton($0) }
                }
            }

            if !model.userPresets.isEmpty {
                Divider()
                Menu("My Presets") {
                    ForEach(model.userPresets) { presetButton($0) }
                    Divider()
                    Menu("Delete") {
                        ForEach(model.userPresets) { p in Button(p.title, role: .destructive) { model.deleteUserPreset(p) } }
                    }
                }
            }

            Divider()
            Button("Save Current Settings as a Preset…") { newName = ""; saving = true }
                .disabled(current == nil)
            Button("Refresh Community List") { Task { await model.loadRadioPresets(force: true) } }
            Text(model.radioPresetSource.description)
        } label: {
            Label("Presets", systemImage: "list.bullet.rectangle")
        }
        .menuIndicator(.visible)
        .fixedSize()
        .alert("Save radio preset", isPresented: $saving) {
            TextField("Name", text: $newName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(current.map { RadioPreset(title: "", frequencyMHz: $0.frequencyMHz, bandwidthKHz: $0.bandwidthKHz,
                                           spreadingFactor: $0.spreadingFactor, codingRate: $0.codingRate).summary } ?? "")
        }
        .alert("Couldn't save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") {}
        } message: { Text(saveError ?? "") }
    }

    @ViewBuilder private func presetButton(_ p: RadioPreset) -> some View {
        Button { apply(p) } label: {
            if let current, current.matches(p) {
                Label("\(p.title) — \(p.summary)", systemImage: "checkmark")
            } else {
                Text("\(p.title) — \(p.summary)")
            }
        }
    }

    private func save() {
        guard let c = current else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { saveError = "Give the preset a name."; return }
        do {
            try model.saveUserPreset(RadioPreset(title: name, frequencyMHz: c.frequencyMHz, bandwidthKHz: c.bandwidthKHz,
                                                 spreadingFactor: c.spreadingFactor, codingRate: c.codingRate))
        } catch { saveError = error.localizedDescription }
    }
}

struct PresetMatchNote: View {
    @Environment(AppModel.self) private var model
    let values: RadioValues?

    var body: some View {
        if let values, case let matches = model.presets(matching: values), !matches.isEmpty {
            Label(RadioPreset.matchSummary(matches), systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.green)
        } else if values != nil {
            Label("Custom settings (not one of the listed presets)", systemImage: "slider.horizontal.3")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
