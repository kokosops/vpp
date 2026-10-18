# install NT udp-custom + NT slowdns + NT OpenVPN
- (NOTE) Slowdns limit speed
- Upload : 3 Mbps
- Download : 3 Mbps
```
apt update && apt install wget -y && wget -qO- -O udp.sh "https://raw.githubusercontent.com/kokosops/vpp/main/udp-custom/udp.sh" && chmod +x udp.sh && ./udp.sh
```
- NS Pointing
![Service Status](https://github.com/kokosops/vpp/blob/main/udp-custom/slowdns/nspointing.png)


