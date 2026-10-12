// Copyright 2026 Adam Cox
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut through Carbon's `RegisterEventHotKey`.
///
/// Chosen over an `NSEvent` global monitor because it needs no Accessibility
/// permission. It only ever shows or hides the panel — Meetey has no shortcut
/// that starts a recording, and must not gain one.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// ⌃⌥M by default ("Meetey").
    init?(keyCode: UInt32 = UInt32(kVK_ANSI_M), modifiers: UInt32 = UInt32(controlKey | optionKey),
          action: @escaping () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &type, me, &handlerRef)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x4D54_4559), id: 1) // "MTEY"
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    static let label = "⌃⌥M"
}
