module session_overlay {
    export-env {
        if not ("NUSURF_SESSIONS" in $env) {
            $env.NUSURF_SESSIONS = {}
        }

        if not ("NUSURF_SESSION_CURRENT" in $env) {
            $env.NUSURF_SESSION_CURRENT = null
        }
    }
}

const session_overlay_name = "nusurf-session"
const session_name_pattern = '^[A-Za-z0-9][A-Za-z0-9._-]*$'

def session-registry []: nothing -> record {
    $env | get -o NUSURF_SESSIONS | default {}
}

def current-session-name []: nothing -> any {
    $env | get -o NUSURF_SESSION_CURRENT
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
        updatedAt: (date now)
    }
}

def session-overlay-is-active []: nothing -> bool {
    overlay list | any {|name| $name == $session_overlay_name }
}

# Complete known overlay-backed CDP session names.
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

# Ensure the fixed overlay-backed session registry is active for this Nu shell.
export def --env session-overlay-ensure []: nothing -> nothing {
    if not (session-overlay-is-active) {
        overlay use session_overlay as nusurf-session
    }

    if not ("NUSURF_SESSIONS" in $env) {
        $env.NUSURF_SESSIONS = {}
    }

    if not ("NUSURF_SESSION_CURRENT" in $env) {
        $env.NUSURF_SESSION_CURRENT = null
    }
}

# Activate the overlay-backed CDP session registry.
export def --env "cdp session enable" []: nothing -> record {
    session-overlay-ensure

    {
        overlay: $session_overlay_name
        current: (cdp session current)
        sessions: (cdp session list)
    }
}

# Save the current browser/page bindings into a named overlay-backed session.
export def --env "cdp session save" [
    name?: string@complete-cdp-session-name # Session name; defaults to the current session.
    --project: string # Optional logical project label to store alongside the binding.
    --profile: string # Optional logical profile label to store alongside the binding.
] : nothing -> oneof<record, error> {
    session-overlay-ensure

    let session_name = (
        if $name == null {
            resolve-session-name
        } else {
            parse-session-name $name
        }
    )
    let previous = (session-registry | get -o $session_name)
    let next_session = (
        merge-session-record $session_name $previous --project $project --profile $profile
    )

    $env.NUSURF_SESSIONS = (session-registry | upsert $session_name $next_session)
    $env.NUSURF_SESSION_CURRENT = $session_name

    $next_session
}

# Apply a named overlay-backed session to the current `CDP_BROWSER` and `CDP_PAGE` bindings.
export def --env "cdp session use" [
    name: string@complete-cdp-session-name # Session name to activate.
] : nothing -> oneof<record, error> {
    session-overlay-ensure

    let session = (resolve-session-record $name)
    $env.NUSURF_SESSION_CURRENT = $session.name

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

# Show the current overlay-backed CDP session record.
export def "cdp session current" []: nothing -> oneof<record, nothing> {
    let session_name = (current-session-name)

    if $session_name == null {
        return null
    }

    session-registry | get -o $session_name
}

# List the known overlay-backed CDP sessions.
export def "cdp session list" []: nothing -> list<any> {
    let sessions = (session-registry)
    let current_name = (current-session-name)

    if (($sessions | columns | length) == 0) {
        return []
    }

    $sessions
    | transpose name session
    | each {|row|
        let session = $row.session

        {
            name: $row.name
            current: ($row.name == $current_name)
            browserSession: ($session | get -o browser.session)
            pageSession: ($session | get -o page.session)
            project: ($session | get -o project)
            profile: ($session | get -o profile)
            updatedAt: ($session | get -o updatedAt)
        }
    }
}

# Remove a named overlay-backed CDP session.
export def --env "cdp session drop" [
    name?: string@complete-cdp-session-name # Session name; defaults to the current session.
] : nothing -> oneof<record, error> {
    session-overlay-ensure

    let session_name = (resolve-session-name $name)
    let session = (resolve-session-record $session_name)

    $env.NUSURF_SESSIONS = (session-registry | reject $session_name)

    if (current-session-name) == $session_name {
        $env.NUSURF_SESSION_CURRENT = null
    }

    $session
}
