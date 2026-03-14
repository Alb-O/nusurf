use common.nu *
use browser.nu [resolve-ws-url]
use schema.nu [
    complete-cdp-command
    complete-cdp-event
    validate-command-input
    validate-event-input
]

export def complete-cdp-session [context: string] {
    let prefix = ($context | split words | last | default "" | str downcase)

    {
        options: {
            completion_algorithm: substring
            sort: true
            case_sensitive: false
        }
        completions: (
            ws list
            | where {|entry| ($entry.id | str downcase | str contains $prefix) }
            | each {|entry|
                {
                    value: $entry.id
                    description: $entry.url
                }
            }
        )
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
    --no-validate
    --max-time(-m): duration = 30sec
] {
    if (not $no_validate) {
        validate-command-input $method $params
    }

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
    --no-validate
    --max-time(-m): duration = 30sec
] {
    if ((not $no_validate) and (not (is-nothing $method))) {
        validate-event-input $method
    }

    if (is-nothing $session_id) {
        next-event-once $session $method $max_time
    } else if (is-nothing $method) {
        ws next-event $session --session-id $session_id --max-time $max_time
    } else {
        ws next-event $session $method --session-id $session_id --max-time $max_time
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
