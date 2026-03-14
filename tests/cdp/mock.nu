use std/assert
use cdp.nu *

def main [http_port: int, expected_ws_url: string] {
    test cdp discover $http_port $expected_ws_url
    test cdp call and event $http_port
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

    let result = (cdp call $session "Browser.getVersion" {
        product: "nu-plugin-ws"
    } --id 41 --session-id "session-41")

    assert equal $result.echoMethod "Browser.getVersion"
    assert equal $result.echoParams.product "nu-plugin-ws"

    let event = (cdp event $session "Test.event" --session-id "session-41" --max-time 2sec)
    assert equal $event.method "Test.event"
    assert equal $event.sessionId "session-41"
    assert equal $event.params.requestId 41
    assert equal $event.params.method "Browser.getVersion"

    let missing = (cdp event $session "Missing.event" --max-time 100ms)
    assert equal ($missing | describe) "nothing"

    cdp close $session | ignore
}
