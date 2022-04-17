


##拉取镜像
docker pull fuzzle/docker-nfs-server:latest

##创建挂载目录
mkdir -p /home/docker/nfs01
chmod 777 /home/docker/nfs01

##modprobe
Linux modprobe命令用于自动处理可载入模块。
modprobe可载入指定的个别模块，或是载入一组相依的模块。modprobe会根据depmod所产生的相依关系，决定要载入哪些模块。若在载入过程中发生错误，在modprobe会卸载整组的模块。

modprobe nfs
modprobe nfsd

## 启动容器
docker run -d --privileged  \
-v /home/docker/nfs01:/nfs \
-e NFS_EXPORT_DIR_1=/nfs \
-e NFS_EXPORT_DOMAIN_1=\* \
-e NFS_EXPORT_OPTIONS_1=rw,insecure,no_subtree_check,no_root_squash,fsid=1 \
-p 111:111 -p 111:111/udp \
-p 2049:2049 -p 2049:2049/udp \
-p 32765:32765 -p 32765:32765/udp \
-p 32766:32766 -p 32766:32766/udp \
-p 32767:32767 -p 32767:32767/udp \
fuzzle/docker-nfs-server:latest
————————————————
版权声明：本文为CSDN博主「成伟平cwp」的原创文章，遵循CC 4.0 BY-SA版权协议，转载请附上原文出处链接及本声明。
原文链接：https://blog.csdn.net/pingweicheng/article/details/108569848

##挂载
客户端挂载命令方式一：
mkdir -p /mnt/nfs_mnt/nfs_a

mount -v -t nfs -o rw,nfsvers=3,nolock,proto=udp,port=2049 192.168.10.130:/nfs /mnt/nfs_mnt/nfs_a
客户端挂载命令方式二：

mount -v -t nfs -o rw,nfsvers=3,nolock,proto=udp  192.168.10.130:/nfs /mnt/nfs_mnt/nfs_a
客户端挂载命令方式三： 
mount 192.168.10.130:/nfs  /mnt/nfs_mnt/nfs_a


执行时若报错
mount: 文件系统类型错误、选项错误、192.168.10.130:/nas_a 上有坏超级块、
       缺少代码页或助手程序，或其他错误
       (对某些文件系统(如 nfs、cifs) 您可能需要
       一款 /sbin/mount.<类型> 助手程序)

       有些情况下在 syslog 中可以找到一些有用信息- 请尝试
       dmesg | tail  这样的命令看看。
出现该问题大部分情况都是由于没有安装nfs的客户端，所以需要使用yum进行安装

yum -y install nfs-utils && systemctl start nfs-utils && systemctl enable nfs-utils
rpcinfo -p
