use serde_json::{Map, Value};
use std::{fs::File, io::Read, path::PathBuf};

// Omarchy's generated colors.toml contains flat, quoted RGB colors. Ignore
// unrelated keys and reject incomplete palettes instead of mixing two themes.
fn parse(text: &str) -> Value {
    let mut colors = Map::new();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if ![
            "background",
            "foreground",
            "accent",
            "lighter_background",
            "dark_foreground",
        ]
        .contains(&key)
        {
            continue;
        }
        let value = value.trim();
        let Some(quote) = value.chars().next().filter(|c| *c == '\'' || *c == '"') else {
            continue;
        };
        let Some(end) = value[1..].find(quote) else {
            continue;
        };
        let color = &value[1..end + 1];
        if color.len() == 7
            && color.starts_with('#')
            && color[1..].bytes().all(|c| c.is_ascii_hexdigit())
        {
            colors.insert(key.into(), color.into());
        }
    }
    if ["background", "foreground", "accent"]
        .iter()
        .all(|key| colors.contains_key(*key))
    {
        Value::Object(colors)
    } else {
        Value::Object(Map::new())
    }
}
pub fn read() -> Value {
    let root = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")));
    let mut text = String::new();
    if let Some(root) = root {
        if let Ok(file) = File::open(root.join("omarchy/current/theme/colors.toml")) {
            if file.take(65537).read_to_string(&mut text).is_ok() && text.len() <= 65536 {
                return parse(&text);
            }
        }
    }
    Value::Object(Map::new())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn requires_complete_valid_palette() {
        assert_eq!(parse("background = '#ffffff'"), serde_json::json!({}));
        let text = "background = '#1a1b26'\nforeground = \"#a9b1d6\"\naccent = '#7aa2f7' # comment\nunknown = '#ffffff'";
        assert_eq!(parse(text)["accent"], "#7aa2f7");
        assert!(parse(text).get("unknown").is_none());
        assert_eq!(
            parse(&text.replace("#7aa2f7", "#invalid")),
            serde_json::json!({})
        );
    }
}
