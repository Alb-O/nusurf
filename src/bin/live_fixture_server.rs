use std::{
	io::{Read, Write},
	net::{SocketAddr, TcpListener, TcpStream},
	path::PathBuf,
	thread,
	time::Duration,
};

fn main() {
	let mut port = 0_u16;
	let mut port_file = None::<PathBuf>;

	let mut args = std::env::args().skip(1);
	while let Some(arg) = args.next() {
		match arg.as_str() {
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

	let listener = TcpListener::bind(("127.0.0.1", port)).expect("failed to bind fixture server");
	let addr = listener.local_addr().expect("failed to resolve fixture server address");
	listener
		.set_nonblocking(true)
		.expect("failed to configure fixture server listener");

	if let Some(port_file) = port_file {
		std::fs::write(port_file, addr.port().to_string()).expect("failed to write fixture server port file");
	} else {
		println!("{}", addr.port());
	}

	run(listener, addr);
}

fn run(listener: TcpListener, addr: SocketAddr) {
	loop {
		match listener.accept() {
			Ok((stream, _)) => {
				thread::spawn(move || handle_fixture_connection(stream));
			}
			Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
				thread::sleep(Duration::from_millis(25));
			}
			Err(err) => {
				eprintln!("fixture server accept error on {addr}: {err}");
				thread::sleep(Duration::from_millis(100));
			}
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
