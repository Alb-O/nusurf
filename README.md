# nusurf

A [Nushell](https://nushell.sh) plugin for WebSocket I/O, plus a Nu-first Chrome DevTools Protocol layer for browser automation and inspection. The plugin binary exposes the `ws` commands. The `cdp` commands come from the bundled Nushell module.

## Quickstart

Start or attach to a browser, select the current context once, then drive a page with selector-based commands.

```bash
# launch or reuse browser and make it current
let browser = (cdp browser start --use)

# open page and make it current
let page = (cdp page new --use)

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

Page commands default to the current page from `cdp use`, and browser-aware commands default to the current browser. Pass `--page` or `--browser` for explicit routing.

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

## Saving CDP Context

Nusurf does not ship a session registry. The current browser/page selection already lives in `$env.CDP_BROWSER` and `$env.CDP_PAGE`, both as plain Nu records, so saved state is just ordinary Nu data.

If you installed nusurf with the Home Manager module, `cdp.nu` is imported automatically. Otherwise import it explicitly:

```nu
use path/to/nu/cdp.nu *
```

Typical workflow:

```nu
# start or attach to a browser and make it current
let browser = (cdp browser start --use)

# create or select a page and make it current
let page = (cdp page new --url "https://example.com" --use)

# store whatever shape you want
let contexts = {
  work: {
    browser: $env.CDP_BROWSER
    page: $env.CDP_PAGE
    project: "demo"
    profile: "team-a"
  }
}

# persist it with plain NUON
$contexts | to nuon | save -f .nusurf-contexts.nuon

# clear the active browser/page binding in this shell
cdp use --clear

# load and restore it later
let contexts = (open .nusurf-contexts.nuon | from nuon)
cdp use --browser $contexts.work.browser --page $contexts.work.page
```

`cdp browser open`, `cdp browser start`, and `cdp page new` all support `--use` for the common "create or attach, then immediately make current" workflow.

One possible saved shape:

```nu
{
  work: {
    browser: {session: "...", url: "..."}
    page: {
      browserSession: "..."
      session: "..."
      targetId: "..."
      webSocketDebuggerUrl: "..."
    }
    project: "demo"
    profile: "team-a"
    updated_at: 2026-03-17T12:00:00+00:00
  }
}
```

Updates are normal record transforms:

```nu
let contexts = (open .nusurf-contexts.nuon | from nuon)

let contexts = (
  $contexts
  | upsert work {
      browser: $env.CDP_BROWSER
      page: $env.CDP_PAGE
      project: "demo"
      profile: "team-b"
      updated_at: 2026-03-17T12:00:00+00:00
    }
)

$contexts | to nuon | save -f .nusurf-contexts.nuon
```

You can inspect, transform, merge, and serialize this however you like with ordinary Nu pipelines.

## Discoverability

Tab completion sourced directly from upstream CDP schema:

- `cdp call <TAB>` completes open websocket sessions and CDP commands.
- `cdp event <TAB>` completes sessions and CDP event names.
- `cdp schema commands Page`, `cdp schema command Page.navigate`, and `cdp schema search commands navigate` all have matching completer support.

Full schema search:

```bash
cdp schema search navigate
cdp schema search commands screencap
cdp schema search events load
```

## Debugging defaults

The convenience entry points keep raw websocket traffic by default, so `ws recv` works immediately:

- `cdp browser open`
- `cdp browser start`
- `cdp page new`

The raw buffer defaults to `128` for low-level inspection, while still using the higher-level Nu commands:

```bash
let browser = (cdp browser start)
cdp call $browser.session "Browser.getVersion" | ignore
ws recv $browser.session --full
```

## Lower-level usage

The higher-level CDP commands cover the normal browser workflow. The raw websocket layer is also accessible.

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

## Nix / Home Manager

A nix package and Home Manager module are included:

Inside this polyrepo, the package defaults to the shared managed-Cargo catalog
and merge script from `poly-rust-env`.

Example Home Manager usage inside the polyrepo:

```nix
{
  imports = [
    ./repos/nusurf/nix/home-manager.nix
  ];

  programs.nusurf.enable = true;
}
```

Outside the polyrepo, construct the package explicitly and pass the managed
Cargo inputs, then hand that package to the Home Manager module:

```nix
let
  nusurfSrc = builtins.fetchTarball "https://github.com/Alb-O/nusurf/archive/main.tar.gz";
  polyRustEnvSrc = builtins.fetchTarball "https://github.com/Alb-O/poly-rust-env/archive/main.tar.gz";
  nusurf = pkgs.callPackage "${nusurfSrc}/nix/package.nix" {
    managedCargoDir = "${polyRustEnvSrc}/modules/managed-cargo";
  };
in
{
  imports = [ "${nusurfSrc}/nix/home-manager.nix" ];

  programs.nusurf = {
    enable = true;
    package = nusurf;
  };
}
```

## Dev

```sh
update-cdp-schema # refresh bundled CDP schema

# run the Rust test suite
cargo test --test integration_tests --all-features

# run the mock-driven Nu coverage
cargo build --bin nu_plugin_nusurf --bin nusurf_live_fixture_server --all-features
nu --no-config-file -- tests/run_suite.nu mock_all

# run the live browser suites
cargo build --bin nu_plugin_nusurf --bin nusurf_live_fixture_server --all-features
nu --no-config-file -- tests/run_suite.nu browser_all
```

`--verbose` on `tests/run_suite.nu` prints stdout and stderr even on success.
