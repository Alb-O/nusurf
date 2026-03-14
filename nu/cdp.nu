def is-nothing [value: any] {
    ($value | describe) == "nothing"
}

def has-column [value: any, column: string] {
    if (is-nothing $value) {
        false
    } else {
        $value | columns | any {|name| $name == $column }
    }
}

def random-id [] {
    # Real Chromium targets round-trip JSON numeric ids through a JS-safe range.
    random int 1..2147483647
}

def json-version-url [target: any] {
    let target_type = ($target | describe)

    if $target_type == "int" {
        return $"http://127.0.0.1:($target)/json/version"
    }

    if $target_type == "string" {
        if ($target | str ends-with "/json/version") {
            return $target
        }

        if (($target | str starts-with "http://") or ($target | str starts-with "https://")) {
            let trimmed = ($target | str trim -r -c "/")
            return $"($trimmed)/json/version"
        }
    }

    error make {
        msg: $"Unsupported CDP discovery target type: ($target_type)"
    }
}

def resolve-ws-url [target: any] {
    let target_type = ($target | describe)

    if $target_type == "int" {
        let info = (http get (json-version-url $target))
        let ws_url = ($info | get -o webSocketDebuggerUrl)

        if (is-nothing $ws_url) {
            error make { msg: $"No webSocketDebuggerUrl in ($target | into string)" }
        }

        return $ws_url
    }

    if $target_type == "string" {
        if (($target | str starts-with "ws://") or ($target | str starts-with "wss://")) {
            return $target
        }

        if (($target | str starts-with "http://") or ($target | str starts-with "https://") or ($target | str ends-with "/json/version")) {
            let info = (http get (json-version-url $target))
            let ws_url = ($info | get -o webSocketDebuggerUrl)

            if (is-nothing $ws_url) {
                error make { msg: $"No webSocketDebuggerUrl in ($target)" }
            }

            return $ws_url
        }
    }

    if ($target_type | str starts-with "record") {
        let ws_url = ($target | get -o webSocketDebuggerUrl)

        if (is-nothing $ws_url) {
            error make { msg: "Expected record with webSocketDebuggerUrl" }
        }

        return $ws_url
    }

    error make {
        msg: $"Unsupported CDP target type: ($target_type)"
    }
}

def resolve-target-id [target: any] {
    let target_type = ($target | describe)

    if $target_type == "string" {
        return $target
    }

    if ($target_type | str starts-with "record") {
        let target_id = ($target | get -o targetId)
        if (not (is-nothing $target_id)) {
            return $target_id
        }

        let id = ($target | get -o id)
        if (not (is-nothing $id)) {
            return $id
        }
    }

    error make {
        msg: $"Unsupported CDP target identifier type: ($target_type)"
    }
}

def resolve-session-id [session: any] {
    let session_type = ($session | describe)

    if $session_type == "string" {
        return $session
    }

    if ($session_type | str starts-with "record") {
        let session_id = ($session | get -o sessionId)
        if (not (is-nothing $session_id)) {
            return $session_id
        }
    }

    error make {
        msg: $"Unsupported CDP session identifier type: ($session_type)"
    }
}

def next-event-once [session: string, method: any, timeout: duration] {
    if (is-nothing $method) {
        ws next-event $session --max-time $timeout
    } else {
        ws next-event $session $method --max-time $timeout
    }
}

export def "cdp discover" [target: any] {
    resolve-ws-url $target
}

export def "cdp open" [
    target: any
    --name(-n): string
] {
    let session = if (is-nothing $name) {
        $"cdp-((random int 1000000000..9999999999))"
    } else {
        $name
    }

    let ws_url = (resolve-ws-url $target)
    ws open $ws_url --name $session
}

export def "cdp call" [
    session: string
    method: string
    params?: any
    --id: int
    --session-id(-s): string
    --max-time(-m): duration = 30sec
] {
    let request_id = if (is-nothing $id) { random-id } else { $id }

    mut command = {
        id: $request_id
        method: $method
    }

    if (not (is-nothing $params)) {
        $command = ($command | upsert params $params)
    }

    if (not (is-nothing $session_id)) {
        $command = ($command | upsert sessionId $session_id)
    }

    $command | ws send-json $session

    let response = (ws await $session $request_id --max-time $max_time)

    if (is-nothing $response) {
        error make {
            msg: $"Timed out waiting for CDP response to ($method)"
        }
    }

    if (has-column $response "error") {
        error make {
            msg: $"CDP command ($method) failed: ($response.error)"
        }
    }

    if (has-column $response "result") {
        $response.result
    } else {
        null
    }
}

export def "cdp event" [
    session: string
    method?: string
    --session-id(-s): string
    --max-time(-m): duration = 30sec
] {
    if (is-nothing $session_id) {
        next-event-once $session $method $max_time
    } else {
        if (is-nothing $method) {
            ws next-event $session --session-id $session_id --max-time $max_time
        } else {
            ws next-event $session $method --session-id $session_id --max-time $max_time
        }
    }
}

export def "cdp attach" [
    session: string
    target: any
    --flatten(-f) = true
    --max-time(-m): duration = 30sec
] {
    cdp call $session "Target.attachToTarget" {
        targetId: (resolve-target-id $target)
        flatten: $flatten
    } --max-time $max_time
}

export def "cdp detach" [
    session: string
    attached_session: any
    --max-time(-m): duration = 30sec
] {
    cdp call $session "Target.detachFromTarget" {
        sessionId: (resolve-session-id $attached_session)
    } --max-time $max_time
}

export def "cdp close" [session: string] {
    ws close $session
}
