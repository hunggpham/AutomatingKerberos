#!/bin/bash

# License stuff

# Log errors

log() {
	local level="$1"
	local msg="$2"
}

error() {
	log ERROR "$1"

	if [ -n "$2" ]; then
		exit $2
	fi
}

generate_unique_str() {
  $DATE +%Y%m%d-%H%M%S
}

# Detect availability of commands

detect_command() {
	local cmd="$1"
	local v="$2"

	log DEBUG "Detecting command $cmd"

	v=${v:-$(echo $cmd | tr 'a-z' 'A-Z')}
	cmd_path=$(type -p $cmd)
	eval_str="${v}=\"$cmd_path\""

	[ -n "$cmd_path" ] || error "Unable to locate command \"$cmd\" in path" 1

	eval "$eval_str"

	log DEBUG "  found at $cmd_path (assigned to \$$v)"
}

# Configuration

configure_b4_run() {
	log DEBUG "Setting up env variables, directories and checking commands availability and "

	detect_command sed
	detect_command cat
	detect_command mkdir
	detect_command service
	detect_command tar
	detect_command pg_dump
	detect_command psql
	detect_command awk
	detect_command keytool
	detect_command openssl
	detect_command msqldump
	detect_command hostname
	detect_command touch
	detect_command chown
	detect_command chmod

	# Get properties
	propFile=autoKerb.properties

	if [ ! -f $propFile ]
		error "Cannot find $propFile" 1
	fi

	# Set up environment variables

	export JAVA_HOME=`getPropertyFromFile java.home $propFile`
	export PATH=$JAVA_HOME/bin:$PATH

	# Set up directories in all hosts of cluster

	sec_dir=`getPropertyFromFile security.dir $propFile`
	x509_dir=$sec_dir/x509
	jks_dir=$sec_dir/jks
	crt_dir=$sec_dir/CAcerts
	rootCA_dir=$sec_dir/rootCAdir

	num_of_nodes=`getPropertyFromFile number.of.nodes $propFile`
	host_prefix=`getPropertyFromFile host.prefix $propFile`
	host_suffix=`getPropertyFromFile host.suffix $propFile`
	this_host=`$HOSTNAME -s`

	for i in $( seq 1 $num_of_nodes ); do ssh $host_prefix$i$host_suffix "mkdir -p $sec_dir $x509_dir $jks_dir $crt_dir; chmod -R 755 $sec_dir"; done

}

# Run this script ONLY on CM server

is_this_CM_server() {
	log DEBUG "Making sure this script is run ONLY on CM server"

	$SERVICE cloudera-scm-server status || error "Unable to confirm this is CM server" 1
}

# Properties file function

getPropertyFromFile() {
	propName=`echo $1 | $SED -e ‘s/\./\\\./g’`   # Replace "." with "\." to be use in sed expression
	fileName=$2
	$CAT $fileName | $SED -n -e 's/^[ ]*//g;/^#/d;s/^$propertyName=//p' | tail -1
}

getProperties() {
	log DEBUG "Getting all properties from properties files"

	SCM_DB_propFile=`getPropertyFromFile SCM.Db.properties.file $propFile`
	if [ ! -d $SCM_DB_propFile ]; then
		error "Cannot find $SCM_DB_propFile" 1
	fi

	# SCM
	SCM_server_port=`getPropertyFromFile com.cloudera.cmf.db.host $SCM_DB_propFile`
	SCM_server=`getPropertyFromFile SCM.server $propFile`
	SCM_host=`echo $SCM_server_port | $AWK -F: '{print $1}'`
	SCM_port=`echo $SCM_server_port | $AWK -F: '{print $2}'`
	SCM_owner=`getPropertyFromFile com.cloudera.cmf.db.user $SCM_DB_propFile`
	SCM_Db_password=`getPropertyFromFile com.cloudera.cmf.db.password $SCM_DB_propFile`
	SCM_Db_mysql_root_user=`getPropertyFromFile SCM.Db.mysql.root.user $propFile`
	SCM_Db_mysql_root_password=`getPropertyFromFile SCM.Db.mysql.root.password $propFile`
	SCM_Db_mysql_root_user=`getPropertyFromFile SCM.Db.mysql.root.user $propFile`
	SCM_Db_mysql_root_password=`getPropertyFromFile SCM.Db.mysql.root.password $propFile`

	# LDAP
	ldap_ou=`getPropertyFromFile LDAP.organization.unit $propFile`
	ldap_org=`getPropertyFromFile LDAP.organization $propFile`
	ldap_location=`getPropertyFromFile LDAP.locale $propFile`
	ldap_state=`getPropertyFromFile LDAP.state $propFile`
	ldap_country=`getPropertyFromFile LDAP.country $propFile`

	# CM keystore
	CM_keystore_storepass=`getPropertyFromFile CM.keystore.storepass $propFile`
	CM_keystore_keypass=`getPropertyFromFile CM.keystore.keypass $propFile`

	# AWS
	AWS_user=`getPropertyFromFile AWS.user $propFile`
	AWS_keyfile=`getPropertyFromFile AWS.keyfile $propFile`
	AWS_keyfile_content=`getPropertyFromFile AWS.keyfile.content $propFile`
	AWS_host_list=`getPropertyFromFile AWS.host.list.filename $propFile`

	# Postgreql
	Postgreql_password_file=`getPropertyFromFile Postgresql.password.file $propFile`
}
# Backup SCM database, in case we need to revert

backupCMDatabase() {
	log DEBUG "Backing up SCM database, in case we need to revert"

#	SCM_DB_propFile=`getPropertyFromFile SCM.Db.properties.file $propFile`
#	if [ ! -d $SCM_DB_propFile ]; then
#		error "Cannot find $SCM_DB_propFile" 1
#	fi
	SCM_DB=`getPropertyFromFile SCM.Db $propFile`
	if [ ${SCM_DB} == "embedded_postgresql" ]; then
		if [ -d /var/lib/cloudera-scm-server-db ]; then
			$SERVICE cloudera-scm-server stop || error "Failed to stop cloudera-scm-server" 1
			$SERVICE cloudera-scm-server-db stop || error "Failed to stop cloudera-scm-server-db" 1
			$TAR zcf cloudera-scm-server-db.gz /var/lib/cloudera-scm-server-db || error "Failed to backup /var/lib/cloudera-scm-server-db" 1
		else
			error "Unable to find embedded_postgresql at /var/lib/cloudera-scm-server-db" 1
		fi
	fi
	if [ ${SCM_DB} == "external_postgresql" ]; then
#		SCM_server_port=`getPropertyFromFile com.cloudera.cmf.db.host $SCM_DB_propFile`
#		SCM_host=`echo $SCM_server_port | $AWK -F: '{print $1}'`
#		SCM_port=`echo $SCM_server_port | $AWK -F: '{print $2}'`
#		SCM_owner=`getPropertyFromFile com.cloudera.cmf.db.user $SCM_DB_propFile`
		$PG_DUMP -h $SCM_host -p $SCM_port -U $SCM_owner > /tmp/scm_server_db_backup.$(`generate_unique_str`) || error "Failed to backup /var/lib/cloudera-scm-server-db" 1
	fi
	if [ ${SCM_DB} == "mysql" ]; then
#		SCM_Db_mysql_root_user=`getPropertyFromFile SCM.Db.mysql.root.user $propFile`
#		SCM_Db_mysql_root_password=`getPropertyFromFile SCM.Db.mysql.root.password $propFile`
		$MKDIR db_backups
		for i in amon metastore nav navms rman scm sentry; do $MYSQLDUMP -h$SCM_host -u$SCM_Db_mysql_root_user -p$SCM_Db_mysql_root_password $i > db_backups/$i.sql; done
	fi	
}

# Create security directories in all nodes

create_sec_dirs() {
	log DEBUG "Creating security directories in all nodes"

	if [ ! -f $AWS_host_list ]; then
		error "Cannot find $AWS_host_list" 1
	fi
	if [ ! -f $AWS_keyfile ]; then
		error "Cannot find $AWS_keyfile" 1
	fi

	#for i in `$CAT $AWS_host_list`; do ssh -i ${AWS.keyfile.content} $i "mkdir -p $sec_dir $x509_dir $jks_dir $crt_dir; chmod -R 755 $sec_dir"; done
	for i in `$CAT $AWS_host_list`; do ssh -i ${AWS.keyfile} $i "mkdir -p $sec_dir $x509_dir $jks_dir $crt_dir; chmod -R 755 $sec_dir"; done
}

# From here down, follow documentation at http://www.cloudera.com/content/cloudera/en/documentation/core/latest/topics/cm_sg_tls_browser.html
# Step 1: Create the Cloudera Manager Server Keystore, Generate a Certificate Request, and Install the Certificate

generate_CM_keystore() {
	log DEBUG "Generating keystore for CM"

#	ldap_ou=`getPropertyFromFile LDAP.organization.unit $propFile`
#	ldap_org=`getPropertyFromFile LDAP.organization $propFile`
#	ldap_location=`getPropertyFromFile LDAP.locale $propFile`
#	ldap_state=`getPropertyFromFile LDAP.state $propFile`
#	ldap_country=`getPropertyFromFile LDAP.country $propFile`
#	CM_keystore_storepass=`getPropertyFromFile CM.keystore.storepass $propFile`
#	CM_keystore_keypass=`getPropertyFromFile CM.keystore.keypass $propFile`

	$KEYTOOL -genkeypair -keystore $jks_dir/${this_host}-keystore.jks -alias $this_host -dname "CN=$SCM_server,OU=$ldap_ou,O=$ldap_org,L=$ldap_location,ST=$ldap_state,C=$ldap_country" -keyalg RSA -keysize 2048 -storepass $CM_storepass -keypass $CM_keypass || error "Failed to generate keystore for CM" 1
}

generate_CM_CSR() {
	log DEBUG "Generating Certificate Signing Request (CSR) for CM"

	$KEYTOOL -certreq -keystore $jks_dir/${this_host}-keystore.jks -alias $this_host -storepass $CM_storepass -keypass $CM_keypass -file $x509_dir/${SCM_server}.csr || error "Failed to generate CSR for CM" 1
}	

# Create our own root CA

generate_root_CA() {
	log DEBUG "Generating root CA"

	# Create root key
	$OPENSSL genrsa -out ${rootCA_dir}/rootCA.key 2048 || error "Failed to create root key" 1
	# Self-sign the generated certificate
	$OPENSSL req -x509 -new -nodes -key ${rootCA_dir}/rootCA.key -days 1024 -out $crt_dir/rootCA.pem || error "Failed to Self-sign the generated root certificate" 1
	# Create an alternate truststore and import the private certificate
	cp $JAVA_HOME/jre/lib/security/cacerts $JAVA_HOME/jre/lib/security/jssecacerts
	$KEYTOOL -importcert -alias RootCA -keystore $JAVA_HOME/jre/lib/security/jssecacerts -file $crt_dir/rootCA.pem -storepass changeit || error "Failed to import the private certificate" 1
	# Copy the alternate truststore to all hosts
	#for i in `$CAT $AWS_host_list`; do scp -i ${AWS.keyfile.content} $JAVA_HOME/jre/lib/security/jssecacerts $i:$JAVA_HOME/jre/lib/security/jssecacerts; done
	for i in `$CAT $AWS_host_list`; do scp -i ${AWS.keyfile} $JAVA_HOME/jre/lib/security/jssecacerts $i:$JAVA_HOME/jre/lib/security/jssecacerts; done
	# Import the CA certificate into the keystore
    $KEYTOOL -delete -alias RootCA -keystore $jks_dir/${this_host}-keystore.jks -storepass password || error "Failed to Import the CA certificate into the keystore" 1
    # Sign the CSR generated previously
    $OPENSSL x509 -req -in $x509_dir/$host_s.csr -CA $crt_dir/rootCA.pem -CAkey rootCA.key -CAcreateserial -out $x509_dir/${this_host}.pem -days 500 || error "Failed to Sign the CSR generated previously" 1
}

import_cert() {
	log DEBUG "Importing certificate"

	$KEYTOOL -importcert -trustcacerts -alias $this_host -file $x509_dir/${this_host}.pem -keystore $jks_dir/${this_host}-keystore.jks -storepass $CM_storepass || error "Failed to import certificate" 1
}

# Set TLS in CM database.   This is equivalent to go to CM's UI: Administration -> Settings -> Security and click the check box or fill in the values for parameter

set_TLS_in_CM() {
	log DEBUG "Set TLS in CM database"

	if [ ! -f $Postgreql_password_file ]; then
		$TOUCH $Postgreql_password_file
		echo "${this_host}:${SCM_port}:${SCM_DB}:${SCM_owner}:${SCM_Db_password}" > $Postgreql_password_file
		$CHOWN $AWS_user:$AWS_user $Postgreql_password_file
		$CHMOD 600 $Postgreql_password_file
	fi

	$PSQL -h $this_host -p $SCM_port -U $SCM_owner -d $SCM_DB -c 'INSERT INTO configs VALUES('
}
