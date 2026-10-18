#!/bin/bash
MYIP=$(wget -qO- ipv4.icanhazip.com);
echo "Checking VPS"
clear
cekray=`cat /root/log-install.txt | grep -ow "XRAY" | sort | uniq`
if [ "$cekray" = "XRAY" ]; then
domainlama=`cat /etc/xray/domain`
else
domainlama=`cat /etc/v2ray/domain`
fi

clear
echo -e "[ ${green}INFO${NC} ] Start " 
sleep 0.5
systemctl stop nginx
domain=$(cat /var/lib/ipvps.conf | cut -d'=' -f2)
Cek=$(lsof -i:80 | cut -d' ' -f1 | awk 'NR==2 {print $1}')
if [[ ! -z "$Cek" ]]; then
sleep 1
echo -e "[ ${red}WARNING${NC} ] Detected port 80 used by $Cek " 
systemctl stop $Cek
sleep 2
echo -e "[ ${green}INFO${NC} ] Processing to stop $Cek " 
sleep 1
fi
echo -e "[ ${green}INFO${NC} ] Starting renew cert... " 
sleep 2
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
# Bare IP -> short-lived profile (Let's Encrypt requirement for IP certificates)
if [[ "$domain" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    ACME_PROFILE="--certificate-profile shortlived --days 3"
else
    ACME_PROFILE=""
fi
ACME_OK=0
/root/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 $ACME_PROFILE \
    --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx" && ACME_OK=1
if [ $ACME_OK -eq 1 ]; then
    ~/.acme.sh/acme.sh --installcert -d "$domain" --fullchainpath /etc/xray/xray.crt --keypath /etc/xray/xray.key --ecc
    echo -e "[ ${green}INFO${NC} ] Renew cert done... " 
else
    echo -e "[ WARNING ] Lets Encrypt failed for $domain - keeping the current certificate"
fi
sleep 2
echo -e "[ ${green}INFO${NC} ] Starting service $Cek " 
sleep 2
echo $domain > /etc/xray/domain
echo $domain > /etc/v2ray/domain
systemctl restart $Cek
systemctl restart nginx
echo -e "[ ${green}INFO${NC} ] All finished... " 
sleep 0.5
echo ""
read -n 1 -s -r -p "Press any key to back on menu"
m-domain
