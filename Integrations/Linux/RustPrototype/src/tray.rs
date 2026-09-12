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
    fn activate(&mut self, _: i32, _: i32) {
        crate::state::dispatch("usage");
    }
    fn secondary_activate(&mut self, _: i32, _: i32) {
        crate::state::dispatch("refresh");
    }
    fn tool_tip(&self) -> ToolTip {
        ToolTip {
            title: self.title(),
            description: self.snapshot["summary"].as_str().unwrap_or("").into(),
            ..Default::default()
        }
    }
    fn icon_pixmap(&self) -> Vec<Icon> {
        let windows = &self.snapshot["entries"][0]["windows"];
        let mut argb = vec![0; 64 * 64 * 4];
        for index in 0..2 {
            let remaining = windows[index]["remaining"].as_u64().unwrap_or(0).min(100) as usize;
            for y in (12 + index * 25)..(27 + index * 25) {
                for x in 5..59 {
                    let pixel = if x - 5 < 54 * remaining / 100 {
                        if remaining <= 20 {
                            [255, 229, 150, 66]
                        } else {
                            [255, 60, 170, 230]
                        }
                    } else {
                        [255, 119, 119, 119]
                    };
                    argb[(y * 64 + x) * 4..(y * 64 + x + 1) * 4].copy_from_slice(&pixel);
                }
            }
        }
        vec![Icon {
            width: 64,
            height: 64,
            data: argb,
        }]
    }
    fn menu(&self) -> Vec<MenuItem<Self>> {
        [
            ("Usage & Spend…", "usage"),
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
pub fn start() -> Result<ksni::blocking::Handle<Tray>, ksni::Error> {
    Tray {
        snapshot: crate::state::snapshot(),
    }
    .spawn()
}
