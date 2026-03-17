const reserved_context_keys = [nusurf user plugin]
const reserved_nusurf_keys = [browser page]

def expect-record [value: any, label: string]: nothing -> record {
    let details = ($value | describe --detailed)

    if $details.type != "record" {
        error make {
            msg: $"Invalid ($label): expected a record, got ($details.detailed_type)"
        }
    }

    $value
}

def expect-known-context-keys [context_record: record]: nothing -> record {
    let unknown_keys = (
        $context_record
        | columns
        | where {|key| $key not-in $reserved_context_keys }
    )

    if (not ($unknown_keys | is-empty)) {
        error make {
            msg: (
                "Unsupported CDP context keys: "
                + ($unknown_keys | str join ", ")
                + ". Use `user` for caller-owned data and `plugin.<namespace>` for plugin data."
            )
        }
    }

    $context_record
}

def expect-known-nusurf-keys [nusurf_record: record]: nothing -> record {
    let unknown_keys = (
        $nusurf_record
        | columns
        | where {|key| $key not-in $reserved_nusurf_keys }
    )

    if (not ($unknown_keys | is-empty)) {
        error make {
            msg: (
                "Unsupported nusurf context keys: "
                + ($unknown_keys | str join ", ")
                + ". Use `nusurf.browser` and `nusurf.page`."
            )
        }
    }

    $nusurf_record
}

def normalize-owned-record [value: any, label: string]: nothing -> record {
    if $value == null {
        {}
    } else {
        expect-record $value $label
    }
}

def normalize-nusurf-record [value: any]: nothing -> record {
    let nusurf_record = (
        if $value == null {
            {}
        } else {
            expect-known-nusurf-keys (expect-record $value "nusurf context")
        }
    )

    {
        browser: $nusurf_record.browser?
        page: $nusurf_record.page?
    }
}

def normalize-context-record [context?: any]: nothing -> record {
    let context_record = (
        if $context == null {
            {}
        } else {
            expect-known-context-keys (expect-record $context "CDP context")
        }
    )

    {
        nusurf: (normalize-nusurf-record $context_record.nusurf?)
        user: (normalize-owned-record $context_record.user? "user context metadata")
        plugin: (normalize-owned-record $context_record.plugin? "plugin context metadata")
    }
}

# Capture the current CDP browser/page selection into the reserved context shape.
#
# `nusurf.browser` and `nusurf.page` are nusurf-owned.
# `user` is for caller-owned metadata.
# `plugin.<namespace>` is for plugin-owned metadata.
export def "cdp context capture" []: nothing -> record {
    normalize-context-record {
        nusurf: {
            browser: $env.CDP_BROWSER?
            page: $env.CDP_PAGE?
        }
    }
}

# Normalize and validate a saved CDP context record without changing it semantically.
export def "cdp context normalize" [context: any]: nothing -> record {
    normalize-context-record $context
}
