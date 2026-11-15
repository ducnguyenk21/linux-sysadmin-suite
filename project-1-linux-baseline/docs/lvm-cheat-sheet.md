\# LVM (Logical Volume Manager) Zero-Downtime Expansion Guide
\## 1. Initial Setup
```bash
\# Create Physical Volume on raw disk
sudo pvcreate /dev/sdb

\# Create Volume Group
sudo vgcreate vg\_data /dev/sdb

\# Allocate 3GB Logical Volume
sudo lvcreate -L 3G -n lv\_app vg\_data

\# Format and Mount persistently
sudo mkfs.ext4 /dev/vg\_data/lv\_app
UUID=$(sudo blkid -s UUID -o value /dev/vg\_data/lv\_app)
echo "UUID=$UUID /mnt/app\_data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a
\`\`\`

## 2. Zero-Downtime Online Expansion
\`\`\`bash
# 1. Expand LVM volume by 1GB
sudo lvextend -L +1G /dev/vg_data/lv_app

# 2. Resize ext4 filesystem dynamically
sudo resize2fs /dev/vg_data/lv_app
\`\`\`
