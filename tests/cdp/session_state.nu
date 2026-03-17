use std/assert
use cdp.nu *

def main [] {
    let enabled = (cdp session enable)
    assert equal $enabled.kind "nusurf/cdp-session-state"
    assert equal $enabled.version 1
    assert equal ($enabled.sessions | length) 0
    assert equal $enabled.current null

    let initial_state = (cdp session state)
    assert equal $initial_state.kind "nusurf/cdp-session-state"
    assert equal $initial_state.version 1
    assert equal $initial_state.currentSession null
    assert equal $initial_state.sessions {}

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

    let state_after_save = (cdp session state)
    assert equal $state_after_save.currentSession "work"
    assert equal (($state_after_save.sessions | columns) | length) 1
    assert equal (($state_after_save.sessions | get work.name)) "work"

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

    let exported_path = (mktemp --suffix ".nuon")
    let exported = (cdp session export $exported_path)
    assert equal ($exported | path exists) true

    let exported_state = (open --raw $exported | from nuon)
    assert equal $exported_state.kind "nusurf/cdp-session-state"
    assert equal $exported_state.version 1
    assert equal $exported_state.currentSession "work"
    assert equal (($exported_state.sessions | get work.profile)) "team-b"

    let dropped = (cdp session drop)
    assert equal $dropped.name "work"
    assert equal ((cdp session list) | length) 0
    assert equal (cdp session current) null

    let imported = (cdp session import $exported)
    assert equal $imported.kind "nusurf/cdp-session-state"
    assert equal $imported.version 1
    assert equal $imported.currentSession "work"
    assert equal (($imported.sessions | get work.project)) "g-p-demo"
    assert equal (($imported.sessions | get work.profile)) "team-b"

    let reused = (cdp session use work)
    assert equal $reused.name "work"
    assert equal ($env.CDP_BROWSER.session) "browser-a"
    assert equal ($env.CDP_PAGE.session) "page-a"

    let invalid_state_path = (mktemp --suffix ".nuon")
    {
        kind: "nusurf/cdp-session-state"
        version: 1
        currentSession: "missing"
        sessions: {}
    } | to nuon | save -f $invalid_state_path

    let import_error = (
        try {
            cdp session import $invalid_state_path | ignore
            ""
        } catch {|err|
            $err.msg
        }
    )
    assert ($import_error | str contains "unknown current session")

    rm -f $exported
    rm -f $invalid_state_path
}
