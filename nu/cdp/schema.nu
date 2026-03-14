use common.nu *

const cdp_schema_file = (path self ../../schema/cdp/protocol.nuon)

export def schema-domains-raw [] {
    open $cdp_schema_file | get domains
}

export def schema-domains [domain?: string] {
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

export def schema-commands [domain?: string] {
    schema-domains $domain
    | each {|domain_record|
        let domain_name = $domain_record.domain
        ($domain_record | get -o commands | default [])
        | each {|command| enrich-command $domain_name $command }
    }
    | flatten
}

export def schema-events [domain?: string] {
    schema-domains $domain
    | each {|domain_record|
        let domain_name = $domain_record.domain
        ($domain_record | get -o events | default [])
        | each {|event| enrich-event $domain_name $event }
    }
    | flatten
}

export def schema-types [domain?: string] {
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

export def schema-lookup [kind: string, qualified: string] {
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

def search-results [kind: string, query: string] {
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
                    description: ($entry | get -o description | default "")
                }
            }
        )
    }
}

def completion-token [context: string] {
    $context | split words | last | default ""
}

export def complete-cdp-domain [context: string] {
    let prefix = (completion-token $context)

    {
        options: {
            completion_algorithm: substring
            sort: true
            case_sensitive: false
        }
        completions: (
            schema-domains
            | where {|entry| ($entry.domain | str downcase | str contains ($prefix | str downcase)) }
            | each {|entry|
                {
                    value: $entry.domain
                    description: $"($entry.commands | default [] | length) commands, ($entry.events | default [] | length) events"
                }
            }
        )
    }
}

export def complete-cdp-command [context: string] {
    completion-results (search-results "command" (completion-token $context))
}

export def complete-cdp-event [context: string] {
    completion-results (search-results "event" (completion-token $context))
}

export def complete-cdp-type [context: string] {
    completion-results (search-results "type" (completion-token $context))
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

export def validate-command-input [method: string, params: any] {
    let command = (schema-lookup "command" $method)
    validate-command-params $method $params $command
}

export def validate-event-input [method: string] {
    schema-lookup "event" $method | ignore
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
        (search-results "command" $query)
        (search-results "event" $query)
        (search-results "type" $query)
    ]
    | flatten
}

export def "cdp schema search commands" [
    query: string
] {
    search-results "command" $query
}

export def "cdp schema search events" [
    query: string
] {
    search-results "event" $query
}

export def "cdp schema search types" [
    query: string
] {
    search-results "type" $query
}
