# nu-plugin-ws

A [Nushell](https://nushell.sh) plugin for WebSocket I/O. It supports one-shot streaming and persistent sessions for protocols like CDP.

## Usage

### One-shot streaming

Use `ws` when one command should open the socket, optionally send input, and stream responses back.

```bash
# Listen only
ws "wss://echo.websocket.org"

# Send text
echo "Hello WebSocket" | ws "wss://echo.websocket.org" --max-time 2sec

# Send binary
0x[48656c6c6f] | ws "wss://echo.websocket.org"

# Custom headers
echo "hello" | ws "wss://api.example.com" --headers {Authorization: "Bearer token123"}
```

Use `--max-time` when the server keeps the socket open and you want the command to exit after a response.

### Persistent sessions

Use persistent sessions for stateful protocols and long-lived connections.

```bash
# Open a named session
ws open "ws://127.0.0.1:9222/devtools/browser/..." --name cdp

# Send and receive raw messages
echo '{"id":1,"method":"Browser.getVersion"}' | ws send cdp
ws recv cdp --max-time 2sec
ws recv cdp --max-time 2sec --full

# List and close sessions
ws list
ws close cdp
```

### JSON routing for CDP-style traffic

Persistent sessions also support JSON-aware helpers for mixed response/event traffic.

```bash
{
  id: 1,
  method: "Browser.getVersion",
  params: {}
} | ws send-json cdp

# Read the next JSON message from the raw stream
ws recv-json cdp --max-time 2sec

# Wait for a response with a specific id
ws await cdp 1 --max-time 2sec

# Read the next routed event, optionally filtered by method
ws next-event cdp "Target.attachedToTarget" --max-time 2sec
```

`ws recv` exposes the raw message stream. `ws recv-json`, `ws await`, and `ws next-event` sit on top of the same session and separate JSON responses from async events.

### CDP browser sessions

The bundled `cdp` helpers smooth out the common browser workflow.

```bash
# Launch a fresh browser, wait for DevTools, and get a reusable workflow record
let browser = (cdp browser start)

# Use the session immediately
cdp call $browser.session "Browser.getVersion"

# Clean up when done
cdp browser stop $browser
```

If a browser is already running on the target port, `cdp browser start` will reuse it instead of launching a second one. `cdp browser find` and `cdp browser args` are still available when you want lower-level control, and `cdp browser wait` removes the startup race by polling until DevTools is ready instead of failing immediately.

## Development

Refresh the committed CDP schema artifact with:

```bash
devenv-run -C . update-cdp-schema
```

Run the Rust test suite for the core engine, plugin behavior, and mock-driven Nu coverage with:

```bash
cargo test --test nushell_tests --test nushell_cdp_tests --test integration_tests --all-features
```

Run the live browser suites through Nu so the Nu workflow layer owns orchestration:

```bash
cargo build --bin nu_plugin_ws --bin nu_ws_live_fixture_server --all-features
nu --no-config-file --plugins target/debug/nu_plugin_ws -- tests/run_live_browser_suite.nu browser-all
```
