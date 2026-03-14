export def is-nothing [value: any] {
    ($value | describe) == "nothing"
}

export def has-column [value: any, column: string] {
    if (is-nothing $value) {
        false
    } else {
        $value | columns | any {|name| $name == $column }
    }
}

export def random-id [] {
    # Real Chromium targets round-trip JSON numeric ids through a JS-safe range.
    random int 1..2147483647
}

export def command-path [name: string] {
    let hit = (which $name | get -o 0.path)

    if (is-nothing $hit) {
        null
    } else {
        $hit | path expand
    }
}

export def resolve-path-candidate [candidate: string] {
    let expanded = ($candidate | path expand)

    if ($expanded | path exists) {
        $expanded
    } else {
        command-path $candidate
    }
}
