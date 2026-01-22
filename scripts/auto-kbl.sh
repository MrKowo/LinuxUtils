#!/bin/bash

# ==============================================================================
# Auto KBL - Automatic Keyboard Layout Switcher
# ==============================================================================

APP_NAME="auto-kbl"

# 1. Config: User settings (config.json)
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_DIR="$XDG_CONFIG_HOME/$APP_NAME"
CONFIG_FILE="$CONFIG_DIR/config.json"

# 2. Data: Internal scripts (layout_daemon.py)
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
DATA_DIR="$XDG_DATA_HOME/$APP_NAME"
PYTHON_SCRIPT="$DATA_DIR/layout_daemon.py"

# 3. State: Logs (daemon.log)
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
STATE_DIR="$XDG_STATE_HOME/$APP_NAME"
LOG_FILE="$STATE_DIR/daemon.log"

# 4. Autostart: Desktop entry
AUTOSTART_DIR="$XDG_CONFIG_HOME/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/$APP_NAME.desktop"

# Colors
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GREY='\033[0;90m'
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

# Ensure directories exist
mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$STATE_DIR"

# --- UI Functions ---

get_system_status() {
    # Check Daemon PID
    if pgrep -f "layout_daemon.py" > /dev/null; then
        DAEMON_STATUS="${GREEN}● Active${RESET}"
    else
        DAEMON_STATUS="${RED}● Stopped${RESET}"
    fi

    # Check Autostart File
    if [ -f "$AUTOSTART_FILE" ]; then
        BOOT_STATUS="${GREEN}Enabled${RESET}"
    else
        BOOT_STATUS="${GREY}Disabled${RESET}"
    fi

    # Check Config File
    if [ -f "$CONFIG_FILE" ]; then
        # Count configured devices (Force no color to avoid grep noise)
        DEV_COUNT=$(grep --color=never -o "device_name" "$CONFIG_FILE" | wc -l)
        CONFIG_STATUS="${WHITE}${DEV_COUNT} Devices${RESET}"
    else
        CONFIG_STATUS="${YELLOW}Not Configured${RESET}"
    fi
}

print_header() {
    clear
    get_system_status
    echo -e "                      ${WHITE}Auto KBL${RESET}"
    echo -e "   ${BLUE}──────────────────────────────────────────────────${RESET}"
    echo -e "   ${GREY}Service:${RESET}   $DAEMON_STATUS      ${GREY}Autostart:${RESET} $BOOT_STATUS"
    echo -e "   ${GREY}Config:${RESET}    $CONFIG_STATUS"
    echo -e "   ${BLUE}──────────────────────────────────────────────────${RESET}"
}

print_option() {
    local num=$1
    local text=$2
    echo -e "   ${BLUE}█${RESET} ${CYAN}${num}${RESET} ${GREY}::${RESET} ${WHITE}${text}${RESET}"
}

print_status() {
    echo -e "   ${BLUE}──────────────────────────────────────────────────${RESET}"
}

check_dependencies() {
    # Distro-Agnostic Check:
    # Instead of checking for 'rpm' or 'apt', we check if Python can actually import the module.
    if ! python3 -c "import evdev" 2>/dev/null; then
        echo -e "${RED}Error: Python module 'evdev' not found.${RESET}"
        echo -e "Please install 'python3-evdev' using your package manager."
        echo -e "Examples:"
        echo -e "  Fedora: ${WHITE}sudo dnf install python3-evdev${RESET}"
        echo -e "  Ubuntu: ${WHITE}sudo apt install python3-evdev${RESET}"
        echo -e "  Arch:   ${WHITE}sudo pacman -S python-evdev${RESET}"
        read -p "Press Enter to exit..."
        exit 1
    fi
}

check_permissions() {
    # 1. Input Group
    if ! groups "$USER" | grep -q "\binput\b"; then
        echo -e "${CYAN}Permissions Check:${RESET} User not in 'input' group."
        read -p "   Add '$USER' to 'input'? (y/n): " ans
        if [[ $ans == "y" ]]; then
            sudo usermod -aG input "$USER"
            echo -e "   ${GREEN}Added.${RESET} Please LOGOUT and LOGIN for this to take effect."
            read -p "   Press Enter..."
        fi
    fi

    # 2. UInput Write Access
    if [ ! -w /dev/uinput ]; then
        echo -e "${CYAN}Permissions Check:${RESET} No write access to /dev/uinput."
        read -p "   Fix permissions temporarily with chmod? (y/n): " ans
        if [[ $ans == "y" ]]; then
            sudo chmod 660 /dev/uinput
            sudo chown root:input /dev/uinput
            echo -e "   ${GREEN}Fixed.${RESET}"
        else
            echo -e "   ${RED}Skipping.${RESET} Shortcuts may fail."
        fi
    fi
}

get_gnome_layouts() {
    gsettings get org.gnome.desktop.input-sources sources | \
    sed "s/^@a(ss) //" | \
    sed "s/[][(),]/ /g" | \
    awk '{ for (i=1; i<=NF; i+=2) print (i-1)/2 ". " $i " " $(i+1) }'
}

scan_devices_and_configure() {
    print_header
    echo -e "   ${CYAN}Scanning hardware...${RESET}"
    
    # We use a temp file in the STATE dir
    TEMP_DEV_FILE="$STATE_DIR/temp_devices.txt"
    TEMP_LAYOUT_FILE="$STATE_DIR/temp_layouts.txt"

    python3 -c "
import evdev
from evdev import ecodes

devices = [evdev.InputDevice(path) for path in evdev.list_devices()]
valid_devices = []

for dev in devices:
    # Filter out our own virtual device to prevent confusion
    if 'auto-layout-injector' in dev.name:
        continue
        
    caps = dev.capabilities()
    if ecodes.EV_KEY in caps:
        # Check if device has KEY_A (30) to identify it as a keyboard
        if 30 in caps[ecodes.EV_KEY]:
            valid_devices.append(dev)

for i, dev in enumerate(valid_devices):
    print(f'{i}|{dev.name}|{dev.path}|{dev.phys}')
" > "$TEMP_DEV_FILE"

    if [ ! -s "$TEMP_DEV_FILE" ]; then
        echo -e "   ${RED}No keyboards found! Check permissions.${RESET}"
        read -p "   Press Enter to return..."
        return
    fi

    get_gnome_layouts > "$TEMP_LAYOUT_FILE"
    declare -A CONFIG_MAP

    # Pre-load existing config safely using Python
    if [ -f "$CONFIG_FILE" ]; then
        TEMP_CONFIG_READ="$STATE_DIR/temp_config_read.txt"
        python3 -c "
import json
import sys
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
        for entry in data:
            print(f\"{entry['device_name']}|{entry['layout_index']}\")
except:
    pass
" > "$TEMP_CONFIG_READ"
        
        while IFS='|' read -r saved_name saved_idx; do
            matched_id=$(grep -F "$saved_name" "$TEMP_DEV_FILE" | cut -d'|' -f1 | head -n 1)
            if [ ! -z "$matched_id" ]; then
                CONFIG_MAP[$matched_id]=$saved_idx
            fi
        done < "$TEMP_CONFIG_READ"
        rm -f "$TEMP_CONFIG_READ"
    fi

    while true; do
        print_header
        
        echo -e "   ${WHITE}Detected Input Devices:${RESET}"
        echo -e "   ${BLUE}┌────┬───────────────────────────────────────────────┬─────────────┐${RESET}"
        echo -e "   ${BLUE}│${RESET} ID ${BLUE}│${RESET} Device Name                                   ${BLUE}│${RESET} Status      ${BLUE}│${RESET}"
        echo -e "   ${BLUE}├────┼───────────────────────────────────────────────┼─────────────┤${RESET}"
        
        while IFS='|' read -r id name path phys; do
            short_name=$(echo "$name" | cut -c 1-45)
            printf -v padded_name "%-45s" "$short_name"
            
            if [[ -n "${CONFIG_MAP[$id]}" ]]; then
                layout_id="${CONFIG_MAP[$id]}"
                printf "   ${BLUE}│${RESET} ${CYAN}%-2s${RESET} ${BLUE}│${RESET} ${WHITE}%s${RESET} ${BLUE}│${RESET} ${GREEN}Layout %-5s${RESET}${BLUE}│${RESET}\n" "$id" "$padded_name" "$layout_id"
            else
                printf "   ${BLUE}│${RESET} %-2s ${BLUE}│${RESET} %s ${BLUE}│${RESET} %-12s${BLUE}│${RESET}\n" "$id" "$padded_name" "Unset"
            fi
        done < "$TEMP_DEV_FILE"
        echo -e "   ${BLUE}└────┴───────────────────────────────────────────────┴─────────────┘${RESET}"

        echo -e "\n   ${WHITE}Available GNOME Layouts:${RESET}"
        while read -r line; do
             echo -e "   ${GREY}•${RESET} ${CYAN}$line${RESET}"
        done < "$TEMP_LAYOUT_FILE"

        echo -e "\n   ${YELLOW}Type ID to configure, or ${RESET}${GREEN}'q'${RESET}${YELLOW} to save & apply.${RESET}"
        read -p "   > " dev_id
        
        if [[ "$dev_id" == "q" ]]; then
            break
        fi

        dev_line=$(grep "^$dev_id|" "$TEMP_DEV_FILE")
        if [[ -z "$dev_line" ]]; then
            continue
        fi
        
        dev_name=$(echo "$dev_line" | cut -d'|' -f2)

        echo -e "   Enter ${CYAN}Layout Index${RESET} for '$dev_name' (or ${YELLOW}'u'${RESET} to unset):"
        read -p "   > " layout_idx
        
        if [[ "$layout_idx" == "u" ]]; then
             unset CONFIG_MAP[$dev_id]
             echo -e "   ${YELLOW}Device unset.${RESET}"
             sleep 0.5
             continue
        fi
        
        if ! grep -q "^$layout_idx\." "$TEMP_LAYOUT_FILE"; then
             echo -e "   ${RED}Invalid Index.${RESET}"
             sleep 1
             continue
        fi

        CONFIG_MAP[$dev_id]=$layout_idx
    done

    json_str="["
    first=true
    for id in "${!CONFIG_MAP[@]}"; do
        layout=${CONFIG_MAP[$id]}
        name=$(grep "^$id|" "$TEMP_DEV_FILE" | cut -d'|' -f2)
        
        safe_name=${name//\\/\\\\}
        safe_name=${safe_name//\"/\\\"}
        
        if [ "$first" = true ]; then first=false; else json_str+=", "; fi
        json_str+="{\"device_name\": \"$safe_name\", \"layout_index\": $layout}"
    done
    json_str+="]"
    echo "$json_str" > "$CONFIG_FILE"
    rm "$TEMP_DEV_FILE" "$TEMP_LAYOUT_FILE"
}

generate_python_script() {
    # Note: We pass the CONFIG_FILE path into the python script so it knows where to look.
    cat << EOF > "$PYTHON_SCRIPT"
#!/usr/bin/env python3
import evdev
import select
import json
import os
import subprocess
import time
import ast
from evdev import ecodes, UInput

CONFIG_FILE = "$CONFIG_FILE"

CAPS = {
    ecodes.EV_KEY: [
        ecodes.KEY_LEFTMETA, ecodes.KEY_SPACE, 
        ecodes.KEY_ENTER, ecodes.KEY_ESC, ecodes.KEY_TAB,
        ecodes.KEY_A, ecodes.KEY_B
    ]
}

def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

def load_config():
    if not os.path.exists(CONFIG_FILE): return []
    try:
        with open(CONFIG_FILE, 'r') as f: return json.load(f)
    except json.JSONDecodeError:
        log("Error: Config file is corrupted.")
        return []

def clean_output(output):
    output = output.strip()
    if output.startswith('@'):
        try: _, content = output.split(' ', 1); return content.strip()
        except: return output
    return output

def enforce_global_config():
    try:
        subprocess.run(
            ["gsettings", "set", "org.gnome.desktop.input-sources", "per-window", "false"],
            stderr=subprocess.DEVNULL
        )
    except: pass

def get_current_mru_first_item():
    try:
        raw = subprocess.check_output(
            ["gsettings", "get", "org.gnome.desktop.input-sources", "mru-sources"], 
            text=True
        )
        s = clean_output(raw)
        if s == "[]" or not s:
            raw_s = subprocess.check_output(
                 ["gsettings", "get", "org.gnome.desktop.input-sources", "sources"], text=True
            )
            parsed_s = ast.literal_eval(clean_output(raw_s))
            return parsed_s[0] if parsed_s else None
            
        mru = ast.literal_eval(s)
        return mru[0] if mru else None
    except:
        return None

def get_target_item_from_index(index):
    try:
        raw = subprocess.check_output(
            ["gsettings", "get", "org.gnome.desktop.input-sources", "sources"], 
            text=True
        )
        sources = ast.literal_eval(clean_output(raw))
        if index < len(sources):
            return sources[index]
    except:
        pass
    return None

def switch_via_shortcut(ui, target_tuple):
    log("Strategy: Cycling layout via Super+Space...")
    for _ in range(4):
        current = get_current_mru_first_item()
        if current == target_tuple: return True
        ui.write(ecodes.EV_KEY, ecodes.KEY_LEFTMETA, 1)
        ui.write(ecodes.EV_KEY, ecodes.KEY_SPACE, 1)
        ui.syn()
        time.sleep(0.15) 
        ui.write(ecodes.EV_KEY, ecodes.KEY_SPACE, 0)
        ui.write(ecodes.EV_KEY, ecodes.KEY_LEFTMETA, 0)
        ui.syn()
        time.sleep(0.25)
    return False

def set_gnome_layout(index, uinput_dev):
    try:
        target = get_target_item_from_index(index)
        if not target: return
        current = get_current_mru_first_item()
        if current == target: return
        subprocess.run(["gsettings", "set", "org.gnome.desktop.input-sources", "current", str(index)], stderr=subprocess.DEVNULL)
        time.sleep(0.1)
        if get_current_mru_first_item() == target: return
        if uinput_dev: switch_via_shortcut(uinput_dev, target)
    except Exception as e:
        log(f"Switching Exception: {e}")

def main():
    config = load_config()
    if not config:
        log("No config found or invalid.")
        return
    enforce_global_config()
    try:
        ui = UInput(CAPS, name="auto-layout-injector", version=0x1)
        log("Virtual keyboard initialized.")
    except Exception as e:
        log(f"Virtual keyboard failed: {e}")
        ui = None
    log("Daemon started. Monitoring devices...")
    monitored_devices = {}
    for _ in range(5):
        try:
            available = [evdev.InputDevice(path) for path in evdev.list_devices()]
            for dev in available:
                if "auto-layout-injector" in dev.name: continue 
                for entry in config:
                    if entry['device_name'] == dev.name:
                        if dev.fd not in monitored_devices:
                            log(f"Monitoring: {dev.name} -> Layout {entry['layout_index']}")
                            monitored_devices[dev.fd] = {'dev': dev, 'layout': entry['layout_index']}
            if monitored_devices: break
        except: pass
        time.sleep(1)
    if not monitored_devices:
        log("No configured devices found.")
        return
    p = select.poll()
    for fd in monitored_devices: p.register(fd, select.POLLIN)
    last_layout = -1
    while True:
        try:
            for fd, event_mask in p.poll():
                dev_info = monitored_devices.get(fd)
                if not dev_info: continue
                device = dev_info['dev']
                target = dev_info['layout']
                try:
                    for event in device.read():
                        if event.type == ecodes.EV_KEY and event.value == 1:
                            if target != last_layout:
                                log(f"Input from {device.name} -> Requesting Layout {target}")
                                enforce_global_config() 
                                set_gnome_layout(target, ui)
                                last_layout = target
                            break 
                except OSError:
                    p.unregister(fd)
                    del monitored_devices[fd]
        except KeyboardInterrupt: break
        except Exception as e:
            log(f"Loop error: {e}")
            time.sleep(1)
    if ui: ui.close()

if __name__ == "__main__":
    main()
EOF
    chmod +x "$PYTHON_SCRIPT"
}

setup_autostart() {
    mkdir -p "$AUTOSTART_DIR"
    cat << EOF > "$AUTOSTART_FILE"
[Desktop Entry]
Type=Application
Name=Auto KBL
Exec=/bin/bash -c "${PYTHON_SCRIPT} > ${LOG_FILE} 2>&1"
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Comment=Switch keyboard layout based on device usage
EOF
}

start_daemon() {
    pkill -f "layout_daemon.py"
    nohup "$PYTHON_SCRIPT" > "$LOG_FILE" 2>&1 &
    sleep 1
}

# --- Service Management ---

manage_service_menu() {
    while true; do
        clear
        print_header
        echo -e "   ${WHITE}Service Management${RESET}"
        print_status
        
        if pgrep -f "layout_daemon.py" > /dev/null; then
            daemon_toggle_text="Stop Service"
        else
            daemon_toggle_text="Start Service"
        fi

        if [ -f "$AUTOSTART_FILE" ]; then
            autostart_toggle_text="Toggle Autostart"
        else
            autostart_toggle_text="Toggle Autostart"
        fi

        print_option 1 "$daemon_toggle_text"
        print_option 2 "$autostart_toggle_text"
        print_option 3 "Back to Main Menu"
        
        echo ""
        print_status
        echo -e "   ${GREY}Select an option:${RESET}"
        read -p "   > " subopt

        case $subopt in
            1)
                if pgrep -f "layout_daemon.py" > /dev/null; then
                    pkill -f "layout_daemon.py"
                    echo -e "   ${YELLOW}Service stopped.${RESET}"
                else
                    if [ ! -f "$PYTHON_SCRIPT" ]; then
                        generate_python_script
                    fi
                    start_daemon
                    echo -e "   ${GREEN}Service started.${RESET}"
                fi
                sleep 0.5
                ;;
            2)
                if [ -f "$AUTOSTART_FILE" ]; then
                    rm -f "$AUTOSTART_FILE"
                    echo -e "   ${YELLOW}Autostart disabled.${RESET}"
                else
                    setup_autostart
                    echo -e "   ${GREEN}Autostart enabled.${RESET}"
                fi
                sleep 0.5
                ;;
            3) return ;;
            *) echo "Invalid option." ; sleep 0.5 ;;
        esac
    done
}

# --- Unified Workflow ---

configure_and_update() {
    scan_devices_and_configure
    generate_python_script
    
    if [ ! -f "$AUTOSTART_FILE" ]; then
        echo -e "\n   ${CYAN}Startup Configuration:${RESET}"
        read -p "   Run automatically on login? (Y/n): " auto_ans
        if [[ "$auto_ans" =~ ^[Nn]$ ]]; then
            echo -e "   ${GREY}Skipping autostart.${RESET}"
        else
            setup_autostart
            echo -e "   ${GREEN}Autostart enabled.${RESET}"
        fi
    else
        setup_autostart 
    fi

    start_daemon
    echo -e "\n   ${GREEN}Success! Configuration applied and daemon restarted.${RESET}"
    read -p "   Press Enter..."
}

uninstall() {
    echo -e "   ${WHITE}Stopping background process...${RESET}"
    pkill -f "layout_daemon.py"
    # Clean up all XDG directories
    rm -f "$PYTHON_SCRIPT" "$CONFIG_FILE" "$AUTOSTART_FILE" "$LOG_FILE"
    rmdir "$CONFIG_DIR" 2>/dev/null
    rmdir "$DATA_DIR" 2>/dev/null
    rmdir "$STATE_DIR" 2>/dev/null
    echo -e "   ${GREEN}Uninstalled successfully.${RESET}"
    read -p "   Press Enter to exit..."
    exit 0
}

monitor_daemon() {
    clear
    print_header
    echo -e "   ${WHITE}Monitoring Logs${RESET} ${GREY}(Ctrl+C to return)${RESET}"
    echo -e "   ${GREY}Log file: $LOG_FILE${RESET}"
    print_status
    if [ ! -f "$LOG_FILE" ]; then echo "Log file not found."; else tail -f "$LOG_FILE"; fi
}

# --- Main Menu ---

check_dependencies
check_permissions

while true; do
    print_header
    print_option 1 "Configure"
    print_option 2 "Manage Services"
    print_option 3 "Monitor Log"
    print_option 4 "Uninstall"
    print_option 5 "Exit"
    echo ""
    print_status
    echo -e "   ${WHITE}Select an option:${RESET}"
    read -p "   > " opt

    case $opt in
        1) configure_and_update ;;
        2) manage_service_menu ;;
        3) (trap 'exit 0' INT; monitor_daemon) ;;
        4) uninstall ;;
        5) exit 0 ;;
        *) echo "Invalid option." ; sleep 1 ;;
    esac
done
