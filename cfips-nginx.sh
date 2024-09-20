#!/bin/bash

###########################################
# Developed by G4L1L3O
# 
#  << Instructions >>
# - change the nginxpath below in configurations if your path is different. 
# - add a cronjob to run this bash script @daily or @weekly /path_to_bash_script/cfips_nginx.sh
# - make sure bash script can be executed by running this: chmod +x cfips-nginx.sh
# - run the script once to create the include files 
# - add this line in your nginx.conf file, within the http block
#   "include cfips.txt;"
# - restart nginx
# - you should now have the real ip in your access logs
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
