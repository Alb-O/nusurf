use std/assert
use cdp.nu *

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
}
