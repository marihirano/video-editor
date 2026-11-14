import EditorCore
import SwiftUI

/// The Style panel's Cursor tab: only for recordings made in the app (imported videos have no cursor log).
struct CursorSection: View {
    @EnvironmentObject private var model: EditorModel
    private var look: CursorLook { model.project?.cursorLook ?? CursorLook() }

    var body: some View {
        PanelSection("Style") {
            ChoiceButtons(choices: CursorLook.Style.allCases, isSelected: { look.style == $0 },
                          label: { s in
                              switch s {
                              case .black: "Black"
                              case .white: "White"
                              case .dot: "Dot"
                              }
                          }) { s in model.updateCursorLook { $0.style = s } }
            SliderRow(title: "Size", valueText: "\(Int((look.size * 100).rounded()))%",
                      value: binding(\.size), range: Settings.cursorSizeRange)
            SliderRow(title: "Smoothing", valueText: "\(Int((look.smoothing * 100).rounded()))%",
                      value: binding(\.smoothing), range: 0...1)
            SliderRow(title: "Motion blur", valueText: "\(Int((look.motionBlur * 100).rounded()))%",
                      value: binding(\.motionBlur), range: 0...1)
            VStack(alignment: .leading, spacing: Theme.s2) {
                Text("Clicks").font(Theme.fontCallout).foregroundStyle(Theme.secondaryText)
                ChoiceButtons(choices: CursorLook.ClickEffect.allCases, isSelected: { look.clickEffect == $0 },
                              label: { e in
                                  switch e {
                                  case .none: "None"
                                  case .circle: "Circle"
                                  case .ripple: "Ripple"
                                  }
                              }) { e in model.updateCursorLook { $0.clickEffect = e } }
            }
            HStack {
                Text("Hide when still").font(Theme.fontCallout).foregroundStyle(Theme.secondaryText)
                Spacer()
                PanelSwitch(isOn: Binding(get: { look.hideWhenIdle }, set: { v in model.updateCursorLook { $0.hideWhenIdle = v } }))
            }
            .help("Fade the cursor out after \(Int(Settings.cursorIdleSeconds)) seconds without moving; it fades back in just before it moves")
        }
    }

    private func binding(_ path: WritableKeyPath<CursorLook, Double>) -> Binding<Double> {
        Binding(get: { look[keyPath: path] }, set: { v in model.updateCursorLook { $0[keyPath: path] = v } })
    }
}

/// A small on/off switch in the accent colour.
struct PanelSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(Theme.accent)
    }
}

/// Tabs under a panel's title (General / Cursor): the chosen one in the main text colour with a line
/// under it, the others in the secondary colour, all on a thin full-width line.
struct PanelTabs<Value: Hashable>: View {
    let tabs: [Value]
    @Binding var selected: Value
    let label: (Value) -> String

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.s5) {
            ForEach(tabs, id: \.self) { t in
                let on = t == selected
                Button { selected = t } label: {
                    Text(label(t)).font(Theme.fontBody)
                        .foregroundStyle(on ? Color.primary : Theme.secondaryText)
                        .padding(.bottom, 10)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(on ? Color.primary : Color.clear).frame(height: 1.5)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .background(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
