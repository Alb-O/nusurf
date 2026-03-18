use std/assert
use ../../nu/cdp

def main [] {
    $env.CDP_BROWSER = {
        session: "browser-a"
        url: "ws://127.0.0.1:9222/devtools/browser/a"
    }
    $env.CDP_PAGE = {
        browserSession: "browser-a"
        session: "page-a"
        targetId: "target-a"
        webSocketDebuggerUrl: "ws://127.0.0.1:9222/devtools/page/a"
    }

    let captured = (cdp context capture)
    assert equal ($captured | columns) [nusurf user plugin]
    assert equal $captured.nusurf.browser.session "browser-a"
    assert equal $captured.nusurf.page.session "page-a"
    assert equal $captured.user {}
    assert equal $captured.plugin {}

    let normalized = (
        cdp context normalize {
            nusurf: {
                browser: $env.CDP_BROWSER
                page: $env.CDP_PAGE
            }
            user: {
                project: "demo"
                profile: "team-a"
            }
            plugin: {
                my_module: {
                    foo: "bar"
                }
            }
        }
    )
    assert equal $normalized.user.project "demo"
    assert equal $normalized.user.profile "team-a"
    assert equal $normalized.plugin.my_module.foo "bar"
    assert equal $normalized.nusurf.browser.session "browser-a"
    assert equal $normalized.nusurf.page.session "page-a"

    let unknown_key_error = (
        try {
            cdp context normalize {
                project: "demo"
            } | ignore
            ""
        } catch {|err|
            $err.msg
        }
    )
    assert ($unknown_key_error | str contains "Unsupported CDP context keys")

    let invalid_nusurf_key_error = (
        try {
            cdp context normalize {
                nusurf: {
                    metadata: {
                        saved_at: 2026-03-17T12:00:00+00:00
                    }
                }
            } | ignore
            ""
        } catch {|err|
            $err.msg
        }
    )
    assert ($invalid_nusurf_key_error | str contains "Unsupported nusurf context keys")

    let invalid_plugin_error = (
        try {
            cdp context normalize {
                plugin: "bad"
            } | ignore
            ""
        } catch {|err|
            $err.msg
        }
    )
    assert ($invalid_plugin_error | str contains "plugin context metadata")
}
