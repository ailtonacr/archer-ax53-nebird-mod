#!/bin/sh
export LD_LIBRARY_PATH=/usr/lib/avira/:$LD_LIBRARY_PATH
/usr/bin/avira/avirasentinellite/avirasentinellite_220531-2-221202_prod/avirasentinellite "$@"