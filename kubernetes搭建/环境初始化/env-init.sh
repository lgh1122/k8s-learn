#!/bin/bash
#
function log()
{
	level=$1
	msg=$2
	if [ "XERROR" == "X${level}" ]; then
		echo -e "\033[1;31m ${level} ${msg} \033[0m"
	elif [ "XINFO" == "X${level}" ]; then
		echo -e "\033[1;32m ${level} ${msg} \033[0m"
	elif [ "XWARN" == "X${level}" ]; then
		echo -e "\033[1;33m ${level} ${msg} \033[0m"
	else
		echo "${msg}"
	fi
}

# 关闭selinux,生产环境已关闭
selinux_status=$(sestatus | grep disabled |wc -l)
if [ $selinux_status -eq 1 ];then
  #echo "INFO:selinux had been disabled"
  log INFO "selinux had been disabled"
else
  sed -ri 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
fi

# 时间同步
yum install -y ntpdate
ntpdate time1.aliyun.com

#安装相关软件
yum install wget vim gcc git lrzsz net-tools tcpdump telnet rsync zip unzip -y

# 关闭swap
swap_state=$(free -m |grep "Swap" |awk '{print $2}')
if [ $swap_state -eq 0 ];then
  #echo "INFO:swap is off state."
  log INFO "swap is off state."
else
  #echo "ERROR:swap is up state."
  log ERROR "swap is up state."
  mv /etc/fstab /etc/fstab.bak
  cat /etc/fstab.bak |grep -v "swap" > /etc/fstab
  #echo "ERROR:please reboot this server node."
  log ERROR "please reboot this server node."
fi

# 关闭防火墙
systemctl disable firewalld
systemctl stop firewalld


yum -y install iptables-services
systemctl enable iptables
systemctl start iptables
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
iptables -P FORWARD ACCEPT
service iptables save

# 导入ipvs模块(用来为大量服务进行负载均衡)
cat > /etc/sysconfig/modules/ipvs.modules <<EOF
#!/bin/bash
modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack_ipv4
EOF
chmod 755 /etc/sysconfig/modules/ipvs.modules && bash /etc/sysconfig/modules/ipvs.modules && lsmod | grep -e ip_vs -e nf_conntrack_ipv4


# 网桥过滤
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 0
EOF

modprobe br_netfilter
netfilter_state=$(lsmod | grep br_netfilter | wc -l)
if [ $netfilter_state -ne 0 ];then
  #echo "INFO:br_netfilter load success"
  log INFO "br_netfilter load success"
else
  #echo "ERROR:br_netfilter load failed.please check..."
  log ERROR "br_netfilter load failed.please check..."
  exit 1
fi
sysctl -p /etc/sysctl.d/k8s.conf

# 安装docker
#cd /etc/yum.repos.d
#wget https://download.docker.com/linux/centos/docker-ce.repo
#cd $prod_dir/packages
#yum install -y docker-ce-18.09.0-3.el7.x86_64.rpm containerd.io-1.2.10-3.2.el7.x86_64.rpm docker-ce-cli-19.03.5-3.el7.x86_64.rpm
#
## 修改Cgroup Driver为 systemd
#mkdir /etc/docker/ -p
#touch /etc/docker/daemon.json
#cat > /etc/docker/daemon.json <<EOF
#{
#    "exec-opts": ["native.cgroupdriver=systemd"],
#    "log-driver": "json-file",
#    "storage-driver": "overlay2"
#}
#EOF
