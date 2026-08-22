#!/data/data/com.termux/files/usr/bin/bash

echo "Verificando ponte de bateria..."
if ! pgrep -f "battery-bridge.sh" > /dev/null; then
    nohup ~/battery-bridge.sh > ~/battery-bridge.log 2>&1 &
    echo "  Ponte de bateria iniciada."
else
    echo "  Ponte de bateria já estava rodando."
fi

echo "Entrando no proot e iniciando serviços..."
proot-distro login debian -- /root/start-all.sh