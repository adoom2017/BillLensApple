use anyhow::{Context, Result};
use chrono::Local;
use std::{
    fs::{File, OpenOptions, create_dir_all},
    io::Write,
    path::Path,
    sync::{Mutex, OnceLock},
};

static LOG_FILE: OnceLock<Option<Mutex<File>>> = OnceLock::new();

pub fn initialize(path: Option<&str>) -> Result<()> {
    if LOG_FILE.get().is_some() {
        return Ok(());
    }

    let file = if let Some(path) = path {
        let path = Path::new(path);
        if let Some(parent) = path.parent() {
            create_dir_all(parent).with_context(|| {
                format!("failed to create logger directory {}", parent.display())
            })?;
        }
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .with_context(|| format!("failed to open log file {}", path.display()))?;
        Some(Mutex::new(file))
    } else {
        None
    };

    LOG_FILE
        .set(file)
        .map_err(|_| anyhow::anyhow!("logger was initialized concurrently"))?;
    info("logger", "initialized");
    Ok(())
}

pub fn info(stage: &str, message: impl AsRef<str>) {
    write_line("INFO", stage, message.as_ref());
}

pub fn error(stage: &str, message: impl AsRef<str>) {
    write_line("ERROR", stage, message.as_ref());
}

fn write_line(level: &str, stage: &str, message: &str) {
    let line = format!(
        "{} [{}] [{}] {}",
        Local::now().format("%Y-%m-%d %H:%M:%S%.3f"),
        level,
        stage,
        message
    );
    eprintln!("{line}");
    if let Some(Some(file)) = LOG_FILE.get().map(|file| file.as_ref()) {
        let mut file = file
            .lock()
            .unwrap_or_else(|error| panic!("logger file lock is poisoned: {error}"));
        writeln!(file, "{line}")
            .unwrap_or_else(|error| panic!("failed to write Rust log file: {error}"));
    }
}
