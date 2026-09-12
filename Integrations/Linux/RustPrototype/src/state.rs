use serde_json::{json, Value};
use std::sync::{Mutex, OnceLock};

#[derive(Default)]
struct State {
    refreshes: u32,
    window: String,
    window_serial: u32,
    quit: bool,
}
static STATE: OnceLock<Mutex<State>> = OnceLock::new();
fn state() -> &'static Mutex<State> {
    STATE.get_or_init(|| {
        Mutex::new(State {
            window: "usage".into(),
            ..State::default()
        })
    })
}
pub fn dispatch(command: &str) -> bool {
    let mut state = state().lock().unwrap();
    match command {
        "refresh" => state.refreshes = state.refreshes.wrapping_add(1),
        "usage" | "spending" | "settings" => {
            state.window = command.into();
            state.window_serial = state.window_serial.wrapping_add(1);
        }
        "quit" => state.quit = true,
        "snapshot" => (),
        _ => return false,
    }
    true
}
pub fn snapshot() -> Value {
    let state = state().lock().unwrap();
    let remaining = 75 - (state.refreshes % 4) * 20;
    json!({
        "schemaVersion": 1, "ok": true, "prototype": true,
        "summary": format!("DEMO · CX {remaining}%"), "stale": false,
        "updated": format!("fixture refresh {}", state.refreshes),
        "window": state.window, "windowSerial": state.window_serial, "quit": state.quit,
        "entries": [{"provider": "codex", "plan": "Rust prototype · synthetic data", "accountLabel": "",
            "status": "", "error": "", "credits": null, "details": [],
            "windows": [{"label": "Session", "remaining": remaining, "resetsAt": null, "pace": ""},
                        {"label": "Weekly", "remaining": 42, "resetsAt": null, "pace": ""}]}],
        "spending": [], "settings": {"quotaDisplay": "remaining", "resetDisplay": "countdown",
            "warningColors": true, "notifyThreshold": 20, "showPace": false, "showCosts": false}
    })
}
