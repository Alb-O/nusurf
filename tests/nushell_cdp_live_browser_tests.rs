#[path = "support/browser.rs"]
mod browser;

use std::{
	io::{Read, Write},
	net::{TcpListener, TcpStream},
	path::{Path, PathBuf},
	process::{Child, Command, Stdio},
	sync::{
		Arc,
		atomic::{AtomicBool, Ordering},
	},
	thread::{self, JoinHandle},
	time::{Duration, Instant},
};

fn build_plugin_binary() -> PathBuf {
	PathBuf::from(env!("CARGO_BIN_EXE_nu_plugin_ws"))
}

fn pick_free_port() -> u16 {
	TcpListener::bind("127.0.0.1:0")
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

		thread::sleep(Duration::from_millis(100));
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
		.arg("--noerrdialogs")
		.arg("--ozone-platform=headless")
		.arg("--ozone-override-screen-size=800,600")
		.arg("--use-angle=swiftshader-webgl")
		.arg("about:blank")
		.stdout(Stdio::null())
		.stderr(Stdio::null())
		.spawn()
		.expect("should launch test browser")
}

fn run_nu_script(
	plugin_path: &Path, include_paths: &[PathBuf], script_path: &Path, script_args: &[String],
) -> Result<(), String> {
	let mut command = Command::new("nu");
	command
		.arg("--no-config-file")
		.stdout(Stdio::piped())
		.stderr(Stdio::piped());

	if !include_paths.is_empty() {
		let include_arg = include_paths
			.iter()
			.map(|path| path.display().to_string())
			.collect::<Vec<_>>()
			.join("\u{1e}");
		command.arg("-I").arg(include_arg);
	}

	command.arg("--plugins").arg(plugin_path).arg("--").arg(script_path);

	for arg in script_args {
		command.arg(arg);
	}

	let mut child = command
		.spawn()
		.map_err(|err| format!("failed to execute nushell: {err}"))?;

	let deadline = Instant::now() + Duration::from_secs(45);

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
						"live Nu CDP test failed for {}\nstdout:\n{}\nstderr:\n{}",
						script_path.display(),
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
					"live Nu CDP test timed out after 45s for {}\nstdout:\n{}\nstderr:\n{}",
					script_path.display(),
					String::from_utf8_lossy(&output.stdout),
					String::from_utf8_lossy(&output.stderr)
				));
			}
			Err(err) => return Err(format!("failed while waiting on nushell: {err}")),
		}
	}
}

struct FixtureServer {
	addr: std::net::SocketAddr,
	stop: Arc<AtomicBool>,
	thread: Option<JoinHandle<()>>,
}

impl FixtureServer {
	fn new() -> Self {
		let listener = TcpListener::bind("127.0.0.1:0").expect("should bind fixture server");
		let addr = listener.local_addr().expect("should resolve fixture server address");
		let stop = Arc::new(AtomicBool::new(false));
		let stop_flag = stop.clone();

		listener
			.set_nonblocking(true)
			.expect("should configure fixture server listener");

		let thread = thread::spawn(move || {
			loop {
				if stop_flag.load(Ordering::SeqCst) {
					break;
				}

				match listener.accept() {
					Ok((stream, _)) => {
						thread::spawn(move || handle_fixture_connection(stream));
					}
					Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
						thread::sleep(Duration::from_millis(25));
					}
					Err(_) => break,
				}
			}
		});

		Self {
			addr,
			stop,
			thread: Some(thread),
		}
	}

	fn port(&self) -> u16 {
		self.addr.port()
	}
}

impl Drop for FixtureServer {
	fn drop(&mut self) {
		self.stop.store(true, Ordering::SeqCst);
		let _ = TcpStream::connect(self.addr);
		if let Some(thread) = self.thread.take() {
			let _ = thread.join();
		}
	}
}

fn handle_fixture_connection(mut stream: TcpStream) {
	let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));

	let mut request = Vec::new();
	let mut buffer = [0_u8; 1024];

	loop {
		match stream.read(&mut buffer) {
			Ok(0) => break,
			Ok(read) => {
				request.extend_from_slice(&buffer[..read]);
				if request.windows(4).any(|window| window == b"\r\n\r\n") {
					break;
				}
			}
			Err(_) => return,
		}
	}

	let request_line = String::from_utf8_lossy(&request);
	let path = request_line
		.lines()
		.next()
		.and_then(|line| line.split_whitespace().nth(1))
		.unwrap_or("/");

	let (status, content_type, body) = fixture_response(path);
	let response = format!(
		"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{body}",
		body.len()
	);

	let _ = stream.write_all(response.as_bytes());
}

fn fixture_response(path: &str) -> (&'static str, &'static str, String) {
	if path.starts_with("/ping") {
		("200 OK", "text/plain; charset=UTF-8", format!("pong {path}"))
	} else {
		("200 OK", "text/plain; charset=UTF-8", "ok".to_string())
	}
}

fn run_live_browser_script(script_name: &str, extra_args: &[String]) -> Result<(), String> {
	let Some(browser) = browser::discover_chromium_browser() else {
		eprintln!("skipping live browser e2e: set NU_CDP_BROWSER or install a Chromium-compatible browser on PATH");
		return Ok(());
	};

	let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
	let plugin_path = build_plugin_binary();
	let include_paths = vec![repo_root.join("nu"), repo_root.join("tests/support")];
	let script_path = repo_root.join("tests").join(script_name);
	let port = pick_free_port();
	let user_data_dir = std::env::temp_dir().join(format!("nu-plugin-ws-live-{}-{}", std::process::id(), port));

	let mut browser_process = spawn_browser(&browser, port, &user_data_dir);

	let test_result = (|| -> Result<(), String> {
		wait_for_devtools(port)?;

		let mut script_args = vec![port.to_string()];
		script_args.extend(extra_args.iter().cloned());

		run_nu_script(&plugin_path, &include_paths, &script_path, &script_args)
	})();

	let _ = browser_process.kill();
	let _ = browser_process.wait();
	let _ = std::fs::remove_dir_all(&user_data_dir);

	test_result
}

#[test]
fn live_browser_nu_cdp_e2e() {
	if let Err(err) = run_live_browser_script("cdp_live_browser_tests.nu", &[]) {
		panic!("{err}");
	}
}

#[test]
fn live_browser_nu_cdp_event_routing() {
	let fixture = FixtureServer::new();

	if let Err(err) = run_live_browser_script("cdp_live_browser_event_routing.nu", &[fixture.port().to_string()]) {
		panic!("{err}");
	}
}

#[test]
fn live_browser_nu_cdp_concurrent_targets() {
	let fixture = FixtureServer::new();

	if let Err(err) = run_live_browser_script("cdp_live_browser_concurrent.nu", &[fixture.port().to_string()]) {
		panic!("{err}");
	}
}

#[test]
fn live_browser_nu_cdp_disconnects() {
	if let Err(err) = run_live_browser_script("cdp_live_browser_disconnect.nu", &[]) {
		panic!("{err}");
	}
}
