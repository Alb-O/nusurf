use {
	serde_json::{Value as JsonValue, json},
	std::{
		net::{SocketAddr, TcpListener, TcpStream},
		path::PathBuf,
		process::Command,
		sync::{Arc, Barrier},
		thread,
		time::Duration,
	},
	tungstenite::{Message, WebSocket, accept},
};

fn build_plugin_binary() -> PathBuf {
	PathBuf::from(env!("CARGO_BIN_EXE_nu_plugin_ws"))
}

struct MockCdpServer {
	http_addr: SocketAddr,
	ws_addr: SocketAddr,
	barrier: Arc<Barrier>,
}

impl MockCdpServer {
	fn new() -> Self {
		let ws_listener = TcpListener::bind("127.0.0.1:0").unwrap();
		let ws_addr = ws_listener.local_addr().unwrap();
		let http_listener = TcpListener::bind("127.0.0.1:0").unwrap();
		let http_addr = http_listener.local_addr().unwrap();
		let barrier = Arc::new(Barrier::new(2));
		let barrier_clone = barrier.clone();
		let ws_url = format!("ws://127.0.0.1:{}", ws_addr.port());

		thread::spawn(move || {
			barrier_clone.wait();

			while let Ok((stream, _peer_addr)) = ws_listener.accept() {
				thread::spawn(move || handle_cdp_connection(stream));
			}
		});

		thread::spawn(move || {
			while let Ok((mut stream, _peer_addr)) = http_listener.accept() {
				let body = json!({
					"Browser": "MockChrome/1.0",
					"webSocketDebuggerUrl": ws_url,
				})
				.to_string();
				thread::spawn(move || handle_http_connection(&mut stream, &body));
			}
		});

		Self {
			http_addr,
			ws_addr,
			barrier,
		}
	}

	fn start(&self) {
		self.barrier.wait();
		thread::sleep(Duration::from_millis(100));
	}

	fn url(&self) -> String {
		format!("ws://127.0.0.1:{}", self.ws_addr.port())
	}
}

fn handle_http_connection(stream: &mut TcpStream, body: &str) {
	use std::io::{Read, Write};

	let mut buf = [0u8; 2048];
	let _ = stream.read(&mut buf);
	let response = format!(
		"HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\nContent-Type: application/json\r\n\r\n{}",
		body.len(),
		body
	);
	let _ = stream.write_all(response.as_bytes());
}

fn handle_cdp_connection(stream: TcpStream) {
	let mut ws_stream = match accept(stream) {
		Ok(ws) => ws,
		Err(_e) => return,
	};
	handle_cdp_websocket(&mut ws_stream);
}

fn handle_cdp_websocket(ws_stream: &mut WebSocket<TcpStream>) {
	while let Ok(msg) = ws_stream.read() {
		match msg {
			Message::Text(text) => {
				let request = match serde_json::from_str::<JsonValue>(&text) {
					Ok(request) => request,
					Err(_) => continue,
				};
				let Some(id) = request.get("id").cloned() else {
					continue;
				};
				let method = request
					.get("method")
					.and_then(JsonValue::as_str)
					.unwrap_or("unknown")
					.to_string();
				let params = request.get("params").cloned().unwrap_or(JsonValue::Null);
				let session_id = request
					.get("sessionId")
					.and_then(JsonValue::as_str)
					.map(str::to_string)
					.unwrap_or_else(|| format!("session-{}", id));

				let event = json!({
					"method": "Test.event",
					"sessionId": session_id,
					"params": {
						"requestId": id.clone(),
						"method": method,
					}
				});
				if ws_stream.send(Message::Text(event.to_string().into())).is_err() {
					break;
				}

				let response = json!({
					"id": id,
					"result": {
						"echoMethod": request.get("method").cloned().unwrap_or(JsonValue::Null),
						"echoParams": params,
					}
				});
				if ws_stream.send(Message::Text(response.to_string().into())).is_err() {
					break;
				}
			}
			Message::Ping(data) => {
				if ws_stream.send(Message::Pong(data)).is_err() {
					break;
				}
			}
			Message::Pong(_) | Message::Frame(_) => {}
			Message::Binary(_) => {}
			Message::Close(_) => {
				let _ = ws_stream.send(Message::Close(None));
				break;
			}
		}
	}
}

#[test]
fn cdp_module_runs_against_mock_server() {
	let server = MockCdpServer::new();
	server.start();

	let plugin_path = build_plugin_binary();
	let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
	let script_path = repo_root.join("tests/cdp/mock.nu");
	let include_path = repo_root.join("nu");

	let output = Command::new("nu")
		.arg("--no-config-file")
		.arg("-I")
		.arg(include_path)
		.arg("--plugins")
		.arg(plugin_path)
		.arg("--")
		.arg(script_path)
		.arg(server.http_addr.port().to_string())
		.arg(server.url())
		.output()
		.expect("should execute nushell");

	assert!(
		output.status.success(),
		"mock Nu CDP tests failed\nstdout:\n{}\nstderr:\n{}",
		String::from_utf8_lossy(&output.stdout),
		String::from_utf8_lossy(&output.stderr)
	);
}

#[test]
fn cdp_schema_introspection_works() {
	let plugin_path = build_plugin_binary();
	let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
	let script_path = repo_root.join("tests/cdp/schema.nu");
	let include_path = repo_root.join("nu");

	let output = Command::new("nu")
		.arg("--no-config-file")
		.arg("-I")
		.arg(include_path)
		.arg("--plugins")
		.arg(plugin_path)
		.arg("--")
		.arg(script_path)
		.output()
		.expect("should execute nushell");

	assert!(
		output.status.success(),
		"cdp schema tests failed\nstdout:\n{}\nstderr:\n{}",
		String::from_utf8_lossy(&output.stdout),
		String::from_utf8_lossy(&output.stderr)
	);
}
