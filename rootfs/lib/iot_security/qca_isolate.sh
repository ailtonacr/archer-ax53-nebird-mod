#!/bin/sh
local ecm_db_defunct_by_tuple="/sys/kernel/debug/ecm/ecm_db/defunct_by_tuple"
local ecm_db_defunct_by_ip="/sys/kernel/debug/ecm/ecm_db/defunct_by_ip"
local ecm_dump="/usr/bin/ecm_dump.sh"
local mac=$1

dec_to_hex(){
	local ip_dec=$1
	local ip_hex=""
	local dec
	local hex
	local len
	
	for i in $(seq 4);do
		dec=`echo "$ip_dec" | awk -F '.' "{print $"$i"}"`
		hex=`printf %x $dec`
		len=`echo $hex |wc -c`
		if [[ $len -lt 3 ]];then
				hex="0$hex"
		fi
		ip_hex="$ip_hex""$hex"
	done
	
	echo "$ip_hex"
}

iot_echo() {
    if [ "$DEBUG" -gt 1 ]; then
        echo "${1}: ""$2" > /dev/console
    fi
}

#Search speed is slow, temporarily abandoned
ecm_del_by_tuple(){
	if [ -e $ecm_db_defunct_by_tuple -a -e $ecm_dump ]; then
		local key=${mac//":"/}
		local conn_tmp_path="/tmp/ecm_dump_conn_$key"
		if [ ! -e $conn_tmp_path ]; then
			/usr/bin/ecm_dump.sh connection level 1 > $conn_tmp_path
			mac=$(echo $mac | tr 'A-F' 'a-f')
			for conn in $(grep -e "snode_address=${mac}" -e "dnode_address=${mac}" $conn_tmp_path | awk -F '.' '{print $3}'); do
				local protocol=$(grep "conns\.conn\.$conn\.protocol" $conn_tmp_path | awk -F '=' '{print $2}')
				local sport=$(grep -w "conns\.conn\.$conn\.sport" $conn_tmp_path | awk -F '=' '{print $2}')
				local dport=$(grep -w "conns\.conn\.$conn\.dport" $conn_tmp_path | awk -F '=' '{print $2}')
				local sip_address=$(grep -w "conns\.conn\.$conn\.sip_address" $conn_tmp_path | awk -F '=' '{print $2}')
				local sip_address_nat=$(grep -w "conns\.conn\.$conn\.sip_address_nat" $conn_tmp_path | awk -F '=' '{print $2}')
				local dip_address=$(grep -w "conns\.conn\.$conn\.dip_address" $conn_tmp_path | awk -F '=' '{print $2}')
				local dip_address_nat=$(grep -w "conns\.conn\.$conn\.dip_address" $conn_tmp_path | awk -F '=' '{print $2}')
				local ip_version=$(grep -w "conns\.conn\.$conn\.ip_version" $conn_tmp_path | awk -F '=' '{print $2}')
				if [ -n ${protocol} -a -n ${sport} -a -n ${dport} -a -n ${sip_address} -a -n ${dip_address} ]; then
					#Currently, only ipv4 addresses are supported
					if [ $ip_version == 4 ];then
						#The WAN traffic is not processed
						if [ $sip_address == $sip_address_nat -a $dip_address == $dip_address_nat ];then
							sport=$(printf %x $sport)
							dport=$(printf %x $dport)
							sip_address=$(dec_to_hex $sip_address)
							dip_address=$(dec_to_hex $dip_address)
							/usr/bin/ecm_dump.sh defunct_by_tuple $sip_address $sport $dip_address $dport $protocol
						fi
					fi
				fi
			done
			rm $conn_tmp_path
		fi
	fi
}

ecm_del_by_ip(){
	if [ -e $ecm_db_defunct_by_ip -a -e $ecm_dump ]; then
		local key=${mac//":"/}
		local conn_tmp_path="/tmp/ecm_dump_conn_$key"
		if [ ! -e $conn_tmp_path ]; then
			/usr/bin/ecm_dump.sh connection level 1 > $conn_tmp_path
			mac=$(echo $mac | tr 'A-F' 'a-f')
	
			local conn_from=$(grep -m 1 -w "snode_address=${mac}" $conn_tmp_path | awk -F '.' '{print $3}')
			if [ ${#conn_from} != 0 ]; then
				local sip_address=$(grep -w "conns\.conn\.$conn_from\.sip_address" $conn_tmp_path | awk -F '=' '{print $2}')
				local ip_version_from=$(grep -w "conns\.conn\.$conn_from\.ip_version" $conn_tmp_path | awk -F '=' '{print $2}')

				if [ ${#sip_address} != 0 ]; then
					#Currently, only ipv4 addresses are supported
					if [ $ip_version_from == 4 ];then
						sip_address=$(dec_to_hex $sip_address)
						/usr/bin/ecm_dump.sh defunct_by_ip $sip_address
						rm -f $conn_tmp_path
						return
					fi
				fi
			fi
			#If there is no acceleration entry with that client as the source, 
			#you need to find if there is an acceleration entry with that client as the destination
			local conn_to=$(grep -m 1 -w "dnode_address=${mac}" $conn_tmp_path | awk -F '.' '{print $3}')
			if [ ${#conn_to} != 0 ]; then
				local dip_address=$(grep -w "conns\.conn\.$conn_to\.dip_address" $conn_tmp_path | awk -F '=' '{print $2}')
				local ip_version_to=$(grep -w "conns\.conn\.$conn_to\.ip_version" $conn_tmp_path | awk -F '=' '{print $2}')
				
				if [ ${#dip_address} != 0 ]; then
					#Currently, only ipv4 addresses are supported
					if [ $ip_version_to == 4 ];then
						dip_address=$(dec_to_hex $dip_address)
						/usr/bin/ecm_dump.sh defunct_by_ip $dip_address
					fi
				fi
			fi

			rm -f $conn_tmp_path
		fi
	fi
}

ecm_del_by_ip