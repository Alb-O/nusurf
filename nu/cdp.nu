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

def command-path [name: string] {
    let hit = (which $name | get -o 0.path)

    if (is-nothing $hit) {
        null
    } else {
        $hit | path expand
    }
}

def resolve-browser-path [candidate: string] {
    let expanded = ($candidate | path expand)

    if ($expanded | path exists) {
        return $expanded
    }

    command-path $candidate
}

def browser-env-candidate [name: string] {
    let raw = ($env | get -o $name)

    if (is-nothing $raw) {
        return null
    }

    let raw_text = ($raw | into string | str trim)
    let direct = (resolve-browser-path $raw_text)

    if (not (is-nothing $direct)) {
        return $direct
    }

    let first = (
        $raw_text
        | split row ":"
        | get -o 0
        | str trim
        | split row " "
        | get -o 0
    )

    if (is-nothing $first) {
        null
    } else {
        resolve-browser-path $first
    }
}

def chromium-browser-candidates [] {
    mut candidates = [
        "google-chrome"
        "google-chrome-stable"
        "chromium"
        "chromium-browser"
        "chrome"
        "brave-browser"
        "microsoft-edge"
        "microsoft-edge-stable"
        "vivaldi"
        "vivaldi-stable"
        "opera"
        "helium"
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
        "/Applications/Chromium.app/Contents/MacOS/Chromium"
    ]

    for base in [
        ($env | get -o ProgramFiles)
        ($env | get -o 'ProgramFiles(x86)')
    ] {
        if (not (is-nothing $base)) {
            $candidates = ($candidates | append $"($base)/Google/Chrome/Application/chrome.exe")
            $candidates = ($candidates | append $"($base)/Microsoft/Edge/Application/msedge.exe")
        }
    }

    $candidates
}

def discover-browser-path [] {
    for candidate in [
        (browser-env-candidate "NU_CDP_BROWSER")
        (browser-env-candidate "BROWSER")
    ] {
        if (not (is-nothing $candidate)) {
            return $candidate
        }
    }

    for candidate in (chromium-browser-candidates) {
        let path = (resolve-browser-path $candidate)
        if (not (is-nothing $path)) {
            return $path
        }
    }

    null
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

export def "cdp browser find" [
    --browser(-b): string
] {
    let path = if (is-nothing $browser) {
        discover-browser-path
    } else {
        resolve-browser-path $browser
    }

    if (is-nothing $path) {
        error make {
            msg: "No Chromium-compatible browser was found. Set NU_CDP_BROWSER or BROWSER, or install a supported browser on PATH."
        }
    }

    $path
}

export def "cdp browser args" [
    --port(-p): int = 9222
    --headless(-h)
    --user-data-dir(-u): string
    --url: string
] {
    mut args = [
        $"--remote-debugging-port=($port)"
        "--remote-allow-origins=*"
        "--no-first-run"
        "--no-default-browser-check"
        "--disable-background-networking"
        "--disable-backgrounding-occluded-windows"
        "--disable-component-update"
        "--disable-default-apps"
        "--disable-hang-monitor"
        "--disable-popup-blocking"
        "--disable-prompt-on-repost"
        "--disable-sync"
        "--disable-blink-features=AutomationControlled" # Otherwise can trigger bot detection
        "--disable-features=Translate"
        "--enable-features=NetworkService,NetworkServiceInProcess"
        "--metrics-recording-only"
        "--password-store=basic"
        "--use-mock-keychain"
    ]

    if $headless {
        $args = ($args | append "--headless=new")
    }

    if (not (is-nothing $user_data_dir)) {
        $args = ($args | append $"--user-data-dir=($user_data_dir)")
    }

    if (not (is-nothing $url)) {
        $args = ($args | append $url)
    }

    $args
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
