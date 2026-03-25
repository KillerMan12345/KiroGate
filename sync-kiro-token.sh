#!/bin/bash
# sync-kiro-token.sh
# 自动同步 Kiro IDE token 到 KiroGate，检测变化后重启服务

set -euo pipefail

# === 配置 ===
KIRO_AUTH="/mnt/c/Users/kingdee/.aws/sso/cache/kiro-auth-token.json"
KIRO_CLIENT="/mnt/c/Users/kingdee/.aws/sso/cache/cea5f95b026d1380f8cab2fb2ac38875390af4a1.json"
KIROGATE_CREDS="$HOME/KiroGate/kiro-merged-creds.json"
KIROGATE_DIR="$HOME/KiroGate"
LOG_FILE="/tmp/kirogate-sync.log"

# KiroGate 环境变量 - 从 .env 文件加载
ENV_FILE="$KIROGATE_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found: $ENV_FILE"
    echo "Copy .env.example to .env and fill in your values."
    exit 1
fi
set -a
source "$ENV_FILE"
set +a
export KIRO_CREDS_FILE="$KIROGATE_CREDS"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

sync_token() {
    # 检查源文件是否存在
    if [[ ! -f "$KIRO_AUTH" ]]; then
        log "ERROR: Kiro auth token file not found: $KIRO_AUTH"
        return 1
    fi
    if [[ ! -f "$KIRO_CLIENT" ]]; then
        log "ERROR: Kiro client file not found: $KIRO_CLIENT"
        return 1
    fi

    # 合并生成新的凭证文件
    local new_creds
    new_creds=$(python3 -c "
import json, sys
with open('$KIRO_AUTH') as f: auth = json.load(f)
with open('$KIRO_CLIENT') as f: client = json.load(f)
merged = {
    'refreshToken': auth['refreshToken'],
    'region': auth.get('region', 'us-east-1'),
    'clientId': client['clientId'],
    'clientSecret': client['clientSecret']
}
# 保留 accessToken（如果有的话）
if 'accessToken' in auth:
    merged['accessToken'] = auth['accessToken']
print(json.dumps(merged))
")

    if [[ -z "$new_creds" ]]; then
        log "ERROR: Failed to merge credentials"
        return 1
    fi

    # 提取新的 refreshToken 用于比较
    local new_refresh
    new_refresh=$(echo "$new_creds" | python3 -c "import json,sys; print(json.load(sys.stdin)['refreshToken'])")

    # 对比旧 token
    local old_refresh=""
    if [[ -f "$KIROGATE_CREDS" ]]; then
        old_refresh=$(python3 -c "
import json
with open('$KIROGATE_CREDS') as f: print(json.load(f).get('refreshToken',''))
" 2>/dev/null || echo "")
    fi

    if [[ "$new_refresh" == "$old_refresh" ]]; then
        log "Token unchanged, skip."
        return 0
    fi

    # Token 有变化，写入新文件
    echo "$new_creds" | python3 -c "import json,sys; json.dump(json.load(sys.stdin), open('$KIROGATE_CREDS','w'), indent=2)"
    log "Token updated: ${new_refresh:0:20}...${new_refresh: -10}"

    # 重启 KiroGate
    restart_kirogate
}

restart_kirogate() {
    log "Restarting KiroGate..."

    # 停止旧进程
    pkill -f "python main.py" 2>/dev/null || true
    sleep 2

    # 启动新进程
    cd "$KIROGATE_DIR"
    source venv/bin/activate
    nohup python main.py >> /tmp/kirogate.log 2>&1 &
    local pid=$!
    sleep 3

    # 健康检查
    if curl -s --connect-timeout 3 http://localhost:8000/health | grep -q '"healthy"'; then
        log "KiroGate restarted OK (PID: $pid)"
    else
        log "WARNING: KiroGate health check failed after restart"
    fi
}

# === 主逻辑 ===
case "${1:-}" in
    watch)
        # 守护模式：每 5 分钟检查一次
        INTERVAL="${2:-300}"
        log "Watch mode started (interval: ${INTERVAL}s)"
        while true; do
            sync_token || true
            sleep "$INTERVAL"
        done
        ;;
    start)
        # 同步 + 确保 KiroGate 在运行
        sync_token
        if ! pgrep -f "python main.py" > /dev/null 2>&1; then
            log "KiroGate not running, starting..."
            restart_kirogate
        fi
        ;;
    restart)
        # 强制同步并重启
        sync_token
        restart_kirogate
        ;;
    *)
        # 默认：只同步 token
        sync_token
        ;;
esac
