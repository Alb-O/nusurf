use std/assert
use cdp.nu *
use cdp/session.nu [complete-cdp-session]

def main [http_port: int, expected_ws_url: string] {
    test cdp discover $http_port $expected_ws_url
    test cdp call and event $http_port
    test cdp schema validation $http_port
    test cdp session completion $http_port
}

def "test cdp discover" [http_port: int, expected_ws_url: string] {
    assert equal (cdp discover $http_port) $expected_ws_url
    assert equal (cdp discover $"http://127.0.0.1:($http_port)") $expected_ws_url
    assert equal (cdp discover $expected_ws_url) $expected_ws_url
}

def "test cdp call and event" [http_port: int] {
    let session = "nu-cdp-test"
    let opened = (cdp open $http_port --name $session)

    assert equal $opened.id $session

    let result = (cdp call $session "Runtime.evaluate" {
        expression: "'nu-plugin-ws'"
    } --id 41 --session-id "session-41")

    assert equal $result.echoMethod "Runtime.evaluate"
    assert equal $result.echoParams.expression "'nu-plugin-ws'"

    let event = (
        cdp event $session "Test.event" --session-id "session-41" --no-validate --max-time 2sec
    )
    assert equal $event.method "Test.event"
    assert equal $event.sessionId "session-41"
    assert equal $event.params.requestId 41
    assert equal $event.params.method "Runtime.evaluate"

    let missing = (cdp event $session "Missing.event" --no-validate --max-time 100ms)
    assert equal ($missing | describe) "nothing"

    cdp close $session | ignore
}

def "test cdp schema validation" [http_port: int] {
    let session = "nu-cdp-validation-test"
    let opened = (cdp open $http_port --name $session)

    assert equal $opened.id $session

    let missing_param_error = (
        try {
            cdp call $session "Runtime.evaluate" {} --id 51
            "missing-param call unexpectedly succeeded"
        } catch {|err|
            $err.msg
        }
    )
    assert (
        $missing_param_error
        | str contains "Missing required CDP params for Runtime.evaluate: expression"
    )

    let unknown_param_error = (
        try {
            cdp call $session "Runtime.evaluate" {expression: "1 + 1", nope: true} --id 52
            "unknown-param call unexpectedly succeeded"
        } catch {|err|
            $err.msg
        }
    )
    assert ($unknown_param_error | str contains "Unknown CDP params for Runtime.evaluate: nope")

    let unknown_event_error = (
        try {
            cdp event $session "Missing.event" --max-time 10ms
            "missing-event read unexpectedly succeeded"
        } catch {|err|
            $err.msg
        }
    )
    assert ($unknown_event_error | str contains "No CDP event named Missing.event")

    let unvalidated = (
        cdp call $session "Missing.method" {foo: "bar"} --no-validate --id 53 --session-id (
            "session-53"
        )
    )
    assert equal $unvalidated.echoMethod "Missing.method"
    assert equal $unvalidated.echoParams.foo "bar"

    cdp close $session | ignore
}

def "test cdp session completion" [http_port: int] {
    let session = "browser"
    let opened = (cdp open $http_port --name $session)

    assert equal $opened.id $session

    let completions = (complete-cdp-session "cdp call bro")
    assert (($completions.completions | where value == "browser" | length) == 1)
    assert (
        (
            $completions.completions
            | where value == "browser" and description =~ "ws://127.0.0.1:"
            | length
        ) == 1
    )

    cdp close $session | ignore
}
