#!/bin/bash

INPUT_FILE="${1:-devkit_kspect.txt}"

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: File not found: $INPUT_FILE"
    exit 1
fi

awk '
function is_eq_sep(line) {
    return (line ~ /^=/ && line !~ /[^=]/ && length(line) > 20)
}

function is_dash_sep(line) {
    return (line ~ /^\342\224\200/ && length(line) > 10)
}

BEGIN {
    mode = "skip"
    major = ""
    sub_ok = 0
    pending = ""
    prev = ""
    prev_nb = ""
    prev_printed = 0
}

{
    line = $0

    if (major == "Health Report") next

    if (mode == "partial" && pending != "") {
        if (is_dash_sep(line)) {
            sub_ok = 0
            pending = ""
            prev = line
            prev_nb = line
            prev_printed = 0
            next
        } else {
            if (sub_ok) { print pending; prev_printed = 1 }
            else { prev_printed = 0 }
            pending = ""
        }
    }

    if (is_eq_sep(line)) {
        sec = prev
        major = sec

        if (sec == "OS" || sec == "BIOS") {
            mode = "full"
            sub_ok = 1
            pending = ""
            if (!prev_printed) print prev
            print line
            prev_printed = 0
        } else if (sec == "Software" || sec == "CPU" || sec == "NUMA" || sec == "Memory" || sec == "Network" || sec == "Storage") {
            mode = "partial"
            sub_ok = 0
            pending = ""
            if (!prev_printed) print prev
            print line
            prev_printed = 0
        } else {
            mode = "skip"
            sub_ok = 0
            pending = ""
            prev_printed = 0
        }

        prev = line
        prev_nb = line
        next
    }

    if (mode == "skip") {
        prev = line
        if (line != "") prev_nb = line
        prev_printed = 0
        next
    }

    if (mode == "full") {
        if (pending != "") { print pending; pending = ""; prev_printed = 1 }
        print line
        prev = line
        prev_nb = line
        prev_printed = 1
        next
    }

    desired = 0
    undesired = 0

    if (major == "Software") {
        if (line == "Software Version" || line == "KVM Info" || line == "Docker Info") desired = 1
        if (line == "Library Info") undesired = 1
    }
    if (major == "CPU") {
        if (line == "CPU") desired = 1
        if (line == "CPU Table") undesired = 1
    }
    if (major == "NUMA") {
        if (line == "NUMA Memory Table") desired = 1
        if (line == "NUMA PCIe Table") undesired = 1
    }
    if (major == "Memory") {
        if (line == "OS Memory Info" || line == "DIMM Table") desired = 1
    }
    if (major == "Network") {
        if (line == "Network Table") desired = 1
        if (line == "Network IRQ Table" || line == "NIC Perf Metrics Table" || line == "Network System Info Table") undesired = 1
    }
    if (major == "Storage") {
        if (line == "Disk Table" || line == "Filesystem Table") desired = 1
        if (line == "Smart Health Table" || line == "RAID Info Table" || line == "Physical Storage Table" || line == "IO Stat Table") undesired = 1
    }

    if (desired) {
        sub_ok = 1
        if (pending != "") { print pending; pending = ""; prev_printed = 1 }
        print line
        prev = line
        prev_nb = line
        prev_printed = 1
        next
    }

    if (undesired) {
        sub_ok = 0
        pending = ""
        prev = line
        prev_nb = line
        prev_printed = 0
        next
    }

    if (is_dash_sep(line)) {
        if (major == "NUMA" && sub_ok && is_dash_sep(prev_nb)) {
            sub_ok = 0
        }
        if (sub_ok) { print line; prev_printed = 1 }
        else { prev_printed = 0 }
        prev = line
        prev_nb = line
        next
    }

    if (mode == "partial" && line != "" && \
        !is_eq_sep(line) && \
        !is_dash_sep(line) && \
        line !~ /^[ \t]/ && \
        line !~ /^\[/ && \
        line !~ /^Note:/) {
        pending = line
        prev = line
        prev_nb = line
        prev_printed = 0
        next
    }

    if (sub_ok) { print line; prev_printed = 1 }
    else { prev_printed = 0 }
    prev = line
    if (line != "") prev_nb = line
}
' "$INPUT_FILE"
