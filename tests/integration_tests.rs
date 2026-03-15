use {
	nu_plugin_test_support::PluginTest,
	nu_protocol::{Span, Value},
	nusurf::NusurfPlugin,
	serde_json::{Value as JsonValue, json},
	std::{
		net::{SocketAddr, TcpListener, TcpStream},
		sync::{Arc, Barrier},
		thread,
		time::Duration,
	},
	tungstenite::{Message, WebSocket, accept},
};

fn eval_to_value(plugin_test: &mut PluginTest, nu_source: &str) -> Value {
	plugin_test
		.eval(nu_source)
		.expect("Nushell evaluation should succeed")
		.into_value(Span::test_data())
		.expect("Pipeline should convert to a value")
}

fn record_string(value: &Value, key: &str) -> String {
	value
		.get_data_by_key(key)
		.expect("record should contain requested key")
		.coerce_str()
		.expect("value should be coercible to string")
		.to_string()
}

fn record_i64(value: &Value, key: &str) -> i64 {
	value
		.get_data_by_key(key)
		.expect("record should contain requested key")
		.as_int()
		.expect("value should be coercible to int")
}

struct MockWebSocketServer {
	addr: SocketAddr,
	barrier: Arc<Barrier>,
}

impl MockWebSocketServer {
	fn new() -> Self {
		let listener = TcpListener::bind("127.0.0.1:0").unwrap();
		let addr = listener.local_addr().unwrap();
		let barrier = Arc::new(Barrier::new(2));

		let barrier_clone = barrier.clone();

		thread::spawn(move || {
			barrier_clone.wait();

			while let Ok((stream, _peer_addr)) = listener.accept() {
				thread::spawn(move || handle_connection(stream));
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

fn handle_connection(stream: TcpStream) {
	let mut ws_stream = match accept(stream) {
		Ok(ws) => ws,
		Err(_e) => return,
	};
	handle_websocket(&mut ws_stream);
}

fn handle_websocket(ws_stream: &mut WebSocket<TcpStream>) {
	while let Ok(msg) = ws_stream.read() {
		match msg {
			Message::Text(text) => {
				let response = format!("Echo: {text}");
				if ws_stream.send(Message::Text(response.into())).is_err() {
					break;
				}
			}
			Message::Binary(data) => {
				let mut response = b"Binary Echo: ".to_vec();
				response.extend_from_slice(&data);
				if ws_stream.send(Message::Binary(response.into())).is_err() {
					break;
				}
			}
			Message::Ping(data) => {
				if ws_stream.send(Message::Pong(data)).is_err() {
					break;
				}
			}
			Message::Pong(_) => {}
			Message::Close(_) => {
				let _ = ws_stream.send(Message::Close(None));
				break;
			}
			Message::Frame(_) => {}
		}
	}
}

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
fn test_websocket_connection_and_echo() {
	let server = MockWebSocketServer::new();
	server.start();

	let mut plugin_test = PluginTest::new("ws", NusurfPlugin.into()).expect("Failed to create plugin test");
	let echoed = eval_to_value(
		&mut plugin_test,
		&format!(r#"echo "Hello WebSocket" | ws "{}" --max-time 5sec"#, server.url()),
	);

	assert_eq!(
		echoed.coerce_str().expect("echoed message should be text"),
		"Echo: Hello WebSocket\n"
	);
}

#[test]
fn test_websocket_invalid_url() {
	let mut plugin_test = PluginTest::new("ws", NusurfPlugin.into()).expect("Failed to create plugin test");

	let result = plugin_test.eval(r#"ws "invalid-url""#);

	assert!(result.is_err(), "Invalid URL should fail");
}

#[test]
fn test_websocket_connection_refused() {
	let mut plugin_test = PluginTest::new("ws", NusurfPlugin.into()).expect("Failed to create plugin test");

	let result = plugin_test.eval(r#"ws "ws://127.0.0.1:12345""#);

	assert!(result.is_err(), "Connection to non-existent server should fail");
}

struct DelayedResponseServer {
	addr: SocketAddr,
	barrier: Arc<Barrier>,
}

impl DelayedResponseServer {
	fn new() -> Self {
		let listener = TcpListener::bind("127.0.0.1:0").unwrap();
		let addr = listener.local_addr().unwrap();
		let barrier = Arc::new(Barrier::new(2));

		let barrier_clone = barrier.clone();

		thread::spawn(move || {
			barrier_clone.wait();

			while let Ok((stream, _)) = listener.accept() {
				thread::spawn(move || handle_delayed_connection(stream));
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

fn handle_delayed_connection(stream: TcpStream) {
	let mut ws_stream = accept(stream).expect("Failed to accept");

	thread::sleep(Duration::from_secs(2));

	if ws_stream
		.send(Message::Text("Delayed response".to_string().into()))
		.is_ok()
	{
		loop {
			match ws_stream.read() {
				Ok(Message::Close(_)) => break,
				Err(_) => break,
				_ => {}
			}
		}
	}
}

#[test]
fn test_websocket_timeout_expires() {
	let server = DelayedResponseServer::new();
	server.start();

	let mut plugin_test = PluginTest::new("ws", NusurfPlugin.into()).expect("Failed to create plugin test");

	let timed_out = eval_to_value(&mut plugin_test, &format!(r#"ws "{}" --max-time 1sec"#, server.url()));

	assert_eq!(timed_out.coerce_str().expect("timeout result should be text"), "");
}

#[test]
fn test_websocket_http_url() {
	let mut plugin_test = PluginTest::new("ws", NusurfPlugin.into()).expect("Failed to create plugin test");

	let result = plugin_test.eval(r#"ws "http://example.com""#);

	assert!(result.is_err(), "HTTP URL should fail for WebSocket connection");
}

struct EarlyCloseServer {
	addr: SocketAddr,
	barrier: Arc<Barrier>,
}

impl EarlyCloseServer {
	fn new() -> Self {
		let listener = TcpListener::bind("127.0.0.1:0").unwrap();
		let addr = listener.local_addr().unwrap();
		let barrier = Arc::new(Barrier::new(2));

		let barrier_clone = barrier.clone();

		thread::spawn(move || {
			barrier_clone.wait();

			while let Ok((stream, _)) = listener.accept() {
				thread::spawn(move || handle_early_close_connection(stream));
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

fn handle_early_close_connection(stream: TcpStream) {
	let mut ws_stream = match accept(stream) {
		Ok(ws) => ws,
		Err(_e) => return,
	};

	// Send one message then immediately close
	let _ = ws_stream.send(Message::Text("Closing soon".to_string().into()));
	thread::sleep(Duration::from_millis(100));
	let _ = ws_stream.send(Message::Close(None));
}

#[test]
fn test_websocket_port_in_url() {
	let mut plugin_test = PluginTest::new("ws", NusurfPlugin.into()).expect("Failed to create plugin test");

	let result = plugin_test.eval(r#"ws "ws://127.0.0.1:99999" --max-time 1sec"#);

	assert!(result.is_err(), "Connection to invalid port should fail gracefully");
}

#[test]
fn test_persistent_websocket_session_lifecycle() {
	let server = MockWebSocketServer::new();
	server.start();

	let mut plugin_test = PluginTest::new("ws", NusurfPlugin.into()).expect("Failed to create plugin test");
	let session_name = "session-lifecycle-test";

	let opened = eval_to_value(
		&mut plugin_test,
		&format!(r#"ws open "{}" --name "{}""#, server.url(), session_name),
	);
	assert_eq!(record_string(&opened, "id"), session_name);
	assert_eq!(record_string(&opened, "url"), server.url());

	let listed = eval_to_value(&mut plugin_test, r#"ws list"#);
	let Value::List { vals, .. } = listed else {
		panic!("ws list should return a list");
	};
	assert!(vals.iter().any(|value| record_string(value, "id") == session_name));

	let closed = eval_to_value(&mut plugin_test, &format!(r#"ws close "{}""#, session_name));
	assert_eq!(record_string(&closed, "id"), session_name);

	let listed_after_close = eval_to_value(&mut plugin_test, r#"ws list"#);
	let Value::List { vals: remaining, .. } = listed_after_close else {
		panic!("ws list should return a list");
	};
	assert!(!remaining.iter().any(|value| record_string(value, "id") == session_name));
}

#[test]
fn test_persistent_websocket_prunes_closed_sessions() {
	let server = EarlyCloseServer::new();
	server.start();

	let mut plugin_test = PluginTest::new("ws", NusurfPlugin.into()).expect("Failed to create plugin test");
	let session_name = "session-prune-closed-test";

	plugin_test
		.eval(&format!(r#"ws open "{}" --name "{}""#, server.url(), session_name))
		.expect("session should open");

	let first_message = eval_to_value(
		&mut plugin_test,
		&format!(r#"ws recv "{}" --max-time 2sec"#, session_name),
	);
	assert_eq!(
		first_message.coerce_str().expect("first message should be text"),
		"Closing soon"
	);

	let closed_error = plugin_test
		.eval(&format!(r#"ws recv "{}" --max-time 2sec"#, session_name))
		.expect_err("closed session should reject further reads");
	let error_text = closed_error.to_string().to_lowercase();
	assert!(
		error_text.contains("closed") || error_text.contains("not found"),
		"closed session errors should mention closure or pruning, got: {error_text}"
	);

	let listed_after_close = eval_to_value(&mut plugin_test, r#"ws list"#);
	let Value::List { vals: remaining, .. } = listed_after_close else {
		panic!("ws list should return a list");
	};
	assert!(!remaining.iter().any(|value| record_string(value, "id") == session_name));
}

#[test]
fn test_persistent_websocket_send_and_receive() {
	let server = MockWebSocketServer::new();
	server.start();

	let mut plugin_test = PluginTest::new("ws", NusurfPlugin.into()).expect("Failed to create plugin test");
	let session_name = "session-send-recv-test";

	plugin_test
		.eval(&format!(r#"ws open "{}" --name "{}""#, server.url(), session_name))
		.expect("session should open");

	plugin_test
		.eval(&format!(r#"echo "hello session" | ws send "{}""#, session_name))
		.expect("message should send");

	let received = eval_to_value(
		&mut plugin_test,
		&format!(r#"ws recv "{}" --max-time 2sec"#, session_name),
	);
	assert_eq!(
		received.coerce_str().expect("received message should be text"),
		"Echo: hello session"
	);

	plugin_test
		.eval(&format!(r#"echo "full mode" | ws send "{}""#, session_name))
		.expect("message should send");

	let received_full = eval_to_value(
		&mut plugin_test,
		&format!(r#"ws recv "{}" --max-time 2sec --full"#, session_name),
	);
	assert_eq!(record_string(&received_full, "type"), "text");
	assert_eq!(record_string(&received_full, "data"), "Echo: full mode");

	let timed_out = eval_to_value(
		&mut plugin_test,
		&format!(r#"ws recv "{}" --max-time 100ms"#, session_name),
	);
	assert!(matches!(timed_out, Value::Nothing { .. }));

	plugin_test
		.eval(&format!(r#"ws close "{}""#, session_name))
		.expect("session should close");
}

#[test]
fn test_persistent_websocket_send_json_and_recv_json() {
	let server = MockCdpServer::new();
	server.start();

	let mut plugin_test = PluginTest::new("ws", NusurfPlugin.into()).expect("Failed to create plugin test");
	let session_name = "session-send-json-test";

	plugin_test
		.eval(&format!(r#"ws open "{}" --name "{}""#, server.url(), session_name))
		.expect("session should open");

	plugin_test
		.eval(&format!(
			r#"{{
				id: 1,
				method: "Browser.getVersion",
				params: {{
					channel: "stable"
				}}
			}} | ws send-json "{}""#,
			session_name
		))
		.expect("json message should send");

	let event = eval_to_value(
		&mut plugin_test,
		&format!(r#"ws recv-json "{}" --max-time 2sec"#, session_name),
	);
	assert_eq!(record_string(&event, "method"), "Test.event");
	let event_params = event.get_data_by_key("params").expect("event should include params");
	assert_eq!(record_i64(&event_params, "requestId"), 1);
	assert_eq!(record_string(&event_params, "method"), "Browser.getVersion");

	let response = eval_to_value(
		&mut plugin_test,
		&format!(r#"ws recv-json "{}" --max-time 2sec"#, session_name),
	);
	assert_eq!(record_i64(&response, "id"), 1);
	let response_result = response
		.get_data_by_key("result")
		.expect("response should include result");
	assert_eq!(record_string(&response_result, "echoMethod"), "Browser.getVersion");
	let echoed_params = response_result
		.get_data_by_key("echoParams")
		.expect("response should include echoed params");
	assert_eq!(record_string(&echoed_params, "channel"), "stable");

	plugin_test
		.eval(&format!(r#"ws close "{}""#, session_name))
		.expect("session should close");
}

#[test]
fn test_persistent_websocket_await_response_and_next_event() {
	let server = MockCdpServer::new();
	server.start();

	let mut plugin_test = PluginTest::new("ws", NusurfPlugin.into()).expect("Failed to create plugin test");
	let session_name = "session-await-event-test";

	plugin_test
		.eval(&format!(r#"ws open "{}" --name "{}""#, server.url(), session_name))
		.expect("session should open");

	plugin_test
		.eval(&format!(
			r#"{{
				id: 2,
				method: "Page.navigate",
				params: {{
					url: "https://example.com"
				}}
			}} | ws send-json "{}""#,
			session_name
		))
		.expect("json message should send");

	let response = eval_to_value(
		&mut plugin_test,
		&format!(r#"ws await "{}" 2 --max-time 2sec"#, session_name),
	);
	assert_eq!(record_i64(&response, "id"), 2);
	let response_result = response
		.get_data_by_key("result")
		.expect("response should include result");
	assert_eq!(record_string(&response_result, "echoMethod"), "Page.navigate");

	let event = eval_to_value(
		&mut plugin_test,
		&format!(r#"ws next-event "{}" "Test.event" --max-time 2sec"#, session_name),
	);
	assert_eq!(record_string(&event, "method"), "Test.event");
	let event_params = event.get_data_by_key("params").expect("event should include params");
	assert_eq!(record_i64(&event_params, "requestId"), 2);
	assert_eq!(record_string(&event_params, "method"), "Page.navigate");

	let missing_response = eval_to_value(
		&mut plugin_test,
		&format!(r#"ws await "{}" 999 --max-time 100ms"#, session_name),
	);
	assert!(matches!(missing_response, Value::Nothing { .. }));

	let missing_event = eval_to_value(
		&mut plugin_test,
		&format!(r#"ws next-event "{}" "Missing.event" --max-time 100ms"#, session_name),
	);
	assert!(matches!(missing_event, Value::Nothing { .. }));

	plugin_test
		.eval(&format!(r#"ws close "{}""#, session_name))
		.expect("session should close");
}
