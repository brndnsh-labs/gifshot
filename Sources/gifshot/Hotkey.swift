import Carbon.HIToolbox

/// Global hotkeys via Carbon `RegisterEventHotKey`: no Accessibility permission needed.
final class HotKeys {
    private static var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []

    /// `keyCode` is a `kVK_*` constant, `modifiers` a mask of Carbon `cmdKey`, `optionKey`, etc.
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        if handler == nil { installHandler() }
        let id = UInt32(Self.actions.count + 1)
        Self.actions[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x6769_6673 /* 'gifs' */, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
        } else {
            NSLog("gifshot: hotkey \(keyCode) could not be registered (\(status)); is it taken?")
        }
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated { HotKeys.actions[id]?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
