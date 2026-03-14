use cdp/schema.nu [
    complete-cdp-command
    complete-cdp-domain
    complete-cdp-event
    complete-cdp-type
]

export use cdp/browser.nu [
    "cdp discover"
    "cdp browser find"
    "cdp browser args"
]

export use cdp/session.nu [
    "cdp open"
    "cdp call"
    "cdp event"
    "cdp attach"
    "cdp detach"
    "cdp close"
]

export use cdp/schema.nu [
    "cdp schema domains"
    "cdp schema commands"
    "cdp schema events"
    "cdp schema types"
    "cdp schema command"
    "cdp schema event"
    "cdp schema type"
    "cdp schema search"
    "cdp schema search commands"
    "cdp schema search events"
    "cdp schema search types"
]
