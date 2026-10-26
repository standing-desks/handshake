//! One operation gate per physical library, shared by background work, explicit sync and launches.
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, Weak};

pub(super) fn operation_gate(root: &Path) -> Arc<Mutex<()>> {
    static GATES: OnceLock<Mutex<HashMap<PathBuf, Weak<Mutex<()>>>>> = OnceLock::new();
    let mut path = root;
    let mut suffix = Vec::new();
    let canonical = loop {
        if let Ok(existing) = path.canonicalize() {
            break existing;
        }
        let Some(name) = path.file_name() else {
            break root.to_owned();
        };
        suffix.push(name.to_owned());
        let Some(parent) = path.parent() else {
            break root.to_owned();
        };
        path = parent;
    };
    let key = suffix
        .into_iter()
        .rev()
        .fold(canonical, |p, name| p.join(name));
    let mut gates = GATES
        .get_or_init(Mutex::default)
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    gates.retain(|_, value| value.strong_count() > 0);
    if let Some(gate) = gates.get(&key).and_then(Weak::upgrade) {
        return gate;
    }
    let gate = Arc::new(Mutex::new(()));
    gates.insert(key, Arc::downgrade(&gate));
    gate
}
