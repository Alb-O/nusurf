use std/assert
use cdp.nu *

export def "is nothing" [value: any] {
    ($value | describe) == "nothing"
}

export def "assert nothing" [value: any, message?: string] {
    let error_message = if (is nothing $message) {
        "expected no value"
    } else {
        $message
    }

    assert (is nothing $value) $error_message
}

export def "assert some" [value: any, message?: string] {
    let error_message = if (is nothing $message) {
        "expected a value"
    } else {
        $message
    }

    assert (not (is nothing $value)) $error_message
}

export def "assert str contains-any" [value: string, needles: list<string>, message: string] {
    assert ($needles | any {|needle| $value | str contains $needle }) $message
}

export def "fixture-url" [fixture_port: int, source: string] {
    $"http://127.0.0.1:($fixture_port)/ping?source=($source)"
}

export def "wait-for-target-ws" [http_port: int, target_id: string, --max-time(-m): duration = 5sec] {
    let deadline = (date now) + $max_time

    loop {
        let target = (
            http get $"http://127.0.0.1:($http_port)/json/list"
            | where id == $target_id
            | get -o 0
        )

        if (not (is nothing $target)) {
            let ws_url = ($target | get -o webSocketDebuggerUrl)
            if (not (is nothing $ws_url)) {
                return $ws_url
            }
        }

        if ((date now) >= $deadline) {
            error make { msg: $"Timed out waiting for target ($target_id) websocket" }
        }

        sleep 100ms
    }
}

export def "create-page" [browser_session: string, http_port: int, name: string] {
    let target = (cdp call $browser_session "Target.createTarget" { url: "about:blank", background: true })
    let ws_url = (wait-for-target-ws $http_port $target.targetId)

    cdp open $ws_url --name $name | ignore

    {
        session: $name
        targetId: $target.targetId
        webSocketDebuggerUrl: $ws_url
    }
}

export def "create-attached-page" [browser_session: string, name: string] {
    let target = (cdp call $browser_session "Target.createTarget" { url: "about:blank", background: true })
    let attached = (cdp attach $browser_session $target.targetId)

    {
        session: $name
        targetId: $target.targetId
        attachedSessionId: $attached.sessionId
    }
}

export def "close-page" [browser_session: string, page_session: string, target_id: string] {
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

export def "close-attached-page" [browser_session: string, attached_session: any, target_id: string] {
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

export def "enable-page-basics" [session: string] {
    cdp call $session "Page.enable" | ignore
    cdp call $session "Runtime.enable" | ignore
}

export def "wait-for-load" [session: string, --max-time(-m): duration = 5sec] {
    let load = (cdp event $session "Page.loadEventFired" --max-time $max_time)
    assert some $load $"Timed out waiting for Page.loadEventFired on ($session)"
    $load
}

export def "drain-events" [
    session: string
    --max-time(-m): duration = 50ms
    --iterations(-i): int = 20
] {
    for _ in 0..$iterations {
        let pending = (cdp event $session --max-time $max_time)
        if (is nothing $pending) {
            break
        }
    }
}
