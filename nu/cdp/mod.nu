use schema.nu [
    complete-cdp-command
    complete-cdp-domain
    complete-cdp-event
    complete-cdp-type
]
use session.nu [complete-cdp-session]

export def main [] {
    help cdp
}

export use browser.nu [discover]
export use page.nu [focus]
export use session.nu [open call event attach detach close]

export module browser.nu
export module page.nu
export module context.nu
export module schema.nu
