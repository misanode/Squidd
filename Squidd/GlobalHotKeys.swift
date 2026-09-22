import AppKit
import Carbon

@MainActor
final class GlobalHotKeys {
    private var handler: EventHandlerRef?
    private var keys: [EventHotKeyRef] = []
    var action: ((UInt32, Bool) -> Void)?

    func register() -> [String] {
        stop()
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr else { return result }
            let id = key.id, pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotKeys>.fromOpaque(context).takeUnretainedValue().action?(id, pressed)
            }
            return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return ["Cannot install shortcuts (\(status))."] }
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let bindings: [(UInt32, UInt32, String)] = [
            (UInt32(kVK_ANSI_Slash), modifiers, "⌃⌥⌘/"),
            (UInt32(kVK_UpArrow), modifiers, "⌃⌥⌘↑"),
            (UInt32(kVK_LeftArrow), modifiers, "⌃⌥⌘←"),
            (UInt32(kVK_DownArrow), modifiers, "⌃⌥⌘↓"),
            (UInt32(kVK_RightArrow), modifiers, "⌃⌥⌘→")
        ]
        var errors: [String] = []
        for (index, binding) in bindings.enumerated() {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(binding.0, binding.1,
                EventHotKeyID(signature: 0x4D495341, id: UInt32(index)), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { keys.append(ref) }
            else { errors.append("\(binding.2) unavailable (\(result)); another app may be using it.") }
        }
        return errors
    }
    func stop() {
        for key in keys { UnregisterEventHotKey(key) }
        keys = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
