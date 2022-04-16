#!/bin/bash
source ./util.sh

# 部署etcd集群

prod_dir=/mnt/nfs_mnt/nfs_a/k8s-install
local_ip=$(ip a s|grep "scope global noprefixroute"|awk -F'[ /]+' '{print $3}')

# 创建etcd证书存放目录
mkdir -pv /data/apps/etcd/{ssl,bin,etc,data}

# 拷贝etcd证书相关文件，
cd $prod_dir
if [ $? -ne 0 ];then
  #echo "ERROR:$prod_dir this directory is not exists"
  log ERROR "$prod_dir this directory is not exists"
  exit 1
else
  cd etcd-ssl
  pem_number=$(find . -name "etcd*.pem" |wc -l)
  if [ $pem_number -eq 4 ];then
	cp etcd*.pem /data/apps/etcd/ssl
	#echo "INFO:copy etcd*.pem files to /data/apps/etcd/ssl success."
	log INFO "copy etcd*.pem files to /data/apps/etcd/ssl success."
  else
	#echo "ERROR:no etcd pem files in this directory.please check..."
	log ERROR "no etcd pem files in this directory.please check..."
	exit 1
  fi
fi

# 拷贝etcd文件到指定目录
cp $prod_dir/software/etcd-v3.3.12-linux-amd64/etcd* /data/apps/etcd/bin/
if [ $? -ne 0 ];then
  #echo "ERROR:copy etcd binary files failed."
  log ERROR "copy etcd binary files failed."
  exit 1
else
  #echo "INFO:copy etcd binary files success."
  log INFO "copy etcd binary files success."
fi

log INFO "begin to install etcd."
# 创建服务文件及配置文件
cd $prod_dir/etc
cp $prod_dir/etc/etcd.service /usr/lib/systemd/system/
cp $prod_dir/etc/etcd.conf /data/apps/etcd/etc/

cd /data/apps/etcd/etc/
sed -i "s/0.0.0.0/$local_ip/g" /data/apps/etcd/etc/etcd.conf

# 启动服务
useradd -r etcd && chown etcd.etcd -R /data/apps/etcd
systemctl daemon-reload
systemctl enable etcd
systemctl restart etcd
# 睡眠10s等待启动
sleep 10

# 检查etcd运行状态
state=$(systemctl status etcd|grep running | wc -l)
if [ $state -eq 1 ]; then
  #echo "INFO:etcd is active(running)."
  log INFO "etcd is active(running)."
else
  #echo "ERROR:etcd is inactive (dead).pleasee check..."
  log ERROR "etcd is inactive (dead).pleasee check..."
  exit 1
fi

# 设置环境变量
#echo "PATH=$PATH:/data/apps/etcd/bin/" >> /etc/profile
#export PATH=$PATH:/data/apps/etcd/bin/