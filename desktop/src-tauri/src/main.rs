#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::VecDeque;
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager, State};

const MAX_CAPTURED_BYTES: usize = 1024 * 1024;

#[derive(Default)]
struct ProcessSlot {
    active: bool,
    cancelled: bool,
    child: Option<Child>,
}

#[derive(Clone, Default)]
struct BuildState(Arc<Mutex<ProcessSlot>>);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BuildRequest {
    project: String,
    version_bump: String,
    outputs: Vec<String>,
    jobs: u8,
    clean: bool,
    locale: String,
}

#[derive(Clone, Debug, Serialize)]
struct BuildLog {
    stream: &'static str,
    line: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct BuildResult {
    success: bool,
    cancelled: bool,
    exit_code: Option<i32>,
    stdout: String,
    stderr: String,
    report: Option<Value>,
}

#[derive(Debug)]
struct PreparedBuild {
    runtime_root: PathBuf,
    project: PathBuf,
    version_bump: String,
    outputs: Vec<String>,
    jobs: u8,
    clean: bool,
    locale: String,
    report_path: PathBuf,
}

#[tauri::command]
async fn detect_projects(app: AppHandle, root: String) -> Result<Value, String> {
    let root = canonical_directory(&root)?;
    let runtime_root = runtime_root(&app)?;
    tauri::async_runtime::spawn_blocking(move || {
        let mut command = ubs_command(&runtime_root)?;
        command.args(["detect", "--json"]).arg(root);
        let output = command
            .output()
            .map_err(|error| format!("UBS detect 실행 실패: {error}"))?;
        let stdout = String::from_utf8_lossy(&output.stdout);
        if let Ok(value) = serde_json::from_str::<Value>(&stdout) {
            return Ok(value);
        }
        let stderr = strip_ansi(&String::from_utf8_lossy(&output.stderr));
        Err(if stderr.trim().is_empty() {
            "빌드 가능한 프로젝트를 찾지 못했습니다.".to_string()
        } else {
            stderr.trim().to_string()
        })
    })
    .await
    .map_err(|error| format!("UBS detect 작업 실패: {error}"))?
}

#[tauri::command]
async fn run_build(
    app: AppHandle,
    state: State<'_, BuildState>,
    request: BuildRequest,
) -> Result<BuildResult, String> {
    let prepared = prepare_build(&app, request)?;
    let shared = state.0.clone();
    {
        let mut slot = shared
            .lock()
            .map_err(|_| "빌드 상태 잠금이 손상되었습니다.".to_string())?;
        if slot.active {
            return Err("이미 실행 중인 빌드가 있습니다.".to_string());
        }
        slot.active = true;
        slot.cancelled = false;
    }

    let worker_state = shared.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        run_build_blocking(app, worker_state, prepared)
    })
    .await;

    match result {
        Ok(inner) => {
            if inner.is_err() {
                clear_process_slot(&shared);
            }
            inner
        }
        Err(error) => {
            clear_process_slot(&shared);
            Err(format!("빌드 작업 실패: {error}"))
        }
    }
}

#[tauri::command]
fn cancel_build(state: State<'_, BuildState>) -> Result<bool, String> {
    request_cancellation(&state.0)
}

fn request_cancellation(shared: &Arc<Mutex<ProcessSlot>>) -> Result<bool, String> {
    let mut slot = shared
        .lock()
        .map_err(|_| "빌드 상태 잠금이 손상되었습니다.".to_string())?;
    if !slot.active {
        return Ok(false);
    }
    slot.cancelled = true;
    if let Some(child) = slot.child.as_mut() {
        terminate_process_tree(child).map_err(|error| format!("빌드 취소 요청 실패: {error}"))?;
    }
    Ok(true)
}

fn prepare_build(app: &AppHandle, request: BuildRequest) -> Result<PreparedBuild, String> {
    let project = canonical_directory(&request.project)?;
    let version_bump = match request.version_bump.as_str() {
        "none" | "build" | "patch" | "minor" | "major" => request.version_bump,
        _ => return Err("지원하지 않는 버전 변경 값입니다.".to_string()),
    };
    let mut outputs = request.outputs;
    if outputs.len() > 5 {
        return Err("출력 형식 선택이 너무 많습니다.".to_string());
    }
    outputs.sort();
    outputs.dedup();
    if outputs
        .iter()
        .any(|value| !matches!(value.as_str(), "appbundle" | "apk" | "ipa" | "web" | "pkg"))
    {
        return Err("지원하지 않는 출력 형식입니다.".to_string());
    }
    if request.jobs > 8 {
        return Err("병렬 작업 수는 자동 또는 1~8이어야 합니다.".to_string());
    }
    let locale = match request.locale.as_str() {
        "ko" | "en" | "ja" | "zh" => request.locale,
        _ => "en".to_string(),
    };

    Ok(PreparedBuild {
        runtime_root: runtime_root(app)?,
        project,
        version_bump,
        outputs,
        jobs: request.jobs,
        clean: request.clean,
        locale,
        report_path: temporary_report_path(),
    })
}

fn run_build_blocking(
    app: AppHandle,
    shared: Arc<Mutex<ProcessSlot>>,
    prepared: PreparedBuild,
) -> Result<BuildResult, String> {
    let mut command = ubs_command(&prepared.runtime_root)?;
    command
        .arg("build")
        .args(["--non-interactive", "--no-publish", "--verbose"])
        .arg("--project")
        .arg(&prepared.project)
        .args(["--version-bump", &prepared.version_bump])
        .arg(if prepared.clean {
            "--clean"
        } else {
            "--skip-clean"
        })
        .arg("--report-json")
        .arg(&prepared.report_path)
        .env("UBS_LANG", &prepared.locale)
        .env("PYTHONUNBUFFERED", "1")
        .env(
            "UBS_FLUTTER_PARALLEL",
            if prepared.jobs == 1 { "false" } else { "true" },
        )
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if !prepared.outputs.is_empty() {
        command
            .arg("--flutter-outputs")
            .arg(prepared.outputs.join(","));
    }
    if prepared.jobs > 0 {
        command.args(["--jobs", &prepared.jobs.to_string()]);
    }
    configure_process_group(&mut command);

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            clear_process_slot(&shared);
            return Err(format!("UBS build 실행 실패: {error}"));
        }
    };
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "빌드 표준 출력을 열지 못했습니다.".to_string())?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "빌드 오류 출력을 열지 못했습니다.".to_string())?;
    {
        let mut slot = shared
            .lock()
            .map_err(|_| "빌드 상태 잠금이 손상되었습니다.".to_string())?;
        slot.child = Some(child);
        if slot.cancelled {
            if let Some(child) = slot.child.as_mut() {
                let _ = terminate_process_tree(child);
            }
        }
    }

    let stdout_reader = stream_output(stdout, app.clone(), "stdout");
    let stderr_reader = stream_output(stderr, app, "stderr");
    let status = match wait_for_child(&shared) {
        Ok(status) => status,
        Err(error) => {
            if let Ok(mut slot) = shared.lock() {
                if let Some(child) = slot.child.as_mut() {
                    let _ = terminate_process_tree(child);
                }
            }
            clear_process_slot(&shared);
            return Err(error);
        }
    };
    let stdout = stdout_reader.join().unwrap_or_default();
    let stderr = stderr_reader.join().unwrap_or_default();
    let cancelled = {
        let mut slot = shared
            .lock()
            .map_err(|_| "빌드 상태 잠금이 손상되었습니다.".to_string())?;
        let cancelled = slot.cancelled;
        slot.child = None;
        slot.active = false;
        slot.cancelled = false;
        cancelled
    };
    let report = read_report(&prepared.report_path);

    Ok(BuildResult {
        success: status.success() && !cancelled,
        cancelled,
        exit_code: status.code(),
        stdout,
        stderr,
        report,
    })
}

fn wait_for_child(shared: &Arc<Mutex<ProcessSlot>>) -> Result<ExitStatus, String> {
    loop {
        let status = {
            let mut slot = shared
                .lock()
                .map_err(|_| "빌드 상태 잠금이 손상되었습니다.".to_string())?;
            let child = slot
                .child
                .as_mut()
                .ok_or_else(|| "실행 중인 빌드 프로세스가 없습니다.".to_string())?;
            child
                .try_wait()
                .map_err(|error| format!("빌드 상태 확인 실패: {error}"))?
        };
        if let Some(status) = status {
            return Ok(status);
        }
        thread::sleep(Duration::from_millis(100));
    }
}

fn stream_output<R: Read + Send + 'static>(
    stream: R,
    app: AppHandle,
    stream_name: &'static str,
) -> thread::JoinHandle<String> {
    thread::spawn(move || {
        let mut reader = BufReader::new(stream);
        let mut captured = VecDeque::new();
        let mut captured_bytes = 0usize;
        loop {
            let mut raw = Vec::new();
            match reader.read_until(b'\n', &mut raw) {
                Ok(0) => break,
                Ok(_) => {
                    let line = strip_ansi(String::from_utf8_lossy(&raw).trim_end());
                    if !line.is_empty() {
                        let _ = app.emit(
                            "build-log",
                            BuildLog {
                                stream: stream_name,
                                line: line.clone(),
                            },
                        );
                        captured_bytes += line.len() + 1;
                        captured.push_back(line);
                        while captured_bytes > MAX_CAPTURED_BYTES {
                            if let Some(removed) = captured.pop_front() {
                                captured_bytes = captured_bytes.saturating_sub(removed.len() + 1);
                            } else {
                                break;
                            }
                        }
                    }
                }
                Err(_) => break,
            }
        }
        captured.into_iter().collect::<Vec<_>>().join("\n")
    })
}

fn runtime_root(app: &AppHandle) -> Result<PathBuf, String> {
    #[cfg(debug_assertions)]
    {
        let _ = app;
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .map_err(|error| format!("개발용 UBS 경로 확인 실패: {error}"))
    }
    #[cfg(not(debug_assertions))]
    {
        let root = app
            .path()
            .resource_dir()
            .map_err(|error| format!("앱 리소스 경로 확인 실패: {error}"))?
            .join("ubs-runtime");
        if root.join("build.sh").is_file() {
            Ok(root)
        } else {
            Err("앱에 UBS 런타임이 포함되지 않았습니다.".to_string())
        }
    }
}

fn canonical_directory(raw: &str) -> Result<PathBuf, String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err("프로젝트 폴더를 선택하세요.".to_string());
    }
    let path = PathBuf::from(raw)
        .canonicalize()
        .map_err(|error| format!("프로젝트 경로 확인 실패: {error}"))?;
    if !path.is_dir() {
        return Err("선택한 경로가 폴더가 아닙니다.".to_string());
    }
    Ok(path)
}

fn ubs_command(runtime_root: &Path) -> Result<Command, String> {
    let script = runtime_root.join("build.sh");
    if !script.is_file() {
        return Err(format!("UBS 실행 파일이 없습니다: {}", script.display()));
    }
    #[cfg(windows)]
    let mut command = Command::new("bash");
    #[cfg(not(windows))]
    let mut command = Command::new("/bin/bash");
    command.arg(script).current_dir(runtime_root);
    add_common_executable_paths(&mut command);
    Ok(command)
}

fn add_common_executable_paths(command: &mut Command) {
    let mut paths: Vec<PathBuf> = std::env::var_os("PATH")
        .as_deref()
        .map(std::env::split_paths)
        .into_iter()
        .flatten()
        .collect();
    for path in [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ] {
        let path = PathBuf::from(path);
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        for suffix in [
            ".cargo/bin",
            ".pub-cache/bin",
            ".local/bin",
            "Desktop/flutter/bin",
            "Development/flutter/bin",
            "flutter/bin",
            ".fvm/default/bin",
        ] {
            let path = home.join(suffix);
            if !paths.contains(&path) {
                paths.push(path);
            }
        }
    }
    if let Ok(path) = std::env::join_paths(paths) {
        command.env("PATH", path);
    }
}

fn temporary_report_path() -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    std::env::temp_dir().join(format!("ubs-desktop-{}-{nonce}.json", std::process::id()))
}

fn read_report(path: &Path) -> Option<Value> {
    let report = fs::read_to_string(path)
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok());
    let _ = fs::remove_file(path);
    report
}

fn clear_process_slot(shared: &Arc<Mutex<ProcessSlot>>) {
    if let Ok(mut slot) = shared.lock() {
        slot.child = None;
        slot.active = false;
        slot.cancelled = false;
    }
}

#[cfg(unix)]
fn configure_process_group(command: &mut Command) {
    use std::os::unix::process::CommandExt;
    command.process_group(0);
}

#[cfg(windows)]
fn configure_process_group(command: &mut Command) {
    use std::os::windows::process::CommandExt;
    command.creation_flags(0x0000_0200);
}

#[cfg(unix)]
fn terminate_process_tree(child: &mut Child) -> std::io::Result<()> {
    let status = Command::new("/bin/kill")
        .args(["-TERM", &format!("-{}", child.id())])
        .status()?;
    if status.success() {
        Ok(())
    } else {
        child.kill()
    }
}

#[cfg(windows)]
fn terminate_process_tree(child: &mut Child) -> std::io::Result<()> {
    let status = Command::new("taskkill")
        .args(["/PID", &child.id().to_string(), "/T", "/F"])
        .status()?;
    if status.success() {
        Ok(())
    } else {
        child.kill()
    }
}

fn strip_ansi(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(character) = chars.next() {
        if character == '\u{1b}' && chars.peek() == Some(&'[') {
            chars.next();
            for control in chars.by_ref() {
                if ('@'..='~').contains(&control) {
                    break;
                }
            }
        } else {
            output.push(character);
        }
    }
    output
}

fn main() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(BuildState::default())
        .invoke_handler(tauri::generate_handler![
            detect_projects,
            run_build,
            cancel_build
        ])
        .build(tauri::generate_context!())
        .expect("UBS desktop 초기화 실패");
    app.run(|app_handle, event| {
        let should_cancel = match event {
            tauri::RunEvent::Exit | tauri::RunEvent::ExitRequested { .. } => true,
            tauri::RunEvent::WindowEvent {
                label,
                event: tauri::WindowEvent::Destroyed,
                ..
            } => label == "main",
            _ => false,
        };
        if should_cancel {
            let state = app_handle.state::<BuildState>();
            let _ = request_cancellation(&state.0);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ansi_sequences_are_removed() {
        assert_eq!(strip_ansi("\u{1b}[32m완료\u{1b}[0m"), "완료");
    }

    #[test]
    fn temporary_reports_are_unique_enough_for_one_process() {
        let first = temporary_report_path();
        thread::sleep(Duration::from_millis(1));
        let second = temporary_report_path();
        assert_ne!(first, second);
        assert_eq!(
            first.extension().and_then(|value| value.to_str()),
            Some("json")
        );
    }

    #[test]
    fn current_repository_is_the_debug_runtime() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .expect("repository root");
        assert!(root.join("build.sh").is_file());
        assert!(root.join("scripts/ubs.py").is_file());
    }

    #[cfg(unix)]
    #[test]
    fn desktop_flutter_sdk_is_available_to_build_commands() {
        let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
            return;
        };
        let mut command = Command::new("/bin/sh");
        add_common_executable_paths(&mut command);
        let path = command
            .get_envs()
            .find(|(key, _)| *key == "PATH")
            .and_then(|(_, value)| value)
            .expect("PATH override");
        assert!(std::env::split_paths(path).any(|entry| entry == home.join("Desktop/flutter/bin")));

        if home.join("Desktop/flutter/bin/flutter").is_file() {
            command.args(["-c", "command -v flutter"]);
            let output = command.output().expect("Flutter lookup");
            assert!(output.status.success());
            assert_eq!(
                String::from_utf8_lossy(&output.stdout).trim(),
                home.join("Desktop/flutter/bin/flutter").to_string_lossy()
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn cancellation_terminates_the_active_process_group() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "sleep 30"]);
        configure_process_group(&mut command);
        let child = command.spawn().expect("spawn cancellable child");
        let shared = Arc::new(Mutex::new(ProcessSlot {
            active: true,
            cancelled: false,
            child: Some(child),
        }));

        assert!(request_cancellation(&shared).expect("cancel request"));
        let mut exited = false;
        for _ in 0..20 {
            let status = shared
                .lock()
                .expect("process slot")
                .child
                .as_mut()
                .expect("active child")
                .try_wait()
                .expect("child status");
            if status.is_some() {
                exited = true;
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        assert!(exited, "cancelled child did not exit within one second");
    }
}
