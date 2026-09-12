use serde_json::{json, Value};
use std::sync::{Mutex, OnceLock};

#[derive(Default)]
struct State {
    settings: crate::settings::Settings,
    refreshes: u32,
    window: String,
    window_serial: u32,
    quit: bool,
    tray_x: i32,
    tray_y: i32,
}
pub fn load_settings(path: std::path::PathBuf) {
    state().lock().unwrap().settings = crate::settings::Settings::load(path);
}
pub fn configure(changes: &Value) -> bool {
    let mut state = state().lock().unwrap();
    if let Err(error) = state.settings.save(changes) {
        state.settings.error = error;
        return false;
    }
    true
}
pub fn activate_tray(x: i32, y: i32) {
    let mut state = state().lock().unwrap();
    state.tray_x = x;
    state.tray_y = y;
    if state.settings.values["refreshOnOpen"] == true {
        state.refreshes = state.refreshes.wrapping_add(1);
    }
    state.window = "tray".into();
    state.window_serial = state.window_serial.wrapping_add(1);
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
        "usage" | "spending" | "settings" | "tray" => {
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
    let used = state.settings.values["quotaDisplay"] == "used";
    let value = if used { 100 - remaining } else { remaining };
    let suffix = if used { "used" } else { "left" };
    let threshold = state.settings.values["notifyThreshold"]
        .as_u64()
        .unwrap_or(20);
    let warnings = state.settings.values["warningColors"] == true;
    json!({
        "schemaVersion": 1, "ok": true, "prototype": true,
        "summary": format!("DEMO · CX {value}% {suffix}"), "stale": false,
        "quotaDisplay": state.settings.values["quotaDisplay"],
        "configError": state.settings.error, "busy": false, "error": "",
        "trayX": state.tray_x, "trayY": state.tray_y,
        "updated": format!("fixture refresh {}", state.refreshes),
        "window": state.window, "windowSerial": state.window_serial, "quit": state.quit,
        "entries": [{"provider": "codex", "plan": "Rust prototype · synthetic data", "accountLabel": "",
            "status": "", "error": "", "credits": null, "details": [],
            "windows": [{"label": "Session", "remaining": remaining, "resetsAt": null, "pace": "",
                "displayValue": value, "displaySuffix": suffix, "warning": warnings && u64::from(remaining) <= threshold,
                "resetText": "Reset time unavailable"},
                {"label": "Weekly", "remaining": 42, "resetsAt": null, "pace": "",
                "displayValue": if used {58} else {42}, "displaySuffix": suffix,
                "warning": warnings && 42 <= threshold, "resetText": "Reset time unavailable"}]}],
        "spending": [], "settings": state.settings.values
    })
}
