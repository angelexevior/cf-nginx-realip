# cf-nginx-realip
Cloudflare/Nginx Restoring original visitor IPs in nginx access logs

# Developed by G4L1L3O
#  << Instructions >>
- change the nginxpath below in configurations if your path is different. 
- add a cronjob to run this bash script @daily or @weekly /path_to_bash_script/cfips_nginx.sh
- make sure bash script can be executed by running this: chmod +x cfips-nginx.sh
- run the script once to create the include files 
- add this line in your nginx.conf file, within the http block
  "include cfips.txt;"
- restart nginx
- you should now have the real ip in your access logs
