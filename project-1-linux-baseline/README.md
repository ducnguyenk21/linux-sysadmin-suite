# Dự Án 1: Tự Động Hóa Bảo Mật Hệ Điều Hành Linux (Hardening) & Quản Trị Lưu Trữ LVM

## 1. Kiến trúc & Tổng quan Dự án

Kho mã nguồn này triển khai bộ khung cấu hình hạ tầng chuẩn Production có tính chất **Idempotent** (đảm bảo chạy lặp lại nhiều lần không phát sinh sai lệch hay lỗi) cho hệ điều hành **Ubuntu Server 24.04 LTS**, kết hợp chuẩn hóa bảo mật theo khung CIS Benchmark, quản trị phân vùng linh hoạt bằng Logical Volume Manager (LVM) và tự động hóa đồng loạt bằng Ansible Roles.

### Sơ đồ Hạ tầng Lab

| Vai trò Node | Hostname | Địa chỉ IP | Thông số & Nhiệm vụ Kỹ thuật |
| :--- | :--- | :--- | :--- |
| **Managed Server** | `srv01` | `192.168.56.11` | Ubuntu 24.04 LTS, 2 vCPU, 4GB RAM, `20GB` OS + `2x5GB` ổ dữ liệu LVM (`/dev/sdb`, `/dev/sdc`) |
| **Control Node** | `vm2-client` | `192.168.56.12` | Ubuntu 24.04 LTS, máy điều khiển Ansible, khóa SSH Ed25519, kiểm thử bảo mật & chịu tải |

### Cấu trúc Thư mục Dự án

```text
project-1-linux-baseline/
├── bootstrap/
│   └── harden.sh                 # Kịch bản Bash bảo mật chuẩn Idempotent (vượt qua ShellCheck 100%)
├── storage/
│   └── lvm-setup.sh              # Tự động khởi tạo PV/VG/LV & cấu hình mount bền vững qua UUID
├── ansible/
│   ├── ansible.cfg               # Cấu hình lõi điều khiển Ansible Engine
│   ├── inventory.ini             # Danh sách máy chủ quản lý
│   ├── site.yml                  # Master Playbook điều phối tuần tự 4 Roles
│   ├── group_vars/               # Tập biến động phân tách theo nhóm máy chủ
│   └── roles/
│       ├── common/               # Cài đặt gói nền tảng, đồng bộ thời gian Chrony NTP & tinh chỉnh Kernel sysctl
│       ├── ssh-hardening/        # Cấu hình động Jinja2 sshd + Handler kiểm duyệt cú pháp sshd -t
│       ├── firewall-fail2ban/    # Tường lửa UFW (default-deny) + Fail2ban chặn tấn công từ pha [preauth]
│       └── lvm-storage/          # Khai báo trạng thái lưu trữ LVM & gắn kết bền vững /etc/fstab
└── docs/
    ├── lynis-audit-report.png    # Bằng chứng kiểm toán bảo mật Lynis (tăng từ 57 lên 82/100 điểm)
    └── runbook-disk-full.md      # Quy trình xử lý sự cố đầy ổ đĩa, cạn kiệt Inode & nghẽn Disk I/O
```

## 2. Các Giải pháp Kỹ thuật Trọng tâm Đã Triển khai

### A. Bảo mật Hệ điều hành & Kiểm toán (`bootstrap/harden.sh` & Ansible Roles)

* **Kiểm soát Truy cập (Access Control):** Bắt buộc xác thực bằng khóa công khai **Ed25519**, khóa đăng nhập trực tiếp tài khoản `root` (`PermitRootLogin no`), vô hiệu hóa xác thực mật khẩu và phân quyền `sudo` tối thiểu qua `/etc/sudoers.d/`.
* **Phòng thủ Mạng & Ngăn chặn Xâm nhập (Firewall & IPS):** Kích hoạt tường lửa `UFW` với chính sách chặn mặc định toàn bộ lưu lượng đi vào (`default deny incoming`), chỉ mở các cổng dịch vụ thiết yếu (`22`, `80`, `443`). Triển khai `Fail2ban` tích hợp bộ lọc `systemd` và biểu thức chính quy tùy chỉnh để chặn ngay các IP rà quét ngắt kết nối sớm ở pha `[preauth]`.
* **Gia cố Nhân Linux & Giám sát Nhật ký:** Tinh chỉnh tham số mạng và bảo vệ bộ nhớ nhân trong `/etc/sysctl.d/99-hardening.conf` (bật SYN Cookies, tắt IP Forwarding và ICMP Redirects, bật ASLR mức 2), vô hiệu hóa các mô-đun nhân không sử dụng, kích hoạt `auditd` và `sysstat`.
* **Kết quả Kiểm toán Bảo mật:** Nâng chỉ số **Lynis Hardening Index từ `57` lên `82/100` điểm** (`docs/lynis-audit-report.png`).

### B. Quản trị Lưu trữ LVM & Mở rộng Trực tuyến Zero-Downtime (`storage/lvm-setup.sh`)

* Gộp hai thiết bị khối vật lý độc lập dung lượng `5GB` (`/dev/sdb`, `/dev/sdc`) thành một Volume Group thống nhất `vg_data` (`10GB`).
* Cấp phát Logical Volume `lv_app` định dạng `ext4`, cấu hình tự động gắn kết bền vững qua mã **UUID** trong `/etc/fstab` kèm bộ cờ `defaults,nofail` tại điểm gắn kết `/mnt/app_data`.
* Thực thi mở rộng dung lượng trực tuyến không gián đoạn dịch vụ (`lvextend -r -L +3G /dev/vg_data/lv_app`) nâng cấp từ `4GB` lên `7GB` ngay khi phân vùng đang hoạt động.

### C. Tài liệu Quy trình Vận hành Chuẩn (`docs/runbook-disk-full.md`)

* Chuẩn hóa ma trận phân loại nhanh (60 giây) và quy trình khắc phục không gây gián đoạn dịch vụ cho 4 kịch bản sự cố thực tế: cạn kiệt block dữ liệu (`df -h`), cạn kiệt bảng Inode (`df -i`), rò rỉ dung lượng do tiến trình giữ tệp đã xóa (`lsof +L1` & làm rỗng qua `/proc/<PID>/fd/<FD>`), và nghẽn cổ chai băng thông I/O (`vmstat`, `iostat`).

## 3. Hướng dẫn Triển khai

### Phương thức 1: Khởi tạo Đơn lẻ qua Kịch bản Bash (Idempotent)

```bash
sudo bash project-1-linux-baseline/bootstrap/harden.sh
sudo bash project-1-linux-baseline/storage/lvm-setup.sh
```

### Phương thức 2: Triển khai Đồng loạt qua Ansible (Từ máy điều khiển `vm2-client`)

```bash
cd ~/project-1-linux-baseline/ansible
ansible-playbook -i inventory.ini site.yml
# Chạy lặp lại lần 2 để xác minh tính Idempotent tuyệt đối: ok=17 changed=0 unreachable=0 failed=0
```