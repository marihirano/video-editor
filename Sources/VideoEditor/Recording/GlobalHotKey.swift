import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut that works while other apps are in front (start / stop recording).
/// Uses the system's hot-key service, which needs no permission.
final class GlobalHotKey {
    /// ⌥⇧⌘R ("R" for record). Claude's call, for Mari to review.
    static let keyCode = UInt32(kVK_ANSI_R)
    static let modifiers = UInt32(cmdKey | optionKey | shiftKey)
    static let label = "⌥⇧⌘R"

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var current: GlobalHotKey?

    init(action: @escaping () -> Void) { self.action = action }

    func register() {
        GlobalHotKey.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.current?.action() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x56454452 /* VEDR */), id: 1)
        RegisterEventHotKey(Self.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}
