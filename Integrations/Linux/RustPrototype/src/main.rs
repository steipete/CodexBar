mod bridge;
mod ipc;
mod state;
mod tray;
use cxx_qt::casting::Upcast;
use cxx_qt_lib::{QGuiApplication, QQmlApplicationEngine, QQmlEngine, QString, QUrl};
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread,
    time::Duration,
};

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut directory = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .map(|path| path.join("codexbar-rust-prototype"));
    let mut command = None;
    let mut no_tray = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--runtime-dir" => {
                directory = Some(PathBuf::from(
                    args.next().ok_or("Missing runtime directory")?,
                ))
            }
            "--snapshot" | "--refresh" | "--usage" | "--spending" | "--settings" | "--quit" => {
                command = Some(arg[2..].to_owned())
            }
            "--no-tray" => no_tray = true,
            "--help" => {
                println!("Rust/QML spike — synthetic data only\n--runtime-dir PATH --no-tray --snapshot --refresh --usage --spending --settings --quit");
                return Ok(());
            }
            _ => return Err(format!("Unknown argument: {arg}").into()),
        }
    }
    let directory = directory.ok_or("Set XDG_RUNTIME_DIR or pass --runtime-dir PATH")?;
    if let Some(command) = command {
        let response = ipc::request(&directory, &command)?;
        println!("{response}");
        if response["ok"] != true {
            return Err("Command failed".into());
        }
        return Ok(());
    }
    let _server = ipc::Server::start(&directory)?;
    let stop = Arc::new(AtomicBool::new(false));
    let tray_thread = if no_tray {
        None
    } else {
        let stop = stop.clone();
        Some(thread::spawn(move || match tray::start() {
            Ok(handle) => {
                eprintln!("Rust StatusNotifierItem registered");
                let mut previous = serde_json::Value::Null;
                while !stop.load(Ordering::Relaxed) {
                    let snapshot = state::snapshot();
                    if snapshot != previous {
                        handle.update(|tray| tray.snapshot = snapshot.clone());
                        previous = snapshot;
                    }
                    thread::sleep(Duration::from_millis(100));
                }
                handle.shutdown().wait();
            }
            Err(error) => eprintln!("Tray unavailable (window remains usable): {error}"),
        }))
    };
    cxx_qt::init_qml_module!("com.steipete.codexbar.prototype");
    let mut app = QGuiApplication::new();
    let mut engine = QQmlApplicationEngine::new();
    engine
        .as_mut()
        .unwrap()
        .on_object_creation_failed(|_, url| {
            eprintln!("QML load failed: {url:?}");
            std::process::exit(1);
        })
        .release();
    {
        let engine: std::pin::Pin<&mut QQmlEngine> = engine.as_mut().unwrap().upcast_pin();
        engine
            .on_quit(|_| bridge::ffi::QCoreApplication::exit_application(0))
            .release();
    }
    {
        let engine: std::pin::Pin<&mut QQmlEngine> = engine.as_mut().unwrap().upcast_pin();
        engine
            .on_exit(|_, code| bridge::ffi::QCoreApplication::exit_application(code))
            .release();
    }
    // Keep production QML files unchanged, loaded directly from this worktree.
    engine
        .as_mut()
        .ok_or("Cannot create QML engine")?
        .load(&QUrl::from_local_file(&QString::from(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/qml/Prototype.qml"
        ))));
    let exit_code = app.as_mut().ok_or("Cannot create Qt application")?.exec();
    stop.store(true, Ordering::Relaxed);
    if let Some(thread) = tray_thread {
        let _ = thread.join();
    }
    if exit_code != 0 {
        return Err(format!("Qt exited with code {exit_code}").into());
    }
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
