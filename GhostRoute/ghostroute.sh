#!/usr/bin/env bash

# Developer: Sreeraj
# GitHub: https://github.com/s-r-e-e-r-a-j

# Global configuration variables
DNS_PORT="53"  # DNS port for Tor
TOR_NETWORK="10.0.0.0/10"  # Virtual network for Tor
LOCALHOST="127.0.0.1"  # Local loopback address
EXCLUDED_NETWORKS=("192.168.0.0/16" "172.16.0.0/12") # Networks to exclude from Tor
EXCLUDED_IPS=("127.0.0.0/8")  # IPs to exclude
TOR_PORT="9040"  # Tor transparent proxy port
TOR_CONFIG='/etc/tor/torrc'  # Tor configuration file path
LOG_FILE="ghostroute.log"  # Log file path

# Detect Linux distribution
detect_distribution() {
    if [ -f /etc/os-release ]; then
        if grep -qi "debian" /etc/os-release || grep -qi "ubuntu" /etc/os-release || grep -qi "kali" /etc/os-release || grep -qi "parrot" /etc/os-release || grep -qi "linuxmint" /etc/os-release || grep -qi "raspbian" /etc/os-release; then
            echo "debian"
        elif grep -qi "fedora" /etc/os-release || grep -qi "centos" /etc/os-release || grep -qi "rhel" /etc/os-release || grep -qi "red hat" /etc/os-release || grep -qi "redhat" /etc/os-release || grep -qi "rocky" /etc/os-release || grep -qi "alma" /etc/os-release; then
            echo "fedora"
        elif grep -qi "arch" /etc/os-release || grep -qi "manjaro" /etc/os-release || grep -qi "endeavouros" /etc/os-release || grep -qi "blackarch" /etc/os-release; then
            echo "arch"
        else
            echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

DISTRO=$(detect_distribution)

# Set Tor user based on distribution
if [ "$DISTRO" = "debian" ]; then
    TOR_USER=$(id -ur debian-tor 2>/dev/null)
elif [ "$DISTRO" = "fedora" ]; then
    TOR_USER=$(id -ur toranon 2>/dev/null)
elif [ "$DISTRO" = "arch" ]; then
    TOR_USER=$(id -ur tor 2>/dev/null)  
fi

# Configuration to append to torrc file
TOR_CONFIG_CONTENT="
## Added by $(basename "$0") for GhostRoute (Tor routing)
## Routes all traffic through Tor on port $TOR_PORT
VirtualAddrNetwork $TOR_NETWORK
AutomapHostsOnResolve 1
TransPort $TOR_PORT
DNSPort $DNS_PORT
"

# Open log file for writing
exec 3>>"$LOG_FILE"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >&3
}

cleanup() {
    if [ -e /proc/$$/fd/3 ]; then
        exec 3>&-
    fi
}

disable_ipv6() {
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
}

enable_ipv6() {
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
}

enable_doh() {
    log_message "[*] Re-enabling DNS over HTTPS (DoH) settings..."

    if [ -f /etc/systemd/resolved.conf.d/disable-doh.conf ]; then
        rm -f /etc/systemd/resolved.conf.d/disable-doh.conf
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            systemctl restart systemd-resolved >/dev/null 2>&1
        fi
        log_message "[+] Restored default DNSOverTLS setting in systemd-resolved"
    fi

    if [ -f /etc/firefox/policies/policies.json ]; then
        rm -f /etc/firefox/policies/policies.json
        log_message "[+] Removed Firefox DoH disable policy"
    fi

    if [ -f /etc/opt/chrome/policies/managed/doh_policy.json ]; then
        rm -f /etc/opt/chrome/policies/managed/doh_policy.json
    fi
    if [ -f /etc/chromium/policies/managed/doh_policy.json ]; then
        rm -f /etc/chromium/policies/managed/doh_policy.json
    fi
    log_message "[+] Removed Chromium/Chrome DoH disable policy"

    if command -v nft >/dev/null 2>&1; then
        nft delete set inet ghostroute doh_providers 2>/dev/null || true
    fi

    log_message "[+] DNS over HTTPS settings restored to system defaults"
}


disable_doh() {
    log_message "[*] Configuring rules to disable DNS over HTTPS (DoH)..."

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat <<EOF > /etc/systemd/resolved.conf.d/disable-doh.conf
[Resolve]
DNSOverTLS=no
EOF
        systemctl restart systemd-resolved >/dev/null 2>&1
        log_message "[+] Disabled DNSOverTLS in systemd-resolved"
    fi

    # Forces Firefox to set DoH policy to "Disabled" (Mode 0)
    local firefox_policy_dir="/etc/firefox/policies"
    mkdir -p "$firefox_policy_dir"
    cat <<EOF > "$firefox_policy_dir/policies.json"
{
  "policies": {
    "DNSOverHTTPS": {
      "Enabled": false,
      "Locked": true
    }
  }
}
EOF
    log_message "[+] Enforced Firefox DoH disable policy"

    # Forces Chromium/Google Chrome/Brave to disable Secure DNS
    local chrome_policy_dir="/etc/opt/chrome/policies/managed"
    local chromium_policy_dir="/etc/chromium/policies/managed"
    mkdir -p "$chrome_policy_dir" "$chromium_policy_dir"

    cat <<EOF > "$chrome_policy_dir/doh_policy.json"
{
  "DnsOverHttpsMode": "off"
}
EOF
    cp "$chrome_policy_dir/doh_policy.json" "$chromium_policy_dir/doh_policy.json" 2>/dev/null || true
    log_message "[+] Enforced Chromium/Chrome DoH disable policy"

   # Apply Firewall Blocks for Major Public DoH Resolver IPs on Port 443
    if command -v nft >/dev/null 2>&1; then
        nft -f - <<EOF >/dev/null 2>&1 || true
table ip ghostroute__gr {
    set doh_providers {
        type ipv4_addr
        flags interval
        elements = {
            1.1.1.1, 1.0.0.1,         # Cloudflare
            8.8.8.8, 8.8.4.4,         # Google
            9.9.9.9, 149.112.112.112, # Quad9
            208.67.222.222, 208.67.220.220 # OpenDNS
        }
    }

    chain output_filter {
        # Drop direct HTTPS connections to known DoH IPs
        ip daddr @doh_providers tcp dport 443 drop
    }
}
EOF
        log_message "[+] Added nftables rule to drop direct connections to public DoH IPs"
    fi

    log_message "[+] DNS over HTTPS successfully disabled across system and browsers"
}


reset_network_rules() {
    # Re-enable IPv6 when resetting rules
    enable_ipv6
    # Enable DNS over HTTPS
    enable_doh
    # Completely delete our custom nftables table
    nft delete table ip ghostroute__gr 2>/dev/null || true
    
    log_message "[+] Cleared all network rules"
}

setup_network_rules() {
    reset_network_rules
    EXCLUDED_IPS+=("${EXCLUDED_NETWORKS[@]}")
    
    # Disable IPv6 to prevent leaks
    disable_ipv6

    # Disable DNS over HTTPS to prevent leaks
    disable_doh

    restart_tor_service() {
        if [ "$DISTRO" = "debian" ] || [ "$DISTRO" = "fedora" ] || [ "$DISTRO" = "arch" ]; then

            if systemctl restart tor >/dev/null 2>&1 || systemctl restart tor@default >/dev/null 2>&1; then

                echo -e " \033[92m[+]\033[0m GhostRoute: Privacy mode \033[92m[ACTIVE]\033[0m"
                show_current_ip
            else
                echo -e "\033[91m[!]\033[0m Failed to restart Tor"
            fi
        fi
    }

    trap restart_tor_service EXIT

    local excluded_set=""
    if [ ${#EXCLUDED_IPS[@]} -gt 0 ]; then
        excluded_set=$(IFS=, ; echo "${EXCLUDED_IPS[*]}")
    fi

    # Load all firewall rules atomically into nftables
    nft -f - <<EOF
table ip ghostroute__gr {

    set excluded_nets {
        type ipv4_addr
        flags interval
        elements = { ${excluded_set} }
    }
    # NAT OUTPUT
    chain ghostroute__output__nat {
        type nat hook output priority dstnat;
        policy accept;

        skuid "$TOR_USER" return

        oif "lo" return

        udp dport $DNS_PORT redirect to :$DNS_PORT
        tcp dport 53 redirect to :$DNS_PORT

        ip daddr @excluded_nets return

        tcp flags syn redirect to :$TOR_PORT
    }
    # FILTER OUTPUT
    chain ghostroute__output__filter {
        type filter hook output priority filter;
        policy drop;

        oif "lo" accept

        oif != "lo" ip daddr != $LOCALHOST ip saddr != $LOCALHOST tcp flags & (ack | fin) == (ack | fin) drop

        oif != "lo" ip daddr != $LOCALHOST ip saddr != $LOCALHOST tcp flags & (ack | rst) == (ack | rst) drop

        ct state established,related accept

        ip daddr @excluded_nets accept

        ip protocol 17 drop

        skuid "$TOR_USER" accept

        reject
    }
}
EOF

    log_message "[+] GhostRoute: Network rules configured for Tor routing"
}


get_location_info() {
    local ip_address=$1
    local country city
    if response=$(curl -s "http://ip-api.com/json/$ip_address"); then
        country=$(echo "$response" | jq -r '.country // empty')
        city=$(echo "$response" | jq -r '.city // empty')
        echo "$country,$city"
    else
        echo ","
    fi
}

show_current_ip() {
    echo -e " \033[93m[*]\033[0m GhostRoute: Fetching public IP address..."
    public_ip=""
    
    # Try to get IP from Tor project API
    for attempt in {1..9}; do
        if response=$(curl -s https://check.torproject.org/api/ip --connect-timeout 5 2>/dev/null); then
            public_ip=$(echo "$response" | jq -r '.IP // empty')
            [ -n "$public_ip" ] && break
        fi
        echo -e " \033[93m[?]\033[0m GhostRoute: Waiting for IP address..."
        sleep 5
    done
    
    # Fallback to alternative method if Tor project API fails
    if [ -z "$public_ip" ]; then
        if response=$(curl -s https://httpbin.org/ip); then
            public_ip=$(echo "$response" | jq -r '.origin // empty')
        fi
    fi
    
    if [ -z "$public_ip" ]; then
        echo -e "\033[91m[!]\033[0m GhostRoute: Could not determine public IP address!"
        exit 1
    fi

    # Display IP and location information
    IFS=, read -r country city <<< "$(get_location_info "$public_ip")"
    if [ -n "$country" ] && [ -n "$city" ]; then
        echo -e " \033[92m[+]\033[0m GhostRoute: Your IP: \033[92m$public_ip\033[0m"
        echo -e " \033[92m[+]\033[0m GhostRoute: Location: \033[92m$country, $city\033[0m"
        log_message "[+] GhostRoute: Current IP: $public_ip"
        log_message "[+] GhostRoute: Location: $country, $city"
    else
        echo -e " \033[92m[+]\033[0m GhostRoute: Your IP: \033[92m$public_ip\033[0m"
        echo -e " \033[93m[!]\033[0m GhostRoute: Could not determine location"
        log_message "[+] GhostRoute: Current IP: $public_ip"
    fi
}

change_ip_address() {
    tor_pid=$(pidof tor)

    if [ -n "$tor_pid" ]; then
        kill -HUP "$tor_pid"
        show_current_ip
    else
        echo -e "\033[91m[!]\033[0m Tor is not running!"
    fi
}

check_bash() {
  if [ -z "$BASH_VERSION" ]; then
      printf "\033[31m[!]\033[0m Error: This script must be run with Bash.\n"
      exit 1
  fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e " \033[91m[!]\033[0m please run as root or with sudo."
        exit 1
    fi
}

install_tor() {
    if command -v tor >/dev/null 2>&1; then
        return 0
    fi

    echo " [*] Tor is not installed. Attempting to install Tor..."

    case "$DISTRO" in
        debian)
            apt-get update && apt-get install -y tor || return 1
            ;;
        fedora)
            dnf update -y && dnf install -y tor || return 1
            ;;
        arch)
            pacman -Syu --noconfirm tor || return 1
            ;;
        *)
            echo " [-] Unsupported distribution. Please install Tor manually."
            return 1
            ;;
    esac

    if command -v tor >/dev/null 2>&1; then
        echo " [+] Tor installed successfully."
        clear
        return 0
    else
        echo " [-] Tor installation failed."
        return 1
    fi
}

install_jq() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi

    echo " [*] jq is not installed. Attempting to install jq..."

    case "$DISTRO" in
        debian)
            apt-get update && apt-get install -y jq || return 1
            ;;
        fedora)
            dnf update -y && dnf install -y jq || return 1
            ;;
        arch)
            pacman -Syu --noconfirm jq || return 1
            ;;
        *)
            echo " [-] Unsupported distribution. Please install jq manually."
            return 1
            ;;
    esac

    if command -v jq >/dev/null 2>&1; then
        echo " [+] jq installed successfully."
        clear
        return 0
    else
        echo " [-] jq installation failed."
        return 1
    fi
}

install_nftables() {
    if command -v nft >/dev/null 2>&1; then
        return 0
    fi

    echo " [*] nftables is not installed. Attempting to install nftables..."

    case "$DISTRO" in
        debian)
            apt-get update && apt-get install -y nftables || return 1
            ;;
        fedora)
            dnf update -y && dnf install -y nftables || return 1
            ;;
        arch)
            pacman -Syu --noconfirm nftables || return 1
            ;;
        *)
            echo " [-] Unsupported distribution. Please install nftables manually."
            return 1
            ;;
    esac

    if command -v nft >/dev/null 2>&1; then
        echo " [+] nftables installed successfully."
        clear
        return 0
    else
        echo " [-] nftables installation failed."
        return 1
    fi
}

main() {
    check_bash
    check_root
    
    if ! install_tor; then
        exit 1
    fi
    
    if ! install_jq; then
         exit 1
    fi

    if ! install_nftables; then
         exit 1
    fi
   
    # If no arguments provided, show usage
    if [ $# -eq 0 ]; then
        show_usage
        exit 1
    fi

    # Parse command line arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            -s|--start)
                setup_network_rules
                shift
                ;;
            -x|--stop)
                reset_network_rules
                echo -e " \033[93m[!]\033[0m GhostRoute: Privacy mode \033[91m[INACTIVE]\033[0m"
                log_message "[!] GhostRoute: Privacy mode deactivated"
                shift
                ;;
            -n|--new-ip)
                change_ip_address
                shift
                ;;
            -i|--ip)
                show_current_ip
                shift
                ;;
            -a|--auto)
                interval=${2:-500}
                if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
                    echo "Error: Interval must be a number"
                    show_usage
                    exit 1
                fi
                echo -e " \033[92m[+]\033[0m GhostRoute: Auto IP switching enabled. Interval: $interval seconds"
                while true; do
                    change_ip_address
                    echo -e " \033[92m[*]\033[0m GhostRoute: Successfully changed IP address\n"
                    sleep "$interval"
                done
                # We don't shift 2 here because we're in an infinite loop
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

show_usage() {
    echo "Usage: ghostroute [OPTION]"
    echo
    echo "Options:"
    echo "  -s, --start       Start GhostRoute (route traffic through Tor)"
    echo "  -x, --stop        Stop GhostRoute and reset network rules"
    echo "  -n, --new-ip      Get a new IP address through Tor"
    echo "  -i, --ip          Show current public IP address"
    echo "  -a, --auto [SEC]  Automatically change IP at regular intervals (default: 500)"
    echo "  -h, --help        Show this help message"
}


# Register cleanup function
trap cleanup EXIT

# Check if Tor configuration needs to be updated
if [ -f "$TOR_CONFIG" ] && ! grep -q "VirtualAddrNetwork" "$TOR_CONFIG"; then
    echo "$TOR_CONFIG_CONTENT" >> "$TOR_CONFIG"
fi

main "$@"
