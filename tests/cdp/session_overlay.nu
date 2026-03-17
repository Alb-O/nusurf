use std/assert
use cdp.nu *

def main [] {
    let enabled = (cdp session enable)
    assert equal $enabled.overlay "nusurf-session"
    assert equal ($enabled.sessions | length) 0
    assert equal $enabled.current null

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

    let saved = (cdp session save work --project "g-p-demo" --profile "team-a")
    assert equal $saved.name "work"
    assert equal $saved.browser.session "browser-a"
    assert equal $saved.page.session "page-a"
    assert equal $saved.project "g-p-demo"
    assert equal $saved.profile "team-a"

    let sessions = (cdp session list)
    assert equal ($sessions | length) 1
    assert equal ($sessions | get 0.name) "work"
    assert equal ($sessions | get 0.current) true
    assert equal ($sessions | get 0.browserSession) "browser-a"
    assert equal ($sessions | get 0.pageSession) "page-a"

    cdp use --clear | ignore

    let cleared = (cdp session current)
    assert equal ($cleared.browser.session) "browser-a"
    assert equal ($cleared.page.session) "page-a"

    let updated = (cdp session save --profile "team-b")
    assert equal $updated.profile "team-b"
    assert equal $updated.project "g-p-demo"
    assert equal $updated.browser.session "browser-a"
    assert equal $updated.page.session "page-a"

    let reused = (cdp session use work)
    assert equal $reused.name "work"
    assert equal ($env.CDP_BROWSER.session) "browser-a"
    assert equal ($env.CDP_PAGE.session) "page-a"

    let dropped = (cdp session drop)
    assert equal $dropped.name "work"
    assert equal ((cdp session list) | length) 0
    assert equal (cdp session current) null
}
