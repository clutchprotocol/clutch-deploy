# Ubuntu Server — SSH setup for Clutch stage

This guide assumes a **fresh Ubuntu Server** LTS VPS (64-bit **x86_64** or **ARM64**), accessed with **OpenSSH** from **Windows**. Tested patterns match **Ubuntu Server 22.04 LTS (Jammy)** and **24.04 LTS (Noble)**. Replace placeholders (`YOUR_SERVER_IP`, domains, Git URLs) with yours.

---

## 0. After install (provider panel)

- Note the server **public IPv4** (and IPv6 if you use it).
- If the host gave you a **root password**, plan to switch to **SSH keys** and rotate the password after first login.

---

## 1. Connect from Windows (PowerShell)

**Password login** (initial access only):

```powershell
ssh root@YOUR_SERVER_IP
```

**SSH key (recommended)**

On your PC:

```powershell
ssh-keygen -t ed25519 -C "your-email@example.com" -f $env:USERPROFILE\.ssh\id_ed25519_clutch
```

Copy the key to the server:

```powershell
type $env:USERPROFILE\.ssh\id_ed25519_clutch.pub | ssh root@YOUR_SERVER_IP "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

Next logins:

```powershell
ssh -i $env:USERPROFILE\.ssh\id_ed25519_clutch root@YOUR_SERVER_IP
```

---

## 2. Confirm Ubuntu and update the system

On the **server**:

```bash
lsb_release -a
uname -m
```

Update package lists and installed packages:

```bash
sudo apt update
sudo apt upgrade -y
```

If the upgrade installed a new kernel, reboot when convenient:

```bash
sudo reboot
```

Then SSH in again.

Common tools for the rest of this guide (safe on **Ubuntu Server minimal**):

```bash
sudo apt install -y git curl nano
```

---

## 3. Install Docker Engine and Compose (Ubuntu packages from Docker)

Use Docker’s **official APT repo for Ubuntu** (not the obsolete `docker.io` from Universe alone).

```bash
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Check:

```bash
docker --version
docker compose version
```

Run containers as a non-root user (optional; useful if you create a deploy user later):

```bash
sudo usermod -aG docker $USER
```

Log out completely and SSH in again so the `docker` group applies.

---

## 4. Firewall: UFW on Ubuntu Server

**UFW** is the default uncomplicated firewall on Ubuntu; enable it only after allowing **SSH**.

```bash
sudo apt install -y ufw
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
```

**Cloudflare Flexible** (TLS ends at Cloudflare; origin is HTTP): **80/tcp** is enough for public HTTP from the edge.

If you later serve **HTTPS on the VPS** (e.g. Cloudflare **Full (strict)**):

```bash
sudo ufw allow 443/tcp
```

Activate and review:

```bash
sudo ufw enable
sudo ufw status verbose
```

---

## 5. Deploy `clutch-deploy` on the Ubuntu server

**Git** (replace with your repo):

```bash
cd ~
git clone https://github.com/clutchprotocol/clutch-deploy.git
cd clutch-deploy
```

**Copy from Windows** (PowerShell; from the parent directory of `clutch-deploy`):

```powershell
scp -r -i $env:USERPROFILE\.ssh\id_ed25519_clutch .\clutch-deploy root@YOUR_SERVER_IP:/root/
```

On the server:

```bash
cd /root/clutch-deploy
```

---

## 6. Environment file

```bash
cp .env.example .env
nano .env
```

Set at least:

- **JWT_SECRET** — long random string  
- **ALLOWED_ORIGINS** — your real `https://` origins  
- **SEQ_API_KEY** — if you use Seq  

In **nano**: save with **Ctrl+O**, Enter; exit with **Ctrl+X**.

---

## 7. Nginx hostnames (Cloudflare Flexible)

```bash
nano config/nginx/nginx.stage.cloudflare-flex.conf
```

Set `server_name` values to the hostnames you use in **Cloudflare DNS**.

---

## 8. Start the Clutch stage stack (Cloudflare Flexible)

From `/root/clutch-deploy` (or wherever you cloned it):

```bash
docker compose -p clutch-stage -f docker-compose.yml -f docker-compose.stage.cloudflare-flex.yml pull
docker compose -p clutch-stage -f docker-compose.yml -f docker-compose.stage.cloudflare-flex.yml up -d --force-recreate
```

Status:

```bash
docker compose -p clutch-stage -f docker-compose.yml -f docker-compose.stage.cloudflare-flex.yml ps
```

Health (set `Host` to your API hostname):

```bash
curl -sS -H "Host: stageapi.yourdomain.com" http://127.0.0.1/health
```

---

## 9. Cloudflare (dashboard)

1. **DNS**: **A** record → server IP, proxy **proxied** (orange cloud).  
2. **SSL/TLS → Overview**: **Flexible** when the origin is HTTP-only.  
3. Test in the browser with **https://** on your hostname.

More detail: [README.md](../README.md) (*Stage behind Cloudflare*).

---

## 10. Maintenance (Ubuntu + Docker Compose v2)

```bash
# Logs
docker compose -p clutch-stage -f docker-compose.yml -f docker-compose.stage.cloudflare-flex.yml logs -f --tail=100

# Stop
docker compose -p clutch-stage -f docker-compose.yml -f docker-compose.stage.cloudflare-flex.yml down
```

On Ubuntu, prefer **`docker compose`** (plugin) rather than the old standalone `docker-compose` binary.

---

## Security checklist (Ubuntu Server)

- Use **SSH keys**; disable root password login when you have a sudo user if your policy requires it.  
- Harden SSH: set `PasswordAuthentication no` in `/etc/ssh/sshd_config` when keys work, then:

  ```bash
  sudo systemctl restart ssh
  ```

  On Ubuntu the unit is **`ssh`** (socket **ssh.socket** may also be in use; `restart ssh` is the usual command).

- Keep **UFW** enabled with only required ports.  
- Enable **unattended security updates** if you want (optional): `sudo apt install unattended-upgrades` and configure `/etc/apt/apt.conf.d/50unattended-upgrades`.  
- Rotate any password that was shared or leaked.

---

## Troubleshooting (Ubuntu)

| Issue | What to try |
|--------|----------------|
| `Permission denied` on `docker` | Log out and back in after `usermod -aG docker`; or use `sudo docker` temporarily. |
| UFW locked you out | Use provider **console / rescue** and `ufw disable` or fix rules. Always allow **OpenSSH** before `ufw enable`. |
| Wrong Ubuntu codename in Docker list | `echo $VERSION_CODENAME` should be `jammy`, `noble`, etc. Re-run the deb line from §3 if you upgraded release. |
