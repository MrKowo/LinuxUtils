#!/bin/bash

# --- AUTO-DETECT SYSTEM INFO ---
if [ -f /etc/os-release ]; then
    source /etc/os-release
    # Use generic name if specific version is missing
    OS_LABEL="${NAME} ${VERSION_ID:-}"
else
    OS_LABEL="Linux"
fi

# --- AUTO-DETECT GRUB COMMAND ---
if command -v grub2-mkconfig >/dev/null 2>&1; then
    GRUB_CMD="grub2-mkconfig"
    GRUB_CFG="/boot/grub2/grub.cfg"
elif command -v grub-mkconfig >/dev/null 2>&1; then
    GRUB_CMD="grub-mkconfig"
    GRUB_CFG="/boot/grub/grub.cfg"
else
    echo "Error: Could not find grub-mkconfig command."
    exit 1
fi

# --- CHECK FOR BLS COMPATIBILITY ---
ENTRY_DIR="/boot/loader/entries"
if [ ! -d "$ENTRY_DIR" ]; then
    echo -e "\033[0;31mError: This distro does not use BLS ($ENTRY_DIR not found).\033[0m"
    echo "This script works on Fedora, RHEL, CentOS, and Arch (BLS), but not standard Ubuntu/Debian."
    exit 1
fi

# Define colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' 

show_labels() {
    echo -e "\n${BLUE}Current Boot Menu Titles (Name | Config File):${NC}"
    # Adjusted awk to handle variable title lengths
    sudo sh -c "grep '^title ' $ENTRY_DIR/*.conf" | awk -F: '{
        title=$2; 
        sub(/^title /, "", title); 
        printf "%-30s %s\n", title, $1
    }'
    echo ""
}

echo -e "${BLUE}==============================${NC}"
echo -e "${BLUE}   GRUB MANAGER: ${OS_LABEL}  ${NC}"
echo -e "${BLUE}==============================${NC}"
echo "1) Clean Labels   (Set to '$OS_LABEL')"
echo "2) Reset Labels   (Restore kernel versions)"
echo "3) View Labels"
echo "4) Exit"
echo -ne "${GREEN}Selection: ${NC}"
read choice

case $choice in
    1)
        echo -e "\n${BLUE}[1/2] Processing boot entry files...${NC}"
        
        # 1. Handle Rescue entries first (specific match)
        # 2. Handle standard entries (catch-all match)
        # We use double quotes in sed to allow variable expansion ($OS_LABEL)
        sudo sh -c "sed -i -E \"s/^title .*\(0-rescue.*\)/title $OS_LABEL (Rescue)/; s/^title .*/title $OS_LABEL/\" $ENTRY_DIR/*.conf"
        
        echo -e "${BLUE}[2/2] Updating GRUB configuration...${NC}"
        sudo $GRUB_CMD -o $GRUB_CFG > /dev/null 2>&1
        
        echo -e "${GREEN}SUCCESS: Labels updated to '$OS_LABEL'.${NC}"
        show_labels
        ;;
    2)
        echo -e "\n${RED}WARNING: This relies on 'kernel-install' (common on Fedora/RHEL).${NC}"
        echo "If your distro does not use kernel-install, this step may fail."
        read -p "Are you sure? (y/n): " confirm
        if [[ $confirm == [yY] ]]; then
            echo -e "\n${BLUE}[1/2] Re-registering kernel entries...${NC}"
            
            # Check if kernel-install exists
            if command -v kernel-install >/dev/null 2>&1; then
                sudo kernel-install add $(uname -r) /lib/modules/$(uname -r)/vmlinuz > /dev/null 2>&1
            else
                echo -e "${RED}Error: 'kernel-install' command not found.${NC}"
                echo "You may need to reinstall the kernel package to restore default labels."
            fi

            echo -e "${BLUE}[2/2] Rebuilding GRUB configuration...${NC}"
            sudo $GRUB_CMD -o $GRUB_CFG > /dev/null 2>&1

            echo -e "${GREEN}SUCCESS: Factory labels restored.${NC}"
            show_labels
        else
            echo "Operation cancelled."
        fi
        ;;
    3)
        show_labels
        ;;
    4)
        exit 0
        ;;
    *)
        echo "Invalid choice. Exiting."
        ;;
esac
