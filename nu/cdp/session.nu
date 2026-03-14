use common.nu *
use browser.nu [resolve-ws-url]
use schema.nu [
    complete-cdp-command
    complete-cdp-event
    validate-command-input
    validate-event-input
]

# Complete known websocket session names.
export def complete-cdp-session [
    context: string # Current commandline context.
] {
    let needle = ($context | split words | last | default "" | str downcase)

    {
        options: {
            completion_algorithm: substring
            sort: true
            case_sensitive: false
        }
        completions: (
            ws list
            | where {|entry| ($entry.id | str downcase | str contains $needle) }
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

    match $target_type {
        "string" => $target
        $record_type if ($record_type | str starts-with "record") => {
            let target_id = (
                $target
                | get -o targetId id
                | compact
                | first
            )

            if $target_id != null {
                return $target_id
            }

            error make {
                msg: $"Unsupported CDP target identifier type: ($target_type)"
            }
        }
        _ => {
            error make {
                msg: $"Unsupported CDP target identifier type: ($target_type)"
            }
        }
    }
}

def resolve-session-id [session: any] {
    let session_type = ($session | describe)

    match $session_type {
        "string" => $session
        $record_type if ($record_type | str starts-with "record") => {
            let session_id = (
                $session
                | get -o sessionId
                | compact
                | first
            )

            if $session_id != null {
                return $session_id
            }

            error make {
                msg: $"Unsupported CDP session identifier type: ($session_type)"
            }
        }
        _ => {
            error make {
                msg: $"Unsupported CDP session identifier type: ($session_type)"
            }
        }
    }
}

# Open a websocket session to a browser or page target.
export def "cdp open" [
    target: any # Browser port, discovery URL, websocket URL, or version record.
    --name(-n): string # Session name to register locally.
] {
    let session = ($name | default $"cdp-((random int 1000000000..9999999999))")
    ws open (resolve-ws-url $target) --name $session
}

# Send a validated CDP command and await its response.
export def "cdp call" [
    session: string # Open websocket session name.
    method: string # Qualified CDP command name.
    params?: any # Command params record.
    --id: int # Explicit request id to use.
    --session-id(-s): string # Attached target session id.
    --no-validate # Skip schema validation before sending.
    --max-time(-m): duration = 30sec # Maximum time to wait for a response.
] {
    if (not $no_validate) {
        validate-command-input $method $params
    }

    let request_id = if $id == null { random-id } else { $id }
    let command = (
        {
            id: $request_id
            method: $method
            params: $params
            sessionId: $session_id
        }
        | compact
    )

    $command | ws send-json $session

    let response = (ws await $session $request_id --max-time $max_time)

    if $response == null {
        error make {
            msg: $"Timed out waiting for CDP response to ($method)"
        }
    }

    let response_error = ($response | get -o error)

    if $response_error != null {
        error make {
            msg: $"CDP command ($method) failed: ($response_error)"
        }
    }

    let response_result = ($response | get -o result)

    if $response_result != null {
        $response_result
    } else {
        null
    }
}

# Read the next CDP event, optionally filtered by method or attached session.
export def "cdp event" [
    session: string # Open websocket session name.
    method?: string # Qualified CDP event name to filter on.
    --session-id(-s): string # Attached target session id to filter on.
    --no-validate # Skip schema validation before listening.
    --max-time(-m): duration = 30sec # Maximum time to wait for an event.
] {
    if ((not $no_validate) and ($method != null)) {
        validate-event-input $method
    }

    match [$session_id $method] {
        [null null] => (ws next-event $session --max-time $max_time)
        [null _] => (ws next-event $session $method --max-time $max_time)
        [_ null] => (ws next-event $session --session-id $session_id --max-time $max_time)
        _ => (ws next-event $session $method --session-id $session_id --max-time $max_time)
    }
}

# Attach a browser session to a target and return the attached session metadata.
export def "cdp attach" [
    session: string # Browser websocket session name.
    target: any # Target id or target record.
    --flatten(-f) = true # Request flattened session routing.
    --max-time(-m): duration = 30sec # Maximum time to wait for the attach result.
] {
    cdp call $session "Target.attachToTarget" {
        targetId: (resolve-target-id $target)
        flatten: $flatten
    } --max-time $max_time
}

# Detach an attached target session from the browser session.
export def "cdp detach" [
    session: string # Browser websocket session name.
    attached_session: any # Attached session id or attached session record.
    --max-time(-m): duration = 30sec # Maximum time to wait for the detach result.
] {
    cdp call $session "Target.detachFromTarget" {
        sessionId: (resolve-session-id $attached_session)
    } --max-time $max_time
}

# Close a websocket session by name.
export def "cdp close" [
    session: string # Open websocket session name.
] {
    ws close $session
}
