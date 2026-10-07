use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{json, Value};
use servo::{ContextMenu, ContextMenuItem, EmbedderControl, EmbedderControlId};

#[derive(Default)]
pub(crate) struct Controls {
    events: VecDeque<Value>,
    menu: Option<(u64, ContextMenu)>,
    ime: Option<(EmbedderControlId, u64)>,
}

static NEXT_CONTROL_ID: AtomicU64 = AtomicU64::new(1);

impl Controls {
    pub fn show(&mut self, control: EmbedderControl) {
        match control {
            EmbedderControl::ContextMenu(menu) => {
                self.dismiss_menu();
                let id = NEXT_CONTROL_ID.fetch_add(1, Ordering::Relaxed);
                let rect = menu.position();
                let items: Vec<_> = menu
                    .items()
                    .iter()
                    .enumerate()
                    .map(|(index, item)| {
                        match item {
                            ContextMenuItem::Separator => json!({"separator": true}),
                            ContextMenuItem::Item {
                                label,
                                action,
                                enabled,
                            } => json!({
                                "index": index, "label": label,
                                // Multiple WebViews are not yet exposed by the browser API.
                                "enabled": *enabled && !matches!(action,
                                    servo::ContextMenuAction::OpenLinkInNewWebView |
                                    servo::ContextMenuAction::OpenImageInNewView),
                            }),
                        }
                    })
                    .collect();
                self.events
                    .push_back(json!({"type": "contextMenu", "id": id,
                    "x": rect.min.x, "y": rect.min.y, "items": items}));
                self.menu = Some((id, menu));
            }
            EmbedderControl::InputMethod(ime) => {
                let id = self
                    .ime
                    .filter(|(current, _)| *current == ime.id())
                    .map(|(_, id)| id)
                    .unwrap_or_else(|| NEXT_CONTROL_ID.fetch_add(1, Ordering::Relaxed));
                self.ime = Some((ime.id(), id));
                let rect = ime.position();
                self.events
                    .push_back(json!({"type": "ime", "id": id, "text": ime.text(),
                    "cursor": ime.insertion_point(), "multiline": ime.multiline(),
                    "inputType": format!("{:?}", ime.input_method_type()),
                    "show": ime.allow_virtual_keyboard(),
                    "x": rect.min.x, "y": rect.min.y,
                    "width": rect.size().width, "height": rect.size().height}));
            }
            _ => {}
        }
    }

    pub fn hide(&mut self, id: EmbedderControlId) {
        if self.ime.is_some_and(|(current, _)| current == id) {
            self.ime = None;
            self.events.push_back(json!({"type": "hideIme"}));
        }
        if self.menu.as_ref().is_some_and(|(_, menu)| menu.id() == id) {
            self.dismiss_menu();
        }
    }

    pub fn reset(&mut self) {
        self.events.clear();
        self.dismiss_menu();
        if self.ime.take().is_some() {
            self.events.push_back(json!({"type": "hideIme"}));
        }
    }

    fn dismiss_menu(&mut self) {
        if let Some((id, menu)) = self.menu.take() {
            menu.dismiss();
            self.events
                .push_back(json!({"type": "hideContextMenu", "id": id}));
        }
    }

    pub fn take_event(&mut self) -> Option<String> {
        self.events.pop_front().map(|event| event.to_string())
    }

    pub fn ime_matches(&self, id: u64) -> bool {
        self.ime.is_some_and(|(_, current)| current == id)
    }

    pub fn respond(&mut self, id: u64, index: Option<usize>) -> bool {
        if !self
            .menu
            .as_ref()
            .is_some_and(|(pending, _)| *pending == id)
        {
            return false;
        }
        let (_, menu) = self.menu.take().unwrap();
        let action = index
            .and_then(|index| menu.items().get(index))
            .and_then(|item| match item {
                ContextMenuItem::Item {
                    action,
                    enabled: true,
                    ..
                } => Some(*action),
                _ => None,
            });
        if let Some(action) = action {
            menu.select(action);
        } else {
            menu.dismiss();
        }
        true
    }
}
