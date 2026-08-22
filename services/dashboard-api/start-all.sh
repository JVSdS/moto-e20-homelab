#!/bin/bash

echo "Verificando SSH..."
if ! pgrep -f "sshd: /usr/sbin/sshd" > /dev/null; then
    /usr/sbin/sshd -E /var/log/auth.log
    echo "  SSH iniciado."
else
    echo "  SSH já estava rodando."
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