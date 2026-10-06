use std::collections::HashSet;

use keyboard_types::{Key, KeyState, KeyboardEvent, Modifiers, NamedKey};

#[derive(Debug, PartialEq)]
pub(crate) enum EditingShortcut {
    Copy,
    Cut,
    Paste,
}

pub(crate) fn editing_shortcut(event: &KeyboardEvent) -> Option<EditingShortcut> {
    if event.state != KeyState::Down || event.modifiers != Modifiers::CONTROL {
        return None;
    }
    let Key::Character(character) = &event.key else {
        return None;
    };
    match character.to_ascii_lowercase().as_str() {
        "c" => Some(EditingShortcut::Copy),
        "x" => Some(EditingShortcut::Cut),
        "v" => Some(EditingShortcut::Paste),
        _ => None,
    }
}

#[derive(Default)]
pub(crate) struct KeyboardState {
    pressed: HashSet<String>,
}

impl KeyboardState {
    pub(crate) fn clear(&mut self) {
        self.pressed.clear();
    }

    pub(crate) fn event(&mut self, label: &str, character: &str, state: KeyState) -> KeyboardEvent {
        let label = label
            .trim()
            .to_ascii_lowercase()
            .replace([' ', '_', '-'], "");
        let repeat = match state {
            KeyState::Down => !self.pressed.insert(label.clone()),
            KeyState::Up => {
                self.pressed.remove(&label);
                false
            }
        };
        let mut modifiers = Modifiers::empty();
        for pressed in &self.pressed {
            modifiers |= match key(pressed, "") {
                Key::Named(NamedKey::Shift) => Modifiers::SHIFT,
                Key::Named(NamedKey::Control) => Modifiers::CONTROL,
                Key::Named(NamedKey::Alt) => Modifiers::ALT,
                Key::Named(NamedKey::Meta) => Modifiers::META,
                _ => Modifiers::empty(),
            };
        }
        KeyboardEvent {
            state,
            key: key(&label, character),
            modifiers,
            repeat,
            ..KeyboardEvent::default()
        }
    }
}

fn key(label: &str, character: &str) -> Key {
    if !character.is_empty() {
        return Key::Character(character.into());
    }
    match label {
        "backspace" => Key::Named(NamedKey::Backspace),
        "tab" => Key::Named(NamedKey::Tab),
        "enter" | "numpadenter" => Key::Named(NamedKey::Enter),
        "escape" | "esc" => Key::Named(NamedKey::Escape),
        "space" | "spacebar" => Key::Character(" ".into()),
        "arrowleft" | "leftarrow" => Key::Named(NamedKey::ArrowLeft),
        "arrowright" | "rightarrow" => Key::Named(NamedKey::ArrowRight),
        "arrowup" | "uparrow" => Key::Named(NamedKey::ArrowUp),
        "arrowdown" | "downarrow" => Key::Named(NamedKey::ArrowDown),
        "delete" | "del" => Key::Named(NamedKey::Delete),
        "insert" | "ins" => Key::Named(NamedKey::Insert),
        "home" => Key::Named(NamedKey::Home),
        "end" => Key::Named(NamedKey::End),
        "pageup" => Key::Named(NamedKey::PageUp),
        "pagedown" => Key::Named(NamedKey::PageDown),
        "shift" | "shiftleft" | "shiftright" => Key::Named(NamedKey::Shift),
        "control" | "ctrl" | "controlleft" | "controlright" => Key::Named(NamedKey::Control),
        "alt" | "altleft" | "altright" => Key::Named(NamedKey::Alt),
        "meta" | "super" | "metaleft" | "metaright" => Key::Named(NamedKey::Meta),
        _ if label.chars().count() == 1 => Key::Character(label.into()),
        _ => Key::Named(NamedKey::Unidentified),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selection_and_clipboard_modifiers_follow_key_state() {
        let mut keyboard = KeyboardState::default();
        keyboard.event("Shift Left", "", KeyState::Down);
        keyboard.event("Shift Right", "", KeyState::Down);
        keyboard.event("Shift Left", "", KeyState::Up);
        assert!(keyboard
            .event("Arrow Right", "", KeyState::Down)
            .modifiers
            .contains(Modifiers::SHIFT));
        keyboard.clear();
        keyboard.event("Control Left", "", KeyState::Down);
        assert!(keyboard
            .event("c", "c", KeyState::Down)
            .modifiers
            .contains(Modifiers::CONTROL));
        keyboard.event("Control Left", "", KeyState::Up);
        assert!(keyboard.event("c", "", KeyState::Up).modifiers.is_empty());
    }

    #[test]
    fn repeat_and_focus_reset_are_preserved() {
        let mut keyboard = KeyboardState::default();
        assert!(!keyboard.event("a", "a", KeyState::Down).repeat);
        assert!(keyboard.event("a", "a", KeyState::Down).repeat);
        keyboard.clear();
        assert!(!keyboard.event("a", "a", KeyState::Down).repeat);
        assert_eq!(
            keyboard.event("a", "é", KeyState::Down).key,
            Key::Character("é".into())
        );
    }

    #[test]
    fn clipboard_shortcuts_use_explicit_editing_actions() {
        let mut keyboard = KeyboardState::default();
        assert_eq!(
            editing_shortcut(&keyboard.event("c", "c", KeyState::Down)),
            None
        );
        keyboard.event("Control Left", "", KeyState::Down);
        for (key, action) in [
            ("c", EditingShortcut::Copy),
            ("x", EditingShortcut::Cut),
            ("v", EditingShortcut::Paste),
        ] {
            assert_eq!(
                editing_shortcut(&keyboard.event(key, key, KeyState::Down)),
                Some(action)
            );
            assert_eq!(
                editing_shortcut(&keyboard.event(key, "", KeyState::Up)),
                None
            );
        }
    }
}
