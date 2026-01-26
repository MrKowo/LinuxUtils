#!/bin/bash

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then 
    echo "This script requires root privileges. Attempting to elevate..."
    exec sudo "$0" "$@"
fi
# --- CONFIGURATION ---
BACKUP_DIR="/boot/grub_tidy_backups"
DRY_RUN=false

# --- AUTO-DETECT SYSTEM INFO ---
if [ -f /etc/os-release ]; then
    source /etc/os-release
    OS_LABEL="${NAME} ${VERSION_ID:-}"
else
    OS_LABEL="Linux"
fi

# --- AUTO-DETECT GRUB COMMAND ---
if command -v grub2-mkconfig >/dev/null 2>&1; then
    GRUB_CMD="grub2-mkconfig"
    # Fedora/RHEL usually use /boot/grub2/grub.cfg
    # But check if /boot/grub2/grub.cfg exists, otherwise try /boot/grub/grub.cfg
    if [ -f "/boot/grub2/grub.cfg" ]; then
        GRUB_CFG="/boot/grub2/grub.cfg"
    elif [ -f "/boot/grub/grub.cfg" ]; then
        GRUB_CFG="/boot/grub/grub.cfg"
    else
        GRUB_CFG="/boot/grub2/grub.cfg" # Default fallback
    fi
elif command -v grub-mkconfig >/dev/null 2>&1; then
    GRUB_CMD="grub-mkconfig"
    GRUB_CFG="/boot/grub/grub.cfg"
else
    echo "Error: Could not find grub-mkconfig command."
    exit 1
fi

ENTRY_DIR="/boot/loader/entries"

# Colors
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GREY='\033[0;90m'
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'
BOLD='\033[1m'
NC='\033[0m' # Keep NC for backward compatibility if used, but alias to RESET 

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${RED}[WARN]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

# --- UI Functions ---

get_system_status() {
    # Check Backups
    if [ -d "$BACKUP_DIR" ]; then
        BACKUP_COUNT=$(ls -1 "$BACKUP_DIR" 2>/dev/null | wc -l)
        if [ "$BACKUP_COUNT" -eq 0 ]; then
             BACKUP_STATUS="${YELLOW}None${RESET}"
        else
             BACKUP_STATUS="${GREEN}${BACKUP_COUNT} Available${RESET}"
        fi
    else
        BACKUP_STATUS="${RED}Dir Missing${RESET}"
    fi

    # Check BLS
    if [ -d "$ENTRY_DIR" ]; then
        BLS_STATUS="${GREEN}Active${RESET}"
    else
        BLS_STATUS="${YELLOW}Not Found${RESET}"
    fi
}

print_header() {
    clear
    get_system_status
    echo -e "                      ${WHITE}GRUB Tidy${RESET}"
    echo -e "   ${BLUE}──────────────────────────────────────────────────${RESET}"
    echo -e "   ${GREY}Backups:${RESET}   $BACKUP_STATUS      ${GREY}BLS Mode:${RESET} $BLS_STATUS"
    echo -e "   ${GREY}Config:${RESET}    ${WHITE}$GRUB_CFG${RESET}"
    echo -e "   ${BLUE}──────────────────────────────────────────────────${RESET}"
}

print_option() {
    local num=$1
    local text=$2
    echo -e "   ${CYAN}${num}${RESET} ${GREY}::${RESET} ${WHITE}${text}${RESET}"
}

print_status() {
    echo -e "   ${BLUE}──────────────────────────────────────────────────${RESET}"
}

# --- FUNCTIONS ---

create_backup() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local target="$BACKUP_DIR/$timestamp"
    
    log "Creating backup at $target..."
    if [ "$DRY_RUN" = true ]; then
        echo "  (Dry Run) Would mkdir -p $target"
        echo "  (Dry Run) Would cp -r $ENTRY_DIR $target/entries"
        echo "  (Dry Run) Would cp $GRUB_CFG $target/grub.cfg"
    else
        sudo mkdir -p "$target"
        [ -d "$ENTRY_DIR" ] && sudo cp -r "$ENTRY_DIR" "$target/entries"
        [ -f "$GRUB_CFG" ] && sudo cp "$GRUB_CFG" "$target/grub.cfg"
        success "Backup created."
    fi
}

clean_bls_entries() {
    if [ ! -d "$ENTRY_DIR" ]; then
        warn "BLS entry directory not found. Skipping BLS cleanup."
        return
    fi

    log "Analyzing BLS entries..."
    
    # Check for BLS entries
    if ! ls "$ENTRY_DIR"/*.conf >/dev/null 2>&1; then
        warn "No .conf files found in $ENTRY_DIR"
        return
    fi

    for file in "$ENTRY_DIR"/*.conf; do
        [ -e "$file" ] || continue
        
        # Read content again safely
        if [ -r "$file" ]; then
            content=$(cat "$file")
        else
            content=$(sudo cat "$file")
        fi
        
        ver=$(echo "$content" | grep -E "^\s*version" | awk '{print $2}')
        current_title=$(echo "$content" | grep -E "^\s*title" | sed 's/^\s*title //')
        
        # Determine new title
        new_title=""
        
        if [[ "$file" == *"rescue"* ]] || [[ "$ver" == *"rescue"* ]]; then
             new_title="$OS_LABEL (Rescue)"
        else
             # Simplify version: 6.8.9-300.fc40... -> 6.8.9
             short_ver=$(echo "$ver" | awk -F- '{print $1}')
             if [ -z "$short_ver" ]; then short_ver="Old"; fi
             new_title="$OS_LABEL ($short_ver)"
        fi
        
        if [ "$current_title" != "$new_title" ]; then
            if [ "$DRY_RUN" = true ]; then
                echo "  (Dry Run) Rename: '$current_title' -> '$new_title'"
            else
                # Use standard sed
                # Escape special chars in title if needed, but titles are usually safe-ish alphanumeric
                sudo sed -i "s|^title .*|title $new_title|" "$file"
                echo "  Renamed: $new_title"
            fi
        fi
    done
}

post_process_grub_cfg() {
    log "Post-processing grub.cfg for non-BLS entries..."
    
    if [ "$DRY_RUN" = true ]; then
        echo "  (Dry Run) Would run: $GRUB_CMD -o $GRUB_CFG"
        echo "  (Dry Run) Would clean Windows/Ubuntu entries in $GRUB_CFG"
        return
    fi
    
    # Regenerate first to apply BLS changes
    log "Regenerating GRUB config..."
    sudo $GRUB_CMD -o "$GRUB_CFG" > /dev/null 2>&1
    
    # Sed magic to clean up other OSes
    # 1. Windows Boot Manager (on /dev/...) -> Windows
    sudo sed -i -E "s/menuentry 'Windows Boot Manager.*class windows/menuentry 'Windows' --class windows/" "$GRUB_CFG"
    
    # 2. Ubuntu ... (on /dev/...) -> Ubuntu
    # This is trickier as Ubuntu versions vary. 
    # Try to catch "Ubuntu" at start and strip the rest until the closing quote
    # Be careful not to break the entry.
    # Safe approach: Just target specific common patterns if user didn't specify.
    # For now, let's just do Windows and maybe generic cleaning of " (on /dev/...)" suffix?
    
    # Clean " (on /dev/sda1)" style suffixes from ANY menuentry
    sudo sed -i -E "s/ \(on \/dev\/[^)]+\)//g" "$GRUB_CFG"
    
    success "GRUB config optimized."
}

reset_entries() {
    log "Resetting kernel entries..."
    if command -v kernel-install >/dev/null 2>&1; then
        for kpath in /lib/modules/*; do
            if [ -d "$kpath" ]; then
                kver=$(basename "$kpath")
                if [ -f "$kpath/vmlinuz" ]; then
                    if [ "$DRY_RUN" = true ]; then
                        echo "  (Dry Run) Would restore: $kver"
                    else
                        echo "  Restoring: $kver"
                        sudo kernel-install add "$kver" "$kpath/vmlinuz" > /dev/null 2>&1
                    fi
                fi
            fi
        done
        [ "$DRY_RUN" = false ] && sudo $GRUB_CMD -o "$GRUB_CFG" > /dev/null 2>&1
        success "Reset complete."
    else
        warn "kernel-install not found. Cannot reset."
    fi


}

restore_backup() {
    print_header
    echo -e "   ${WHITE}Restore Backup${RESET}"
    print_status
    
    backups=()
    if [ -d "$BACKUP_DIR" ]; then
        while IFS= read -r line; do
            backups+=("$line")
        done < <(ls -1 "$BACKUP_DIR" | sort -r)
    fi
    
    local i=1
    if [ ${#backups[@]} -eq 0 ]; then
         echo -e "   ${YELLOW}(No backups found)${RESET}"
    else
        for bk in "${backups[@]}"; do
            print_option "$i" "$bk"
            ((i++))
        done
    fi
    print_option "$i" "Specify custom path"
    print_option "$((i+1))" "Cancel"
    
    echo ""
    print_status
    echo -ne "   ${BLUE}>${RESET} "
    read idx
    
    target_restore=""
    
    # Validate input is number
    if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
        warn "Invalid selection."
        return
    fi
    
    if [ "$idx" -le "${#backups[@]}" ] && [ "$idx" -gt 0 ]; then
        # Array is 0-indexed, choice is 1-indexed
        chosen_bk="${backups[$((idx-1))]}"
        target_restore="$BACKUP_DIR/$chosen_bk"
    elif [ "$idx" -eq $i ]; then
        echo -ne "${GREEN}Enter full path to backup directory: ${NC}"
        read custom_path
        if [ -d "$custom_path" ]; then
            target_restore="$custom_path"
        else
            warn "Directory not found: $custom_path"
            return
        fi
    else
        echo "Operation cancelled."
        return
    fi
    
    echo -e "${RED}WARNING: This will overwite current $ENTRY_DIR and $GRUB_CFG with content from $target_restore.${NC}"
    read -p "Are you sure? (y/n): " confirm
    if [[ $confirm == [yY] ]]; then
        log "Restoring backup..."
        if [ -d "$target_restore/entries" ]; then
            # Clean current entries safely?
            # Or just copy over? 
            # Safer to wipe current entries if we are restoring a full state.
            sudo rm -rf "${ENTRY_DIR:?}"/*
            sudo cp -r "$target_restore/entries/"* "$ENTRY_DIR/"
        fi
        
        if [ -f "$target_restore/grub.cfg" ]; then
            sudo cp "$target_restore/grub.cfg" "$GRUB_CFG"
        fi
        
        success "Restore complete. Please verify labels."
        show_labels
    else
        echo "Restore cancelled."
    fi
}


get_icon() {
    local text="$1"
    local lower_text=$(echo "$text" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$lower_text" == *"fedora"* ]]; then
        echo ""
    elif [[ "$lower_text" == *"ubuntu"* ]]; then
        echo ""
    elif [[ "$lower_text" == *"debian"* ]]; then
        echo ""
    elif [[ "$lower_text" == *"arch"* ]]; then
        echo ""
    elif [[ "$lower_text" == *"opensuse"* ]]; then
        echo ""
    elif [[ "$lower_text" == *"windows"* ]]; then
        echo ""
    elif [[ "$lower_text" == *"rescue"* ]]; then
        echo ""
    else
        echo "" # Generic Linux
    fi
}

show_labels() {
    if [ -d "$ENTRY_DIR" ]; then
        # improved loop to process each line individually for icons
        # Use sudo grep to get lines
        mapfile -t lines < <(sudo grep -h "^title" "$ENTRY_DIR"/*.conf 2>/dev/null | sed 's/^title //')
        
        if [ ${#lines[@]} -eq 0 ]; then
             echo -e "   ${GREY}(No BLS entries found)${RESET}"
        else
            for line in "${lines[@]}"; do
                icon=$(get_icon "$line")
                echo -e "   ${CYAN}${icon}  ${WHITE}${line}${RESET}"
            done
        fi
    else
        echo -e "   ${GREY}(No BLS entries found)${RESET}"
    fi
}

show_menu() {
    print_header
    
    echo -e "   ${BOLD}Current Boot Entries:${RESET}"
    show_labels
    print_status
    
    # Options Section
    print_option 1 "Clean Labels"
    print_option 2 "Reset Labels"
    print_option 3 "Dry Run"
    print_option 4 "Load Backup"
    print_option 5 "Exit"
    
    echo ""
    print_status
    echo -e "   ${BOLD}Select an option:${RESET}"
    echo -ne "   ${BLUE}>${RESET} "
    read choice
    
    case $choice in
        1)
            create_backup
            clean_bls_entries
            post_process_grub_cfg
            ;;
        2)
            create_backup
            reset_entries
            ;;
        3)
            print_header
            echo -e "   ${WHITE}Dry Run Selection${RESET}"
            print_status
            print_option 1 "Test Clean Labels"
            print_option 2 "Test Reset Labels"
            print_option 3 "Back"
            
            echo ""
            print_status
            echo -ne "   ${BLUE}>${RESET} "
            read dry_choice
            
            DRY_RUN=true
            case $dry_choice in
                1)
                    echo -e "\n${BLUE}--- DRY RUN: CLEAN LABELS ---${NC}"
                    clean_bls_entries
                    post_process_grub_cfg
                    ;;
                2)
                    echo -e "\n${BLUE}--- DRY RUN: RESET LABELS ---${NC}"
                    reset_entries
                    ;;
                3)
                    # Do nothing, loop back
                    ;;
                *)
                    echo "Invalid selection."
                    ;;
            esac
            DRY_RUN=false
            ;;
        4)
            restore_backup
            ;;
        5)
            clear
            exit 0
            ;;
        *)
            echo "Invalid choice."
            ;;
    esac
}

# Main Logic
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    clean_bls_entries
    post_process_grub_cfg
else
    # Loop menu
    while true; do
        show_menu
        echo "Press Enter to continue..."
        read
    done
fi
