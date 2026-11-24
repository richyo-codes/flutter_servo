use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use servo::{ContextMenu, ContextMenuItem, EmbedderControl, EmbedderControlId};

#[derive(Default)]
pub(crate) struct Controls {
    navigation: Option<PendingNavigation>,
    events: VecDeque<Value>,
    menu: Option<(u64, ContextMenu)>,
    picker: Option<(u64, servo::FilePicker)>,
    ime: Option<(EmbedderControlId, u64)>,
}

static NEXT_CONTROL_ID: AtomicU64 = AtomicU64::new(1);

struct PendingNavigation {
    id: u64,
    created: Instant,
    request: Option<servo::NavigationRequest>,
}

impl Drop for PendingNavigation {
    fn drop(&mut self) {
        if let Some(request) = self.request.take() {
            request.deny();
        }
    }
}

impl Controls {
    pub fn redirect_blocked(&mut self) {
        if !self
            .events
            .iter()
            .any(|event| event["type"] == "redirectBlocked")
        {
            self.events.push_back(json!({"type":"redirectBlocked"}));
        }
    }
    pub fn permission_denied(&mut self, feature: String) {
        if !self
            .events
            .iter()
            .any(|event| event["type"] == "permissionDenied" && event["feature"] == feature)
        {
            self.events
                .push_back(json!({"type":"permissionDenied","feature":feature}));
        }
    }
    pub fn request_navigation(&mut self, request: servo::NavigationRequest) {
        self.expire_navigation();
        if self.navigation.is_some() {
            request.deny();
            return;
        }
        let id = NEXT_CONTROL_ID.fetch_add(1, Ordering::Relaxed);
        self.events
            .push_back(json!({"type":"navigationRequest","id":id,"url":request.url.as_str()}));
        self.navigation = Some(PendingNavigation {
            id,
            created: Instant::now(),
            request: Some(request),
        });
    }

    fn expire_navigation(&mut self) {
        if self
            .navigation
            .as_ref()
            .is_some_and(|p| p.created.elapsed() >= Duration::from_secs(5))
        {
            self.navigation.take();
            self.events
                .retain(|event| event["type"] != "navigationRequest");
        }
    }

    pub fn decide_navigation(&mut self, id: u64, allow: bool) -> bool {
        self.expire_navigation();
        if !self.navigation.as_ref().is_some_and(|p| p.id == id) {
            return false;
        }
        let mut pending = self.navigation.take().unwrap();
        if allow {
            pending.request.take().unwrap().allow();
        }
        true
    }
    pub fn popup_blocked(&mut self) {
        // A script may request many windows before Flutter drains events.
        if !self
            .events
            .iter()
            .any(|event| event["type"] == "popupBlocked")
        {
            self.events.push_back(json!({"type": "popupBlocked"}));
        }
    }

    pub fn title_changed(&mut self, title: Option<String>) {
        self.events.retain(|event| event["type"] != "title");
        self.events
            .push_back(json!({"type": "title", "title": title}));
    }

    pub fn show(&mut self, control: EmbedderControl) {
        match control {
            EmbedderControl::FilePicker(picker) => {
                if self.picker.is_some() {
                    picker.dismiss();
                    return;
                }
                let id = NEXT_CONTROL_ID.fetch_add(1, Ordering::Relaxed);
                let filters: Vec<_> = picker.filter_patterns().iter().map(|p| &p.0).collect();
                self.events.push_back(json!({"type":"filePicker", "id":id,
                    "multiple":picker.allow_select_multiple(), "filters":filters}));
                self.picker = Some((id, picker));
            }
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
        if self.picker.as_ref().is_some_and(|(_, p)| p.id() == id) {
            self.picker.take();
            self.events.retain(|e| e["type"] != "filePicker");
        }
        if self.ime.is_some_and(|(current, _)| current == id) {
            self.ime = None;
            self.events.push_back(json!({"type": "hideIme"}));
        }
        if self.menu.as_ref().is_some_and(|(_, menu)| menu.id() == id) {
            self.dismiss_menu();
        }
    }

    pub fn reset(&mut self) {
        self.navigation.take();
        self.picker.take();
        self.events.clear();
        self.dismiss_menu();
        if self.ime.take().is_some() {
            self.events.push_back(json!({"type": "hideIme"}));
        }
    }

    pub fn cancel_picker(&mut self) {
        self.picker.take();
        self.events.retain(|event| event["type"] != "filePicker");
    }

    fn dismiss_menu(&mut self) {
        if let Some((id, menu)) = self.menu.take() {
            menu.dismiss();
            self.events
                .push_back(json!({"type": "hideContextMenu", "id": id}));
        }
    }

    pub fn take_event(&mut self) -> Option<String> {
        self.expire_navigation();
        self.events.pop_front().map(|event| event.to_string())
    }

    pub fn ime_matches(&self, id: u64) -> bool {
        self.ime.is_some_and(|(_, current)| current == id)
    }

    pub fn respond_picker(&mut self, id: u64, paths: &Value) -> bool {
        if !self
            .picker
            .as_ref()
            .is_some_and(|(pending, _)| *pending == id)
        {
            return false;
        }
        let (_, mut picker) = self.picker.take().unwrap();
        let Some(values) = paths.as_array() else {
            return false;
        };
        if values.is_empty() {
            picker.dismiss();
            return true;
        }
        if values.len() > 64 || (!picker.allow_select_multiple() && values.len() != 1) {
            return false;
        }
        let mut selected = Vec::new();
        for value in values {
            let Some(path) = value.as_str().map(std::path::Path::new) else {
                return false;
            };
            #[cfg(windows)]
            if !matches!(path.components().next(), Some(std::path::Component::Prefix(prefix)) if matches!(prefix.kind(), std::path::Prefix::Disk(_)))
            {
                return false;
            }
            if !path.is_absolute() || !path.is_file() {
                return false;
            }
            selected.push(path.to_owned());
        }
        picker.select(&selected);
        picker.submit();
        true
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
