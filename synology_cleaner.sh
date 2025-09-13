#!/bin/bash

# A interactive script to find and delete all Synology '@eaDir'
# directories from a remote host via SSH.

# --- Configuration ---
BATCH_SIZE=100 # How many directories to delete per SSH connection.

# --- ANSI Color Codes for better UX ---
C_BLUE="\033[1;34m"
C_GREEN="\033[1;32m"
C_RED="\033[1;31m"
C_YELLOW="\033[1;33m"
C_RESET="\033[0m"

# --- Temporary file setup and cleanup ---
# A trap ensures that even if the script is exited (Ctrl+C), the temp files are removed.
TMP_RAW_LIST=$(mktemp)
TMP_FINAL_LIST=$(mktemp)
QUEUE_FILE="to_delete_queue.txt" # We keep this file for resumability

# Define a cleanup function
cleanup() {
    echo -e "\n${C_YELLOW}Cleaning up temporary files...${C_RESET}"
    rm -f "$TMP_RAW_LIST" "$TMP_FINAL_LIST"
    # Don't delete the queue file on exit, to allow resuming.
}
trap cleanup INT TERM EXIT

# --- Helper Functions ---
function print_header() {
    echo -e "${C_BLUE}=====================================================${C_RESET}"
    echo -e "${C_BLUE}  Synology @eaDir Remote Cleanup Utility${C_RESET}"
    echo -e "${C_BLUE}=====================================================${C_RESET}"
}

# --- Main Script Logic ---

print_header
echo -e "This script will find and remove all '@eaDir' folders from a remote server."

# 1. SELECT SSH HOST
# -----------------------------------------------------------------------------
echo
echo -e "${C_YELLOW}Step 1: Select your SSH host...${C_RESET}"
SSH_CONFIG="$HOME/.ssh/config"
if [ ! -f "$SSH_CONFIG" ]; then
    echo -e "${C_RED}Error: SSH config file not found at '$SSH_CONFIG'.${C_RESET}"
    echo -e "Please enter the SSH host manually (e.g., user@hostname):"
    read -r SSH_HOST
else
    # Parse hosts from ssh/config. A bit of awk magic to get only the host aliases.
    mapfile -t hosts < <(awk '/^Host / && !/\*/ {for (i=2; i<=NF; i++) print $i}' "$SSH_CONFIG")
    if [ ${#hosts[@]} -eq 0 ]; then
        echo -e "${C_RED}No hosts found in your SSH config.${C_RESET}"
        echo -e "Please enter the SSH host manually (e.g., user@hostname):"
        read -r SSH_HOST
    else
        echo "Please choose a host from your ~/.ssh/config:"
        select host_option in "${hosts[@]}"; do
            if [[ -n "$host_option" ]]; then
                SSH_HOST=$host_option
                break
            else
                echo "Invalid selection. Please try again."
            fi
        done
    fi
fi
echo -e "${C_GREEN}Selected host: $SSH_HOST${C_RESET}"

# 2. GET REMOTE PATH
# -----------------------------------------------------------------------------
echo
echo -e "${C_YELLOW}Step 2: Enter the absolute path to the directory you want to clean.${C_RESET}"
echo "Example: /home/Backup/MEDIA/Music/Rips/flac"
read -rp "Remote path: " REMOTE_BASE_PATH

# Ensure path is not empty
if [ -z "$REMOTE_BASE_PATH" ]; then
    echo -e "${C_RED}Error: Path cannot be empty.${C_RESET}"
    exit 1
fi

# 3. GENERATE, CLEAN, AND VERIFY THE LIST
# -----------------------------------------------------------------------------
if [ ! -f "$QUEUE_FILE" ]; then
    echo
    echo -e "${C_YELLOW}Step 3: Generating file list from remote server via rsync...${C_RESET}"
    echo "This may take a while depending on the number of files."

    RSYNC_ERROR_LOG=$(mktemp)
    trap 'cleanup; rm -f "$RSYNC_ERROR_LOG"' INT TERM EXIT # Add to cleanup

    # Use the improved rsync command for a clean, recursive list of just filenames.
    if ! rsync -nr --out-format='%n' "$SSH_HOST:$REMOTE_BASE_PATH/" . > "$TMP_RAW_LIST" 2> "$RSYNC_ERROR_LOG"; then
        echo -e "\n${C_RED}Error: rsync failed. It could not connect or find the specified path.${C_RESET}"
        echo -e "${C_YELLOW}--- Error details from rsync ---${C_RESET}"
        cat "$RSYNC_ERROR_LOG"
        echo -e "${C_YELLOW}--------------------------------${C_RESET}"
        echo "Please check:"
        echo "1. The host '$SSH_HOST' is correct."
        echo "2. The remote path '$REMOTE_BASE_PATH' exists."
        echo "3. You have read permissions on the remote path."
        exit 1
    elif [ ! -s "$TMP_RAW_LIST" ]; then
        echo -e "\n${C_RED}Error: rsync connected successfully but found no files.${C_RESET}"
        echo "This likely means the source directory '$REMOTE_BASE_PATH' is empty."
        exit 1
    fi
    rm -f "$RSYNC_ERROR_LOG" # Clean up on success

    echo "File list generated. Now cleaning and preparing the deletion list..."

    # Clean the raw list to get only the root @eaDir directories.
    # This ensures @eaDir is a full path component, followed by a slash or the end of the line.
    grep -E '/@eaDir(/|$)' "$TMP_RAW_LIST" | sed 's|\(/@eaDir\).*|\1|' | sort -u > "$TMP_FINAL_LIST"

    # Prepend the absolute path to each line
    awk -v prefix="$REMOTE_BASE_PATH/" '{print prefix $0}' "$TMP_FINAL_LIST" > "$QUEUE_FILE"

    TOTAL_DIRS=$(wc -l < "$QUEUE_FILE")
    echo -e "${C_GREEN}Found $TOTAL_DIRS '@eaDir' directories to delete.${C_RESET}"
else
    echo
    echo -e "${C_YELLOW}Found existing queue file '$QUEUE_FILE'. Resuming previous session...${C_RESET}"
    TOTAL_DIRS=$(wc -l < "$QUEUE_FILE") # This will be the remaining count
    echo -e "${C_GREEN}There are $TOTAL_DIRS directories remaining to be deleted.${C_RESET}"
fi

if [ ! -s "$QUEUE_FILE" ]; then
    echo -e "${C_GREEN}No '@eaDir' directories found or queue is empty. Nothing to do!${C_RESET}"
    exit 0
fi

# Final confirmation
echo
read -p "Are you sure you want to PERMANENTLY delete these directories? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted by user."
    exit 1
fi

# 4. BATCH DELETION
# -----------------------------------------------------------------------------
echo
echo -e "${C_YELLOW}Step 4: Starting batch deletion...${C_RESET}"
DELETED_COUNT=0
while [ -s "$QUEUE_FILE" ]; do
  # Build a safe, quoted list of arguments for the batch
  BATCH_ARGS=$(head -n "$BATCH_SIZE" "$QUEUE_FILE" | while IFS= read -r line; do printf '%q ' "$line"; done)
  NUM_IN_BATCH=$(head -n "$BATCH_SIZE" "$QUEUE_FILE" | wc -l)
  
  # Attempt to delete the entire batch
  if ssh -n "$SSH_HOST" "rm -rf $BATCH_ARGS"; then
    # If successful, remove the processed lines from the queue
    sed -i "1,${NUM_IN_BATCH}d" "$QUEUE_FILE"
    DELETED_COUNT=$((DELETED_COUNT + NUM_IN_BATCH))
    REMAINING_DIRS=$(wc -l < "$QUEUE_FILE")
    printf "Batch successful. Deleted ${DELETED_COUNT} directories. (${REMAINING_DIRS} remaining)\r"
  else
    echo -e "\n${C_RED}ERROR: A batch failed to delete. Halting script.${C_RESET}"
    echo "You can safely rerun the script to resume."
    exit 1
  fi
done

# --- Final Cleanup and Exit ---
rm -f "$QUEUE_FILE"

echo -e "\n\n${C_GREEN}=====================================================${C_RESET}"
echo -e "${C_GREEN}  All '@eaDir' directories have been deleted!${C_RESET}"
echo -e "${C_GREEN}=====================================================${C_RESET}"

# Explicitly disable the trap on a clean exit.
trap - INT TERM EXIT

