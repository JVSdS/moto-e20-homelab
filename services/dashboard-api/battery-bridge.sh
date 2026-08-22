#!/data/data/com.termux/files/usr/bin/bash

# ATENÇÃO: este script roda no Termux NATIVO (fora do proot), não dentro do Debian.
# O caminho DESTINO é específico desta instalação — pode variar conforme o dispositivo/versão do proot-distro.
# Ver README, seção "Bateria real via ponte Termux:API", para contexto completo.

DESTINO="/data/data/com.termux/files/usr/var/lib/proot-distro/containers/debian/rootfs/home/devops/apps/healthcheck/battery.json"

while true; do
    termux-battery-status > "$DESTINO"
    sleep 30
done