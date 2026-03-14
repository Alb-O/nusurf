const cdp_schema_files = [
    (path self ../schema/cdp/browser_protocol.json)
    (path self ../schema/cdp/js_protocol.json)
]

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

def schema-domains-raw [] {
    $cdp_schema_files
    | each {|path|
        open $path | get domains
    }
    | flatten
}

def schema-domains [domain?: string] {
    let domains = (schema-domains-raw)

    if (is-nothing $domain) {
        $domains
    } else {
        $domains | where domain == $domain
    }
}

def enrich-command [domain_name: string, command: record] {
    $command
    | upsert domain $domain_name
    | upsert qualified $"($domain_name).($command.name)"
}

def enrich-event [domain_name: string, event: record] {
    $event
    | upsert domain $domain_name
    | upsert qualified $"($domain_name).($event.name)"
}

def enrich-type [domain_name: string, type_def: record] {
    $type_def
    | upsert domain $domain_name
    | upsert qualified $"($domain_name).($type_def.id)"
}

def schema-commands [domain?: string] {
    schema-domains $domain
    | each {|domain_record|
        let domain_name = $domain_record.domain
        ($domain_record | get -o commands | default [])
        | each {|command| enrich-command $domain_name $command }
    }
    | flatten
}

def schema-events [domain?: string] {
    schema-domains $domain
    | each {|domain_record|
        let domain_name = $domain_record.domain
        ($domain_record | get -o events | default [])
        | each {|event| enrich-event $domain_name $event }
    }
    | flatten
}

def schema-types [domain?: string] {
    schema-domains $domain
    | each {|domain_record|
        let domain_name = $domain_record.domain
        ($domain_record | get -o types | default [])
        | each {|type_def| enrich-type $domain_name $type_def }
    }
    | flatten
}

def parse-qualified [qualified: string] {
    let parts = ($qualified | split row ".")

    if (($parts | length) != 2) {
        error make {
            msg: $"Expected a qualified CDP name like Domain.member, got: ($qualified)"
        }
    }

    {
        domain: ($parts | get 0)
        member: ($parts | get 1)
    }
}

def schema-lookup [kind: string, qualified: string] {
    let parsed = (parse-qualified $qualified)

    let entries = match $kind {
        "command" => (schema-commands $parsed.domain)
        "event" => (schema-events $parsed.domain)
        "type" => (schema-types $parsed.domain)
        _ => (error make { msg: $"Unsupported CDP schema lookup kind: ($kind)" })
    }

    let entry = ($entries | where qualified == $qualified | get -o 0)

    if (is-nothing $entry) {
        error make {
            msg: $"No CDP ($kind) named ($qualified)"
        }
    }

    $entry
}

def entry-member [entry: record] {
    let name = ($entry | get -o name)

    if (is-nothing $name) {
        $entry | get id
    } else {
        $name
    }
}

def enrich-search-entry [kind: string, entry: record] {
    $entry
    | upsert kind $kind
    | upsert member (entry-member $entry)
}

def schema-search-kind [kind: string, query: string] {
    let needle = ($query | str downcase)

    let entries = match $kind {
        "command" => (schema-commands)
        "event" => (schema-events)
        "type" => (schema-types)
        _ => (error make { msg: $"Unsupported CDP schema search kind: ($kind)" })
    }

    $entries
    | each {|entry| enrich-search-entry $kind $entry }
    | where {|entry|
        let qualified = ($entry.qualified | str downcase)
        let member = ($entry.member | into string | str downcase)
        let description = ($entry | get -o description | default "" | into string | str downcase)

        (($qualified | str contains $needle)
            or ($member | str contains $needle)
            or ($description | str contains $needle))
    }
}

def schema-command-parameter-names [command: record] {
    ($command | get -o parameters | default [])
    | each {|parameter| $parameter.name }
}

def schema-command-required-parameter-names [command: record] {
    ($command | get -o parameters | default [])
    | where {|parameter| (($parameter | get -o optional) | default false) == false }
    | each {|parameter| $parameter.name }
}

def validate-command-params [method: string, params: any, command: record] {
    let allowed = (schema-command-parameter-names $command)
    let required = (schema-command-required-parameter-names $command)

    let param_record = if (is-nothing $params) {
        {}
    } else {
        let param_type = ($params | describe)

        if (not ($param_type | str starts-with "record")) {
            error make {
                msg: $"CDP command ($method) params must be a record, got: ($param_type)"
            }
        }

        $params
    }

    let keys = ($param_record | columns)
    let unknown = ($keys | where {|name| not ($allowed | any {|allowed_name| $allowed_name == $name }) })
    let missing = ($required | where {|name| not ($keys | any {|param_name| $param_name == $name }) })

    if (($unknown | length) > 0) {
        error make {
            msg: $"Unknown CDP params for ($method): (($unknown | str join ', '))"
        }
    }

    if (($missing | length) > 0) {
        error make {
            msg: $"Missing required CDP params for ($method): (($missing | str join ', '))"
        }
    }
}

def validate-command-input [method: string, params: any] {
    let command = (schema-lookup "command" $method)
    validate-command-params $method $params $command
}

def validate-event-input [method: string] {
    schema-lookup "event" $method | ignore
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

export def "cdp schema domains" [] {
    schema-domains
    | each {|domain_record|
        $domain_record
        | upsert commands (($domain_record | get -o commands | default [] | length))
        | upsert events (($domain_record | get -o events | default [] | length))
        | upsert types (($domain_record | get -o types | default [] | length))
    }
}

export def "cdp schema commands" [
    domain?: string
] {
    schema-commands $domain
}

export def "cdp schema events" [
    domain?: string
] {
    schema-events $domain
}

export def "cdp schema types" [
    domain?: string
] {
    schema-types $domain
}

export def "cdp schema command" [
    qualified: string
] {
    schema-lookup "command" $qualified
}

export def "cdp schema event" [
    qualified: string
] {
    schema-lookup "event" $qualified
}

export def "cdp schema type" [
    qualified: string
] {
    schema-lookup "type" $qualified
}

export def "cdp schema search" [
    query: string
] {
    [
        (schema-search-kind "command" $query)
        (schema-search-kind "event" $query)
        (schema-search-kind "type" $query)
    ]
    | flatten
}

export def "cdp schema search commands" [
    query: string
] {
    schema-search-kind "command" $query
}

export def "cdp schema search events" [
    query: string
] {
    schema-search-kind "event" $query
}

export def "cdp schema search types" [
    query: string
] {
    schema-search-kind "type" $query
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
