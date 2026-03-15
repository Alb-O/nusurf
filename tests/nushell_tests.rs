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

struct MockCdpServer {
	addr: SocketAddr,
	barrier: Arc<Barrier>,
}

impl MockCdpServer {
	fn new() -> Self {
		let listener = TcpListener::bind("127.0.0.1:0").unwrap();
		let addr = listener.local_addr().unwrap();
		let barrier = Arc::new(Barrier::new(2));

		let barrier_clone = barrier.clone();

		thread::spawn(move || {
			barrier_clone.wait();

			while let Ok((stream, _peer_addr)) = listener.accept() {
				thread::spawn(move || handle_cdp_connection(stream));
			}
		});

		Self { addr, barrier }
	}

	fn start(&self) {
		self.barrier.wait();
		thread::sleep(Duration::from_millis(100));
	}

	fn url(&self) -> String {
		format!("ws://127.0.0.1:{}", self.addr.port())
	}
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

				let event = json!({
					"method": "Test.event",
					"params": {
						"requestId": id.clone(),
						"method": method,
					}
				});
				let event = if let Some(session_id) = request
					.get("params")
					.and_then(|params| params.get("sessionId"))
					.and_then(JsonValue::as_str)
				{
					let mut event = event;
					event["sessionId"] = JsonValue::String(session_id.to_string());
					event
				} else {
					event
				};
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
fn nushell_ws_tests_pass() {
	let server = MockCdpServer::new();
	server.start();

	let plugin_path = PathBuf::from(env!("CARGO_BIN_EXE_nu_plugin_nusurf"));
	let script_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/ws/basic.nu");
	let output = Command::new("nu")
		.arg("--no-config-file")
		.arg("--plugins")
		.arg(&plugin_path)
		.arg("--")
		.arg(script_path)
		.arg(server.url())
		.output()
		.expect("should execute nushell");

	assert!(
		output.status.success(),
		"nushell test script failed\nstdout:\n{}\nstderr:\n{}",
		String::from_utf8_lossy(&output.stdout),
		String::from_utf8_lossy(&output.stderr)
	);
}
