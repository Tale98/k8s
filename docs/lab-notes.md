# Lab Notes: Firewall / Database Replication+TLS / Keepalived VRRP / CI-CD

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

---

## 4. CI/CD (GitHub Actions)

### หลักการ

```
CI (Continuous Integration)  = ทุก push ให้ระบบ build/test อัตโนมัติทันที ไม่รอคนมาเทสเอง
CD (Continuous Delivery/Deployment) = เตรียม/ส่ง artifact (image) ไปใช้งานจริงอัตโนมัติ
```

Runner (ทั้ง GitHub Actions self-hosted runner และ GitLab Runner) ทำงานแบบ **"เปิด connection ออกไปหา server เองล่วงหน้า แล้วค้างสายรอ"** (เหมือน call center ที่ลูกค้าโทรเข้าไปรอสาย) — เพราะฉะนั้นใช้งานได้แม้เครื่อง runner อยู่หลัง NAT/private network โดยไม่ต้องเปิด port อะไรเลยฝั่งเรา ตัว event (push/merge) เกิดที่ GitHub ก็จริง แต่ไม่ต้องเป็นฝ่าย "เปิด connection เข้ามา" หา runner

### สถาปัตยกรรมที่ทำจริง: แยก CI กับ CD คนละไฟล์ คนละ trigger

```
main    ──push──▶            .github/workflows/ci.yml   (build + validate เท่านั้น ไม่ publish)
release ──merge จาก main──▶  push (แค่จุดพัก ไม่มี workflow ผูกไว้ หรือจะ validate ซ้ำก็ได้)
tag "X.Y.Z" (มือ, push จาก release) ──▶ .github/workflows/cd.yml  (build + push ขึ้น ghcr.io)
```

**เหตุผลที่แยก branch/ไฟล์**: กันไม่ให้ workflow เดียวรก ต้องมี `if:` คอยแยกเงื่อนไขเยอะ ๆ — แยก trigger ให้ทำหน้าที่แยกกันตั้งแต่ระดับ `on:` เลย ไม่ต้องใช้ `if:` แยก step อีกที

**เหตุผลที่ tag เป็นตัว publish จริง ไม่ใช่ push เข้า `release` เฉย ๆ**: semantic version (major.minor.patch) เป็นการตัดสินใจของคน ไม่มีเครื่องมือไหนรู้ได้เองว่า commit นี้ "สำคัญแค่ไหน" — สำหรับ scale เล็ก/คนเดียว tag มือคือคำตอบที่ดีที่สุด ไม่ต้องพึ่ง auto-versioning tool (`github.run_number`, semantic-release ฯลฯ) ซึ่งเหมาะกับทีมใหญ่ที่มีวินัย commit message ร่วมกันมากกว่า

### `ci.yml` (trigger จาก `main`)

```yaml
name: CI
on:
  push:
    branches: ["main"]
jobs:
  build-and-validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: docker compose config
      - run: docker build ./frontend
      - run: docker build ./backend
```

### `cd.yml` (trigger จาก tag เท่านั้น)

```yaml
name: CD
on:
  push:
    tags:
      - "[0-9]+.[0-9]+.[0-9]+"
permissions:
  contents: read
  packages: write
jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Set lowercase owner
        run: echo "OWNER_LC=$(echo '${{ github.repository_owner }}' | tr '[:upper:]' '[:lower:]')" >> $GITHUB_ENV
      - name: Build and push versioned frontend
        run: |
          docker build -t ghcr.io/${{ env.OWNER_LC }}/frontend:latest -t ghcr.io/${{ env.OWNER_LC }}/frontend:${{ github.ref_name }} ./frontend
          docker push ghcr.io/${{ env.OWNER_LC }}/frontend:latest
          docker push ghcr.io/${{ env.OWNER_LC }}/frontend:${{ github.ref_name }}
      - name: Build and push versioned backend
        run: |
          docker build -t ghcr.io/${{ env.OWNER_LC }}/backend:latest -t ghcr.io/${{ env.OWNER_LC }}/backend:${{ github.ref_name }} ./backend
          docker push ghcr.io/${{ env.OWNER_LC }}/backend:latest
          docker push ghcr.io/${{ env.OWNER_LC }}/backend:${{ github.ref_name }}
```

### Syntax สำคัญที่เจอระหว่างทาง

| Syntax | ความหมาย |
|---|---|
| `uses:` vs `run:` | `uses` เรียก action สำเร็จรูปจาก marketplace, `run` สั่ง shell ตรง ๆ |
| `secrets.GITHUB_TOKEN` | token ที่ GitHub สร้างให้อัตโนมัติทุก run ไม่ต้องสร้าง PAT เอง |
| `${{ ... }}` | expression syntax ดึงค่าตัวแปรที่ระบบเตรียมไว้ (`github.actor`, `github.ref_name`, `github.sha`, ...) |
| `$GITHUB_ENV` | ไฟล์พิเศษ เขียน `KEY=value` ลงไปแล้วใช้ `${{ env.KEY }}` ใน step ถัดไปได้ (แต่ละ step รันคนละ shell process ตัวแปรธรรมดาข้าม step ไม่ได้) |
| `if:` บน step | กำหนดเงื่อนไขให้ step นั้นรันเฉพาะบางกรณี (ระดับ step ไม่ใช่แค่ระดับ job) |
| `tags:` filter | ใช้ glob pattern ของ GitHub เอง **ไม่ใช่ regex เต็มรูปแบบ** รองรับ `*`, `**`, `?`, `+`, `[0-9]` |

### ข้อควรระวังที่เจอจริง

- **Docker image tag ต้องเป็นตัวพิมพ์เล็กทั้งหมด** — `github.repository_owner`/`github.actor` ให้ค่าตามที่ username สะกดจริง (มีตัวใหญ่ได้) ต้องแปลงเองด้วย `tr '[:upper:]' '[:lower:]'` ก่อนใช้เป็น image tag เสมอ
- **`docker build -t tag1 -t tag2 ...`** — build ครั้งเดียวแปะได้หลาย tag พร้อมกัน (หรือใช้ `docker tag` แปะชื่อเพิ่มให้ image ที่ build เสร็จแล้วโดยไม่ build ซ้ำก็ได้ ผลเหมือนกัน)
- **`git push` ธรรมดาไม่พา tag ไปด้วย** ต้อง push แยก: `git push origin <tag-name>`
- **Git tag ถูกออกแบบให้แก้ไม่ได้ (immutable)** — `git tag` ชื่อซ้ำจะ error ถ้าต้อง force ใช้ `git tag -f` + `git push --force` แต่ไม่ควรทำถ้า tag เคย push ออกไปแล้ว (คนละคนอาจอ้างอิง commit คนละตัวภายใต้ชื่อเดียวกัน) — ถ้า tag ผิด ให้ข้ามไปใช้เลขใหม่แทน
- **`on: push: branches: [...] tags: [...]`** ทำงานแบบ **OR** เสมอ (1 push มี ref เดียว เป็นได้แค่ branch หรือ tag อย่างใดอย่างหนึ่ง ไม่มีทาง AND)
- **ไม่มี event `on: merge:`** ใน GitHub Actions — merge ที่ถูก push ออกไปนับเป็น `push` event ธรรมดา

### Self-hosted runner (concept, ยังไม่ได้ทำจริง)

ติดตั้งเป็น native package (ไม่ใช่ Docker image) รันเป็น systemd service (คล้าย `keepalived`):
```bash
./config.sh --url https://github.com/<user>/<repo> --token <TOKEN>
sudo ./svc.sh install && sudo ./svc.sh start
```
ขอ token ผ่าน command line ได้ (ไม่ต้องเข้าเว็บ) เหมาะกับ automation จริง:
```bash
gh api -X POST /repos/<user>/<repo>/actions/runners/registration-token --jq .token
```
**สำคัญ**: self-hosted runner ยังต้องพึ่ง github.com เป็นตัวกลางเสมอ (แค่เปลี่ยนว่า "งานรันที่ไหน" ไม่ใช่ "ตัด GitHub ออกทั้งหมด") ถ้าอยาก 100% internal ไม่พึ่ง GitHub เลย ต้องใช้ **GitHub Enterprise Server** (จ่ายเงิน) หรือ **GitLab CE self-hosted** (ฟรี) หรือ **DIY git hook** (`post-receive` บน bare repo ของเราเอง ไม่ต้องมี token/service ภายนอกเลย)

### GitLab CI/CD เทียบ GitHub Actions (สรุปสั้น)

| | GitHub Actions | GitLab CI/CD |
|---|---|---|
| ไฟล์ config | หลายไฟล์ `.github/workflows/*.yml` | ไฟล์เดียว `.gitlab-ci.yml` |
| จัดลำดับ job | ไม่มี stage ในตัว ใช้ `needs:` เอง | มี `stages:` ชัดเจน |
| Self-host ฟรีไหม | ❌ ต้อง GitHub Enterprise Server (เสียเงิน) | ✅ GitLab CE ฟรี |
| Spec ขั้นต่ำถ้า self-host | — | ~8GB RAM / 4 vCPU (หนักกว่า service อื่นในบทเรียนนี้มาก) |
