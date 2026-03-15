# nu-plugin-ws

A [Nushell](https://nushell.sh) plugin for WebSocket I/O, plus a Nu-first Chrome DevTools Protocol layer for browser automation and inspection.

## Agent Quickstart

The high-level workflow is: start or attach to a browser, select the current context once, then drive a page with selector-based commands.

```bash
# Launch or reuse a browser on the default CDP port.
let browser = (cdp browser start)

# Make that browser the current context for later commands.
cdp use $browser

# Open a page target and make it current.
let page = (cdp page new)
cdp use $page

# Navigate, wait for the normal load event, then wait for a selector.
cdp page goto "https://example.com/login" --wait-for "form"

# Inspect the DOM from Nu records.
cdp page query "input[name=email]"
cdp page query ".result" --all

# Drive simple interactions through the DOM layer.
cdp page fill "input[name=email]" "agent@example.com"
cdp page click "button[type=submit]"

# Wait for state changes when the page updates asynchronously.
cdp page wait ".flash" --state visible --text "Signed in"

# Clean up when done.
cdp page close
cdp browser stop $browser
```

All page commands default to the current page from `cdp use`, and browser-aware commands default to the current browser. You can still pass `--page` or `--browser` explicitly when you do not want ambient context.

`cdp page wait` and `cdp page query` return normalized element records:

```nu
{
  selector: "button[type=submit]"
  tag: "button"
  id: "submit"
  classes: ["primary"]
  text: "Sign in"
  value: null
  visible: true
  disabled: false
  href: null
  html: "<button ...>"
}
```

## Discoverability

The REPL is meant to be usable without memorizing the CDP schema:

- `cdp call <TAB>` completes open websocket session names and CDP command names.
- `cdp event <TAB>` completes session names and CDP event names.
- `cdp schema commands Page`, `cdp schema command Page.navigate`, and `cdp schema search commands navigate` all have matching completer support.
- `cdp page wait --state <TAB>` suggests `present`, `visible`, `hidden`, and `gone`.

Use schema search when you know roughly what you need but not the exact protocol name:

```bash
cdp schema search navigate
cdp schema search commands screencap
cdp schema search events load
```

Use current-context behavior when you want short commands, and explicit `--page` / `--browser` when you want scripts to be more obvious about routing.

## Debugging Defaults

The convenience entry points keep raw websocket traffic by default so `ws recv` works immediately:

- `cdp browser open`
- `cdp browser start`
- `cdp page new`

That raw buffer now defaults to `128`. This makes it easier to inspect low-level traffic while still using the higher-level Nu commands:

```bash
let browser = (cdp browser start)
cdp call $browser.session "Browser.getVersion" | ignore
ws recv $browser.session --full
```

Low-level `cdp open` still keeps `--raw-buffer` at `0` by default for compatibility and minimal overhead.

## Lower-Level Usage

### One-shot websocket streaming

Use `ws` when one command should open the socket, optionally send input, and stream responses back.

```bash
ws "wss://echo.websocket.org"
echo "Hello WebSocket" | ws "wss://echo.websocket.org" --max-time 2sec
0x[48656c6c6f] | ws "wss://echo.websocket.org"
echo "hello" | ws "wss://api.example.com" --headers {Authorization: "Bearer token123"}
```

### Persistent websocket sessions

```bash
ws open "ws://127.0.0.1:9222/devtools/browser/..." --name cdp
echo '{"id":1,"method":"Browser.getVersion"}' | ws send cdp
ws recv cdp --max-time 2sec
ws recv cdp --max-time 2sec --full
ws list
ws close cdp
```

### Raw CDP helpers

```bash
let browser = (cdp browser start)
cdp call $browser.session "Browser.getVersion"

let page = (cdp page new)
cdp page eval "document.title"
cdp page goto "data:text/html,<main>ok</main>"
cdp page wait "main"
```

`cdp page click` and `cdp page fill` are DOM-driven through `Runtime.evaluate`. They are intended for lightweight agent workflows, not full input synthesis.

## Development

Refresh the bundled CDP schema:

```bash
devenv-run -C . update-cdp-schema
```

Run the Rust test suite plus the mock-driven Nu coverage:

```bash
devenv-run -C . cargo test --test nushell_tests --test nushell_cdp_tests --test integration_tests --all-features
```

Run the live browser suites:

```bash
devenv-run -C . cargo build --bin nu_plugin_ws --bin nu_ws_live_fixture_server --all-features
devenv-run -C . nu --no-config-file --plugins target/debug/nu_plugin_ws -- tests/run_live_browser_suite.nu browser_all
```

Add `--verbose` to `tests/run_live_browser_suite.nu` when you want per-script stdout and stderr even on success.
