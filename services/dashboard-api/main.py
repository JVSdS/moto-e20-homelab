from fastapi import FastAPI, Request
from fastapi.staticfiles import StaticFiles
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware
from datetime import datetime
import platform
import psutil
import shutil
import os
import secrets
import base64
import json
from dotenv import load_dotenv

load_dotenv()
API_KEY = os.getenv("API_KEY")

app = FastAPI()

class BasicAuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if request.url.path == "/":
            return await call_next(request)

        auth = request.headers.get("Authorization")
        if auth is None or not auth.startswith("Basic "):
            return JSONResponse(
                status_code=401,
                content={"detail": "Autenticação necessária"},
                headers={"WWW-Authenticate": "Basic"}
            )

        try:
            decoded = base64.b64decode(auth[6:]).decode("utf-8")
            username, password = decoded.split(":", 1)
        except Exception:
            return JSONResponse(status_code=401, content={"detail": "Credenciais malformadas"})

        if not secrets.compare_digest(password, API_KEY or ""):
            return JSONResponse(
                status_code=401,
                content={"detail": "Credenciais inválidas"},
                headers={"WWW-Authenticate": "Basic"}
            )

        return await call_next(request)

app.add_middleware(BasicAuthMiddleware)

def read_battery():
    caminho = os.path.expanduser("~/apps/healthcheck/battery.json")
    try:
        with open(caminho, "r") as f:
            data = json.load(f)
        return {
            "percentage": data.get("percentage"),
            "status": data.get("status"),
            "temperature": data.get("temperature"),
            "health": data.get("health")
        }
    except Exception:
        return None

@app.get("/")
def health():
    return {
        "status": "ok",
        "hostname": platform.node(),
        "timestamp": datetime.utcnow().isoformat()
    }

@app.get("/api/status")
def status():
    disk = shutil.disk_usage("/")
    return {
        "cpu_percent": None,
        "cpu_note": "indisponível no proot (leitura de /proc/stat não reflete uso real)",
        "ram_used_mb": round(psutil.virtual_memory().used / 1024 / 1024, 1),
        "ram_total_mb": round(psutil.virtual_memory().total / 1024 / 1024, 1),
        "disk_used_gb": round(disk.used / 1024 / 1024 / 1024, 1),
        "disk_total_gb": round(disk.total / 1024 / 1024 / 1024, 1),
        "hostname": platform.node(),
        "battery": read_battery()
    }

app.mount("/dashboard", StaticFiles(directory="static", html=True), name="static")
