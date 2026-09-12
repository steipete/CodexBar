use fs2::FileExt;
use serde_json::{json, Value};
use std::{
    fs::{self, DirBuilder, File, OpenOptions},
    io::{self, BufRead, BufReader, Read, Write},
    os::unix::{
        fs::{DirBuilderExt, MetadataExt},
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread::{self, JoinHandle},
    time::Duration,
};

const LIMIT: u64 = 65536;
fn read_message(stream: &UnixStream) -> io::Result<Value> {
    stream.set_read_timeout(Some(Duration::from_secs(1)))?;
    let mut bytes = Vec::new();
    BufReader::new(stream.take(LIMIT)).read_until(b'\n', &mut bytes)?;
    if bytes.last() != Some(&b'\n') {
        return Err(io::Error::other("Incomplete or oversized message"));
    }
    serde_json::from_slice(&bytes).map_err(io::Error::other)
}
pub fn request(directory: &Path, command: &str) -> io::Result<Value> {
    let mut stream = UnixStream::connect(directory.join("desktop.sock"))?;
    stream.set_write_timeout(Some(Duration::from_secs(1)))?;
    writeln!(stream, "{}", json!({"command": command}))?;
    read_message(&stream)
}
pub struct Server {
    _lock: File,
    socket: PathBuf,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}
impl Server {
    pub fn start(directory: &Path) -> io::Result<Self> {
        match DirBuilder::new().mode(0o700).create(directory) {
            Ok(()) => (),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => (),
            Err(error) => return Err(error),
        }
        let metadata = fs::symlink_metadata(directory)?;
        if !metadata.is_dir()
            || metadata.uid() != rustix::process::geteuid().as_raw()
            || metadata.mode() & 0o077 != 0
        {
            return Err(io::Error::other(
                "Runtime directory must be owned by this user with mode 0700",
            ));
        }
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(directory.join("desktop.lock"))?;
        lock.try_lock_exclusive()
            .map_err(|_| io::Error::other("Prototype already running in this directory"))?;
        let socket = directory.join("desktop.sock");
        match fs::remove_file(&socket) {
            Ok(()) => (),
            Err(error) if error.kind() == io::ErrorKind::NotFound => (),
            Err(error) => return Err(error),
        }
        let listener = UnixListener::bind(&socket)?;
        listener.set_nonblocking(true)?;
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let thread = thread::spawn(move || {
            while !stopping.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let reply = match read_message(&stream) {
                            Ok(value) => {
                                if value["command"] == "configure" {
                                    let ok = crate::state::configure(&value["settings"]);
                                    let mut snapshot = crate::state::snapshot();
                                    snapshot["ok"] = json!(ok);
                                    snapshot
                                } else if crate::state::dispatch(
                                    value["command"].as_str().unwrap_or(""),
                                ) {
                                    crate::state::snapshot()
                                } else {
                                    json!({"ok": false, "error": "Unknown command"})
                                }
                            }
                            Err(error) => json!({"ok": false, "error": error.to_string()}),
                        };
                        let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));
                        let _ = writeln!(stream, "{reply}");
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(20))
                    }
                    Err(_) => break,
                }
            }
        });
        Ok(Self {
            _lock: lock,
            socket,
            stop,
            thread: Some(thread),
        })
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        let _ = fs::remove_file(&self.socket);
    }
}
