use std::collections::{HashMap, HashSet};

use accesskit::{Action, ActionRequest, Affine, Node, NodeId, Rect, Role, TreeId, TreeUpdate};
use serde_json::{json, Value};

#[derive(Default)]
struct Subtree {
    root: Option<NodeId>,
    focus: Option<NodeId>,
    nodes: HashMap<NodeId, Node>,
}

impl Subtree {
    fn descendant_text(&self, node: &Node) -> Option<String> {
        let mut stack: Vec<_> = node.children().iter().rev().copied().collect();
        let mut seen = HashSet::new();
        let mut text = Vec::new();
        while let Some(id) = stack.pop() {
            if !seen.insert(id) {
                continue;
            }
            let Some(child) = self.nodes.get(&id).filter(|child| !child.is_hidden()) else {
                continue;
            };
            if let Some(label) = child.label().or_else(|| {
                matches!(child.role(), Role::Label | Role::TextRun)
                    .then(|| child.value())
                    .flatten()
            }) {
                text.push(label);
            } else {
                stack.extend(child.children().iter().rev().copied());
            }
        }
        (!text.is_empty()).then(|| text.join(" "))
    }
}

#[derive(Default)]
pub(crate) struct PageAccessibility {
    root: Option<TreeId>,
    trees: HashMap<TreeId, Subtree>,
    click_targets: HashMap<String, (TreeId, NodeId)>,
    dirty: bool,
}

#[derive(Clone, Copy)]
struct Visit {
    tree: TreeId,
    node: NodeId,
    transform: Affine,
    parent_bounds: Option<Rect>,
    tree_focused: bool,
    hidden: bool,
    text_covered: bool,
}

impl PageAccessibility {
    pub(crate) fn set_root(&mut self, root: Option<TreeId>) {
        if self.root != root {
            *self = Self {
                root,
                dirty: true,
                ..Self::default()
            };
        }
    }

    pub(crate) fn update(&mut self, update: TreeUpdate) {
        if self.root.is_none() {
            return;
        }
        let tree = self.trees.entry(update.tree_id).or_default();
        if let Some(info) = update.tree {
            tree.root = Some(info.root);
        }
        tree.focus = Some(update.focus);
        tree.nodes.extend(update.nodes);
        self.dirty = true;
    }

    pub(crate) fn take_event(&mut self) -> Option<String> {
        if !std::mem::take(&mut self.dirty) {
            return None;
        }
        self.click_targets.clear();
        let mut nodes = Vec::new();
        let mut visited = HashSet::new();
        let mut stack = Vec::new();
        if let Some(id) = self.root {
            if let Some(root) = self.trees.get(&id).and_then(|tree| tree.root) {
                stack.push(Visit {
                    tree: id,
                    node: root,
                    transform: Affine::IDENTITY,
                    parent_bounds: None,
                    tree_focused: true,
                    hidden: false,
                    text_covered: false,
                });
            }
        }
        while let Some(visit) = stack.pop() {
            let Visit {
                tree: tree_id,
                node: id,
                ..
            } = visit;
            if !visited.insert((tree_id, id)) {
                continue;
            }
            let Some(tree) = self.trees.get(&tree_id) else {
                continue;
            };
            let Some(node) = tree.nodes.get(&id) else {
                continue;
            };
            let hidden = visit.hidden || node.is_hidden();
            let transform = visit.transform * node.transform().copied().unwrap_or(Affine::IDENTITY);
            let focused = visit.tree_focused && tree.focus == Some(id);
            let role = node.role();
            let text_node = matches!(role, Role::TextRun | Role::Label);
            let names_contents = matches!(
                role,
                Role::Heading | Role::Link | Role::Button | Role::DefaultButton
            );
            let bounds = node
                .bounds()
                .map(|rect| transform.transform_rect_bbox(rect));
            let children = Visit {
                transform,
                parent_bounds: bounds.or(visit.parent_bounds),
                hidden,
                text_covered: visit.text_covered || names_contents || role == Role::PasswordInput,
                ..visit
            };
            stack.extend(node.children().iter().rev().map(|child| Visit {
                node: *child,
                ..children
            }));
            if let Some(graft) = node.tree_id() {
                if let Some(root) = self.trees.get(&graft).and_then(|tree| tree.root) {
                    stack.push(Visit {
                        tree: graft,
                        node: root,
                        tree_focused: focused,
                        ..children
                    });
                }
            }
            if hidden || (text_node && visit.text_covered) || role == Role::GenericContainer {
                continue;
            }
            // This Servo revision does not assign bounds to text runs. Use the
            // nearest box so paragraph text is still available to screen readers.
            let Some(bounds) = bounds.or(if text_node { visit.parent_bounds } else { None }) else {
                continue;
            };
            let rect = [bounds.x0, bounds.y0, bounds.x1, bounds.y1];
            if !rect.iter().all(|value| value.is_finite()) {
                continue;
            }
            let label = node
                .label()
                .or_else(|| {
                    node.labelled_by().iter().find_map(|id| {
                        let label = tree.nodes.get(id)?;
                        label.value().or_else(|| label.label())
                    })
                })
                .map(str::to_owned)
                .or_else(|| names_contents.then(|| tree.descendant_text(node)).flatten());
            let value = if role == Role::PasswordInput {
                None
            } else {
                node.value()
                    .filter(|value| !text_node || !value.trim().is_empty())
            };
            // Servo handles Click but this revision does not mark links as
            // supporting it. Expose activation for its known clickable roles.
            let clickable = !node.is_disabled()
                && (node.supports_action(Action::Click)
                    || matches!(role, Role::Link | Role::Button | Role::DefaultButton));
            if label.is_none()
                && value.is_none()
                && !clickable
                && !matches!(role, Role::Heading | Role::Image | Role::RootWebArea)
            {
                continue;
            }
            let key = format!("{}:{}", tree_id.0, id.0);
            nodes.push(json!({
                "id": key,
                "role": format!("{role:?}"),
                "label": label,
                "value": value,
                "rect": rect,
                "focused": focused,
                "disabled": node.is_disabled(),
                "readOnly": node.is_read_only(),
                "checked": node.toggled().map(|value| format!("{value:?}")),
                "clickable": clickable,
            }));
            if clickable {
                self.click_targets.insert(key, (tree_id, id));
            }
        }
        // A navigation can replace the document graft. Drop nodes that were
        // detached from the latest tree, including superseded document trees.
        self.trees.retain(|tree_id, tree| {
            tree.nodes
                .retain(|id, _| visited.contains(&(*tree_id, *id)));
            !tree.nodes.is_empty()
        });
        Some(json!({"type": "accessibilityTree", "nodes": nodes}).to_string())
    }

    pub(crate) fn action(&self, response: &Value) -> Option<ActionRequest> {
        if self.dirty || response["action"].as_str()? != "Click" {
            return None;
        }
        let (target_tree, target_node) = self.click_targets.get(response["id"].as_str()?)?;
        Some(ActionRequest {
            action: Action::Click,
            target_tree: *target_tree,
            target_node: *target_node,
            data: None,
        })
    }
}
