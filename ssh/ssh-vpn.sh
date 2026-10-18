#!/bin/bash
# ssh-vpn.sh (διορθωμένη έκδοση) - ασφαλές να ξανατρέξει (idempotent)
# Κύριες διορθώσεις:
#   * SSH ports: δεν πολλαπλασιάζονται πια οι εγγραφές "Port" σε κάθε εκτέλεση
#   * AddressFamily inet + ListenAddress 0.0.0.0 -> κάτω από το όριο των 16 listen sockets
#   * sshd -t πριν το restart, με αυτόματο rollback αν το config είναι χαλασμένο
#   * mkdir /run/sshd, dropbear/banner/shells/iptables/rc.local χωρίς διπλότυπα
#   * δεν κάνει exit 0 στη μέση αν υπάρχει ήδη το ddos-deflate

export DEBIAN_FRONTEND=noninteractive

green='\e[32m'; yell='\e[33m'; NC='\e[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo "Τρέξε το script ως root."
    exit 1
fi

# ---------------------------------------------------------------
# Ρυθμίσεις
# ---------------------------------------------------------------
SSH_PORTS="22 200 666 58080 51443 53 40000 500"   # ΜΕΧΡΙ 16 ports (εδώ 8, μόνο IPv4)
DROPBEAR_MAIN_PORT=143
DROPBEAR_EXTRA="-p 50000 -p 109 -p 110 -p 69"
BASE="https://raw.githubusercontent.com/kokosops/vpp/main"
ALT="https://raw.githubusercontent.com/NETWORKTWEAKER/AUTO-SCRIPT/master"
# Αν θες να χαλαρώσεις τους κανόνες κωδικού (όπως έκανε το αρχικό script) βάλε 1
RELAX_PASSWORD_RULES=1

# initializing var
MYIP=$(wget -qO- ipv4.icanhazip.com)
NET=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
source /etc/os-release
ver=$VERSION_ID

# detail πιστοποιητικού
country=ID
state=Indonesia
locality=Jakarta
organization=none
organizationalunit=none
commonname=none
email=none

# ---------------------------------------------------------------
# Βοηθητικές συναρτήσεις
# ---------------------------------------------------------------
apt_try() {
    # εγκατάσταση πακέτων ένα-ένα, χωρίς να σταματά αν κάποιο δεν υπάρχει
    for p in "$@"; do
        apt-get install -y "$p" >/dev/null 2>&1 || echo "[skip] πακέτο '$p' δεν εγκαταστάθηκε"
    done
}

rc_add() {
    # προσθέτει γραμμή στο rc.local πριν το "exit 0", μόνο αν δεν υπάρχει ήδη
    grep -qxF "$1" /etc/rc.local || sed -i "\$ i\\$1" /etc/rc.local
}

ipt_add() {
    # προσθέτει κανόνα iptables μόνο αν δεν υπάρχει
    iptables -C "$@" 2>/dev/null || iptables -A "$@"
}

port_busy() {
    # true αν η πόρτα ακούγεται από κάτι που ΔΕΝ είναι sshd (ή systemd-resolved)
    # Το systemd-resolved (πόρτα 53) το αγνοούμε: το setup1.sh το απενεργοποιεί αργότερα (dnsdisable.sh)
    ss -tlnpH "sport = :$1" 2>/dev/null | grep -v '"sshd"' | grep -v '"systemd-resolve"' | grep -q .
}

configure_sshd() {
    local cfg=/etc/ssh/sshd_config
    local bak="$cfg.bak.$(date +%s)"
    cp "$cfg" "$bak"
    mkdir -p /run/sshd && chmod 0755 /run/sshd

    # καθάρισμα όλων των παλιών/διπλών ρυθμίσεων που διαχειριζόμαστε
    sed -i '/^\s*\(Port\|AddressFamily\|ListenAddress\|Banner\)\s/d' "$cfg"
    sed -i '/^# --- ssh-vpn.sh ---$/d' "$cfg"
    sed -i 's/^AcceptEnv/#AcceptEnv/' "$cfg"
    sed -i 's/^#\?\s*PasswordAuthentication.*/PasswordAuthentication yes/' "$cfg"

    # drop-in αρχεία (Ubuntu/cloud-init) μπορούν να επικαλύψουν τα παραπάνω
    if ls /etc/ssh/sshd_config.d/*.conf >/dev/null 2>&1; then
        sed -i '/^\s*\(Port\|AddressFamily\|ListenAddress\)\s/d' /etc/ssh/sshd_config.d/*.conf
        sed -i 's/^\s*PasswordAuthentication\s.*/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/*.conf
    fi

    {
        echo ""
        echo "# --- ssh-vpn.sh ---"
        echo "AddressFamily inet"
        echo "ListenAddress 0.0.0.0"
        for p in $SSH_PORTS; do
            if [ "$p" != "22" ] && port_busy "$p"; then
                echo "# Port $p παραλείφθηκε: ήδη σε χρήση από άλλη υπηρεσία" >> "$cfg.skipped"
                echo "[warn] η πόρτα $p είναι σε χρήση, παραλείπεται για το sshd"
                continue
            fi
            echo "Port $p"
        done
        echo "Banner /etc/issue.net"
    } >> "$cfg"
    rm -f "$cfg.skipped"

    if sshd -t; then
        systemctl restart ssh 2>/dev/null || systemctl restart sshd
        echo -e "[ ${green}ok${NC} ] sshd ξεκίνησε"
    else
        echo "[ERROR] το sshd_config έχει πρόβλημα, επαναφορά από $bak"
        cp "$bak" "$cfg"
        return 1
    fi
}

# ---------------------------------------------------------------
# Βασικά πακέτα
# ---------------------------------------------------------------
apt-get update -y
apt-get dist-upgrade -y
apt-get install -y netfilter-persistent
apt-get remove --purge ufw firewalld exim4 -y

apt_try screen curl jq bzip2 gzip vnstat coreutils rsyslog iftop zip unzip git \
    apt-transport-https build-essential shc wget figlet ruby python3 make cmake \
    net-tools nano sed gnupg bc dirmngr libxml-parser-perl neofetch lsof \
    libsqlite3-dev libz-dev gcc g++ libreadline-dev zlib1g-dev libssl-dev dos2unix
gem install lolcat >/dev/null 2>&1 || true

# ---------------------------------------------------------------
# Κανόνες κωδικού (τοπικά, χωρίς κατέβασμα κρυπτογραφημένου PAM αρχείου)
# ---------------------------------------------------------------
if [ "$RELAX_PASSWORD_RULES" = "1" ] && [ -f /etc/pam.d/common-password ]; then
    cp -n /etc/pam.d/common-password /etc/pam.d/common-password.orig
    sed -i 's/^\(password\s\+requisite\s\+pam_pwquality.so.*\)/# \1/' /etc/pam.d/common-password
    sed -i 's/^\(password\s\+requisite\s\+pam_cracklib.so.*\)/# \1/' /etc/pam.d/common-password
    sed -i 's/\(pam_unix.so.*\)\bobscure\b/\1/' /etc/pam.d/common-password
fi

cd /root || exit 1

# ---------------------------------------------------------------
# rc.local
# ---------------------------------------------------------------
cat > /etc/systemd/system/rc-local.service <<-END
[Unit]
Description=/etc/rc.local
ConditionPathExists=/etc/rc.local
[Service]
Type=forking
ExecStart=/etc/rc.local start
TimeoutSec=0
StandardOutput=tty
RemainAfterExit=yes
SysVStartPriority=99
[Install]
WantedBy=multi-user.target
END

cat > /etc/rc.local <<-END
#!/bin/sh -e
# rc.local
exit 0
END
chmod +x /etc/rc.local
systemctl daemon-reload
systemctl enable rc-local
systemctl start rc-local.service

# disable ipv6
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
rc_add 'echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6'

# timezone GMT+7
ln -fs /usr/share/zoneinfo/Asia/Jakarta /etc/localtime

# ---------------------------------------------------------------
# nginx
# ---------------------------------------------------------------
apt-get install -y nginx certbot
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
wget -O /etc/nginx/nginx.conf "$BASE/ssh/nginx.conf"
rm -f /etc/nginx/conf.d/vps.conf /etc/nginx/conf.d/default.conf
wget -O /etc/nginx/conf.d/vps.conf "$BASE/ssh/vps.conf"

mkdir -p /etc/systemd/system/nginx.service.d
printf "[Service]\nExecStartPost=/bin/sleep 0.1\n" > /etc/systemd/system/nginx.service.d/override.conf
systemctl daemon-reload
systemctl restart nginx

mkdir -p /home/vps/public_html/ss-ws /home/vps/public_html/clash-ws
wget -O /home/vps/public_html/index.html "$BASE/ssh/index"
wget -O /home/vps/public_html/.htaccess "$ALT/ssh/.htaccess"

# ---------------------------------------------------------------
# badvpn
# ---------------------------------------------------------------
wget -O /usr/bin/badvpn-udpgw "$BASE/ssh/newudpgw"
chmod +x /usr/bin/badvpn-udpgw
for p in 7100 7200 7300 7400 7500 7600 7700 7800 7900; do
    rc_add "screen -dmS badvpn$p badvpn-udpgw --listen-addr 127.0.0.1:$p --max-clients 500"
    if ! ss -tlnH "sport = :$p" 2>/dev/null | grep -q . && ! ss -ulnH "sport = :$p" 2>/dev/null | grep -q .; then
        screen -dmS "badvpn$p" badvpn-udpgw --listen-addr 127.0.0.1:$p --max-clients 500
    fi
done

# ---------------------------------------------------------------
# Dropbear (ΠΡΩΤΑ, ώστε το banner/ports να μπουν σωστά)
# ---------------------------------------------------------------
echo "=== Install Dropbear ==="
apt-get install -y dropbear
wget -O /etc/issue.net "$BASE/banner/banner.conf"

set_kv() {  # set_kv ΑΡΧΕΙΟ ΚΛΕΙΔΙ 'ΤΙΜΗ'  (δουλεύει και αν η γραμμή είναι σχολιασμένη)
    if grep -q "^#\?\s*$2=" "$1"; then
        sed -i "s|^#\?\s*$2=.*|$2=$3|" "$1"
    else
        echo "$2=$3" >> "$1"
    fi
}
set_kv /etc/default/dropbear NO_START 0
set_kv /etc/default/dropbear DROPBEAR_PORT "$DROPBEAR_MAIN_PORT"
set_kv /etc/default/dropbear DROPBEAR_EXTRA_ARGS "\"$DROPBEAR_EXTRA\""
set_kv /etc/default/dropbear DROPBEAR_BANNER '"/etc/issue.net"'

grep -qxF "/bin/false" /etc/shells || echo "/bin/false" >> /etc/shells
grep -qxF "/usr/sbin/nologin" /etc/shells || echo "/usr/sbin/nologin" >> /etc/shells

# ---------------------------------------------------------------
# OpenSSH (ports) - το κρίσιμο κομμάτι
# ---------------------------------------------------------------
configure_sshd || echo "[warn] το sshd δεν ρυθμίστηκε, έλεγξε χειροκίνητα"
systemctl restart dropbear || /etc/init.d/dropbear restart

# ---------------------------------------------------------------
# stunnel
# ---------------------------------------------------------------
cd /root || exit 1
apt-get install -y stunnel4
cat > /etc/stunnel/stunnel.conf <<-END
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh-ssl]
accept = 222
connect = 127.0.0.1:22

[dropbear-ssl]
accept = 777
connect = 127.0.0.1:109

[ws-stunnel]
accept = 2096
connect = 700

[openvpn]
accept = 442
connect = 127.0.0.1:1194

END

openssl genrsa -out key.pem 2048
openssl req -new -x509 -key key.pem -out cert.pem -days 1095 \
    -subj "/C=$country/ST=$state/L=$locality/O=$organization/OU=$organizationalunit/CN=$commonname/emailAddress=$email"
cat key.pem cert.pem > /etc/stunnel/stunnel.pem
chmod 600 /etc/stunnel/stunnel.pem

sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4
systemctl enable stunnel4
systemctl restart stunnel4

# ---------------------------------------------------------------
# fail2ban
# ---------------------------------------------------------------
apt-get install -y fail2ban

# ---------------------------------------------------------------
# DOS-Deflate
# ---------------------------------------------------------------
if [ -d /usr/local/ddos ]; then
    echo "DOS-Deflate υπάρχει ήδη, παραλείπεται."
else
    mkdir -p /usr/local/ddos
    echo 'Installing DOS-Deflate 0.6'
    wget -q -O /usr/local/ddos/ddos.conf       http://www.inetbase.com/scripts/ddos/ddos.conf
    wget -q -O /usr/local/ddos/LICENSE         http://www.inetbase.com/scripts/ddos/LICENSE
    wget -q -O /usr/local/ddos/ignore.ip.list  http://www.inetbase.com/scripts/ddos/ignore.ip.list
    wget -q -O /usr/local/ddos/ddos.sh         http://www.inetbase.com/scripts/ddos/ddos.sh
    chmod 0755 /usr/local/ddos/ddos.sh
    ln -sf /usr/local/ddos/ddos.sh /usr/local/sbin/ddos
    /usr/local/ddos/ddos.sh --cron > /dev/null 2>&1
    echo 'DOS-Deflate εγκαταστάθηκε (config: /usr/local/ddos/ddos.conf)'
fi

# ---------------------------------------------------------------
# Μπλοκάρισμα torrent
# ---------------------------------------------------------------
ipt_add FORWARD -m string --string "get_peers" --algo bm -j DROP
ipt_add FORWARD -m string --string "announce_peer" --algo bm -j DROP
ipt_add FORWARD -m string --string "find_node" --algo bm -j DROP
ipt_add FORWARD -m string --algo bm --string "BitTorrent" -j DROP
ipt_add FORWARD -m string --algo bm --string "BitTorrent protocol" -j DROP
ipt_add FORWARD -m string --algo bm --string "peer_id=" -j DROP
ipt_add FORWARD -m string --algo bm --string ".torrent" -j DROP
ipt_add FORWARD -m string --algo bm --string "announce.php?passkey=" -j DROP
ipt_add FORWARD -m string --algo bm --string "torrent" -j DROP
ipt_add FORWARD -m string --algo bm --string "announce" -j DROP
ipt_add FORWARD -m string --algo bm --string "info_hash" -j DROP
iptables-save > /etc/iptables.up.rules
netfilter-persistent save
netfilter-persistent reload

# ---------------------------------------------------------------
# Menu / scripts
# ---------------------------------------------------------------
cd /usr/bin || exit 1
fetch() { wget -O "$1" "$2" && chmod +x "$1"; }

# menu
fetch menu       "$BASE/menu/menu.sh"
fetch m-vmess    "$BASE/menu/m-vmess.sh"
fetch m-vless    "$BASE/menu/m-vless.sh"
fetch running    "$BASE/menu/running.sh"
fetch clearcache "$BASE/menu/clearcache.sh"
fetch m-ssws     "$BASE/menu/m-ssws.sh"
fetch m-trojan   "$BASE/menu/m-trojan.sh"

# menu ssh ovpn
fetch m-sshovpn  "$BASE/menu/m-sshovpn.sh"
fetch usernew    "$BASE/ssh/usernew.sh"
fetch trial      "$BASE/ssh/trial.sh"
fetch renew      "$BASE/ssh/renew.sh"
fetch hapus      "$BASE/ssh/hapus.sh"
fetch cek        "$BASE/ssh/cek.sh"
fetch member     "$BASE/ssh/member.sh"
fetch delete     "$BASE/ssh/delete.sh"
fetch autokill   "$BASE/ssh/autokill.sh"
fetch ceklim     "$BASE/ssh/ceklim.sh"
fetch tendang    "$BASE/ssh/tendang.sh"
fetch sshws      "$ALT/ssh/sshws.sh"
fetch user-lock  "$BASE/ssh/user-lock.sh"
fetch user-unlock "$BASE/ssh/user-unlock.sh"

# menu system
fetch m-system   "$BASE/menu/m-system.sh"
fetch m-domain   "$BASE/menu/m-domain.sh"
fetch add-host   "$BASE/ssh/add-host.sh"
fetch certv2ray  "$BASE/xray/certv2ray.sh"
fetch speedtest  "$BASE/ssh/speedtest_cli.py"
fetch auto-reboot "$BASE/menu/auto-reboot.sh"
fetch restart    "$BASE/menu/restart.sh"
fetch bw         "$BASE/menu/bw.sh"
fetch m-tcp      "$BASE/menu/tcp.sh"
fetch xp         "$BASE/ssh/xp.sh"
fetch m-dns      "$BASE/menu/m-dns.sh"
cd /root || exit 1

# ---------------------------------------------------------------
# cron
# NOTE: το νυχτερινό auto-reboot αφαιρέθηκε σκόπιμα (το VPS δεν πρέπει να κάνει reboot κάθε βράδυ)
# ---------------------------------------------------------------
cat > /etc/cron.d/xp_otm <<-END
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 0 * * * root /usr/bin/xp
END

echo "7" > /home/re_otm
service cron restart >/dev/null 2>&1

# ---------------------------------------------------------------
# Καθαρισμός
# ---------------------------------------------------------------
echo -e "[ ${green}INFO${NC} ] Clearing trash"
apt-get autoclean -y >/dev/null 2>&1
if dpkg -s unscd >/dev/null 2>&1; then
    apt-get -y remove --purge unscd >/dev/null 2>&1
fi
apt-get -y --purge remove 'samba*' 'apache2*' 'bind9*' >/dev/null 2>&1
apt-get -y remove 'sendmail*' >/dev/null 2>&1
apt-get autoremove -y >/dev/null 2>&1

# ---------------------------------------------------------------
# Τελικό restart υπηρεσιών
# ---------------------------------------------------------------
chown -R www-data:www-data /home/vps/public_html
echo -e "${yell}[SERVICE]${NC} Restart All service SSH & OVPN"
for s in nginx openvpn ssh dropbear fail2ban stunnel4 vnstat squid; do
    systemctl restart "$s" >/dev/null 2>&1 \
        && echo -e "[ ${green}ok${NC} ] Restarting $s" \
        || echo "[ -- ] $s δεν υπάρχει ή δεν ξεκίνησε"
done

# ιστορικό εντολών: απενεργοποίηση (μία φορά)
grep -qxF "unset HISTFILE" /etc/profile || echo "unset HISTFILE" >> /etc/profile

rm -f /root/key.pem /root/cert.pem /root/bbr.sh
# Το script ΔΕΝ διαγράφεται πια μόνο του (rm -f /root/ssh-vpn.sh αφαιρέθηκε)

echo ""
echo "Τέλος. Έλεγχος: ss -tlnp | grep -E 'sshd|dropbear|stunnel'"
