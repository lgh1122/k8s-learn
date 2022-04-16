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