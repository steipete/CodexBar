use serde_json::{json, Value};
use std::{fs, io::Write, os::unix::fs::OpenOptionsExt, path::PathBuf};

pub struct Settings {
    pub values: Value,
    pub error: String,
    path: Option<PathBuf>,
    blocked: bool,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            values: json!({"quotaDisplay":"remaining", "resetDisplay":"countdown",
                "warningColors":true, "notifyThreshold":20, "showPace":false,
                "showCosts":false, "trayStyle":"meters", "refreshOnOpen":true, "followOmarchyTheme":true}),
            error: String::new(),
            path: None,
            blocked: false,
        }
    }
}
impl Settings {
    pub fn load(path: PathBuf) -> Self {
        let mut settings = Self {
            path: Some(path.clone()),
            ..Self::default()
        };
        let result = match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|_| "Settings file is not valid JSON.".to_owned())
                .and_then(|changes| settings.merged(&changes)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return settings,
            Err(_) => Err("Cannot read the prototype settings file.".into()),
        };
        match result {
            Ok(values) => settings.values = values,
            Err(error) => {
                settings.error = error;
                settings.blocked = true;
            }
        }
        settings
    }
    fn merged(&self, changes: &Value) -> Result<Value, String> {
        let object = changes.as_object().ok_or("Settings must be an object.")?;
        let mut next = self.values.clone();
        for (key, value) in object {
            let valid = match key.as_str() {
                "quotaDisplay" => matches!(value.as_str(), Some("remaining" | "used")),
                "resetDisplay" => matches!(value.as_str(), Some("countdown" | "absolute" | "both")),
                "trayStyle" => matches!(value.as_str(), Some("meters" | "icon")),
                "notifyThreshold" => value.as_u64().is_some_and(|n| (1..=99).contains(&n)),
                "warningColors" | "showPace" | "refreshOnOpen" | "followOmarchyTheme" => {
                    value.is_boolean()
                }
                "showCosts" => value == false,
                _ => false,
            };
            if !valid {
                return Err(format!("Invalid setting: {key}"));
            }
            next[key] = value.clone();
        }
        Ok(next)
    }
    pub fn save(&mut self, changes: &Value) -> Result<(), String> {
        if self.blocked {
            return Err(self.error.clone());
        }
        let next = self.merged(changes)?;
        if let Some(path) = &self.path {
            let persist = || -> std::io::Result<()> {
                let parent = path
                    .parent()
                    .filter(|p| !p.as_os_str().is_empty())
                    .unwrap_or(std::path::Path::new("."));
                fs::create_dir_all(parent)?;
                let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
                let mut file = fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(&temporary)?;
                let result = (|| {
                    file.write_all(serde_json::to_string_pretty(&next)?.as_bytes())?;
                    file.sync_all()?;
                    fs::rename(&temporary, path)
                })();
                if result.is_err() {
                    let _ = fs::remove_file(temporary);
                }
                result
            };
            persist().map_err(|_| {
                "Could not save settings; previous preferences were kept.".to_owned()
            })?;
        }
        self.values = next;
        self.error.clear();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn invalid_changes_do_not_partially_apply() {
        let mut settings = Settings::default();
        let before = settings.values.clone();
        assert!(settings
            .save(&json!({"quotaDisplay":"used", "notifyThreshold":101}))
            .is_err());
        assert_eq!(settings.values, before);
        assert!(settings.save(&json!({"notifyThreshold":20.5})).is_err());
        assert!(settings.save(&json!({"showCosts":true})).is_err());
    }
    #[test]
    fn malformed_file_is_preserved() {
        let path = std::env::temp_dir().join(format!(
            "cbrust-settings-{}-{}.json",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let original = b"{broken";
        fs::write(&path, original).unwrap();
        let mut settings = Settings::load(path.clone());
        let refused = settings.save(&json!({"quotaDisplay":"used"})).is_err();
        let preserved = fs::read(&path).unwrap() == original;
        fs::remove_file(path).unwrap();
        assert!(refused && preserved);
        assert_eq!(settings.values["quotaDisplay"], "remaining");
    }
}
