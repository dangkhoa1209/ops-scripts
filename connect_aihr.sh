#!/bin/bash

# =================================================================
# Script Name: connect_aihr.sh
# Description: Mở SSH Tunnel kết nối MongoDB Server AiHR qua KeePassXC
# Location:    /Users/dangkhoa/scripts/jobtest/connect_aihr.sh
# Author:      Dang Khoa
# =================================================================

readonly KP_CLI="/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
readonly DB_PATH="/Users/dangkhoa/KeePassXCDatebase.kdbx"
readonly ENTRY_TITLE="ServerAiHR"
readonly LOCAL_PORT=27019

# Hàm lấy dữ liệu từ KeePassXC
get_secret() {
    local attr=$1
    echo "$MASTER_PW" | "$KP_CLI" show "$DB_PATH" "$ENTRY_TITLE" -a "$attr" 2>/dev/null
}

# --- 3. BẮT ĐẦU THỰC THI ---
# Kiểm tra file database có tồn tại không
if [ ! -f "$DB_PATH" ]; then
    echo "Không tìm thấy file KeePassDatabase"
    exit 1
fi

# Yêu cầu nhập Master Password
echo -n "KeePassXC Password: "
read -s MASTER_PW
echo ""

# Hút dữ liệu từ KeePassXC
echo "KeePassXC..."
SSH_HOST=$(get_secret "URL")
SSH_USER=$(get_secret "UserName")
SSH_PASS=$(get_secret "Password")
SSH_PORT=$(get_secret "Port") #Tab nâng cao

# Nếu không tìm thấy Port trong Advanced thì mặc định là 22
SSH_PORT=${SSH_PORT:-22}

# Kiểm tra xem có lấy được dữ liệu không
if [ -z "$SSH_PASS" ] || [ -z "$SSH_HOST" ]; then
    echo "Lỗi: Không lấy được thông tin. Kiểm tra lại Master Password hoặc Entry '$ENTRY_TITLE'."
    exit 1
fi

# --- BỔ SUNG: HIỂN THỊ THÔNG TIN TRƯỚC KHI CONNECT ---
echo "--------------------------------------------------------"
echo "THÔNG TIN KẾT NỐI:"
echo "   Server IP (URL): $SSH_HOST"
echo "   User SSH:       $SSH_USER"
echo "   Port SSH:       $SSH_PORT"
echo "   Local Port:      $LOCAL_PORT"
echo "--------------------------------------------------------"

# Hỏi xác nhận (Nhấn Enter để tiếp tục, Ctrl+C để hủy)
echo -n "👉 Nhấn [Enter] để bắt đầu Tunnel (hoặc Ctrl+C để thoát)..."
read

# --- 4. THIẾT LẬP SSH TUNNEL ---
echo "Connecting to $SSH_HOST..."

# Lệnh SSH Tunnel chạy ngầm
sshpass -p "$SSH_PASS" ssh -L ${LOCAL_PORT}:localhost:27017 $SSH_USER@$SSH_HOST -p $SSH_PORT -fN

# Kiểm tra kết quả lệnh SSH
if [ $? -eq 0 ]; then
    echo "--------------------------------------------------------"
    echo "KẾT NỐI THÀNH CÔNG!"
    echo "Local Address: localhost:$LOCAL_PORT"
    echo "--------------------------------------------------------"
else
    echo "❌ Lỗi kết nối: Vui lòng kiểm tra VPN hoặc thông tin Server."
fi

# Xóa mật khẩu khỏi RAM để bảo mật
unset MASTER_PW
unset SSH_PASS
