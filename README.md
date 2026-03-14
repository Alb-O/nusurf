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
# Wait for a DevTools target on the default port and open a stable session name
cdp browser open

# Or wait explicitly, then attach
cdp browser wait 9222 --max-time 10sec
cdp browser open 9222 --name browser

# Use the session immediately
cdp call browser "Browser.getVersion"
```

If you need to launch Chromium yourself first, `cdp browser find` locates a supported browser and `cdp browser args` builds sane remote-debugging flags. `cdp browser wait` removes the startup race by polling until DevTools is ready instead of failing immediately.

## Development

Refresh the committed CDP schema artifact with:

```bash
devenv-run -C . update-cdp-schema
```
