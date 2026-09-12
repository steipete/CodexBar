use cxx_qt_build::{CxxQtBuilder, QmlModule};
fn main() {
    CxxQtBuilder::new_qml_module(
        QmlModule::new("com.steipete.codexbar.prototype").qml_file("qml/Prototype.qml"),
    )
    .qt_module("Network")
    .qt_module("Quick")
    .files(["src/bridge.rs"])
    .build();
}
