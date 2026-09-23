#!/bin/bash
set -e

# start FastAPI ไว้เบื้องหลัง (พร้อมรับ traffic ตลอดเวลา ไม่ว่าจะถือ VIP หรือไม่)
uvicorn app:app --host 0.0.0.0 --port 8000 --app-dir / &

# keepalived รันเป็น foreground process หลัก (PID 1 ของ container)
exec keepalived --dont-fork --log-console
