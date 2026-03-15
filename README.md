# nusurf

A [Nushell](https://nushell.sh) plugin for WebSocket I/O, plus a Nu-first Chrome DevTools Protocol layer for browser automation and inspection.

## Quickstart

Start or attach to a browser, select the current context once, then drive a page with selector-based commands.

```bash
# launch or reuse browser
let browser = (cdp browser start)

# set current browser
cdp use $browser

# open page, make current
let page = (cdp page new)
cdp use $page

# navigate, then wait for selector
cdp page goto "https://example.com/login" --wait-for "form"

# inspect DOM
cdp page query "input[name=email]"
cdp page query ".result" --all

# fill and click
cdp page fill "input[name=email]" "agent@example.com"
cdp page click "button[type=submit]"

# wait for async update
cdp page wait ".flash" --state visible --text "Signed in"

# cleanup
cdp page close
cdp browser stop $browser
```

Page commands default to the current page from `cdp use`, and browser-aware commands default to the current browser. Pass `--page` or `--browser` when you want explicit routing.

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

Tab completion sourced directly from upstream CDP schema:

- `cdp call <TAB>` completes open websocket session names and CDP command names.
- `cdp event <TAB>` completes session names and CDP event names.
- `cdp schema commands Page`, `cdp schema command Page.navigate`, and `cdp schema search commands navigate` all have matching completer support.
- `cdp page wait --state <TAB>` suggests `present`, `visible`, `hidden`, and `gone`.

Use schema search when you know the shape of a command or event but not its exact name:

```bash
cdp schema search navigate
cdp schema search commands screencap
cdp schema search events load
```

Use current context for short commands, and explicit `--page` / `--browser` when you want scripts to be more obvious.

## Debugging defaults

The convenience entry points keep raw websocket traffic by default, so `ws recv` works immediately:

- `cdp browser open`
- `cdp browser start`
- `cdp page new`

The raw buffer now defaults to `128`, which makes low-level inspection easier while still using the higher-level Nu commands:

```bash
let browser = (cdp browser start)
cdp call $browser.session "Browser.getVersion" | ignore
ws recv $browser.session --full
```

Low-level `cdp open` still defaults `--raw-buffer` to `0` for compatibility and minimal overhead.

## Lower-level usage

The higher-level CDP commands cover the normal browser workflow. Drop to the raw websocket layer when you need a one-off socket or a protocol the CDP helpers do not model.

### One-shot websocket streaming

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

`cdp page click` and `cdp page fill` stay intentionally lightweight: they are DOM-driven through `Runtime.evaluate`, not true input synthesis.

## Dev

Refresh the bundled CDP schema:

```bash
devenv-run -C . update-cdp-schema
```

Run the Rust test suite:

```bash
devenv-run -C . cargo test --test integration_tests --all-features
```

Run the mock-driven Nu coverage:

```bash
devenv-run -C . cargo build --bin nu_plugin_nusurf --bin nusurf_live_fixture_server --all-features
devenv-run -C . nu --no-config-file -- tests/run_suite.nu mock_all
```

Run the live browser suites:

```bash
devenv-run -C . cargo build --bin nu_plugin_nusurf --bin nusurf_live_fixture_server --all-features
devenv-run -C . nu --no-config-file -- tests/run_suite.nu browser_all
```

Add `--verbose` to `tests/run_suite.nu` to print per-script stdout and stderr even on success.
