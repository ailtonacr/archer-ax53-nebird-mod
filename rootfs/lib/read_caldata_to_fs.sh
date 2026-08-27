#!/bin/sh
#
# Copyright (c) 2015 The Linux Foundation. All rights reserved.
# Copyright (C) 2011 OpenWrt.org

. /lib/ipq806x.sh
. /lib/functions.sh

ART_BACKUP_TGT_FILE=/tp_data/art_backup.tgz
ART_BACKUP_NAME=ART.bin
ART_BACKUP_HASH=ART.md5

art_part_check()
{
    local mtdblock="$1"
    dd if="$mtdblock" of=/dev/null 2>/dev/null
    if [ "$?" = 0 ]; then
        return 0
    else
        return 1
    fi
}

art_bak_check()
{
    local backup_ok=0

    if [ -f "$ART_BACKUP_TGT_FILE" ]; then
        local md5_chk=$(tar xzOf $ART_BACKUP_TGT_FILE $ART_BACKUP_NAME 2>/dev/null | md5sum | head -c 32)
        local md5_record=$(tar xzOf $ART_BACKUP_TGT_FILE $ART_BACKUP_HASH 2>/dev/null | head -c 32)
        if [ "$(echo -n "$md5_chk" | wc -c)" = 32 ] && [ "$md5_chk" = "$md5_record" ]; then
            backup_ok=1
            echo "ART backup check pass!" > /dev/console
        fi
    fi

    [ "$backup_ok" = 1 ] && return 0

    echo "ART backup check fail!" > /dev/console
    return 1
}

art_restore()
{
    local mtd_ART=$(find_mtd_part 0:ART)
    local ret=2
    [ -c "${mtd_ART/mtdblock/mtd}" ] && \
        mtd_ART=${mtd_ART/mtdblock/mtd}

    art_bak_check

    [ "$?" -ge 1 ] && {
        echo "ART RESTORE FAIL, backup invalid!" > /dev/console
        return 1
    }

    (cd /tmp; tar xzf $ART_BACKUP_TGT_FILE)
    md5sum -cs "/tmp/$ART_BACKUP_HASH"
    if [ "$?" = 0 ]; then
        mtd write "/tmp/$ART_BACKUP_NAME" "$mtd_ART"
        if [ "$?" = 0 ]; then
            echo "ART RESTORE SUCCESS!" > /dev/console
            ret=0
        else
            echo "ART RESTORE FAIL(on mtd write)!" > /dev/console
            ret=2
        fi
    fi
    rm "/tmp/$ART_BACKUP_NAME" "/tmp/$ART_BACKUP_HASH" 2> /dev/null

    return $ret
}

art_backup()
{
    local mtd_ART=$(find_mtd_part 0:ART)

    [ -c "${mtd_ART/mtdblock/mtd}" ] && \
        mtd_ART=${mtd_ART/mtdblock/mtd}

    art_bak_check
    [ "$?" = 0 ] && return 0

    [ "$(is_cal)" = "false" ] && return 0

    # do backup
    rm "$ART_BACKUP_TGT_FILE" 2> /dev/null
    dd if="$mtd_ART" of="/tmp/$ART_BACKUP_NAME" 2>/dev/null
    md5sum "/tmp/$ART_BACKUP_NAME"  > "/tmp/$ART_BACKUP_HASH"
    tar -C /tmp -czf "$ART_BACKUP_TGT_FILE" "$ART_BACKUP_NAME" "$ART_BACKUP_HASH"
    rm "/tmp/$ART_BACKUP_NAME" "/tmp/$ART_BACKUP_HASH" 2>/dev/null

    art_bak_check
    [ "$?" = 0 ] && {
        echo "ART backup success!" > /dev/console
        return 1
    }

    return 2
}

do_load_ipq4019_board_bin()
{
    local board=$(ipq806x_board_name)
    local mtdblock=$(find_mtd_part 0:ART)

    local apdk="/tmp"

    if [ -z "$mtdblock" ]; then
        # read from mmc
        mtdblock=$(find_mmc_part 0:ART)
    fi

    [ -n "$mtdblock" ] || return

	local art_fail=0

    art_part_check "$mtdblock"
    if [ "$?" = 0 ] ; then
        echo "ART read test OK!" > /dev/console
        art_backup
    else
        echo "ART read test FAIL!" > /dev/console
        art_restore
        [ "$?" != 0 ] && {
            echo "SKIP ART LOAD!" > /dev/console
            art_fail=1
        }
    fi

    # load board.bin
    case "$board" in
            ap-dk0*)
                    mkdir -p ${apdk}
                    dd if=${mtdblock} of=${apdk}/wifi0.caldata bs=32 count=377 skip=128
                    dd if=${mtdblock} of=${apdk}/wifi1.caldata bs=32 count=377 skip=640
            ;;
            ap16* | ap148*)
                    mkdir -p ${apdk}
                    dd if=${mtdblock} of=${apdk}/wifi0.caldata bs=32 count=377 skip=128
                    dd if=${mtdblock} of=${apdk}/wifi1.caldata bs=32 count=377 skip=640
                    dd if=${mtdblock} of=${apdk}/wifi2.caldata bs=32 count=377 skip=1152
            ;;
            ap-hk14 | ap-hk01-c6)
                    FILESIZE=131072
                    mkdir -p ${apdk}/IPQ8074
                    dd if=${mtdblock} of=${apdk}/IPQ8074/caldata.bin bs=1 count=$FILESIZE skip=4096
                    ln -s ${apdk}/IPQ8074/caldata.bin /lib/firmware/IPQ8074/caldata.bin

                    mkdir -p ${apdk}/qcn9000
                    dd if=${mtdblock} of=${apdk}/qcn9000/caldata_1.bin bs=1 count=$FILESIZE skip=157696
                    ln -s ${apdk}/qcn9000/caldata_1.bin /lib/firmware/qcn9000/caldata_1.bin
            ;;
            ap-hk01-*)
                    HK_BD_FILENAME=/lib/firmware/IPQ8074/bdwlan.bin
                    mkdir -p ${apdk}/IPQ8074
                    if [ -f "$HK_BD_FILENAME" ]; then
                        FILESIZE=$(stat -Lc%s "$HK_BD_FILENAME")
                    else
                        FILESIZE=131072
                    fi
                    dd if=${mtdblock} of=${apdk}/IPQ8074/caldata.bin bs=1 count=$FILESIZE skip=4096
                    [ -L /lib/firmware/IPQ8074/caldata.bin ] || \
                    ln -s ${apdk}/IPQ8074/caldata.bin /lib/firmware/IPQ8074/caldata.bin
            ;;
            ap-hk10-*)
                    FILESIZE=131072
                    mkdir -p ${apdk}/IPQ8074
                    dd if=${mtdblock} of=${apdk}/IPQ8074/caldata.bin bs=1 count=$FILESIZE skip=4096
                    ln -s ${apdk}/IPQ8074/caldata.bin /lib/firmware/IPQ8074/caldata.bin

                    mkdir -p ${apdk}/qcn9000
                    dd if=${mtdblock} of=${apdk}/qcn9000/caldata_1.bin bs=1 count=$FILESIZE skip=157696
                    dd if=${mtdblock} of=${apdk}/qcn9000/caldata_2.bin bs=1 count=$FILESIZE skip=311296
                    ln -s ${apdk}/qcn9000/caldata_1.bin /lib/firmware/qcn9000/caldata_1.bin
                    ln -s ${apdk}/qcn9000/caldata_2.bin /lib/firmware/qcn9000/caldata_2.bin
	    ;;
            ap-hk* | ap-ac* | ap-oa*)
                    HK_BD_FILENAME=/lib/firmware/IPQ8074/bdwlan.bin
                    mkdir -p ${apdk}/IPQ8074
                    dd if=${mtdblock} of=${apdk}/wifi1.caldata bs=1 count=12064 skip=208896
                    if [ -f "$HK_BD_FILENAME" ]; then
                        FILESIZE=$(stat -Lc%s "$HK_BD_FILENAME")
                    else
                        FILESIZE=131072
                    fi
                    dd if=${mtdblock} of=${apdk}/IPQ8074/caldata.bin bs=1 count=$FILESIZE skip=4096
                    [ -L /lib/firmware/IPQ8074/caldata.bin ] || \
                    ln -s ${apdk}/IPQ8074/caldata.bin /lib/firmware/IPQ8074/caldata.bin
            ;;
            ap-cp01-c3*)
                    CP_BD_FILENAME=/lib/firmware/IPQ6018/bdwlan.bin
                    mkdir -p ${apdk}/IPQ6018
                    if [ -f "$CP_BD_FILENAME" ]; then
                        FILESIZE=$(stat -Lc%s "$CP_BD_FILENAME")
                    else
                        FILESIZE=65536
                    fi
                    dd if=${mtdblock} of=${apdk}/IPQ6018/caldata.bin bs=1 count=$FILESIZE skip=4096
                    [ -L /lib/firmware/IPQ6018/caldata.bin ] || \
                    ln -s ${apdk}/IPQ6018/caldata.bin /lib/firmware/IPQ6018/caldata.bin

                    mkdir -p ${apdk}/qcn9000
                    FILESIZE=131072
                    dd if=${mtdblock} of=${apdk}/qcn9000/caldata_1.bin bs=1 count=$FILESIZE skip=157696
                    ln -s ${apdk}/qcn9000/caldata_1.bin /lib/firmware/qcn9000/caldata_1.bin
            ;;
            ap-mp02.1* | db-mp02.1*)
                    mkdir -p ${apdk}/IPQ5018
                    FILESIZE=131072

                    if [ "$art_fail" = 1 ]; then
                        mkdir -p ${apdk}/qcn6122 ${apdk}/IPQ5018
                        dd if=/dev/zero of=${apdk}/IPQ5018/caldata.bin bs=1 count=$FILESIZE skip=4096
                        dd if=/dev/zero of=${apdk}/qcn6122/caldata_1.bin bs=1 count=$FILESIZE skip=157696
                        cp ${apdk}/IPQ5018/caldata.bin /lib/firmware/IPQ5018/caldata.bin
                        cp ${apdk}/qcn6122/caldata_1.bin /lib/firmware/qcn6122/caldata_1.bin
                        rm ${apdk}/IPQ5018/caldata.bin ${apdk}/qcn6122/caldata_1.bin
                    else
                        if [ -e /sys/firmware/devicetree/base/compressed_art ]
                        then
                            #FTM Daemon compresses the caldata and writes the lzma file in ART Partition
                            dd if=${mtdblock} of=${apdk}/virtual_art.bin.lzma
                            lzma -fdv --single-stream ${apdk}/virtual_art.bin.lzma || {
                            # Create dummy virtual_art.bin file of size 512K
                            dd if=/dev/zero of=${apdk}/virtual_art.bin bs=1024 count=512
                            }
                        else
                            dd if=${mtdblock} of=${apdk}/virtual_art.bin
                        fi

                        dd if=${apdk}/virtual_art.bin of=${apdk}/IPQ5018/caldata.bin bs=1 count=$FILESIZE skip=4096

                        mkdir -p ${apdk}/qcn6122
                        # Read after 154KB
                        dd if=${apdk}/virtual_art.bin of=${apdk}/qcn6122/caldata_1.bin bs=1 count=$FILESIZE skip=157696
                        # Read after 304KB
                        # dd if=${apdk}/virtual_art.bin of=${apdk}/qcn6122/caldata_2.bin bs=1 count=$FILESIZE skip=311296

                        ln -s ${apdk}/IPQ5018/caldata.bin /lib/firmware/IPQ5018/caldata.bin
                        # To Remove later
                        # ln -s ${apdk}/qcn6122/caldata_1.bin /lib/firmware/qcn9100/caldata_1.bin
                        # ln -s ${apdk}/qcn6122/caldata_2.bin /lib/firmware/qcn9100/caldata_2.bin

                        ln -s ${apdk}/qcn6122/caldata_1.bin /lib/firmware/qcn6122/caldata_1.bin
                        # ln -s ${apdk}/qcn6122/caldata_2.bin /lib/firmware/qcn6122/caldata_2.bin
                    fi

                    if [ "$(uci get factory.factorymode.enable)" != "yes" ]; then
                        [ -f "${apdk}/virtual_art.bin" ] && rm "${apdk}/virtual_art.bin"
                    fi
            ;;
            ap-mp03.1)
                    mkdir -p ${apdk}/IPQ5018
                    FILESIZE=131072

                    if [ -e /sys/firmware/devicetree/base/compressed_art ]
                    then
                        #FTM Daemon compresses the caldata and writes the lzma file in ART Partition
                        dd if=${mtdblock} of=${apdk}/virtual_art.bin.lzma
                        lzma -fdv --single-stream ${apdk}/virtual_art.bin.lzma || {
                        # Create dummy virtual_art.bin file of size 512K
                        dd if=/dev/zero of=${apdk}/virtual_art.bin bs=1024 count=512
                        }

                        dd if=${apdk}/virtual_art.bin of=${apdk}/IPQ5018/caldata.bin bs=1 count=$FILESIZE skip=4096

                        mkdir -p ${apdk}/qcn9000
                        # Read after 154KB
                        dd if=${apdk}/virtual_art.bin of=${apdk}/qcn9000/caldata_1.bin bs=1 count=$FILESIZE skip=157696
                    else
                        dd if=${mtdblock} of=${apdk}/IPQ5018/caldata.bin bs=1 count=$FILESIZE skip=4096

                        mkdir -p ${apdk}/qcn9000
                        dd if=${mtdblock} of=${apdk}/qcn9000/caldata_1.bin bs=1 count=$FILESIZE skip=157696
                    fi

                    ln -s ${apdk}/IPQ5018/caldata.bin /lib/firmware/IPQ5018/caldata.bin
                    ln -s ${apdk}/qcn9000/caldata_1.bin /lib/firmware/qcn9000/caldata_1.bin
            ;;
            ap-mp03.1-* | db-mp03.1-* | ap-mp03.6*)
                    MP_BD_FILENAME=/lib/firmware/IPQ5018/bdwlan.bin
                    mkdir -p ${apdk}/IPQ5018
                    if [ -f "$MP_BD_FILENAME" ]; then
                        FILESIZE=$(stat -Lc%s "$MP_BD_FILENAME")
                    else
                        FILESIZE=131072
                    fi
                    dd if=${mtdblock} of=${apdk}/IPQ5018/caldata.bin bs=1 count=$FILESIZE skip=4096
                    ln -s ${apdk}/IPQ5018/caldata.bin /lib/firmware/IPQ5018/caldata.bin

                    mkdir -p ${apdk}/qcn9000
                    dd if=${mtdblock} of=${apdk}/qcn9000/caldata_1.bin bs=1 count=$FILESIZE skip=157696
                    ln -s ${apdk}/qcn9000/caldata_1.bin /lib/firmware/qcn9000/caldata_1.bin
            ;;
            ap-mp03.5*)
                    MP_BD_FILENAME=/lib/firmware/IPQ5018/bdwlan.bin
                    mkdir -p ${apdk}/IPQ5018
                    if [ -f "$MP_BD_FILENAME" ]; then
                        FILESIZE=$(stat -Lc%s "$MP_BD_FILENAME")
                    else
                        FILESIZE=131072
                    fi
                    dd if=${mtdblock} of=${apdk}/IPQ5018/caldata.bin bs=1 count=$FILESIZE skip=4096
                    ln -s ${apdk}/IPQ5018/caldata.bin /lib/firmware/IPQ5018/caldata.bin

                    mkdir -p ${apdk}/qcn6122
                    dd if=${mtdblock} of=${apdk}/qcn6122/caldata_1.bin bs=1 count=$FILESIZE skip=157696
                    # To remove later
                    ln -s ${apdk}/qcn6122/caldata_1.bin /lib/firmware/qcn9100/caldata_1.bin

                    ln -s ${apdk}/qcn6122/caldata_1.bin /lib/firmware/qcn6122/caldata_1.bin

                    dd if=${mtdblock} of=${apdk}/qcn6122/caldata_2.bin bs=1 count=$FILESIZE skip=311296
                    # To remove later
                    ln -s ${apdk}/qcn6122/caldata_2.bin /lib/firmware/qcn9100/caldata_2.bin
                    ln -s ${apdk}/qcn6122/caldata_2.bin /lib/firmware/qcn6122/caldata_2.bin
            ;;
            ap-mp03.3* | db-mp03.3* | tb-mp04*)
                    MP_BD_FILENAME=/lib/firmware/IPQ5018/bdwlan.bin
                    mkdir -p ${apdk}/IPQ5018
                    FILESIZE=131072
                    if [ "$art_fail" = 1 ]; then
                        mkdir -p ${apdk}/qcn6122 ${apdk}/IPQ5018
                        dd if=/dev/zero of=${apdk}/IPQ5018/caldata.bin bs=1 count=$FILESIZE skip=4096
                        dd if=/dev/zero of=${apdk}/qcn6122/caldata_1.bin bs=1 count=$FILESIZE skip=157696
                        cp ${apdk}/IPQ5018/caldata.bin /lib/firmware/IPQ5018/caldata.bin
                        cp ${apdk}/qcn6122/caldata_1.bin /lib/firmware/qcn6122/caldata_1.bin
                        rm ${apdk}/IPQ5018/caldata.bin ${apdk}/qcn6122/caldata_1.bin
                    else
                        dd if=${mtdblock} of=${apdk}/IPQ5018/caldata.bin bs=1 count=$FILESIZE skip=4096
                        ln -s ${apdk}/IPQ5018/caldata.bin /lib/firmware/IPQ5018/caldata.bin

                        mkdir -p ${apdk}/qcn6122
                        dd if=${mtdblock} of=${apdk}/qcn6122/caldata_1.bin bs=1 count=$FILESIZE skip=157696
                        # To remove later
                        ln -s ${apdk}/qcn6122/caldata_1.bin /lib/firmware/qcn9100/caldata_1.bin

                        ln -s ${apdk}/qcn6122/caldata_1.bin /lib/firmware/qcn6122/caldata_1.bin

                        mkdir -p ${apdk}/qcn9000
                        dd if=${mtdblock} of=${apdk}/qcn9000/caldata_2.bin bs=1 count=$FILESIZE skip=311296
                        ln -s ${apdk}/qcn9000/caldata_2.bin /lib/firmware/qcn9000/caldata_2.bin
                    fi
            ;;
            ap-mp03.4*)
                    MP_BD_FILENAME=/lib/firmware/IPQ5018/bdwlan.bin
                    mkdir -p ${apdk}/IPQ5018
                    if [ -f "$MP_BD_FILENAME" ]; then
                        FILESIZE=$(stat -Lc%s "$MP_BD_FILENAME")
                    else
                        FILESIZE=131072
                    fi
                    dd if=${mtdblock} of=${apdk}/IPQ5018/caldata.bin bs=1 count=$FILESIZE skip=4096
                    ln -s ${apdk}/IPQ5018/caldata.bin /lib/firmware/IPQ5018/caldata.bin

                    mkdir -p ${apdk}/qcn9000
                    dd if=${mtdblock} of=${apdk}/qcn9000/caldata_1.bin bs=1 count=$FILESIZE skip=157696
                    ln -s ${apdk}/qcn9000/caldata_1.bin /lib/firmware/qcn9000/caldata_1.bin

                    mkdir -p ${apdk}/qcn9000
                    dd if=${mtdblock} of=${apdk}/qcn9000/caldata_2.bin bs=1 count=$FILESIZE skip=311296
                    ln -s ${apdk}/qcn9000/caldata_2.bin /lib/firmware/qcn9000/caldata_2.bin
            ;;
            ap-mp*)
                    MP_BD_FILENAME=/lib/firmware/IPQ5018/bdwlan.bin
                    mkdir -p ${apdk}/IPQ5018
                    if [ -f "$MP_BD_FILENAME" ]; then
                        FILESIZE=$(stat -Lc%s "$MP_BD_FILENAME")
                    else
                        FILESIZE=131072
                    fi
                    dd if=${mtdblock} of=${apdk}/IPQ5018/caldata.bin bs=1 count=$FILESIZE skip=4096
                    [ -L /lib/firmware/IPQ5018/caldata.bin ] || \
                    ln -s ${apdk}/IPQ5018/caldata.bin /lib/firmware/IPQ5018/caldata.bin
            ;;
            ap-cp*)
                    CP_BD_FILENAME=/lib/firmware/IPQ6018/bdwlan.bin
                    mkdir -p ${apdk}/IPQ6018
                    if [ -f "$CP_BD_FILENAME" ]; then
                        FILESIZE=$(stat -Lc%s "$CP_BD_FILENAME")
                    else
                        FILESIZE=65536
                    fi
                    dd if=${mtdblock} of=${apdk}/IPQ6018/caldata.bin bs=1 count=$FILESIZE skip=4096
                    [ -L /lib/firmware/IPQ6018/caldata.bin ] || \
                    ln -s ${apdk}/IPQ6018/caldata.bin /lib/firmware/IPQ6018/caldata.bin
            ;;
   esac
}

