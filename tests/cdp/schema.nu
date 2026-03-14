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
}
