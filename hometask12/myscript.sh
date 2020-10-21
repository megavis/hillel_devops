#!/bin/bash

CONFIG=./config.json
#PROJECT='wordpress' --- obsolete
WORDPRESS_DEPS=./wordpress-requirements.txt

# echo message and exit with status code !=0 then
function error() {
	echo "[!]" $1
	exit 1
}

function ok() {
	echo "[+]" $1
}

# checks last status code, if not 0 returns text message in param1 and exit
function check_exitcode() {
	last_code=$?
	if [ $last_code -ne 0 ]; then
		echo "[!]" $1
		exit 1
	fi
}

# Check if apt is available
apt -v > /dev/null 2>&1
check_exitcode "APT is required for deployment (Debian is highly recommended)"

#  Check the script is running from root(or as sudo)
if [[ `whoami` != "root" ]]; then
	error "deployment script must be started from root"
fi

# Install requirements
apt install -y apache2 php7.3 default-mysql-server php7.3-mysql
check_exitcode "apt install finished with errors, check repository availability"

# Install php requirements for WP
DEPS=""
for PKG in $(cat $WORDPRESS_DEPS); do
	DEPS="${DEPS} php-${PKG}";
done
apt install -y ${DEPS}
check_exitcode "installation of php requirements has not been successful"

# Check is default http port is accesible
# -------------------------------------------
# read port numbers from config and prepare regexp for egrep :port|:port|:port|...
PORTS=$(jq '.[].config.port' < ${CONFIG} | sed 's/^/|:/' | tr -d '\n' | sed 's/|//');

# now check it by netstat
systemctl stop apache2
CHECK_PORT_CMD="netstat -anlt | egrep \"${PORTS}\" | wc -l"
if [ $(eval $CHECK_PORT_CMD) -ne 0 ]; then
	netstat -lnpt | egrep "${PORTS}"
	error "deploymet error : can't free port(s) ${PORTS}, the loking proccesses are above"
fi

# Download and unpack WP:latest from official site
mkdir /tmp/wp-install
wget -P /tmp/wp-install https://ru.wordpress.org/latest-ru_RU.tar.gz
tar xzvf /tmp/wp-install/latest-ru_RU.tar.gz -C /tmp/wp-install

# Projects deployment
PROJECTS=$(jq '.[].project' < $CONFIG | sed 's/"//g'); 
index=0
for PROJECT in $PROJECTS; do
	ok "Begin '${PROJECT}' deployment......."
	
	# Read variables from config
	DB_NAME=$(jq '.['$index'].config.db.name' < ${CONFIG} | sed 's/"//g');
	DB_USER=$(jq '.['$index'].config.db.username' < ${CONFIG} | sed 's/"//g');
	DB_PASS=$(jq '.['$index'].config.db.password' < ${CONFIG} | sed 's/"//g');
	SITE_NAME=$(jq '.['$index'].config.sitename' < ${CONFIG} | sed 's/"//g');
	SITE_ROOT=$(jq '.['$index'].config.siteroot_dir' < ${CONFIG} | sed 's/"//g');
	SITE_PORT=$(jq '.['$index'].config.port' < ${CONFIG} | sed 's/"//g');

	#echo $DB_NAME
	BACKUP_DEPTH=$(jq '.['$index'].config.backup.depth' < ${CONFIG} | sed 's/"//g');
	BACKUP_PERIOD=$(jq '.['$index'].config.backup.period' < ${CONFIG} | sed 's/"//g');
	BACKUP_PATH=$(jq '.['$index'].config.backup.path' < ${CONFIG} | sed 's/"//g');

	# Create backup script and place it in required directory
	if [[ ${BACKUP_PERIOD} =~ ^(hourly|daily|weekly|monthly)\$ ]]; then
		error "Incorrect backup period (has to be hourly|daily|weekly|monthly)"
	fi
	
	if [ ! -d ${BACKUP_PATH} ]; then
		error "Backup path not exists or inaccessible"
	fi

	BACKUP_SCRIPT=/etc/cron.${BACKUP_PERIOD}/${PROJECT}-backup
	echo "#!/bin/bash
###
### !!! this is automate generated ${PROJECT} backup script !!!
###
DEPTH=${BACKUP_DEPTH}
FILENAME=\"${BACKUP_PATH}/${PROJECT}-backup.tgz\"

# rotate previos versions
for (( NUM=DEPTH; NUM>=0; --NUM));
do
        if [ \$NUM -eq 0 ] && [ -f \${FILENAME} ]; then
		mv -f \${FILENAME} \${FILENAME}.1
	fi
       	if [ \$NUM -lt \$DEPTH ] && [ -f \${FILENAME}.\${NUM} ]; then
		mv -f \${FILENAME}.\${NUM} \${FILENAME}.\`expr \$NUM + 1\`
	fi
done

DUMP=\"/tmp/${PROJECT}-${DB_NAME}-dump.sql\"
mysqldump ${DB_NAME} > \${DUMP}

tar czfP \${FILENAME} \${DUMP} /var/log/apache2/${PROJECT}-* ${SITE_ROOT} /etc/apache2/*

rm -f \${DUMP}

" > ${BACKUP_SCRIPT}
	chmod a+x ${BACKUP_SCRIPT}

	# Setup apache vhost and documentroot
	mkdir -p ${SITE_ROOT}
	if [ ! -d ${SITE_ROOT} ]; then
		error "Directory ${SITE_ROOT} does not exist or not accesible"
	fi

	if [ $SITE_PORT -ne 80 ]; then
		echo "Listen ${SITE_PORT}" > /etc/apache2/sitest-enabled/001-${POJECT}.conf
	fi

	echo "<VirtualHost *:${SITE_PORT}>
		ServerName \"${SITE_NAME}\"
		ServerAdmin webmaster@${SITE_NAME}
		DocumentRoot ${SITE_ROOT}
		ErrorLog /var/log/apache2/${PROJECT}-error.log
		CustomLog /var/log/apache2/${PROJECT}-access.log combined
</VirtualHost>" >> /etc/apache2/sites-enabled/001-${PROJECT}.conf

	# Copy WP files to project directory
	cp -f -R /tmp/wp-install/wordpress/* ${SITE_ROOT}
	chown -R www-data:www-data ${SITE_ROOT}

	# Mysql db&user setup
	echo "CREATE DATABASE ${DB_NAME};" | mysql
	check_exitcode "Database not created, see errors above"
	echo "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}' IDENTIFIED BY '${DB_PASS}';" | mysql
	check_exitcode "User not created, see errors above"

	# Cleanup ;-)
	rm -f -R ${SITE_ROOT}/wordpress
	rm -f ${SITE_ROOT}/index.html
	
	(( index++ ));
done

# Final cleanup
rm -f -R /tmp/wp-install

# Services start
systemctl start apache2
ok "waiting for apache2 start..."
sleep 3

systemctl status apache2
ok "Script finished"

