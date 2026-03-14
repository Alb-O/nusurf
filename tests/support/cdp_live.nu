use std/assert
use cdp.nu *

# Return whether a value is Nushell `nothing`.
export def "is nothing" [
    value: any # Value to inspect.
] {
    ($value | describe) == "nothing"
}

# Assert that a value is Nushell `nothing`.
export def "assert nothing" [
    value: any # Value expected to be `nothing`.
    message?: string # Optional assertion message override.
] {
    let error_message = if (is nothing $message) {
        "expected no value"
    } else {
        $message
    }

    assert (is nothing $value) $error_message
}

# Assert that a value is present.
export def "assert some" [
    value: any # Value expected to be present.
    message?: string # Optional assertion message override.
] {
    let error_message = if (is nothing $message) {
        "expected a value"
    } else {
        $message
    }

    assert (not (is nothing $value)) $error_message
}

# Assert that a string contains at least one of the given needles.
export def "assert str contains-any" [
    value: string # String to inspect.
    needles: list<string> # Candidate substrings to match.
    message: string # Assertion message on failure.
] {
    assert ($needles | any {|needle| $value | str contains $needle }) $message
}

# Build a fixture server URL tagged with a source label.
export def "fixture-url" [
    fixture_port: int # Fixture server port.
    source: string # Source label to include in the query string.
] {
    $"http://127.0.0.1:($fixture_port)/ping?source=($source)"
}

# Wait for a target to expose its websocket debugger URL.
export def "wait-for-target-ws" [
    http_port: int # Browser HTTP discovery port.
    target_id: string # Target id to wait for.
    --max-time(-m): duration = 5sec # Maximum time to wait for the websocket URL.
] {
    let deadline = (date now) + $max_time

    loop {
        let ws_url = (
            http get $"http://127.0.0.1:($http_port)/json/list"
            | where id == $target_id
            | get -o 0.webSocketDebuggerUrl
        )

        if (not (is nothing $ws_url)) {
            return $ws_url
        }

        if ((date now) >= $deadline) {
            error make { msg: $"Timed out waiting for target ($target_id) websocket" }
        }

        sleep 100ms
    }
}

# Create a page target and open a named websocket session to it.
export def "create-page" [
    browser_session: string # Browser websocket session name.
    http_port: int # Browser HTTP discovery port.
    name: string # Page websocket session name.
] {
    let target = (
        cdp call $browser_session "Target.createTarget" {
            url: "about:blank"
            background: true
        }
    )
    let ws_url = (wait-for-target-ws $http_port $target.targetId)

    cdp open $ws_url --name $name | ignore

    {
        session: $name
        targetId: $target.targetId
        webSocketDebuggerUrl: $ws_url
    }
}

# Create a page target and attach it through the browser session.
export def "create-attached-page" [
    browser_session: string # Browser websocket session name.
    name: string # Logical page name stored in the returned record.
] {
    let target = (
        cdp call $browser_session "Target.createTarget" {
            url: "about:blank"
            background: true
        }
    )
    let attached = (cdp attach $browser_session $target.targetId)

    {
        session: $name
        targetId: $target.targetId
        attachedSessionId: $attached.sessionId
    }
}

# Close a browser websocket session and ignore transport failures.
export def "close-browser" [
    browser_session: string # Browser websocket session name.
] {
    try {
        cdp close $browser_session | ignore
    } catch {
        null
    }
}

# Close a page target and its websocket session.
export def "close-page" [
    browser_session: string # Browser websocket session name.
    page_session: string # Page websocket session name.
    target_id: string # Target id to close in the browser session.
] {
    try {
        cdp call $browser_session "Target.closeTarget" { targetId: $target_id } | ignore
    } catch {
        null
    }

    try {
        cdp close $page_session | ignore
    } catch {
        null
    }
}

# Detach an attached page session and close its target.
export def "close-attached-page" [
    browser_session: string # Browser websocket session name.
    attached_session: any # Attached session id or attached session record.
    target_id: string # Target id to close in the browser session.
] {
    try {
        cdp detach $browser_session $attached_session | ignore
    } catch {
        null
    }

    try {
        cdp call $browser_session "Target.closeTarget" { targetId: $target_id } | ignore
    } catch {
        null
    }
}

# Enable the common Page and Runtime domains for a session.
export def "enable-page-basics" [
    session: string # Browser or page websocket session name.
] {
    cdp call $session "Page.enable" | ignore
    cdp call $session "Runtime.enable" | ignore
}

# Wait for one Page.loadEventFired event on a session.
export def "wait-for-load" [
    session: string # Browser or page websocket session name.
    --max-time(-m): duration = 5sec # Maximum time to wait for the load event.
] {
    let load = (cdp event $session "Page.loadEventFired" --max-time $max_time)
    assert some $load $"Timed out waiting for Page.loadEventFired on ($session)"
    $load
}

# Drain pending events from a session until it goes idle or hits an iteration cap.
export def "drain-events" [
    session: string # Browser or page websocket session name.
    --max-time(-m): duration = 50ms # Maximum time to wait per event poll.
    --iterations(-i): int = 20 # Maximum polls before stopping.
] {
    for _ in 0..$iterations {
        let pending = (cdp event $session --max-time $max_time)
        if (is nothing $pending) {
            break
        }
    }
}
