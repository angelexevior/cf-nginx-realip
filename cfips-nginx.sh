#!/bin/bash

###########################################
# Developed by Angel Exevior
# 
#  << Instructions >>
# - add a cronjob to run this command: 
#
###########################################

# Configurations
nginxpath=/usr/local/nginx/conf

####################################################################
# DO NOT CHANGE BELOW THIS LINE UNLESS YOU KNOW WHAT YOU ARE DOING #
####################################################################
# First empty the include file
> $nginxpath/cfips.txt;

# Get cf new ips list and loop
for i in $(curl https://www.cloudflare.com/ips-v4);
do
        printf "set_real_ip_from $i;\n" >> $nginxpath/cfips.txt;
done

# Finally, add the override for nginx
printf "real_ip_header CF-Connecting-IP;" >> $nginxpath/cfips.txt;