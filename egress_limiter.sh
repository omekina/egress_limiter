#!/bin/sh


CONFIG_FILE="/root/egress_limiter.json";
DATA_DIR="/opt/egress_limiter";


validate_config() {
    if [ ! -e "$CONFIG_FILE" ]
    then
        echo "config file: \"$CONFIG_FILE\" was not found" 1>&2;
        return 1;
    fi
    if grep -Pq "[^A-Za-z0-9_{}:\\[\\],\.\"' \\t-]" "$CONFIG_FILE";
    then
        echo "config file: \"$CONFIG_FILE\" contains invalid characters" 1>&2;
        return 1;
    fi
    jq -e . >/dev/null "$CONFIG_FILE";
    if [ $? != 0 ]
    then
        return 1;
    fi
}


size_to_bytes() {
    raw_input="$1";
    number=$(echo "$raw_input" | grep -Po "^\d+(?=(KB|MB|GB|TB)$)");
    if [ $? != "0" ]
    then
        return 1;
    fi

    if [[ "$raw_input" =~ .*"KB" ]]; then echo "${number}000"; return 0; fi
    if [[ "$raw_input" =~ .*"MB" ]]; then echo "${number}000000"; return 0; fi
    if [[ "$raw_input" =~ .*"GB" ]]; then echo "${number}000000000"; return 0; fi
    if [[ "$raw_input" =~ .*"TB" ]]; then echo "${number}000000000000"; return 0; fi

    return 1;
}


validate_tc_speed() {
    value="$1";
    echo "$1" | grep -Po "^\d+(bit|kbit|mbit|gbit|tbit|bps|kbps|mbps|gbps|tbps)$" &>/dev/null;
    return "$?";
}


# Service runtime

validate_config;
if [ $? != 0 ]
then
    echo "stopping...";
    exit 1;
fi
