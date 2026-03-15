use common.nu *

const cdp_schema_file = (path self ../../schema/cdp/protocol.nuon)

# Load the raw protocol domain list from the bundled schema file.
export def schema-domains-raw [] {
    open $cdp_schema_file | get domains
}

# Return protocol domains, optionally filtered by domain name.
export def schema-domains [
    domain?: string # Domain name to filter on.
] {
    if $domain == null {
        schema-domains-raw
    } else {
        schema-domains-raw | where domain == $domain
    }
}

def enrich-entry [domain_name: string, member: string, entry: record] {
    (
        $entry
        | upsert domain $domain_name
        | upsert qualified $"($domain_name).(($entry | get $member))"
    )
}

def schema-members [field: string, member: string, domain?: string] {
    schema-domains $domain
    | each {|domain_record|
        ($domain_record | get -o $field | default [])
        | each {|entry| enrich-entry $domain_record.domain $member $entry }
    }
    | flatten
}

def schema-kind-entries [kind: string, domain?: string] {
    match $kind {
        "command" => (schema-members "commands" "name" $domain)
        "event" => (schema-members "events" "name" $domain)
        "type" => (schema-members "types" "id" $domain)
        _ => (error make { msg: $"Unsupported CDP schema kind: ($kind)" })
    }
}

# Return protocol commands, optionally filtered by domain name.
export def schema-commands [
    domain?: string # Domain name to filter on.
] {
    schema-kind-entries "command" $domain
}

# Return protocol events, optionally filtered by domain name.
export def schema-events [
    domain?: string # Domain name to filter on.
] {
    schema-kind-entries "event" $domain
}

# Return protocol types, optionally filtered by domain name.
export def schema-types [
    domain?: string # Domain name to filter on.
] {
    schema-kind-entries "type" $domain
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

# Look up a protocol entry by kind and qualified name.
export def schema-lookup [
    kind: string # Schema entry kind: command, event, or type.
    qualified: string # Qualified protocol name like `Page.navigate`.
] {
    let parsed = (parse-qualified $qualified)
    let entry = (
        schema-kind-entries $kind $parsed.domain
        | where qualified == $qualified
        | get -o 0
    )

    if $entry == null {
        error make {
            msg: $"No CDP ($kind) named ($qualified)"
        }
    }

    $entry
}

def entry-member [entry: record] {
    let name = ($entry | get -o name)

    if $name == null {
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

def search-results [kind: string, query: string] {
    let needle = ($query | str downcase)
    schema-kind-entries $kind
    | each {|entry| enrich-search-entry $kind $entry }
    | where {|entry|
        [
            $entry.qualified
            ($entry.member | into string)
            ($entry | get -o description | default "" | into string)
        ]
        | any {|value| ($value | str downcase | str contains $needle) }
    }
}

def completion-results [entries: list<any>] {
    {
        options: {
            completion_algorithm: substring
            sort: true
            case_sensitive: false
        }
        completions: (
            $entries
            | each {|entry|
                {
                    value: $entry.qualified
                    description: (
                        # upstream protocol descriptions contain
                        # hard-wrapped newlines, even mid-sentence
                        $entry
                        | get -o description
                        | default ""
                        | str replace -a "\n" " "
                        | str trim
                    )
                }
            }
        )
    }
}

def completion-token [context: string] {
    $context | split words | last | default ""
}

# Complete CDP domain names from commandline context.
export def complete-cdp-domain [
    context: string # Current commandline context.
] {
    let needle = (completion-token $context | str downcase)

    {
        options: {
            completion_algorithm: substring
            sort: true
            case_sensitive: false
        }
        completions: (
            schema-domains
            | where {|entry|
                (
                    $entry.domain
                    | str downcase
                    | str contains $needle
                )
            }
            | each {|entry|
                {
                    value: $entry.domain
                    description: (
                        $"($entry.commands | default [] | length) commands, "
                        + $"($entry.events | default [] | length) events"
                    )
                }
            }
        )
    }
}

# Complete CDP command names from commandline context.
export def complete-cdp-command [
    context: string # Current commandline context.
] {
    completion-results (search-results "command" (completion-token $context))
}

# Complete CDP event names from commandline context.
export def complete-cdp-event [
    context: string # Current commandline context.
] {
    completion-results (search-results "event" (completion-token $context))
}

# Complete CDP type names from commandline context.
export def complete-cdp-type [
    context: string # Current commandline context.
] {
    completion-results (search-results "type" (completion-token $context))
}

def validate-command-params [method: string, params: any, command: record] {
    let parameters = ($command | get -o parameters | default [])
    let allowed = ($parameters | get name)
    let required = (
        $parameters
        | default false optional
        | where optional == false
        | get name
    )

    let param_type = ($params | describe)
    let param_record = if $param_type == "nothing" {
        {}
    } else if ($param_type | str starts-with "record") {
        $params
    } else {
        error make {
            msg: $"CDP command ($method) params must be a record, got: ($param_type)"
        }
    }

    let keys = ($param_record | columns)
    let unknown = ($keys | where $it not-in $allowed)
    let missing = ($required | where $it not-in $keys)

    if (not ($unknown | is-empty)) {
        error make {
            msg: $"Unknown CDP params for ($method): (($unknown | str join ', '))"
        }
    }

    if (not ($missing | is-empty)) {
        error make {
            msg: $"Missing required CDP params for ($method): (($missing | str join ', '))"
        }
    }
}

# Validate a CDP command call against the bundled schema.
export def validate-command-input [
    method: string # Qualified CDP command name.
    params: any # Params record to validate.
] {
    let command = (schema-lookup "command" $method)
    validate-command-params $method $params $command
}

# Validate a CDP event name against the bundled schema.
export def validate-event-input [
    method: string # Qualified CDP event name.
] {
    schema-lookup "event" $method | ignore
}

# List protocol domains with command, event, and type counts.
export def "cdp schema domains" [] {
    schema-domains
    | each {|domain_record|
        $domain_record
        | upsert commands (($domain_record | get -o commands | default [] | length))
        | upsert events (($domain_record | get -o events | default [] | length))
        | upsert types (($domain_record | get -o types | default [] | length))
    }
}

# List protocol commands, optionally filtered by domain.
export def "cdp schema commands" [
    domain?: string@complete-cdp-domain # Domain name to filter on.
] {
    schema-commands $domain
}

# List protocol events, optionally filtered by domain.
export def "cdp schema events" [
    domain?: string@complete-cdp-domain # Domain name to filter on.
] {
    schema-events $domain
}

# List protocol types, optionally filtered by domain.
export def "cdp schema types" [
    domain?: string@complete-cdp-domain # Domain name to filter on.
] {
    schema-types $domain
}

# Show one protocol command by qualified name.
export def "cdp schema command" [
    qualified: string@complete-cdp-command # Qualified CDP command name.
] {
    schema-lookup "command" $qualified
}

# Show one protocol event by qualified name.
export def "cdp schema event" [
    qualified: string@complete-cdp-event # Qualified CDP event name.
] {
    schema-lookup "event" $qualified
}

# Show one protocol type by qualified name.
export def "cdp schema type" [
    qualified: string@complete-cdp-type # Qualified CDP type name.
] {
    schema-lookup "type" $qualified
}

# Search commands, events, and types with one query string.
export def "cdp schema search" [
    query: string # Search text to match against qualified names and descriptions.
] {
    [
        (search-results "command" $query)
        (search-results "event" $query)
        (search-results "type" $query)
    ]
    | flatten
}

# Search only protocol commands with one query string.
export def "cdp schema search commands" [
    query: string@complete-cdp-command # Search text to match against qualified names and descriptions.
] {
    search-results "command" $query
}

# Search only protocol events with one query string.
export def "cdp schema search events" [
    query: string@complete-cdp-event # Search text to match against qualified names and descriptions.
] {
    search-results "event" $query
}

# Search only protocol types with one query string.
export def "cdp schema search types" [
    query: string@complete-cdp-type # Search text to match against qualified names and descriptions.
] {
    search-results "type" $query
}
