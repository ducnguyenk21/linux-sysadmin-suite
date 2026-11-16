# Quy Trình Vận Hành (Runbook): Chẩn Đoán & Xử Lý Sự Cố Đầy Ổ Đĩa và Nghẽn Hiệu Năng I/O

## 1. Mục đích & Phạm vi Áp dụng

Tài liệu này cung cấp quy trình chuẩn hóa (SOP) dành cho Kỹ sư Quản trị Hệ thống Linux (SysAdmin) và Kỹ sư Vận hành Trung tâm Dữ liệu (NOC Engineer) nhằm khoanh vùng và xử lý dứt điểm sự cố cạn kiệt dung lượng lưu trữ cũng như nghẽn cổ chai tốc độ đọc/ghi (Disk I/O) trên máy chủ Ubuntu 24.04 LTS (`srv01`) mà **không làm gián đoạn dịch vụ (Zero-Downtime)**.

## 2. Ma trận Phân loại Nhanh (Trong 60 Giây Đầu Tiên)

| Triệu chứng Thực tế | Câu lệnh Chẩn đoán Chính | Phân loại Nguyên nhân Gốc rễ (Root Cause) |
| :--- | :--- | :--- |
| `df -h` báo `Use%` chạm `100%`, `du -sh` khớp với `df -h` | `du -xh --max-depth=1 /mnt/app_data \| sort -hr` | Tệp dữ liệu lớn hợp lệ hoặc tệp log phình to chưa xoay vòng |
| `df -h` báo đầy nhưng `du -sh` chỉ báo vài KB/MB | `sudo lsof +L1` | Tệp tin đã bị xóa tên (`unlink`) nhưng vẫn bị tiến trình giữ mở (Open File Descriptor) |
| `df -h` vẫn còn trống nhiều nhưng ghi dữ liệu báo `No space left on device` | `df -i` | Cạn kiệt bảng **Inode** do tồn tại hàng triệu tệp tin kích thước siêu nhỏ |
| `Load Average` tăng vọt, API/DB phản hồi chậm, chỉ số `%wa` cao | `vmstat 1 5` & `iostat -xz 1 3` | Bão hòa băng thông hoặc giới hạn IOPS của thiết bị lưu trữ |

## 3. Quy trình Xử lý Chi tiết Từng Kịch bản

### Kịch bản A: Tệp Đã Xóa Nhưng Vẫn Bị Tiến Trình Giữ Mở

**Cơ chế tầng nhân (Kernel VFS):** Khi chạy lệnh `rm`, nhân Linux gọi system call `unlink()` để xóa tên tệp khỏi thư mục và giảm bộ đếm liên kết cứng (`NLINK`) về `0`. Tuy nhiên, phân hệ quản lý tệp ảo (VFS) sẽ **không thu hồi các block dữ liệu vật lý** trên ổ đĩa cho tới khi toàn bộ các File Descriptor (`/proc/<PID>/fd/<FD>`) đang mở tệp đó được đóng lại.

1. **Truy tìm PID tiến trình và số hiệu File Descriptor đang giữ tệp:**

   ```bash
   sudo lsof +L1 /mnt/app_data
   ```

2. **Biện pháp khắc phục (Lựa chọn theo mức độ quan trọng của dịch vụ):**

   * **Tiến trình chạy nền không quan trọng:** Gửi tín hiệu kết thúc chuẩn (`SIGTERM`):

     ```bash
     kill <PID>
     ```

   * **Dịch vụ Production trọng yếu (Zero-Downtime):** Xả rỗng trực tiếp dữ liệu qua con trỏ File Descriptor trong `/proc` về `0 byte` mà không cần khởi động lại tiến trình:

     ```bash
     sudo truncate -s 0 /proc/<PID>/fd/<FD>
     ```

3. **Bằng chứng Kiểm thử Thực tế trên Hạ tầng Lab (`srv01`):**

   ```text
   nguyen@srv01:~$ df -h /mnt/app_data && du -sh /mnt/app_data
   Filesystem                       Size  Used Avail Use% Mounted on
   /dev/mapper/vg_data-lv_app       6.9G  2.1G  4.5G  31% /mnt/app_data
   24K     /mnt/app_data

   nguyen@srv01:~$ sudo lsof +L1 /mnt/app_data/
   COMMAND  PID   USER   FD   TYPE DEVICE   SIZE/OFF NLINK NODE NAME
   tail    6917 nguyen    3r   REG  252,0 2147483648     0   13 /mnt/app_data/test.log (deleted)

   nguyen@srv01:~$ kill 6917
   nguyen@srv01:~$ df -h /mnt/app_data/
   Filesystem                       Size  Used Avail Use% Mounted on
   /dev/mapper/vg_data-lv_app       6.9G   28K  6.5G   1% /mnt/app_data
   ```

### Kịch bản B: Cạn kiệt Khối Dữ liệu Vật lý (`df -h` = 100%)

1. **Khoanh vùng thư mục và tệp tin chiếm nhiều dung lượng nhất (cờ `-x` ngăn quét tràn sang phân vùng khác):**

   ```bash
   sudo du -xh --max-depth=1 /mnt/app_data | sort -hr
   sudo find /mnt/app_data -type f -size +500M -exec ls -lh {} +
   ```

2. **Biện pháp xử lý:**

   * Nén hoặc dọn dẹp các tệp sao lưu/log cũ quá hạn (`gzip`), hoặc làm rỗng tệp log đang được ghi (`sudo truncate -s 0 /duong/dan/file.log`).
   * Nếu dung lượng tăng do dữ liệu nghiệp vụ hợp lệ, thực hiện mở rộng nóng phân vùng LVM trực tuyến không gián đoạn:

     ```bash
     sudo lvextend -r -L +3G /dev/vg_data/lv_app
     ```

### Kịch bản C: Cạn kiệt Bảng Inode (`df -i` = 100%)

1. **Xác minh tỷ lệ sử dụng Inode:**

   ```bash
   df -i /mnt/app_data
   ```

2. **Tìm chính xác thư mục chứa nhiều tệp tin con nhất (thường gặp ở thư mục session, cache, hàng đợi mail):**

   ```bash
   sudo find /mnt/app_data -xdev -printf '%h\n' | sort | uniq -c | sort -nr | head -n 10
   ```

3. **Biện pháp xử lý:** Xóa theo lô các tệp tạm đã cũ bằng lệnh `find /duong/dan -type f -mtime +3 -delete`. Tuyệt đối không dùng `rm -f /duong/dan/*` vì Shell sẽ mở rộng ký tự đại diện `*` làm tràn bộ đệm đối số `ARG_MAX` của nhân Linux (`Argument list too long`).

### Kịch bản D: Chẩn đoán Nghẽn Cổ chai Disk I/O

1. **Theo dõi thời gian CPU chờ đĩa (`wa`), số tiến trình bị chặn (`b`) và độ bão hòa thiết bị (`%util`, `w_await`):**

   ```bash
   vmstat 1 5
   iostat -xz 1 3
   ```

2. **Bằng chứng Kiểm thử Áp lực Thực tế (`srv01` dưới tải `stress-ng --cpu 1 --hdd 2`):**

   ```text
   # vmstat 1 5 (mẫu thời gian thực cho thấy hàng đợi CPU r=4..5 và lưu lượng ghi đĩa bo đạt tới 262 MB/s)
   procs -----------memory---------- ---swap-- -----io---- -system-- --------cpu--------
    r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st gu
    4  0      0 2557992  33924 1163624    0    0     0 131072  647  397 33 67  0  0  0  0
    4  0      0 2428304  33952 1259156    0    0     0 262392 1557  587 14 86  0  0  0  0

   # iostat -xz 1 3 (Device Mapper dm-0 ánh xạ luồng ghi từ LVM xuống ổ vật lý sdb)
   Device            r/s     rkB/s   w/s     wkB/s   w_await  aqu-sz  %util
   dm-0             0.00      0.00 41.90 124937.14      4.80    2.30 102.57
   sdb              0.00      0.00 103.81 113965.71     7.29    1.81 104.29
   ```

3. **Biện pháp xử lý:** Khoanh vùng chính xác PID đang chiếm dụng I/O lớn nhất bằng `sudo pidstat -d 1` hoặc `sudo iotop -oPa`, sau đó hạ mức độ ưu tiên lập lịch I/O của tiến trình đó xuống lớp nhàn rỗi (`Idle`) bằng lệnh `sudo ionice -c 3 -p <PID>`.