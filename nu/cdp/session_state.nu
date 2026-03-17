const session_state_kind = "nusurf/cdp-session-state"
const session_state_version = 1
const session_name_pattern = '^[A-Za-z0-9][A-Za-z0-9._-]*$'

def expect-record [value: any, label: string]: nothing -> record {
    let details = ($value | describe --detailed)

    if $details.type != "record" {
        error make {
            msg: $"Invalid ($label): expected a record, got ($details.detailed_type)"
        }
    }

    $value
}

def empty-session-state []: nothing -> record {
    {
        kind: $session_state_kind
        version: $session_state_version
        current_session: null
        sessions: {}
    }
}

def normalize-session-record [name: string, session?: any]: nothing -> record {
    let session_record = (
        if $session == null {
            {}
        } else {
            expect-record $session $"session record for ($name)"
        }
    )

    {
        name: $name
        browser: ($session_record | get -o browser)
        page: ($session_record | get -o page)
        project: ($session_record | get -o project)
        profile: ($session_record | get -o profile)
        updated_at: ($session_record | get -o updated_at)
    }
}

def normalize-session-registry [sessions?: any]: nothing -> record {
    let session_registry = (
        if $sessions == null {
            {}
        } else {
            expect-record $sessions "session registry"
        }
    )

    $session_registry
    | items {|name, session|
        {
            name: $name
            session: (normalize-session-record $name $session)
        }
    }
    | reduce --fold {} {|row, acc|
        $acc | upsert $row.name $row.session
    }
}

def normalize-session-state [state?: any]: nothing -> record {
    let state_record = (
        if $state == null {
            empty-session-state
        } else {
            expect-record $state "CDP session state"
        }
    )
    let kind = ($state_record | get -o kind | default $session_state_kind)

    let version = ($state_record | get -o version | default $session_state_version)

    if $kind != $session_state_kind {
        error make {
            msg: (
                $"Unsupported CDP session state kind ($kind). "
                + $"Expected ($session_state_kind)."
            )
        }
    }

    if $version != $session_state_version {
        error make {
            msg: (
                $"Unsupported CDP session state version ($version). "
                + $"Expected ($session_state_version)."
            )
        }
    }

    let sessions = (normalize-session-registry ($state_record | get -o sessions))
    let current_session = ($state_record | get -o current_session | default null)
    let current_session_name = (
        if $current_session == null {
            null
        } else {
            parse-session-name $current_session
        }
    )

    {
        kind: $kind
        version: $session_state_version
        current_session: (
            if (
                ($current_session_name != null)
                and (($sessions | columns) | any {|name| $name == $current_session_name })
            ) {
                $current_session_name
            } else {
                null
            }
        )
        sessions: $sessions
    }
}

def validate-imported-session-state [state: any]: nothing -> record {
    let state_record = (expect-record $state "CDP session state")
    let imported_current_session = ($state_record | get -o current_session)
    let normalized = (normalize-session-state $state)

    if (
        ($imported_current_session != null)
        and (($normalized.sessions | get -o $imported_current_session) == null)
    ) {
        error make {
            msg: (
                "Imported CDP session state references unknown current session "
                + $"($imported_current_session)"
            )
        }
    }

    $normalized
}

def legacy-session-state []: nothing -> any {
    let legacy_sessions = ($env | get -o NUSURF_SESSIONS)
    let legacy_current = ($env | get -o NUSURF_SESSION_CURRENT)

    if (($legacy_sessions == null) and ($legacy_current == null)) {
        return null
    }

    normalize-session-state {
        current_session: $legacy_current
        sessions: ($legacy_sessions | default {})
    }
}

def has-legacy-session-state []: nothing -> bool {
    ("NUSURF_SESSIONS" in $env) or ("NUSURF_SESSION_CURRENT" in $env)
}

def session-state-record []: nothing -> record {
    let state = (
        [
            ($env | get -o NUSURF_CDP_SESSION_STATE)
            (legacy-session-state)
            (empty-session-state)
        ]
        | compact
        | first
    )

    normalize-session-state $state
}

def --env update-session-state [state: record]: nothing -> record {
    let normalized = (normalize-session-state $state)
    $env.NUSURF_CDP_SESSION_STATE = $normalized

    try { hide-env NUSURF_SESSIONS }
    try { hide-env NUSURF_SESSION_CURRENT }

    $normalized
}

def session-registry []: nothing -> record {
    session-state-record | get sessions
}

def current-session-name []: nothing -> any {
    session-state-record | get -o current_session
}

def current-browser-context []: nothing -> any {
    $env | get -o CDP_BROWSER
}

def current-page-context []: nothing -> any {
    $env | get -o CDP_PAGE
}

def parse-session-name [name: string]: nothing -> string {
    let trimmed = ($name | str trim)

    if ($trimmed | is-empty) {
        error make {
            msg: "Session name is empty"
        }
    }

    if not ($trimmed =~ $session_name_pattern) {
        error make {
            msg: (
                $"Invalid session name ($name). "
                + "Use letters, numbers, '.', '_', or '-'."
            )
        }
    }

    $trimmed
}

def resolve-session-name [name?: string]: nothing -> string {
    if $name != null {
        return (parse-session-name $name)
    }

    let current_name = (current-session-name)

    if $current_name == null {
        error make {
            msg: "No current cdp session is selected"
        }
    }

    $current_name
}

def resolve-session-record [name: string]: nothing -> record {
    let session_name = (parse-session-name $name)
    let session = (session-registry | get -o $session_name)

    if $session == null {
        error make {
            msg: $"Unknown cdp session ($session_name)"
        }
    }

    $session
}

def merge-session-record [
    session_name: string
    previous?: record
    --project: string
    --profile: string
] : nothing -> record {
    let browser = (current-browser-context)
    let page = (current-page-context)
    let preserve_existing_context = (($browser == null) and ($page == null) and ($previous != null))

    {
        name: $session_name
        browser: (
            if $preserve_existing_context {
                $previous | get -o browser
            } else {
                $browser
            }
        )
        page: (
            if $preserve_existing_context {
                $previous | get -o page
            } else {
                $page
            }
        )
        project: ($project | default ($previous | get -o project))
        profile: ($profile | default ($previous | get -o profile))
        updated_at: (date now)
    }
}

def list-session-summaries [state: record]: nothing -> list<any> {
    let sessions = ($state | get sessions)
    let current_name = ($state | get -o current_session)

    if (($sessions | columns | length) == 0) {
        return []
    }

    $sessions
    | items {|name, session|
        {
            name: $name
            current: ($name == $current_name)
            browser_session: ($session | get -o browser.session)
            page_session: ($session | get -o page.session)
            project: ($session | get -o project)
            profile: ($session | get -o profile)
            updated_at: ($session | get -o updated_at)
        }
    }
}

# Complete known CDP session names from the structured state registry.
export def complete-cdp-session-name [
    context: string # Current commandline context.
] : nothing -> record {
    let needle = ($context | split words | last | default "" | str downcase)

    {
        options: {
            completion_algorithm: substring
            sort: true
            case_sensitive: false
        }
        completions: (
            session-registry
            | columns
            | where {|name| ($name | str downcase | str contains $needle) }
            | each {|name|
                {
                    value: $name
                    description: (
                        session-registry
                        | get $name
                        | get -o page.session browser.session project profile
                        | compact
                        | str join " "
                    )
                }
            }
        )
    }
}

# Ensure the structured CDP session state exists in the current Nu shell.
export def --env session-state-ensure []: nothing -> record {
    let current_state = ($env | get -o NUSURF_CDP_SESSION_STATE)

    if (($current_state != null) and not (has-legacy-session-state)) {
        return (normalize-session-state $current_state)
    }

    update-session-state (session-state-record)
}

# Ensure the session state registry exists and return a summary.
export def --env "cdp session enable" []: nothing -> record {
    let state = (session-state-ensure)
    let current = (
        if $state.current_session == null {
            null
        } else {
            $state.sessions | get -o $state.current_session
        }
    )

    {
        kind: $state.kind
        version: $state.version
        current: $current
        sessions: (list-session-summaries $state)
    }
}

# Show the full structured CDP session state record.
export def "cdp session state" []: nothing -> record {
    session-state-record
}

# Write the current structured CDP session state to a NUON file.
export def "cdp session export" [
    path: path # Output NUON file path.
] : nothing -> path {
    session-state-record | to nuon | save -f $path
    $path | path expand
}

# Load structured CDP session state from a NUON file into the current Nu shell.
export def --env "cdp session import" [
    path: path # Input NUON file path.
] : nothing -> record {
    let state = (validate-imported-session-state (open --raw $path | from nuon))
    update-session-state $state
}

# Save the current browser/page bindings into a named CDP session record.
export def --env "cdp session save" [
    name?: string@complete-cdp-session-name # Session name; defaults to the current session.
    --project: string # Optional logical project label to store alongside the binding.
    --profile: string # Optional logical profile label to store alongside the binding.
] : nothing -> oneof<record, error> {
    let current_state = (session-state-ensure)
    let session_name = (
        if $name == null {
            resolve-session-name
        } else {
            parse-session-name $name
        }
    )
    let previous = ($current_state | get sessions | get -o $session_name)
    let next_session = (
        merge-session-record $session_name $previous --project $project --profile $profile
    )

    update-session-state (
        $current_state
        | upsert sessions ($current_state.sessions | upsert $session_name $next_session)
        | upsert current_session $session_name
    ) | ignore

    $next_session
}

# Apply a named CDP session record to the current `CDP_BROWSER` and `CDP_PAGE` bindings.
export def --env "cdp session use" [
    name: string@complete-cdp-session-name # Session name to activate.
] : nothing -> oneof<record, error> {
    let current_state = (session-state-ensure)
    let session = (resolve-session-record $name)

    update-session-state ($current_state | upsert current_session $session.name) | ignore

    if $session.browser == null {
        try { hide-env CDP_BROWSER }
    } else {
        $env.CDP_BROWSER = $session.browser
    }

    if $session.page == null {
        try { hide-env CDP_PAGE }
    } else {
        $env.CDP_PAGE = $session.page
    }

    $session
}

# Show the current CDP session record from the structured state registry.
export def "cdp session current" []: nothing -> oneof<record, nothing> {
    let session_name = (current-session-name)

    if $session_name == null {
        return null
    }

    session-registry | get -o $session_name
}

# List the known CDP sessions from the structured state registry.
export def "cdp session list" []: nothing -> list<any> {
    list-session-summaries (session-state-record)
}

# Remove a named CDP session from the structured state registry.
export def --env "cdp session drop" [
    name?: string@complete-cdp-session-name # Session name; defaults to the current session.
] : nothing -> oneof<record, error> {
    let current_state = (session-state-ensure)
    let session_name = (resolve-session-name $name)
    let session = (resolve-session-record $session_name)

    update-session-state (
        $current_state
        | upsert sessions ($current_state.sessions | reject $session_name)
        | upsert current_session (
            if $current_state.current_session == $session_name {
                null
            } else {
                $current_state.current_session
            }
        )
    ) | ignore

    $session
}
