#!/usr/bin/env bash

# ==============================================================================
# Modern TUI AWS File Transfer (Powered by fzf + rsync)
# Features: Fuzzy File Search, Live Preview, Multi-select, Saved Profiles
# ==============================================================================

set -u

CONFIG_DIR="$HOME/.config/aws-tui"
PROFILES_FILE="$CONFIG_DIR/ec2_profiles.conf"
mkdir -p "$CONFIG_DIR"
touch "$PROFILES_FILE"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Check for fzf
if ! command -v fzf >/dev/null 2>&1; then
    echo -e "${RED}[Error] 'fzf' is required for the interactive search UI.${NC}"
    echo "Install it via: sudo dnf install fzf  OR  sudo apt install fzf"
    exit 1
fi

# Helper: Fuzzy search files/folders from a starting directory
select_local_files() {
    local start_dir="${1:-$PWD}"
    echo -e "${CYAN}Opening file finder... (Type to search, TAB to select multiple, ENTER to confirm)${NC}" >&2
    
    # Find files/dirs (ignoring .git and node_modules noise), pipe to fzf with live preview
    find "$start_dir" -maxdepth 4 \( -name ".git" -o -name "node_modules" -o -name ".cache" \) -prune -o -print 2>/dev/null | \
    fzf --multi \
        --height=80% \
        --layout=reverse \
        --border=rounded \
        --prompt="🔍 Search Local Files/Dirs > " \
        --header="TAB: Multi-select | ENTER: Confirm | ESC: Cancel | Ctrl-U/D: Scroll Preview" \
        --preview='if [ -d {} ]; then ls -la --color=always {}; else head -n 100 {}; fi' \
        --preview-window=right:50%:wrap
}

# Helper: Add a new EC2 profile
add_ec2_profile() {
    echo -e "\n${YELLOW}--- Add New EC2 Server Profile ---${NC}"
    read -p "Profile Nickname (e.g., prod-web, staging): " P_NAME
    read -p "EC2 Host (Public IP or DNS): " P_HOST
    read -p "EC2 Username [default: ubuntu]: " P_USER
    P_USER=${P_USER:-ubuntu}

    echo -e "${CYAN}Select your .pem / SSH key file using the search menu:${NC}"
    sleep 1
    P_KEY=$(find "$HOME" -maxdepth 3 \( -name "*.pem" -o -name "*.cer" -o -name "id_*" \) 2>/dev/null | \
        fzf --height=50% --layout=reverse --border --prompt="🔑 Search SSH Key > " \
            --header="Select your private key (ESC to type path manually)")

    if [[ -z "$P_KEY" ]]; then
        read -e -p "Enter full path to SSH key manually: " P_KEY
        P_KEY="${P_KEY/#\~/$HOME}"
    fi

    if [[ ! -f "$P_KEY" ]]; then
        echo -e "${RED}[Error] Key file '$P_KEY' does not exist! Profile not saved.${NC}"
        return 1
    fi

    # Fix permissions automatically
    chmod 400 "$P_KEY" 2>/dev/null

    echo "${P_NAME}|${P_USER}|${P_HOST}|${P_KEY}" >> "$PROFILES_FILE"
    echo -e "${GREEN}[Saved] Profile '$P_NAME' added!${NC}"
}

# ==============================================================================
# Main Menu Loop
# ==============================================================================
while true; do
    ACTION=$(printf "🚀 Transfer Local Files -> AWS EC2 (SSH/rsync)\n📥 Download AWS EC2 -> Local PC\n☁️  Upload Local Files -> AWS S3 Bucket\n⚙️  Manage Saved EC2 Profiles\n❌ Quit" | \
        fzf --height=40% --layout=reverse --border=rounded \
            --prompt="AWS Transfer > " \
            --header="Select an action (Use arrow keys or type to filter)")

    [[ -z "$ACTION" || "$ACTION" == *"Quit"* ]] && echo "Exiting." && exit 0

    case "$ACTION" in
        *"Transfer Local Files -> AWS EC2"*)
            # 1. Pick Server Profile
            if [[ ! -s "$PROFILES_FILE" ]]; then
                echo -e "${YELLOW}No saved EC2 servers found. Let's create one first!${NC}"
                add_ec2_profile || continue
            fi

            PROFILE_LINE=$( (cat "$PROFILES_FILE"; echo "➕ [Add New Server Profile]") | \
                fzf --height=40% --layout=reverse --border \
                    --prompt="🖥️  Select Server > " \
                    --header="Name | User | Host | Key")

            [[ -z "$PROFILE_LINE" ]] && continue

            if [[ "$PROFILE_LINE" == "➕ [Add New Server Profile]" ]]; then
                add_ec2_profile || continue
                PROFILE_LINE=$(tail -n 1 "$PROFILES_FILE")
            fi

            IFS='|' read -r P_NAME P_USER P_HOST P_KEY <<< "$PROFILE_LINE"

            # 2. Pick Search Root (Current Dir vs Home Dir)
            SEARCH_ROOT=$(printf "Current Directory ($PWD)\nHome Directory ($HOME)\nCustom Path..." | \
                fzf --height=30% --layout=reverse --border --prompt="📂 Search files starting from > ")
            
            [[ -z "$SEARCH_ROOT" ]] && continue
            if [[ "$SEARCH_ROOT" == *"Home"* ]]; then
                START_DIR="$HOME"
            elif [[ "$SEARCH_ROOT" == *"Custom"* ]]; then
                read -e -p "Enter directory to search in: " START_DIR
                START_DIR="${START_DIR/#\~/$HOME}"
            else
                START_DIR="$PWD"
            fi

            # 3. Fuzzy Search and Multi-Select Files
            mapfile -t SELECTED_FILES < <(select_local_files "$START_DIR")
            if [[ ${#SELECTED_FILES[@]} -eq 0 ]]; then
                echo -e "${YELLOW}No files selected. Returning to menu.${NC}"
                continue
            fi

            # 4. Pick Remote Destination
            REMOTE_DIR=$(printf "~/ (Home Directory)\n/var/www/html\n/tmp\nCustom Remote Path..." | \
                fzf --height=35% --layout=reverse --border --prompt="🎯 Remote Destination on $P_NAME > ")

            [[ -z "$REMOTE_DIR" ]] && continue
            if [[ "$REMOTE_DIR" == "Custom"* ]]; then
                read -p "Enter remote path on $P_HOST: " REMOTE_DIR
            else
                REMOTE_DIR=$(echo "$REMOTE_DIR" | awk '{print $1}')
            fi

            # 5. Execute rsync with progress
            echo -e "\n${CYAN}Transferring ${#SELECTED_FILES[@]} item(s) to $P_NAME ($P_USER@$P_HOST:$REMOTE_DIR)...${NC}"
            rsync -avzP -e "ssh -i \"$P_KEY\" -o StrictHostKeyChecking=accept-new" "${SELECTED_FILES[@]}" "${P_USER}@${P_HOST}:${REMOTE_DIR}"
            
            [[ $? -eq 0 ]] && echo -e "\n${GREEN}✔ Transfer Complete!${NC}" || echo -e "\n${RED}✖ Transfer Failed.${NC}"
            read -p "Press Enter to return to menu..."
            ;;

        *"Download AWS EC2 -> Local PC"*)
            if [[ ! -s "$PROFILES_FILE" ]]; then
                echo -e "${YELLOW}No saved EC2 servers found. Let's add one!${NC}"
                add_ec2_profile || continue
            fi

            PROFILE_LINE=$(cat "$PROFILES_FILE" | fzf --height=40% --layout=reverse --border --prompt="🖥️  Select Server > ")
            [[ -z "$PROFILE_LINE" ]] && continue
            IFS='|' read -r P_NAME P_USER P_HOST P_KEY <<< "$PROFILE_LINE"

            echo -e "${CYAN}Fetching remote file list from $P_NAME ($P_HOST)...${NC}"
            REMOTE_FILE=$(ssh -i "$P_KEY" -o StrictHostKeyChecking=accept-new "${P_USER}@${P_HOST}" \
                "find ~ -maxdepth 3 -not -path '*/.*' 2>/dev/null" | \
                fzf --height=60% --layout=reverse --border --prompt="🔍 Search Remote Files > " \
                    --header="Searching remote home directory on $P_NAME")

            [[ -z "$REMOTE_FILE" ]] && continue

            echo -e "${CYAN}Downloading '$REMOTE_FILE' to current directory ($PWD)...${NC}"
            rsync -avzP -e "ssh -i \"$P_KEY\"" "${P_USER}@${P_HOST}:${REMOTE_FILE}" "$PWD/"
            [[ $? -eq 0 ]] && echo -e "\n${GREEN}✔ Download Complete!${NC}" || echo -e "\n${RED}✖ Download Failed.${NC}"
            read -p "Press Enter to return to menu..."
            ;;

        *"Upload Local Files -> AWS S3 Bucket"*)
            if ! command -v aws >/dev/null 2>&1; then
                echo -e "${RED}[Error] AWS CLI not installed.${NC}"
                read -p "Press Enter..."
                continue
            fi

            # 1. Search Local Files
            mapfile -t SELECTED_FILES < <(select_local_files "$PWD")
            [[ ${#SELECTED_FILES[@]} -eq 0 ]] && continue

            # 2. Fetch and Fuzzy Search S3 Buckets
            echo -e "${CYAN}Fetching your S3 buckets...${NC}"
            BUCKET=$(aws s3 ls | awk '{print $3}' | \
                fzf --height=50% --layout=reverse --border --prompt="🪣 Search S3 Buckets > ")
            
            [[ -z "$BUCKET" ]] && continue

            read -p "Optional S3 folder prefix (press Enter for root): " PREFIX
            PREFIX="${PREFIX#/}"
            S3_DEST="s3://${BUCKET}${PREFIX:+/$PREFIX}"

            for item in "${SELECTED_FILES[@]}"; do
                echo -e "${CYAN}Uploading $item -> $S3_DEST ...${NC}"
                if [[ -d "$item" ]]; then
                    aws s3 cp "$item" "$S3_DEST/$(basename "$item")" --recursive
                else
                    aws s3 cp "$item" "$S3_DEST/"
                fi
            done
            echo -e "\n${GREEN}✔ S3 Upload Finished!${NC}"
            read -p "Press Enter to return to menu..."
            ;;

        *"Manage Saved EC2 Profiles"*)
            SUB_ACT=$(printf "➕ Add New Server Profile\n🗑️  Delete a Server Profile\n📄 View Saved Profiles\n🔙 Back" | \
                fzf --height=35% --layout=reverse --border --prompt="Manage Profiles > ")
            
            case "$SUB_ACT" in
                *"Add"*) add_ec2_profile ;;
                *"Delete"*)
                    TO_DEL=$(cat "$PROFILES_FILE" | fzf --height=40% --layout=reverse --border --prompt="Select Profile to Delete > ")
                    if [[ -n "$TO_DEL" ]]; then
                        grep -vF "$TO_DEL" "$PROFILES_FILE" > "${PROFILES_FILE}.tmp" && mv "${PROFILES_FILE}.tmp" "$PROFILES_FILE"
                        echo -e "${GREEN}Profile removed.${NC}"
                    fi
                    ;;
                *"View"*)
                    echo -e "\n${YELLOW}Saved Profiles ($PROFILES_FILE):${NC}"
                    column -t -s '|' "$PROFILES_FILE"
                    echo ""
                    read -p "Press Enter..."
                    ;;
            esac
            ;;
    esac
done