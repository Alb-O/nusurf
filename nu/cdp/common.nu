# Generate a Chromium-safe random message id.
export def random-id []: nothing -> int {
    # Real Chromium targets round-trip JSON numeric ids through a JS-safe range.
    random int 1..2147483647
}

export def completion-token []: string -> string {
    $in | split words | last | default ""
}

# Resolve an explicit path or a PATH command candidate.
export def resolve-path-candidate [
    # Path or command candidate to resolve.
] : string -> oneof<path, nothing> {
    let candidate = $in
    let expanded = ($candidate | path expand)

    if ($expanded | path exists) {
        $expanded
    } else {
        let hit = (which $candidate | get -o path | first)

        if $hit != null {
            $hit | path expand
        }
    }
}
