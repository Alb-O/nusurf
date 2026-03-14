use std/assert

def main [url: string] {
    test ws send-json and recv-json $url
    test ws await and next-event $url
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

    let missing_response = (ws await $session 999 --max-time 100ms)
    assert equal ($missing_response | describe) "nothing"

    let missing_event = (ws next-event $session "Missing.event" --max-time 100ms)
    assert equal ($missing_event | describe) "nothing"

    ws close $session | ignore
}
