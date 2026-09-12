use ksni::{blocking::TrayMethods, menu::StandardItem, Icon, MenuItem, ToolTip};

pub struct Tray {
    pub snapshot: serde_json::Value,
}
impl ksni::Tray for Tray {
    fn id(&self) -> String {
        "codexbar-rust-prototype".into()
    }
    fn title(&self) -> String {
        "CodexBar Rust prototype — DEMO".into()
    }
    fn activate(&mut self, x: i32, y: i32) {
        crate::state::activate_tray(x, y);
        self.snapshot = crate::state::snapshot();
    }
    fn secondary_activate(&mut self, _: i32, _: i32) {
        crate::state::dispatch("refresh");
    }
    fn tool_tip(&self) -> ToolTip {
        ToolTip {
            title: self.title(),
            description: tooltip(&self.snapshot),
            ..Default::default()
        }
    }
    fn icon_pixmap(&self) -> Vec<Icon> {
        [16, 22, 32, 64]
            .into_iter()
            .map(|size| icon(&self.snapshot, size))
            .collect()
    }
    fn menu(&self) -> Vec<MenuItem<Self>> {
        [
            ("Usage & Spend…", "usage"),
            ("Settings…", "settings"),
            ("Refresh demo", "refresh"),
            ("Quit prototype", "quit"),
        ]
        .into_iter()
        .map(|(label, command)| {
            StandardItem {
                label: label.into(),
                activate: Box::new(move |_| {
                    crate::state::dispatch(command);
                }),
                ..Default::default()
            }
            .into()
        })
        .collect()
    }
}
fn tooltip(snapshot: &serde_json::Value) -> String {
    let mut lines = vec!["Codex · synthetic data".to_owned()];
    let used = snapshot["settings"]["quotaDisplay"] == "used";
    if let Some(windows) = snapshot["entries"][0]["windows"].as_array() {
        for window in windows {
            let remaining = window["remaining"].as_u64().unwrap_or(0).min(100);
            lines.push(format!(
                "{}: {}% {}",
                window["label"].as_str().unwrap_or("Quota"),
                if used { 100 - remaining } else { remaining },
                if used { "used" } else { "left" }
            ));
        }
    }
    lines.push("Click for usage · middle-click to refresh".into());
    lines.join("\n")
}
fn icon(snapshot: &serde_json::Value, size: usize) -> Icon {
    let settings = &snapshot["settings"];
    let mut data = vec![0; size * size * 4];
    let left = size / 8;
    let width = size - 2 * left;
    for index in 0..2 {
        let remaining = snapshot["entries"][0]["windows"][index]["remaining"]
            .as_u64()
            .unwrap_or(0)
            .min(100) as usize;
        let value = if settings["trayStyle"] == "icon" {
            100
        } else if settings["quotaDisplay"] == "used" {
            100 - remaining
        } else {
            remaining
        };
        let warning = settings["warningColors"] == true
            && remaining <= settings["notifyThreshold"].as_u64().unwrap_or(20) as usize;
        for y in (size / 4 + index * size / 3)..(size / 4 + index * size / 3 + size / 5) {
            for x in left..(left + width) {
                let pixel = if x - left < width * value / 100 {
                    if warning {
                        [255, 245, 165, 65]
                    } else {
                        [255, 220, 225, 240]
                    }
                } else {
                    [255, 85, 90, 105]
                };
                data[(y * size + x) * 4..(y * size + x + 1) * 4].copy_from_slice(&pixel);
            }
        }
    }
    Icon {
        width: size as i32,
        height: size as i32,
        data,
    }
}
pub fn start() -> Result<ksni::blocking::Handle<Tray>, ksni::Error> {
    Tray {
        snapshot: crate::state::snapshot(),
    }
    .spawn()
}
