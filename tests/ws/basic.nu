use std/assert

def main [url: string] {
    test ws send-json and recv-json $url
    test ws await and next-event $url
    test ws next-event session filter $url
}

def "test ws send-json and recv-json" [url: string] {
    let session = "nu-send-json"
    let opened = (ws open $url --name $session)

    assert equal $opened.id $session
    assert equal $opened.url $url

    {
        id: 11
        method: "Browser.getVersion"
        params: {
            channel: "stable"
        }
    } | ws send-json $session

    let event = (ws recv-json $session --max-time 2sec)
    assert equal $event.method "Test.event"
    assert equal $event.params.requestId 11
    assert equal $event.params.method "Browser.getVersion"

    let response = (ws recv-json $session --max-time 2sec)
    assert equal $response.id 11
    assert equal $response.result.echoMethod "Browser.getVersion"
    assert equal $response.result.echoParams.channel "stable"

    ws close $session | ignore
}

def "test ws next-event session filter" [url: string] {
    let session = "nu-session-filter"
    ws open $url --name $session | ignore

    {
        id: 13
        method: "Runtime.evaluate"
        params: {
            sessionId: "attached-a"
        }
    } | ws send-json $session

    {
        id: 14
        method: "Runtime.evaluate"
        params: {
            sessionId: "attached-b"
        }
    } | ws send-json $session

    let response_a = (ws await $session 13 --max-time 2sec)
    let response_b = (ws await $session 14 --max-time 2sec)
    assert equal $response_a.id 13
    assert equal $response_b.id 14

    let event_b = (ws next-event $session "Test.event" --session-id "attached-b" --max-time 2sec)
    let event_a = (ws next-event $session "Test.event" --session-id "attached-a" --max-time 2sec)
    let missing = (ws next-event $session "Test.event" --max-time 100ms)

    assert equal $event_b.sessionId "attached-b"
    assert equal $event_b.params.requestId 14
    assert equal $event_a.sessionId "attached-a"
    assert equal $event_a.params.requestId 13
    assert equal ($missing | describe) "nothing"

    ws close $session | ignore
}

def "test ws await and next-event" [url: string] {
    let session = "nu-await-event"
    let opened = (ws open $url --name $session)

    assert equal $opened.id $session

    {
        id: 12
        method: "Page.navigate"
        params: {
            url: "https://example.com"
        }
    } | ws send-json $session

    let response = (ws await $session 12 --max-time 2sec)
    assert equal $response.id 12
    assert equal $response.result.echoMethod "Page.navigate"
    assert equal $response.result.echoParams.url "https://example.com"

    let event = (ws next-event $session "Test.event" --max-time 2sec)
    assert equal $event.method "Test.event"
    assert equal $event.params.requestId 12
    assert equal $event.params.method "Page.navigate"

    let duplicate_event = (ws next-event $session --max-time 100ms)
    assert equal ($duplicate_event | describe) "nothing"

    let missing_response = (ws await $session 999 --max-time 100ms)
    assert equal ($missing_response | describe) "nothing"

    let missing_event = (ws next-event $session "Missing.event" --max-time 100ms)
    assert equal ($missing_event | describe) "nothing"

    ws close $session | ignore
}
