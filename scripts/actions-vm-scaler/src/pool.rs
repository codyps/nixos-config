//! Host-wide FIFO admission. Each VM owns a lease, including during cleanup.
use std::{
    collections::{BTreeSet, VecDeque},
    sync::{Arc, Mutex},
};
use tokio::sync::watch;

struct State {
    used: BTreeSet<usize>,
    waiting: VecDeque<String>,
}
pub struct Pool {
    capacity: usize,
    state: Mutex<State>,
    changed: watch::Sender<u64>,
}
pub struct Lease {
    pub slot: usize,
    pool: Arc<Pool>,
}

impl Pool {
    pub fn new(capacity: usize) -> Arc<Self> {
        Arc::new(Self {
            capacity,
            state: Mutex::new(State {
                used: BTreeSet::new(),
                waiting: VecDeque::new(),
            }),
            changed: watch::channel(0).0,
        })
    }
    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changed.subscribe()
    }
    fn notify(&self) {
        self.changed.send_modify(|v| *v = v.wrapping_add(1));
    }
    pub fn reserve(self: &Arc<Self>, owner: &str) -> Option<Lease> {
        let mut state = self.state.lock().unwrap();
        if !state.waiting.iter().any(|s| s == owner) {
            state.waiting.push_back(owner.into());
        }
        if state.waiting.front().is_none_or(|s| s != owner) {
            return None;
        }
        let slot = (0..self.capacity).find(|s| !state.used.contains(s))?;
        state.waiting.pop_front();
        state.used.insert(slot);
        drop(state);
        // Wake the next waiter if there are additional free slots.
        self.notify();
        Some(Lease {
            slot,
            pool: self.clone(),
        })
    }
    pub fn cancel(&self, owner: &str) {
        let mut state = self.state.lock().unwrap();
        let before = state.waiting.len();
        state.waiting.retain(|s| s != owner);
        let removed = before != state.waiting.len();
        drop(state);
        if removed {
            self.notify();
        }
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        self.pool.state.lock().unwrap().used.remove(&self.slot);
        self.pool.notify();
    }
}
