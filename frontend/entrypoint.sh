#!/bin/sh
set -e

# สร้างหน้าเว็บที่บอกตัวตนของตัวเอง เอาไว้ดูว่า VIP ตอบมาจากเครื่องไหน
cat > /usr/share/nginx/html/index.html <<HTML
<h1>Hello from ${HOSTNAME} (role: ${ROLE})</h1>
HTML

# start nginx ไว้เบื้องหลัง (ให้ service พร้อมรับ traffic ตลอดเวลา ไม่ว่าจะถือ VIP หรือไม่)
nginx -g "daemon off;" &

# keepalived รันเป็น foreground process หลัก (PID 1 ของ container)
exec keepalived --dont-fork --log-console
