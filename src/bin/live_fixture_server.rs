use {
	serde_json::{Value as JsonValue, json},
	std::{
		io::{Read, Write},
		net::{TcpListener, TcpStream},
		path::PathBuf,
		thread,
	},
	tungstenite::{Message, WebSocket, accept},
};

fn main() {
	let args = Args::parse();

	match args.mode {
		FixtureMode::LiveHttp => run_live_http_fixture(args.port, args.port_file),
		FixtureMode::Ws => run_ws_fixture(args.port, args.port_file),
		FixtureMode::Cdp => run_cdp_fixture(args.port, args.port_file),
	}
}

struct Args {
	mode: FixtureMode,
	port: u16,
	port_file: Option<PathBuf>,
}

impl Args {
	fn parse() -> Self {
		let mut mode = FixtureMode::LiveHttp;
		let mut port = 0_u16;
		let mut port_file = None::<PathBuf>;

		let mut args = std::env::args().skip(1);
		while let Some(arg) = args.next() {
			match arg.as_str() {
				"--mode" => {
					let value = args.next().expect("--mode requires a value");
					mode = FixtureMode::parse(&value);
				}
				"--port" => {
					let value = args.next().expect("--port requires a value");
					port = value.parse().expect("--port must be an integer");
				}
				"--port-file" => {
					let value = args.next().expect("--port-file requires a value");
					port_file = Some(PathBuf::from(value));
				}
				other => panic!("unsupported argument: {other}"),
			}
		}

		Self { mode, port, port_file }
	}
}

enum FixtureMode {
	LiveHttp,
	Ws,
	Cdp,
}

impl FixtureMode {
	fn parse(value: &str) -> Self {
		match value {
			"live-http" => Self::LiveHttp,
			"ws" => Self::Ws,
			"cdp" => Self::Cdp,
			other => panic!("unsupported fixture mode: {other}"),
		}
	}
}

fn bind_listener(port: u16, label: &str) -> TcpListener {
	TcpListener::bind(("127.0.0.1", port)).unwrap_or_else(|err| panic!("failed to bind {label}: {err}"))
}

fn announce(port_file: Option<PathBuf>, payload: String) {
	if let Some(port_file) = port_file {
		std::fs::write(port_file, payload).expect("failed to write fixture server port file");
	} else {
		println!("{payload}");
	}
}

fn run_live_http_fixture(port: u16, port_file: Option<PathBuf>) {
	let listener = bind_listener(port, "fixture server");
	let addr = listener.local_addr().expect("failed to resolve fixture server address");

	announce(port_file, addr.port().to_string());

	loop {
		match listener.accept() {
			Ok((stream, _)) => {
				thread::spawn(move || handle_live_http_connection(stream));
			}
			Err(err) => eprintln!("fixture server accept error on {addr}: {err}"),
		}
	}
}

fn handle_live_http_connection(mut stream: TcpStream) {
	let request = read_http_request(&mut stream);
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

fn read_http_request(stream: &mut TcpStream) -> Vec<u8> {
	let mut request = Vec::new();
	let mut buffer = [0_u8; 1024];

	let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(2)));

	loop {
		match stream.read(&mut buffer) {
			Ok(0) => break,
			Ok(read) => {
				request.extend_from_slice(&buffer[..read]);
				if request.windows(4).any(|window| window == b"\r\n\r\n") {
					break;
				}
			}
			Err(_) => break,
		}
	}

	request
}

fn fixture_response(path: &str) -> (&'static str, &'static str, String) {
	if path.starts_with("/ping") {
		("200 OK", "text/plain; charset=UTF-8", format!("pong {path}"))
	} else {
		("200 OK", "text/plain; charset=UTF-8", "ok".to_string())
	}
}

fn run_ws_fixture(port: u16, port_file: Option<PathBuf>) {
	let listener = bind_listener(port, "ws fixture server");
	let addr = listener.local_addr().expect("failed to resolve ws fixture address");

	announce(port_file, addr.port().to_string());

	loop {
		match listener.accept() {
			Ok((stream, _)) => {
				thread::spawn(move || handle_ws_connection(stream, WsFixtureKind::Ws));
			}
			Err(err) => eprintln!("ws fixture accept error on {addr}: {err}"),
		}
	}
}

fn run_cdp_fixture(port: u16, port_file: Option<PathBuf>) {
	let ws_listener = bind_listener(0, "cdp websocket fixture");
	let ws_addr = ws_listener
		.local_addr()
		.expect("failed to resolve cdp websocket address");
	let http_listener = bind_listener(port, "cdp http fixture");
	let http_addr = http_listener.local_addr().expect("failed to resolve cdp http address");
	let ws_url = format!("ws://127.0.0.1:{}", ws_addr.port());

	announce(
		port_file,
		json!({
			"httpPort": http_addr.port(),
			"wsPort": ws_addr.port(),
		})
		.to_string(),
	);

	thread::spawn(move || {
		loop {
			match ws_listener.accept() {
				Ok((stream, _)) => {
					thread::spawn(move || handle_ws_connection(stream, WsFixtureKind::Cdp));
				}
				Err(err) => eprintln!("cdp websocket accept error on {ws_addr}: {err}"),
			}
		}
	});

	loop {
		match http_listener.accept() {
			Ok((mut stream, _)) => {
				let ws_url = ws_url.clone();
				thread::spawn(move || handle_cdp_http_connection(&mut stream, &ws_url));
			}
			Err(err) => eprintln!("cdp http accept error on {http_addr}: {err}"),
		}
	}
}

enum WsFixtureKind {
	Ws,
	Cdp,
}

fn handle_ws_connection(stream: TcpStream, kind: WsFixtureKind) {
	let mut ws_stream = match accept(stream) {
		Ok(ws) => ws,
		Err(_) => return,
	};

	match kind {
		WsFixtureKind::Ws => handle_ws_fixture_messages(&mut ws_stream),
		WsFixtureKind::Cdp => handle_cdp_fixture_messages(&mut ws_stream),
	}
}

fn handle_ws_fixture_messages(ws_stream: &mut WebSocket<TcpStream>) {
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

				let event = {
					let mut event = json!({
						"method": "Test.event",
						"params": {
							"requestId": id.clone(),
							"method": method,
						}
					});

					if let Some(session_id) = request
						.get("params")
						.and_then(|params| params.get("sessionId"))
						.and_then(JsonValue::as_str)
					{
						event["sessionId"] = JsonValue::String(session_id.to_string());
					}

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

fn handle_cdp_fixture_messages(ws_stream: &mut WebSocket<TcpStream>) {
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
					.unwrap_or_else(|| format!("session-{id}"));

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

fn handle_cdp_http_connection(stream: &mut TcpStream, ws_url: &str) {
	let _ = read_http_request(stream);
	let body = json!({
		"Browser": "MockChrome/1.0",
		"webSocketDebuggerUrl": ws_url,
	})
	.to_string();
	let response = format!(
		"HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\nContent-Type: application/json\r\n\r\n{}",
		body.len(),
		body
	);

	let _ = stream.write_all(response.as_bytes());
}
