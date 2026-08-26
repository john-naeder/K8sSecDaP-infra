# Runbook — cứu userver-worker-2

Trạng thái: **offline từ ~2026-08-18**. Không cứu được từ xa.

## Đã kiểm tra những gì (2026-08-25)

| Phép thử | Kết quả |
|---|---|
| `tailscale status` | offline, last seen 6 ngày |
| ARP/ping sweep toàn bộ `192.168.0.0/24` từ master | chỉ thấy router `.1` và worker-1 `.12` |
| `tcpdump` thụ động 75s trên `wlp2s0` (arp + dhcp + icmp6) | chỉ thấy MAC của router và của master |

Phép thử thứ ba là phép quyết định. Một máy còn sống và **đã associate** Wi-Fi
thì vẫn phát ARP broadcast đi tìm gateway, kể cả khi IP của nó sai subnet và
kể cả khi nó không có default route. Suốt 75 giây không có MAC lạ nào.

Kết luận: **worker-2 không associate vào Wi-Fi.** Lỗi nằm dưới tầng IP, nên
mọi giả thuyết kiểu "sai IP nên không gọi được" đều bị loại.

## Vì sao không có đường cứu từ xa

- Không có BMC/IPMI. Đây là laptop, không phải server có out-of-band.
- Wake-on-LAN không dùng được: WoWLAN qua Wi-Fi phụ thuộc driver + firmware và
  card phải còn được cấp điện. Không tin cậy được.
- Router không giúp gì. Nó chỉ thấy thiết bị nào đã associate.
- Quyền quản trị router (qua SSH tunnel) cũng không giúp: vấn đề nằm ở phía
  client.

## Hai nguyên nhân khả dĩ, theo thứ tự khả năng

**1. Máy đang suspend hoặc đã tắt.** Nhiều khả năng nhất. Nó là laptop và
`HandleLidSwitch` mặc định của systemd-logind là `suspend`. worker-1 đã được
đặt `ignore`, master thì **chưa** — nên rất có thể worker-2 cũng chưa.

**2. netplan hỏng làm wpa_supplicant không associate được.** Ví dụ block
`access-points` bị sai indent sau khi sửa tay, hoặc `netplan apply` chạy nửa
chừng trên interface Wi-Fi.

Cả hai đều chỉ sửa được khi ngồi trước máy.

## Khi về đến nơi

1. Mở nắp / bấm nguồn. **Nếu nó boot lên và vào mạng thì xong** — chỉ là
   suspend, không phải netplan. Kiểm tra ngay:
   ```bash
   ip -4 addr show; ip route show default; tailscale status
   ```

2. Nếu có mạng nhưng sai: xem netplan sinh ra cái gì.
   ```bash
   sudo netplan generate          # in ra lỗi cú pháp nếu có
   sudo cat /run/netplan/wpa-*.conf
   systemctl status netplan-wpa-*.service
   journalctl -u wpa_supplicant -b --no-pager | tail -40
   ```

3. Nếu không vào được Wi-Fi: cắm dây LAN (hoặc dongle USB-C) rồi sửa qua đó.
   Không có dây thì phải dùng bàn phím + màn hình trực tiếp.

4. Khôi phục về cấu hình **giống hệt hai máy kia** — đây là cấu hình đã chứng
   minh chạy được nhiều tuần:
   ```yaml
   network:
     version: 2
     wifis:
       <iface>:
         dhcp4: true            # GIỮ. Nó là lưới an toàn, không phải rác.
         optional: true
         addresses:
           - 192.168.0.13/24    # IP tĩnh vẫn có, chạy song song với DHCP
         access-points:
           "95LVD-2":
             hidden: true
             auth: { key-management: "psk", password: "<PSK>" }
           "95LVD-back":
             auth: { key-management: "psk", password: "<PSK>" }
   ```
   Rồi `sudo netplan generate && sudo netplan apply`, và **reboot để xác nhận**
   nó tự lên được — chứ không chỉ xác nhận lúc đang chạy.

5. Ghi lại MAC Wi-Fi để điền vào `inventory/host_vars/userver-worker-2.yml`:
   ```bash
   ip link show <iface> | awk '/link\/ether/{print $2}'
   ```

6. Chống tái diễn — **làm cả trên master, nó đang không được bảo vệ**:
   ```bash
   sudo mkdir -p /etc/systemd/logind.conf.d
   printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n' \
     | sudo tee /etc/systemd/logind.conf.d/10-server-lid.conf
   sudo systemctl restart systemd-logind
   ```
   Bảo vệ ngay lập tức mà không cần restart daemon nào:
   ```bash
   sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
   ```
   Gỡ ra bằng `unmask` nếu cần.

7. Bỏ comment `userver-worker-2` trong `ansible/inventory/hosts.yml`.

## Giữ chỗ IP trong LAN

Mục tiêu: không thiết bị nào khác nhận được `.11`, `.12`, `.13` khi node
reboot hay chết.

Vào trang quản trị router. Không cần về nhà, tunnel qua node đang sống:

```bash
ssh -L 8080:192.168.0.1:80 johnnaeder@100.80.0.1
# giữ phiên, mở http://localhost:8080 ở máy mình
```

Trong UI Archer C64:

1. **Network -> LAN -> DHCP Server**: đặt pool bắt đầu từ `192.168.0.100` đến
   `192.168.0.199`. Đây là bước quan trọng nhất — nó khiến router **không bao
   giờ** cấp `.2`-`.99` cho bất kỳ ai, nên `.11/.12/.13` an toàn tuyệt đối kể
   cả khi node đang tắt. (Lease đang thấy là `.131` và `.150`, nên pool hiện
   tại nhiều khả năng đã rộng hơn khoảng này — cần thu lại.)

2. **Address Reservation** (tuỳ chọn, lớp bảo vệ thứ hai): gắn MAC với IP.

   | Node | MAC | IP |
   |---|---|---|
   | userver-master | `b4:d5:bd:f1:e9:6a` | 192.168.0.11 |
   | userver-worker-1 | `80:b6:55:b8:ee:76` | 192.168.0.12 |
   | userver-worker-2 | *(lấy khi cứu được máy)* | 192.168.0.13 |

Bước 1 một mình là đủ. Bước 2 chỉ thêm chắc.
