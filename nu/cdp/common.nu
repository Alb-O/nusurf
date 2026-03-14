# Return whether a value is Nushell `nothing`.
export def is-nothing [
    value: any # Value to inspect.
] {
    ($value | describe) == "nothing"
}

# Return whether a record or table exposes a column.
export def has-column [
    value: any # Value that may expose columns.
    column: string # Column name to look up.
] {
    if (is-nothing $value) {
        false
    } else {
        $value | columns | any {|name| $name == $column }
    }
}

# Generate a Chromium-safe random message id.
export def random-id [] {
    # Real Chromium targets round-trip JSON numeric ids through a JS-safe range.
    random int 1..2147483647
}

# Resolve a command name from PATH and expand it to an absolute path.
export def command-path [
    name: string # Command name to resolve.
] {
    let hit = (which $name | get -o 0.path)

    if (is-nothing $hit) {
        null
    } else {
        $hit | path expand
    }
}

# Resolve an explicit path or a PATH command candidate.
export def resolve-path-candidate [
    candidate: string # Path or command candidate to resolve.
] {
    let expanded = ($candidate | path expand)

    if ($expanded | path exists) {
        $expanded
    } else {
        command-path $candidate
    }
}
