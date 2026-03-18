# nusurf

A [Nushell](https://nushell.sh) plugin for WebSocket I/O and [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol) interaction for fully Nu-driven browser control (no Playwright or other similar libs!)

The plugin binary exposes the `ws` command. The `cdp` command come from the bundled Nushell module.

## Quickstart

Browser and page commands use the selected `cdp focus` context.

```bash
# launch browser, set new page and navigate
let browser = (cdp browser start --focus)
let page = (cdp page new --focus)
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

Page commands default to the page selected by `cdp focus`. Browser-aware commands default to the selected browser. Pass `--page` or `--browser` for explicit routing.

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
- `plugin`: plugin-owned data under `plugin.<namespace>`

The Home Manager module imports `cdp`. Otherwise:

```nu
use path/to/nu/cdp
```

Example:

```nu
let browser = (cdp browser start --focus)
let page = (cdp page new --url "https://example.com" --focus)

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
cdp focus --clear

# read NUON and apply binding
let contexts = (open .nusurf-contexts.nuon | from nuon)
cdp focus --browser $contexts.work.nusurf.browser --page $contexts.work.nusurf.page
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
    plugin: {
      my_module: {
        cache_key: "demo"
      }
    }
  }
}
```

Saved context files are user-managed Nu data. Nusurf does not rewrite them.

Edit `user` freely. Treat `plugin` as plugin-owned data and `nusurf.browser` and `nusurf.page` as saved CDP connection data. `cdp context normalize` checks shape and ownership. It does not check whether browser/page records still point to live CDP sessions.

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
      plugin: ($contexts.work | get -o plugin | default {})
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

Example Home Manager usage inside the polyrepo:

```nix
{
  imports = [
    ./repos/nusurf/nix/home-manager.nix
  ];

  programs.nusurf = {
    enable = true;
    managedCargoDir = ./repos/poly-rust-env/modules/managed-cargo;
  };
}
```

Outside the polyrepo, pass the managed-Cargo path explicitly:

```nix
let
  nusurfSrc = builtins.fetchTarball "https://github.com/Alb-O/nusurf/archive/main.tar.gz";
  polyRustEnvSrc = builtins.fetchTarball "https://github.com/Alb-O/poly-rust-env/archive/main.tar.gz";
in
{
  imports = [ "${nusurfSrc}/nix/home-manager.nix" ];

  programs.nusurf = {
    enable = true;
    managedCargoDir = "${polyRustEnvSrc}/modules/managed-cargo";
  };
}
```

You can still pass `programs.nusurf.package` explicitly, but the module no
longer assumes sibling repo checkouts exist.

## Devenv

For local polyrepo development, `nusurf` is also exposed as a shared `devenv`
import surface. The superproject's generated `devenv.local.yaml` now injects:

```yaml
inputs:
  nusurf:
    url: path:/agent/repos/nusurf
    flake: false
imports:
  - nusurf/nushell-plugin
```

That import adds:

- `nu_plugin_nusurf` to the shell packages
- `nu` to the shell packages
- `$NUSURF_PLUGIN` with the plugin binary path
- `$NUSURF_CDP_MODULE` with the bundled `cdp` module path
- `nu-with-nusurf` as a stable helper for local interactive use

Example:

```sh
nu-with-nusurf -c 'help ws'
nu-with-nusurf -c "use $env.NUSURF_CDP_MODULE; help cdp"
devenv-run -C . --shell 'command -v nu-with-nusurf'
```

## Dev

```sh
update-cdp-schema # refresh bundled CDP schema

# run the Rust test suite
cargo test --test integration_tests --all-features

# run the mock-driven Nu coverage
cargo build --bin nu_plugin_nusurf --bin nusurf_live_fixture_server --all-features
./tests/run_suite mock_all

# run the live browser suites
cargo build --bin nu_plugin_nusurf --bin nusurf_live_fixture_server --all-features
./tests/run_suite browser_all
```

`--verbose` on `./tests/run_suite` prints stdout and stderr even on success.
