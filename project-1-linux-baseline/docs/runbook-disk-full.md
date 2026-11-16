# Operational Runbook: Disk Space Exhaustion & I/O Bottleneck Diagnostics

## 1. Purpose & Scope
This runbook provides a standardized troubleshooting procedure for Linux Systems Administrators and NOC Engineers to diagnose and resolve disk space exhaustion and storage I/O bottlenecks on Ubuntu 24.04 LTS production servers (`srv01`) without causing service downtime.

---

## 2. Rapid Triage Matrix (First 60 Seconds)

| Symptom | Primary Diagnostic Command | Root Cause Category |
| :--- | :--- | :--- |
| `df -h` shows 100% `Use%`, `du -sh` matches | `du -xh --max-depth=1 /path \| sort -hr` | Legitimate large files / unrotated logs |
| `df -h` shows high usage, `du -sh` shows minimal usage | `sudo lsof +L1` | Unlinked (deleted) files still held open by active processes |
| `df -h` shows free space, but writes fail with `No space left on device` | `df -i` | Inode table exhaustion (millions of tiny files) |
| High Load Average, slow API/DB response, `%wa` elevated | `vmstat 1 5` & `iostat -xz 1 3` | Disk IOPS / bandwidth saturation |

---

## 3. Resolution Procedures

### Scenario A: Unlinked Open Files ("Ghost" Disk Usage)
**Mechanism:** Running `rm` invokes `unlink()`, dropping the file's hard link count (`NLINK`) to `0`. However, the Linux Kernel VFS does not deallocate disk blocks from the Inode until all open File Descriptors (`/proc/<PID>/fd/<FD>`) are closed.

1. **Identify the holding process and File Descriptor:**
   ```bash
   sudo lsof +L1 /mnt/app_data
   ```
2. **Resolution (Choose based on service criticality):**
   - **Non-critical background process:** Terminate the process cleanly (`SIGTERM`):
     ```bash
     kill <PID>
     ```
   - **Critical production service (Zero-Downtime):** Truncate the open File Descriptor directly via `/proc` without restarting the service:
     ```bash
     sudo truncate -s 0 /proc/<PID>/fd/<FD>
     ```
3. **Lab Validation Evidence (`srv01`):**
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

---

### Scenario B: Legitimate Data Block Exhaustion (`df -h` = 100%)
1. **Locate largest directories and files on the affected mount point (without crossing filesystem boundaries):**
   ```bash
   sudo du -xh --max-depth=1 /mnt/app_data | sort -hr
   sudo find /mnt/app_data -type f -size +500M -exec ls -lh {} +
   ```
2. **Mitigation:**
   - Compress or archive old logs (`gzip`), or truncate active oversized logs safely (`sudo truncate -s 0 /path/to/large.log`).
   - If disk growth is legitimate business data, perform an online LVM expansion:
     ```bash
     sudo lvextend -r -L +3G /dev/vg_data/lv_app
     ```

---

### Scenario C: Inode Exhaustion (`df -i` = 100%)
1. **Verify Inode consumption:**
   ```bash
   df -i /mnt/app_data
   ```
2. **Pinpoint directories containing excessive small files (e.g., session caches, mail queues):**
   ```bash
   sudo find /mnt/app_data -xdev -printf '%h\n' | sort | uniq -c | sort -nr | head -n 10
   ```
3. **Mitigation:** Batch-delete obsolete temporary files safely using `find ... -delete` rather than `rm *` (which triggers `Argument list too long`).

---

### Scenario D: Storage I/O Bottleneck Diagnosis
1. **Inspect CPU wait (`wa`), blocked processes (`b`), and device saturation (`%util`, `w_await`):**
   ```bash
   vmstat 1 5
   iostat -xz 1 3
   ```
2. **Lab Validation Evidence (`srv01` under `stress-ng --cpu 1 --hdd 2` load):**
   ```text
   # vmstat 1 5 (real-time samples showing run queue r=4..5 and write throughput bo up to 262 MB/s)
   procs -----------memory---------- ---swap-- -----io---- -system-- --------cpu--------
    r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st gu
    4  0      0 2557992  33924 1163624    0    0     0 131072  647  397 33 67  0  0  0  0
    4  0      0 2428304  33952 1259156    0    0     0 262392 1557  587 14 86  0  0  0  0

   # iostat -xz 1 3 (Device Mapper dm-0 mapping write load to physical disk sdb)
   Device            r/s     rkB/s   w/s     wkB/s   w_await  aqu-sz  %util
   dm-0             0.00      0.00 41.90 124937.14      4.80    2.30 102.57
   sdb              0.00      0.00 103.81 113965.71     7.29    1.81 104.29
   ```
3. **Mitigation:** Identify the top I/O-consuming PID via `sudo pidstat -d 1` or `sudo iotop -oPa` and throttle its I/O scheduling priority using `sudo ionice -c 3 -p <PID>`.