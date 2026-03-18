use std/assert
use ../../nu/cdp
use ../../nu/cdp/page.nu [complete-cdp-page-wait-state]
use ../../nu/cdp/schema.nu [
    complete-cdp-command
    complete-cdp-domain
    complete-cdp-event
    complete-cdp-type
]

def main [] {
    let domains = (cdp schema domains)
    assert (($domains | where domain == "Runtime" | length) == 1)
    assert (($domains | where domain == "Page" | length) == 1)

    let runtime_commands = (cdp schema commands Runtime)
    assert (($runtime_commands | where qualified == "Runtime.evaluate" | length) == 1)

    let evaluate = (cdp schema command "Runtime.evaluate")
    assert equal $evaluate.domain "Runtime"
    assert equal $evaluate.name "evaluate"
    assert (($evaluate.parameters | where name == "expression" | length) == 1)

    let load_event = (cdp schema event "Page.loadEventFired")
    assert equal $load_event.domain "Page"
    assert equal $load_event.name "loadEventFired"

    let session_type = (cdp schema type "Target.SessionID")
    assert equal $session_type.domain "Target"
    assert equal $session_type.id "SessionID"
    assert equal $session_type.type "string"

    let command_matches = (cdp schema search commands "evalu")
    assert (($command_matches | where qualified == "Runtime.evaluate" | length) == 1)

    let event_matches = (cdp schema search events "load")
    assert (($event_matches | where qualified == "Page.loadEventFired" | length) == 1)

    let all_matches = (cdp schema search "session")
    assert (($all_matches | where qualified == "Target.SessionID" and kind == "type" | length) == 1)

    let domain_completions = (complete-cdp-domain "cdp schema commands Pa")
    assert (($domain_completions.completions | where value == "Page" | length) == 1)

    let command_completions = (complete-cdp-command "cdp call browser Runtime.eva")
    assert (($command_completions.completions | where value == "Runtime.evaluate" | length) == 1)

    let event_completions = (complete-cdp-event "cdp event browser Page.loa")
    assert (($event_completions.completions | where value == "Page.loadEventFired" | length) == 1)

    let type_completions = (complete-cdp-type "cdp schema type Target.Sess")
    assert (($type_completions.completions | where value == "Target.SessionID" | length) == 1)

    let wait_state_completions = (complete-cdp-page-wait-state "cdp page wait #app --state vi")
    assert (($wait_state_completions.completions | where value == "visible" | length) == 1)

    let schema_commands_signature = (scope commands | where name == "cdp schema commands" | get 0.signatures.nothing)
    let schema_command_signature = (scope commands | where name == "cdp schema command" | get 0.signatures.nothing)
    let schema_search_signature = (
        scope commands
        | where name == "cdp schema search commands"
        | get 0.signatures.nothing
    )
    let page_wait_signature = (scope commands | where name == "cdp page wait" | get 0.signatures.nothing)

    assert equal (
        $schema_commands_signature
        | where parameter_name == "domain"
        | get 0.completion
    ) "complete-cdp-domain"
    assert equal (
        $schema_command_signature
        | where parameter_name == "qualified"
        | get 0.completion
    ) "complete-cdp-command"
    assert equal (
        $schema_search_signature
        | where parameter_name == "query"
        | get 0.completion
    ) "complete-cdp-command"
    assert equal (
        $page_wait_signature
        | where parameter_name == "state"
        | get 0.completion
    ) "complete-cdp-page-wait-state"
}
