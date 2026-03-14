#[path = "support/browser.rs"]
mod browser;

use std::{
	io::{Read, Write},
	net::TcpStream,
	path::{Path, PathBuf},
	process::{Child, Command, Stdio},
	thread,
	time::{Duration, Instant},
};

fn build_plugin_binary() -> PathBuf {
	PathBuf::from(env!("CARGO_BIN_EXE_nu_plugin_ws"))
}

fn pick_free_port() -> u16 {
	std::net::TcpListener::bind("127.0.0.1:0")
		.expect("should bind local port")
		.local_addr()
		.expect("should resolve local port")
		.port()
}

fn wait_for_devtools(port: u16) -> Result<(), String> {
	let addr = format!("127.0.0.1:{port}");
	let request = format!("GET /json/version HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\n\r\n");

	for _attempt in 0..150 {
		if let Ok(mut stream) = TcpStream::connect(&addr) {
			let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
			let _ = stream.write_all(request.as_bytes());

			let mut buffer = [0_u8; 1024];
			let mut response = Vec::new();

			loop {
				match stream.read(&mut buffer) {
					Ok(0) => break,
					Ok(read) => {
						response.extend_from_slice(&buffer[..read]);

						// We only need the status line to know DevTools is up.
						if response
							.windows("HTTP/1.1 200".len())
							.any(|window| window == b"HTTP/1.1 200")
						{
							return Ok(());
						}
					}
					Err(_) => break,
				}
			}

			if String::from_utf8_lossy(&response).contains("HTTP/1.1 200") {
				return Ok(());
			}
		}

		std::thread::sleep(Duration::from_millis(100));
	}

	Err(format!("Timed out waiting for DevTools on port {port}"))
}

fn spawn_browser(browser: &Path, port: u16, user_data_dir: &Path) -> Child {
	Command::new(browser)
		.arg("--headless=new")
		.arg(format!("--remote-debugging-port={port}"))
		.arg("--remote-allow-origins=*")
		.arg(format!("--user-data-dir={}", user_data_dir.display()))
		.arg("--no-first-run")
		.arg("--no-default-browser-check")
		.arg("about:blank")
		.stdout(Stdio::null())
		.stderr(Stdio::null())
		.spawn()
		.expect("should launch test browser")
}

fn run_nu_script(plugin_path: &Path, include_path: &Path, script_path: &Path, port: u16) -> Result<(), String> {
	let mut child = Command::new("nu")
		.arg("--no-config-file")
		.arg("-I")
		.arg(include_path)
		.arg("--plugins")
		.arg(plugin_path)
		.arg("--")
		.arg(script_path)
		.arg(port.to_string())
		.stdout(Stdio::piped())
		.stderr(Stdio::piped())
		.spawn()
		.map_err(|err| format!("failed to execute nushell: {err}"))?;

	let deadline = Instant::now() + Duration::from_secs(30);

	loop {
		match child.try_wait() {
			Ok(Some(status)) => {
				let output = child
					.wait_with_output()
					.map_err(|err| format!("failed to collect nushell output: {err}"))?;

				return if status.success() {
					Ok(())
				} else {
					Err(format!(
						"live Nu CDP test failed\nstdout:\n{}\nstderr:\n{}",
						String::from_utf8_lossy(&output.stdout),
						String::from_utf8_lossy(&output.stderr)
					))
				};
			}
			Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(100)),
			Ok(None) => {
				let _ = child.kill();
				let output = child
					.wait_with_output()
					.map_err(|err| format!("failed to collect timed out nushell output: {err}"))?;

				return Err(format!(
					"live Nu CDP test timed out after 30s\nstdout:\n{}\nstderr:\n{}",
					String::from_utf8_lossy(&output.stdout),
					String::from_utf8_lossy(&output.stderr)
				));
			}
			Err(err) => return Err(format!("failed while waiting on nushell: {err}")),
		}
	}
}

#[test]
fn live_browser_nu_cdp_e2e() {
	let Some(browser) = browser::discover_chromium_browser() else {
		eprintln!("skipping live browser e2e: set NU_CDP_BROWSER or install a Chromium-compatible browser on PATH");
		return;
	};

	let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
	let plugin_path = build_plugin_binary();
	let script_path = repo_root.join("tests/cdp_live_browser_tests.nu");
	let include_path = repo_root.join("nu");
	let port = pick_free_port();
	let user_data_dir = std::env::temp_dir().join(format!("nu-plugin-ws-live-{}-{}", std::process::id(), port));

	let mut browser_process = spawn_browser(&browser, port, &user_data_dir);

	let test_result = (|| -> Result<(), String> {
		wait_for_devtools(port)?;
		run_nu_script(&plugin_path, &include_path, &script_path, port)
	})();

	let _ = browser_process.kill();
	let _ = browser_process.wait();
	let _ = std::fs::remove_dir_all(&user_data_dir);

	if let Err(err) = test_result {
		panic!("{err}");
	}
}
