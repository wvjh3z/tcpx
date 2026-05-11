#!/bin/bash
# Test menu 10 (log cleanup) on all VMs
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Get IPs
declare -A IPS USERS
for vm in vm-deb11 vm-deb12 vm-deb13 vm-ubu2004 vm-ubu2204 vm-ubu2404; do
  mac=$(virsh domiflist $vm 2>/dev/null | grep -oE "([0-9a-f]{2}:){5}[0-9a-f]{2}")
  ip=$(virsh net-dhcp-leases default 2>/dev/null | grep "$mac" | grep -oE "192\.[0-9]+\.[0-9]+\.[0-9]+")
  IPS[$vm]=$ip
  [[ $vm == vm-ubu* ]] && USERS[$vm]=ubuntu || USERS[$vm]=debian
  echo "$vm -> $ip (${USERS[$vm]})"
done

echo ""
echo "Distributing script..."
for vm in "${!IPS[@]}"; do
  ip=${IPS[$vm]}; user=${USERS[$vm]}
  [[ -z "$ip" ]] && continue
  $SCP /tmp/tcpx.sh ${user}@${ip}:/tmp/t.sh 2>/dev/null
  $SSH ${user}@${ip} "sudo cp /tmp/t.sh /root/tcpx.sh" 2>/dev/null
done
echo "Done"
echo ""

# Test log cleanup on each VM
for vm in vm-deb11 vm-deb12 vm-deb13 vm-ubu2004 vm-ubu2204 vm-ubu2404; do
  ip=${IPS[$vm]}; user=${USERS[$vm]}
  [[ -z "$ip" ]] && echo "[$vm] NO IP - SKIP" && continue

  echo "===== [$vm] $ip ====="
  os=$($SSH ${user}@${ip} "grep PRETTY /etc/os-release" 2>/dev/null)
  echo "  $os"

  # Run log cleanup
  result=$($SSH ${user}@${ip} "sudo bash /root/tcpx.sh log 2>&1 | tail -10" 2>/dev/null)
  echo "  $result"

  # Verify
  cron=$($SSH ${user}@${ip} "sudo crontab -l 2>/dev/null | grep clean_logs" 2>/dev/null)
  script=$($SSH ${user}@${ip} "ls -la /root/clean_logs.sh 2>/dev/null" 2>/dev/null)
  journal=$($SSH ${user}@${ip} "cat /etc/systemd/journald.conf.d/disable.conf 2>/dev/null | grep Storage" 2>/dev/null)

  echo "  VERIFY: cron=[${cron:+OK}] script=[${script:+OK}] journald=[${journal:+OK}]"
  echo ""
done

echo "===== ALL DONE ====="
