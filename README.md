# nusurf

A [Nushell](https://nushell.sh) plugin for WebSocket I/O, plus a Nu-first Chrome DevTools Protocol layer for browser automation and inspection. The plugin binary exposes the `ws` commands. The `cdp` commands come from the bundled Nushell module.

## Quickstart

Browser and page commands use the selected `cdp use` context.

```bash
# launch browser, set new page and navigate
let browser = (cdp browser start --use)
let page = (cdp page new --use)
cdp page goto "https://example.com/login" --wait-for "form"

# DOM interaction
cdp page query "input[name=email]"
cdp page query ".result" --all
cdp page fill "input[name=email]" "agent@example.com"
cdp page click "button[type=submit]"

# wait for page state
cdp page wait ".flash" --state visible --text "Signed in"

# cleanup
cdp page close
cdp browser stop $browser
```

Page commands default to the page selected by `cdp use`. Browser-aware commands default to the selected browser. Pass `--page` or `--browser` for explicit routing.

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

`$env.CDP_BROWSER` and `$env.CDP_PAGE` are plain Nu records. Saved state is ordinary Nu data.

To avoid ownership ambiguity, nusurf reserves these top-level keys in a saved context record:

- `nusurf`: nusurf-owned data under `nusurf.browser` and `nusurf.page`
- `user`: caller-owned metadata like `project` or `profile`
- `ext`: extension/module-owned data under `ext.<namespace>`

`project` and `profile` are not nusurf fields. They belong under `user` unless a module owns them under `ext.<namespace>`.

The Home Manager module imports `cdp.nu`. Otherwise:

```nu
use path/to/nu/cdp.nu *
```

Example:

```nu
let browser = (cdp browser start --use)
let page = (cdp page new --url "https://example.com" --use)

# context record
let work = (
  cdp context capture
  | upsert user {
      project: "demo"
      profile: "team-a"
    }
)

let contexts = {work: $work}

# save to NUON file
$contexts | to nuon | save -f .nusurf-contexts.nuon

# clear shell binding
cdp use --clear

# read NUON and apply binding
let contexts = (open .nusurf-contexts.nuon | from nuon)
cdp use --browser $contexts.work.nusurf.browser --page $contexts.work.nusurf.page
```

Example saved NUON:

```nu
{
  work: {
    nusurf: {
      browser: {session: "...", url: "..."}
      page: {
        browserSession: "..."
        session: "..."
        targetId: "..."
        webSocketDebuggerUrl: "..."
      }
    }
    user: {
      project: "demo"
      profile: "team-a"
    }
    ext: {
      my_module: {
        cache_key: "demo"
      }
    }
  }
}
```

Saved context files are user-managed Nu data. Nusurf does not rewrite them.

Edit `user` and `ext` freely. Leave `nusurf.browser` and `nusurf.page` to nusurf. `cdp context normalize` checks shape and ownership. It does not check whether browser/page records still point to live CDP sessions.

Example update:

```nu
let contexts = (open .nusurf-contexts.nuon | from nuon)

let contexts = (
  $contexts
  | upsert work {
      nusurf: {
        browser: $env.CDP_BROWSER
        page: $env.CDP_PAGE
      }
      user: {
        project: "demo"
        profile: "team-b"
      }
      ext: ($contexts.work | get -o ext | default {})
    }
)

$contexts | to nuon | save -f .nusurf-contexts.nuon
```

`cdp context normalize` validates this reserved shape. Storage, transforms, and serialization stay in ordinary Nu pipelines.

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

The convenience entry points keep raw websocket traffic by default, so `ws recv` works without extra setup:

- `cdp browser open`
- `cdp browser start`
- `cdp page new`

The raw buffer default is `128`:

```bash
let browser = (cdp browser start)
cdp call $browser.session "Browser.getVersion" | ignore
ws recv $browser.session --full
```

## Lower-level usage

The higher-level CDP commands cover browser automation and inspection. The raw websocket layer is also available.

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
