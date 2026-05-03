#!/bin/bash

# --- CONFIG ---
readonly KP_CLI="/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
readonly DB_PATH="/Users/dangkhoa/KeePassXCDatebase.kdbx"
readonly ENTRY_TITLE="DB AiHR"
readonly TARGET_DB="YKK"
readonly LOCAL_PORT=27019
readonly SAVE_DIR="/Users/dangkhoa/Developer/Work/Jobtest/mongorestore/dump"

get_secret() {
    echo "$MASTER_PW" | "$KP_CLI" show "$DB_PATH" "$ENTRY_TITLE" -a "$1" 2>/dev/null
}

# --- AUTH & SECRETS ---
echo -n "KeepassXC Password: "
read -s MASTER_PW
echo -e "\n"

DB_USER=$(get_secret "UserName")
DB_PASS=$(get_secret "Password")

# --- VALIDATION ---
mkdir -p "$SAVE_DIR"
[ -z "$DB_PASS" ] && { echo "❌ Thất bại!"; exit 1; }
! lsof -i :$LOCAL_PORT > /dev/null && { echo "❌ Tunnel chưa mở!"; exit 1; }

# --- EXECUTE ---
FILE_NAME="dump_${TARGET_DB}_$(date +%Y%m%d_%H%M).archive"
FULL_PATH="$SAVE_DIR/$FILE_NAME"

echo "🚀 Dumping $TARGET_DB..."

mongodump --host 127.0.0.1 --port $LOCAL_PORT \
--db $TARGET_DB --username "$DB_USER" --password "$DB_PASS" \
--authenticationDatabase admin --archive="$FULL_PATH" \
--numParallelCollections 4

# --- RESULT ---
if [ $? -eq 0 ]; then
    echo -e "\n✅ OK! $(du -sh "$FULL_PATH" | cut -f1)"
    echo "📍 $FULL_PATH"
else
    echo -e "\n❌ Failed!"; rm -f "$FULL_PATH"
fi

unset MASTER_PW
