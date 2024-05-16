#!/bin/bash
# Egress traffic limiter
# Author: Ondřej Mekina




CONFIG_FILE="/root/egress_limiter.json";
DATA_DIR="/opt/egress_limiter";
UPDATE_INTERVAL="30"; # Passed to sleep




# _____ Config validation _____
validate_config() {
    if [ ! -e "$CONFIG_FILE" ]
    then
        echo "was not found" 1>&2;
        return 1;
    fi
    if grep -Pq "[^A-Za-z0-9_{}:\\[\\],\.\"' \\t-]" "$CONFIG_FILE";
    then
        echo "contains invalid characters" 1>&2;
        return 1;
    fi
    jq -e . 2>&1 "$CONFIG_FILE";
    if [ $? != 0 ]
    then
        return 1;
    fi
}

validate_tc_speed() {
    value="$1";
    echo "$1" | grep -Po "^\d+(bit|kbit|mbit|gbit|tbit)$" &>/dev/null;
    return "$?";
}




# _____ Config parsing _____
size_to_bytes() {
    raw_input="$1";
    number=$(echo "$raw_input" | grep -Po "^\d+(?=(KB|MB|GB|TB)$)");
    if [ $? != "0" ]; then return 1; fi

    if [[ "$raw_input" =~ .*"KB" ]]; then echo "${number}$(repeat "0" 3)"; return 0; fi
    if [[ "$raw_input" =~ .*"MB" ]]; then echo "${number}$(repeat "0" 6)"; return 0; fi
    if [[ "$raw_input" =~ .*"GB" ]]; then echo "${number}$(repeat "0" 9)"; return 0; fi
    if [[ "$raw_input" =~ .*"TB" ]]; then echo "${number}$(repeat "0" 12)"; return 0; fi

    return 1;
}

config_to_ruleset() {
    jq_decoded=$(jq -r ".[] | .interface + \"\t\" + (.limits[] | .from + \"\t\" + .limit_to)" "$CONFIG_FILE" 2>&1) ;
    if [ $? != "0" ]; then echo "$jq_decoded"; return 1; fi
    jq_decoded=$(echo "$jq_decoded" | head -c -1);
    result="";
    IFS=$'\n';
    for line in $jq_decoded
    do
        IFS=$'\t';
        read -r cur_interface cur_from cur_limit <<< "$line";
        cur_from_translated=$(size_to_bytes "$cur_from");
        if [ $? != "0" ]; then echo "invalid size unit \"$cur_from\""; return 1; fi
        validate_tc_speed "$cur_limit";
        if [ $? != "0" ]; then echo "invalid tc bandwidth unit \"$cur_limit\""; return 1; fi
        result+=$(echo -e "\n$cur_interface\t$cur_from_translated\t$cur_limit");
    done
    result=$(echo "$result" | tail -c +2 | sort -Vr -t $'\t' -k1,2);
    echo "$result";
}




# _____ Interface managing _____
reset_states() {
    find "$DATA_DIR" -name "*.state" -type f -delete
}

check_rules() {
    ruleset="$1";

    IFS=$'\n';
    last_iface="";
    last_reached=true;
    cur_index=0;
    for rule in $ruleset
    do
        IFS=$'\t';
        read -r iface from limit <<< "$rule";

        # handle skipping lower limits
        if [ $last_reached == true ]
        then
            if [ "$iface" == "$last_iface" ]; then continue; fi
            last_reached=false;
        fi

        # handle index incrementation
        if [ "$iface" != "$last_iface" ]
        then
            cur_index=0;
        else
            cur_index=$((cur_index + 1));
        fi
        last_iface="$iface";

        # check if current (or even higher) limit is already applied
        if [ -f "$DATA_DIR/$iface.state" ]
        then
            if (($(cat "$DATA_DIR/$iface.state") <= "$cur_index")); then continue; fi
        fi

        # get current egress
        cur_egress=$(get_iface_total_egress "$iface");
        if [ $? != "0" ]; then >&2 echo "$(date) - could not get egress stats for interface \"$iface\""; continue; fi

        # write start to checkpoint
        if [ ! -f "$DATA_DIR/$iface.chkp" ]; then
            echo "$(date) - storing new initial value \"$cur_egress\" for interface \"$iface\"" >> "$DATA_DIR/action.log";
            echo "$cur_egress" > "$DATA_DIR/$iface.chkp";
            continue;
        fi
        start_egress=$(cat "$DATA_DIR/$iface.chkp");

        # rate limiting
        if (( $((cur_egress - start_egress)) > $from ))
        then
            apply_htb_egress_limiting "$iface" "$limit";
            echo "$cur_index" > "$DATA_DIR/$iface.state";
            last_reached=true;
        fi
    done
}




# _____ Networking functions _____
get_iface_total_egress() {
    iface="$1";
    iface_line=$(cat "/proc/net/dev" | grep "$iface");
    if [ $? != "0" ]; then return 1; fi
    echo "$(echo "$iface_line" | head -n 1 | sed -n "s/^ *[^ ]\+ \+\([^ ]\+ \+\)\{8\}\([0-9]\+\) .*$/\2/p")";
}

# Warning: No qdiscs must be present on the interface (as they will be deleted)
apply_htb_egress_limiting() {
    device="$1"
    limit="$2"
    echo "$(date) - setting new bandwidth limit \"$limit\" for iface \"$device\"" >> "$DATA_DIR/action.log";
    tc qdisc del dev "$device" root &>/dev/null || true;
    tc qdisc add dev "$device" root handle 1: htb default 10;
    tc class add dev "$device" parent 1: classid 1:10 htb rate "$limit";
}




# _____ Utils _____
repeat() {
    pat="$1";
    n=$(($2));
    for ((i=1; i <= $n; ++i))
    do
        echo -n "$pat";
    done
}




# _____ Runtime _____
validation=$(validate_config);
if [ $? != "0" ]
then
    echo "error validating config file: \"$CONFIG_FILE\": $validation";
    exit 1;
fi
mkdir -p "$DATA_DIR";

ruleset=$(config_to_ruleset);
if [ $? != "0" ]
then
    >&2 echo "config file: \"$CONFIG_FILE\" could not be parsed: $ruleset";
    exit 1;
fi

reset_states;

while true
do
    check_rules "$ruleset";
    sleep "$UPDATE_INTERVAL";
done
