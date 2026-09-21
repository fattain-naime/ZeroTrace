#!/usr/bin/env bash

if [ -z "$BASH_VERSION" ]; then
    printf "\033[31m[!]\033[0m Error: This script must be run with Bash.\n"
    exit 1
fi

# Require root
if [[ "$EUID" -ne 0 ]]; then
    echo -e "\e[31m[!]\e[0m Please run this script as root."
    exit 1
fi

read -p "[+] To install press (Y) | To uninstall press (N) >> " choice
choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')

if [[ "$choice" == "y" ]]; then
    chmod 755 ghostroute.sh
    mkdir -p /usr/share/ghostroute
    cp ghostroute.sh /usr/share/ghostroute/ghostroute.sh

    # Shell wrapper
    echo -e "#!/usr/bin/env bash\nexec /usr/share/ghostroute/ghostroute.sh \"\$@\"" > /usr/bin/ghostroute

    chmod +x /usr/bin/ghostroute
    chmod +x /usr/share/ghostroute/ghostroute.sh

    echo -e "\n\n[✔] GhostRoute installed successfully!"
    echo -e "[→] Now you can run it by typing: \e[6;30;42mghostroute\e[0m\n"

elif [[ "$choice" == "n" ]]; then
    rm -rf /usr/share/ghostroute
    rm -f /usr/bin/ghostroute
    echo "[✔] GhostRoute has been removed successfully."

else
    echo "[!] Invalid choice. Please enter Y or N."
fi
