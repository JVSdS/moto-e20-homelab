#!/data/data/com.termux/files/usr/bin/bash

REMOTE_HOST="192.168.100.86"
REMOTE_PORT="8022"
REMOTE_USER="saves-sync"
SSH_KEY="$HOME/.ssh/id_ed25519_sync"
LOG_FILE="$HOME/saves-sync.log"
MARKER_FILE="$HOME/.saves-sync-marker"
FAIL_FLAG="$HOME/.saves-sync-failed"

PPSSPP_DIR="/storage/emulated/0/Download/PSP Games/PSP/PPSSPP_STATE"
MYOLDBOY_DIR="/storage/emulated/0/MyOldBoy/save"

if [ ! -f "$MARKER_FILE" ]; then
    touch -d "@0" "$MARKER_FILE" 2>/dev/null || touch -t 197001010000 "$MARKER_FILE"
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

sync_folder() {
    local src_dir="$1"
    local remote_subdir="$2"

    if [ ! -d "$src_dir" ]; then
        log "AVISO: pasta não encontrada: $src_dir"
        return
    fi

    find "$src_dir" -type f -newer "$MARKER_FILE" | while IFS= read -r file; do
        log "Enviando: $file"
        sftp -i "$SSH_KEY" -P "$REMOTE_PORT" -b - "$REMOTE_USER@$REMOTE_HOST" >> "$LOG_FILE" 2>&1 <<EOF2
put "$file" "/upload/$remote_subdir/"
EOF2
        if [ $? -eq 0 ]; then
            log "OK: $file"
        else
            log "ERRO ao enviar: $file"
            touch "$FAIL_FLAG"
        fi
    done
}

log "=== Iniciando sincronização ==="
rm -f "$FAIL_FLAG"

sync_folder "$PPSSPP_DIR" "ppsspp"
sync_folder "$MYOLDBOY_DIR" "myoldboy"

if [ -f "$FAIL_FLAG" ]; then
    log "AVISO: uma ou mais transferências falharam — marcador NÃO atualizado, arquivos serão tentados novamente na próxima execução."
    rm -f "$FAIL_FLAG"
else
    touch "$MARKER_FILE"
    log "Todas as transferências OK — marcador atualizado."
fi

log "=== Sincronização concluída ==="