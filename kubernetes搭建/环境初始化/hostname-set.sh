
local_ip=$(ip a s|grep "scope global noprefixroute"|awk -F'[ /]+' '{print $3}')

hostnamectl --static set-hostname ${local_ip}


# 5、在master添加hosts
cat >> /etc/hosts << EOF
192.168.10.162 k8s-master01
192.168.10.163 k8s-master02
192.168.10.164 k8s-master03
192.168.10.165 k8s-master04
192.168.10.190 k8s-node01
192.168.10.191 k8s-node02
192.168.10.192 k8s-node03
192.168.10.193 k8s-node04
EOF

echo " hostnamectl set success"

hostnamectl