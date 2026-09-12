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
    if settings["trayStyle"] == "icon" {
        // The app's bracket-and-bars mark, distinct from a full quota meter.
        let segments = [
            (22.0, 18.0, 10.0, 32.0),
            (10.0, 32.0, 22.0, 46.0),
            (42.0, 18.0, 54.0, 32.0),
            (54.0, 32.0, 42.0, 46.0),
            (28.0, 40.0, 28.0, 27.0),
            (36.0, 40.0, 36.0, 20.0),
        ];
        for y in 0..size {
            for x in 0..size {
                let px = (x as f64 + 0.5) * 64.0 / size as f64;
                let py = (y as f64 + 0.5) * 64.0 / size as f64;
                let mut pixel = [0, 0, 0, 0];
                if (px - px.clamp(16.0, 48.0)).hypot(py - py.clamp(16.0, 48.0)) <= 13.0 {
                    pixel = [255, 27, 35, 53];
                }
                for (index, &(ax, ay, bx, by)) in segments.iter().enumerate() {
                    let t = (((px - ax) * (bx - ax) + (py - ay) * (by - ay))
                        / ((bx - ax) * (bx - ax) + (by - ay) * (by - ay)))
                        .clamp(0.0, 1.0);
                    if (px - ax - t * (bx - ax)).hypot(py - ay - t * (by - ay)) <= 2.5 {
                        pixel = if index < 4 {
                            [255, 166, 200, 255]
                        } else {
                            [255, 121, 223, 189]
                        };
                    }
                }
                data[(y * size + x) * 4..(y * size + x + 1) * 4].copy_from_slice(&pixel);
            }
        }
        return Icon {
            width: size as i32,
            height: size as i32,
            data,
        };
    }
    let left = size / 8;
    let width = size - 2 * left;
    for index in 0..2 {
        let remaining = snapshot["entries"][0]["windows"][index]["remaining"]
            .as_u64()
            .unwrap_or(0)
            .min(100) as usize;
        let value = if settings["quotaDisplay"] == "used" {
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn static_mark_is_independent_of_quota() {
        let mut snapshot = crate::state::snapshot();
        snapshot["settings"]["trayStyle"] = "icon".into();
        let before = icon(&snapshot, 22).data;
        snapshot["entries"][0]["windows"][0]["remaining"] = 0.into();
        assert_eq!(before, icon(&snapshot, 22).data);
        snapshot["settings"]["trayStyle"] = "meters".into();
        assert_ne!(before, icon(&snapshot, 22).data);
    }
}
