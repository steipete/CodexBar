use cxx_qt_lib::QString;
use std::pin::Pin;

#[cxx_qt::bridge]
pub mod ffi {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
        include!("QCoreApplication");
        type QCoreApplication;
        #[Self = "QCoreApplication"]
        #[rust_name = "exit_application"]
        fn exit(code: i32);
    }
    extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[qproperty(QString, snapshot_json, cxx_name = "snapshotJson")]
        #[qproperty(QString, capture_path, cxx_name = "capturePath")]
        #[qproperty(QString, theme_json, cxx_name = "themeJson")]
        type RustDesktop = super::RustDesktopState;
        #[qinvokable]
        fn sync(self: Pin<&mut RustDesktop>);
        #[qinvokable]
        fn dispatch(self: Pin<&mut RustDesktop>, command: &QString);
        #[qinvokable]
        fn save_settings(self: Pin<&mut RustDesktop>, changes: &QString) -> bool;
        #[qinvokable]
        fn reload_theme(self: Pin<&mut RustDesktop>);
    }
}

pub struct RustDesktopState {
    snapshot_json: QString,
    capture_path: QString,
    theme_json: QString,
}
impl Default for RustDesktopState {
    fn default() -> Self {
        Self {
            theme_json: QString::from(crate::theme::read().to_string().as_str()),
            capture_path: QString::from(
                std::env::var("CODEXBAR_RUST_CAPTURE")
                    .unwrap_or_default()
                    .as_str(),
            ),
            snapshot_json: QString::from(crate::state::snapshot().to_string().as_str()),
        }
    }
}
impl ffi::RustDesktop {
    pub fn reload_theme(self: Pin<&mut Self>) {
        self.set_theme_json(QString::from(crate::theme::read().to_string().as_str()));
    }
    pub fn save_settings(mut self: Pin<&mut Self>, changes: &QString) -> bool {
        let ok = serde_json::from_str(&changes.to_string())
            .is_ok_and(|changes| crate::state::configure(&changes));
        self.as_mut().sync();
        ok
    }
    pub fn sync(self: Pin<&mut Self>) {
        self.set_snapshot_json(QString::from(crate::state::snapshot().to_string().as_str()));
    }
    pub fn dispatch(mut self: Pin<&mut Self>, command: &QString) {
        crate::state::dispatch(&command.to_string());
        self.as_mut().sync();
    }
}
