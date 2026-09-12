#!/bin/bash

echo "Verificando SSH..."
SSHD_COUNT=$(pgrep -f "sshd: /usr/sbin/sshd" | wc -l)
if [ "$SSHD_COUNT" -eq 0 ]; then
    /usr/sbin/sshd -E /var/log/auth.log
    echo "  SSH iniciado."
elif [ "$SSHD_COUNT" -eq 1 ]; then
    echo "  SSH já estava rodando (1 instância)."
else
    echo "  AVISO: $SSHD_COUNT instâncias de SSH detectadas — limpando e reiniciando."
    pkill -f "sshd: /usr/sbin/sshd"
    sleep 1
    /usr/sbin/sshd -E /var/log/auth.log
    echo "  SSH reiniciado após limpeza."
fi

echo "Verificando cron..."
if ! pgrep -x cron > /dev/null; then
    cron
    echo "  cron iniciado."
else
    echo "  cron já estava rodando."
fi

echo "Verificando fail2ban..."
if ! pgrep -f "fail2ban-server" > /dev/null; then
    rm -f /var/run/fail2ban/fail2ban.pid
    fail2ban-client -x start
    echo "  fail2ban iniciado."
else
    echo "  fail2ban já estava rodando."
fi

echo "Verificando aplicação FastAPI..."
if ! pgrep -f "uvicorn main:app" > /dev/null; then
    su - devops -c "cd ~/apps/healthcheck && source venv/bin/activate && nohup uvicorn main:app --host 0.0.0.0 --port 8000 > app.log 2>&1 &"
    echo "  Aplicação iniciada."
else
    echo "  Aplicação já estava rodando."
fi

sleep 2
echo "--- Status final ---"
ps aux | grep -E "sshd|cron|fail2ban|uvicorn" | grep -v grep
echo "Pronto."