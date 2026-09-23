# Lab Notes: Firewall / Database Replication+TLS / Keepalived VRRP

> สรุปความรู้และคำสั่งจาก lab บน Multipass VM (`k8s-master`, `k8s-worker-1`, `k8s-worker-2`)

---

## 1. Firewall (UFW)

> ยังไม่ได้ลงมือทำจริงใน lab นี้ — เอกสารนี้เป็น guide สำหรับตอนจะเริ่มทำ

### หลักการ

UFW (Uncomplicated Firewall) คือ frontend ที่ทำให้ตั้งค่า `iptables` ง่ายขึ้นบน Ubuntu หลักการพื้นฐาน:

- **Default deny incoming, allow outgoing** — ปิดทุกอย่างที่เข้ามาก่อน แล้วค่อยเปิดเฉพาะที่จำเป็น
- เปิดเฉพาะ port/service ที่ใช้จริง ไม่เปิดกว้างเกินจำเป็น
- จำกัดแหล่งที่มา (source IP/subnet) ให้แคบที่สุดเท่าที่ทำได้ ไม่ใช่เปิดรับจากทุกที่ (`0.0.0.0/0`) ถ้าไม่จำเป็น

### คำสั่งพื้นฐาน

```bash
sudo ufw status verbose        # เช็คสถานะปัจจุบัน
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp          # SSH — อย่าลืมเปิดก่อน enable ไม่งั้นหลุดออกจาก VM
sudo ufw enable
```

### Rule ที่ควรตั้งสำหรับ lab นี้โดยเฉพาะ

| Service | Port | จำกัดจากไหน | หมายเหตุ |
|---|---|---|---|
| SSH | 22/tcp | เฉพาะ subnet ที่ใช้จริง | ต้องเปิดก่อน enable ufw เสมอ |
| Postgres | 5432/tcp | เฉพาะ `192.168.252.0/24` | ไม่เปิดรับจากอินเทอร์เน็ต |
| VRRP (keepalived) | **protocol 112** (ไม่ใช่ TCP/UDP) | ระหว่าง `worker-1` ↔ `worker-2` เท่านั้น | VRRP ใช้ IP protocol ตรง ๆ ไม่ใช่ port แบบ TCP/UDP ปกติ ต้องเปิดด้วย `ufw allow proto vrrp` หรือ `ufw allow from <peer-ip> proto 112` |

ตัวอย่างเปิด VRRP ระหว่าง 2 เครื่อง:

```bash
# บน worker-1
sudo ufw allow from 192.168.252.10 proto vrrp

# บน worker-2
sudo ufw allow from 192.168.252.9 proto vrrp
```

---

## 2. Database Replication + TLS/SSL (PostgreSQL)

### สถาปัตยกรรมที่ทำจริง

```
pg-primary (docker compose)
   │
   ├── wal_level=replica, archive_mode=on, archive_timeout=30
   ├── WAL ถูก archive ไปที่ ./wal_archive (host bind mount)
   │
   ▼ pg_basebackup -R + streaming replication (ผ่าน SSL/TLS)
pg-replica (docker compose)
   └── standby.signal + primary_conninfo (auto-gen โดย -R)
```

### Replication setup (สรุปคำสั่งหลัก)

**สร้าง replication user บน primary:**
```sql
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_pass';
```

**เปิดสิทธิ์ใน `pg_hba.conf`:**
```
host replication replicator 172.16.0.0/12 scram-sha-256
```

**สร้าง replica ด้วย `pg_basebackup -R`:**
```bash
pg_basebackup -h pg-primary -U replicator -D $PGDATA -R -X stream -c fast
```
`-R` จะสร้าง `standby.signal` + เขียน `primary_conninfo` ลง `postgresql.auto.conf` ให้อัตโนมัติ

### Point-In-Time Recovery (PITR) — หลักการ

```
[pg_basebackup: snapshot ณ เวลา T0]  +  [WAL archive ต่อเนื่อง]
        =
กู้ข้อมูลกลับไปเวลาไหนก็ได้ (T0 ≤ target ≤ ปัจจุบัน)
```

ขั้นตอน recovery:
1. เอา base backup มาวางเป็น data directory
2. สร้าง `recovery.signal`
3. ตั้งค่าใน `postgresql.auto.conf`:
```
restore_command = 'cp /wal_archive/%f %p'
recovery_target_time = '<timestamp ก่อนเหตุการณ์ที่ต้องการย้อน>'
recovery_target_action = 'promote'
```
4. Start ขึ้นมา → Postgres replay WAL อัตโนมัติจนถึงเวลาที่กำหนดแล้ว promote เอง

**ข้อควรระวังที่เจอจริง:**
- ต้อง `SELECT pg_switch_wal();` ก่อน stop primary ทุกครั้ง (planned) เพื่อบังคับ archive segment ล่าสุด ไม่งั้น transaction ล่าสุดอาจหายเพราะยังไม่ archive
- `archive_timeout` ควรตั้งไว้เป็น safety net (กันกรณี crash แบบไม่ทันตั้งตัว)
- หลัง primary promote แล้ว **replica เดิมใช้ต่อไม่ได้** (timeline fork) ต้อง `pg_basebackup` ใหม่เสมอ
- PITR ทำได้แค่ "จุดเดียว" (primary) แล้ว replica ทุกตัว rebuild ใหม่จากจุดนั้น ห้ามทำ PITR แยกกันหลาย node

### TLS/SSL

**Gen cert (self-signed พอสำหรับ internal):**
```bash
openssl req -new -x509 -days 365 -nodes -text \
  -out server.crt -keyout server.key -subj "/CN=pg-primary"
chmod 600 server.key
```
วางไว้ใน `$PGDATA` ตรง ๆ (Postgres หาเจอเองอัตโนมัติ ไม่ต้องตั้ง `ssl_cert_file`/`ssl_key_file`)

**เปิด SSL:**
```
-c ssl=on
```

**บังคับให้ต้องใช้ SSL เท่านั้น (`pg_hba.conf`):**
```
hostssl all all all scram-sha-256   # แทน host ธรรมดา
```

**Replica ต่อแบบ verify-ca** (เอาแค่ public cert `.crt` — **ห้ามเอา `.key` ออกจาก primary เด็ดขาด**):
```bash
PGSSLMODE=verify-ca PGSSLROOTCERT=/certs/server.crt pg_basebackup ...
```

**เช็คว่า connection เข้ารหัสจริง:**
```sql
SELECT client_addr, ssl, cipher FROM pg_stat_ssl JOIN pg_stat_replication USING (pid);
```

---

## 3. Keepalived / VRRP

### หลักการ

```
Client
   │
   ▼ VIP (Virtual IP) — IP เดียวที่ client รู้จัก
[worker-1 = MASTER, priority 100] ←heartbeat (VRRP)→ [worker-2 = BACKUP, priority 90]
```

- MASTER ถือ VIP ไว้ตลอด (ตราบใดที่ยังส่ง heartbeat ปกติ)
- BACKUP คอยฟัง heartbeat เฉย ๆ — ถ้าขาดหายเกิน timeout จะเลื่อนตัวเองขึ้นมาถือ VIP แทน
- Service จริง (เช่น nginx) **รันอยู่ทั้ง 2 เครื่องตลอดเวลา** — แต่ traffic จะวิ่งไปหาแค่เครื่องที่ถือ VIP เท่านั้น เพราะฉะนั้น failover เร็วมาก (ไม่ต้อง start service ใหม่ แค่เปลี่ยนว่าใครรับ traffic)

### กฎ: ชั้นไหนควร active-active vs active-passive

> ชั้นที่ client ต่อเข้ามา "ตรง ๆ" โดยไม่มีตัวกลางคอยกระจาย → **active-passive** (กัน infinite regress ของการ "load balance ตัว load balancer เอง")
> ชั้นที่มี LB/VIP อยู่ข้างบนคอยกระจายให้อยู่แล้ว → **active-active** ได้เต็มที่

### Config ตัวอย่าง (unicast — ใช้กับ Multipass เพราะ multicast ใช้ไม่ได้)

**worker-1 (MASTER):**
```
vrrp_instance VI_1 {
    state MASTER
    interface enp0s1
    virtual_router_id 51
    priority 100
    advert_int 1
    unicast_src_ip 192.168.252.9
    unicast_peer {
        192.168.252.10
    }
    authentication {
        auth_type PASS
        auth_pass mysecret1
    }
    virtual_ipaddress {
        192.168.252.50
    }
}
```

**worker-2 (BACKUP):** เหมือนกันทุกอย่าง ยกเว้น `state BACKUP`, `priority 90`, สลับ `unicast_src_ip`/`unicast_peer`

### ปัญหาที่เจอจริงระหว่างทำ + วิธีแก้

| ปัญหา | สาเหตุ | วิธีแก้ |
|---|---|---|
| Config ไฟล์เพี้ยน (`v` หายจาก `vrrp_instance`) | byte แรกหายตอนส่งผ่าน stdin ของ `multipass exec`/paste | เขียนไฟล์บน host ก่อน แล้ว `multipass transfer` เข้า VM แทน |
| ทั้ง 2 เครื่องถือ VIP พร้อมกัน (split-brain) | Multicast (`224.0.0.18`) ใช้ไม่ได้บน bridge network ของ Multipass | เปลี่ยนจาก multicast → **unicast** (`unicast_src_ip` + `unicast_peer`) |

### คำสั่งทดสอบ/ยืนยันผล

**เช็คว่า VIP อยู่ที่เครื่องไหน (จากฝั่ง server):**
```bash
multipass exec k8s-worker-1 -- ip -o -4 addr show enp0s1
```

**เช็คว่า VIP อยู่ที่เครื่องไหน (จากฝั่ง client — ต้องดู MAC ไม่ใช่ IP เพราะ IP ที่ตอบกลับมาคือ VIP เสมอ):**
```bash
ping -c 1 192.168.252.50
arp -n 192.168.252.50
```

**ทดสอบ failover จริง (ดับทั้ง VM):**
```bash
multipass stop k8s-worker-1     # ดู VIP ย้ายไป worker-2
multipass start k8s-worker-1    # worker-1 priority สูงกว่า จะแย่ง VIP กลับอัตโนมัติ (preemption)
```

**ป้องกัน preemption** (ถ้าไม่อยากให้ MASTER เดิมแย่ง VIP กลับอัตโนมัติเมื่อกลับมา):
```
nopreempt
```
ใส่ไว้ใน `vrrp_instance` block ของฝั่งที่ไม่อยากให้ preempt (ปกติใส่ฝั่ง state ที่เป็น BACKUP หรือใช้คู่กับ `state BACKUP` เสมอในทุกเครื่อง)
