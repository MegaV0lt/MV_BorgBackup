#!/usr/bin/env bash

# Bash Skript für einfaches Setup von NC_DB_Export.sh
#
# Verwendung:
# 	- setup.sh ausführen
#   - Benötigte Informationen eingeben
#
# WICHTIG
# Das Skript liest die Werte mittels Nextcloud's occ aus und speichtert sie in der
# Konfiguratoinsdatei NC_DB_Export.conf
# Die gespeichertern Werte VOR dem Start von NC_DB_Export.sh auf richtigkeit überprüfen!
#
# VERSION=251117

set -Eeuo pipefail  # Bei jedem Fehler beenden

# Vorgaben
nextcloudFileDir='/var/www/nextcloud'
webserverUser='www-data'
webserverServiceName='apache2'
NC_DB_EXPORT_CONF='NC_DB_Export.conf'  # Konfigurationsdatei

f_occ_get() {
	sudo -u "$webserverUser" php "${nextcloudFileDir}/occ" config:system:get "$1"
}

# Infomationen sammeln
clear
echo 'Pfad zur Nextcloud Installation.'
echo "Normalerweise: $nextcloudFileDir"
echo ''
read -r -p "Verzeichnis eingeben oder ENTER falls das Verzeichnis ${nextcloudFileDir} ist: " NEXTCLOUDFILEDIRECTORY
[[ -n "$NEXTCLOUDFILEDIRECTORY" ]] && nextcloudFileDir="$NEXTCLOUDFILEDIRECTORY"

clear
echo 'Webserver Benutzer.'
echo "Normalerweise: $webserverUser"
echo ''
read -r -p "Benutzername eingeben oder ENTER falls der Benutzer ${webserverUser} ist: " WEBSERVERUSER
[[ -n "$WEBSERVERUSER" ]] && webserverUser="$WEBSERVERUSER"

clear
echo 'Webserver Servicename.'
echo 'Normalerweise: nginx oder apache2'
echo ''
read -r -p "Webserver Servicename eingeben oder ENTER falls der Webserver Servicename ${webserverServiceName} ist: " WEBSERVERSERVICENAME
[[ -n "$WEBSERVERSERVICENAME" ]] && webserverServiceName="$WEBSERVERSERVICENAME"

clear
skipStepDisableVhost=false
stopWebserverDuringBackup=true
vHostFile=""

if [[ "$webserverServiceName" == 'nginx' ]] ; then
  if [[ ! -d "/etc/nginx/conf.d" ]] || [[ -z "$(ls -A /etc/nginx/conf.d)" ]]; then
    skipStepDisableVhost=true
  fi
else
  if [[ ! -d "/etc/apache2/sites-enabled" ]] || [[ -z "$(ls -A /etc/apache2/sites-enabled)" ]]; then
    skipStepDisableVhost=true
  fi
fi

if [[ "$skipStepDisableVhost" == 'false' ]] ; then
  echo "Soll der Webserver während des Backups gestoppt werden?"
  echo "Bei 'nein' wird der Nextcloud Virtual Host (vHost) temporär deaktiviert."
  echo ""
  read -r -p "Soll der Webserver gestoppt werden? [j/n]" STOPWEBSERVER

  if [[ "$STOPWEBSERVER" == 'n' ]] ; then
    if [[ "$webserverServiceName" == 'nginx' ]] ; then
      files=(/etc/nginx/conf.d/*)
      echo "Bitte wählen Sie die Virtual Host Datei für Nextcloud aus:"
      select selected_file in "${files[@]}"; do
          if [[ -n "$selected_file" ]]; then
              break
          else
              echo "Ungültige Auswahl. Bitte erneut versuchen."
          fi
      done

      vHostFile="$selected_file"
      stopWebserverDuringBackup=false
    else
      files=(/etc/apache/site-enabled/*.conf)
      echo "Bitte wählen Sie die Virtual Host Datei für Nextcloud aus:"
      select selected_file in "${files[@]}"; do
          if [[ -n "$selected_file" ]]; then
              break
          else
              echo "Ungültige Auswahl. Bitte erneut versuchen."
          fi
      done

      vHostFile="$selected_file"
      stopWebserverDuringBackup=false
    fi
  fi
fi

clear
echo 'Ermittelte/Eingegebene Werte:'
echo "Nextcloud Installation: $nextcloudFileDir"
echo "Webserver Benutzer: $webserverUser"
echo "Webserver Servicename: $webserverServiceName"

if [ "$stopWebserverDuringBackup" = true ] ; then
	echo "Webserver während des Backups stoppen: ja"
else
  echo "Webserver während des Backups stoppen: nein (Nextcloud vHost wird temporär deaktiviert)"
  echo "Nextcloud Virtual Host Datei: ${vHostFile}"
fi

echo ''
read -r -p "Sind die Informationen korrekt? [j/N] " CORRECTINFO
if [[ "${CORRECTINFO,,}" != 'j' ]] ; then
  echo 'ABBRUCH!'
  echo 'Es wurden keine Dateien verändert!'
  exit 1
fi

# Test-Aufruf von occ
if ! f_occ_get datadirectory &>/dev/null ; then
  echo 'Fehler beim Aufruf von OCC: Bitte Eingaben auf richtigkeit überprüfen.'
  echo 'ABBRUCH!'
  echo 'Es wurden keine Dateien verändert!'
  exit 1
fi

# Daten von occ einlesen und in Konfiguration schreiben

if [[ -e "$NC_DB_EXPORT_CONF" ]] ; then
  echo -e "\n\nSichere vorhandene $NC_DB_EXPORT_CONF nach ${NC_DB_EXPORT_CONF}_bak"
  cp --force "$NC_DB_EXPORT_CONF" "${NC_DB_EXPORT_CONF}_bak"
fi

echo -e "\n\nErstelle $NC_DB_EXPORT_CONF mit den ermittelten Werten…\n"

# Nextcloud data dir
nextcloudDataDir=$(f_occ_get datadirectory)

# Database system
databaseSystem=$(f_occ_get dbtype)

# PostgreSQL is identified as pgsql
if [[ "${databaseSystem,,}" == 'pgsql' ]] ; then
  databaseSystem='postgresql'
fi

# Database
nextcloudDatabase=$(f_occ_get dbname)

# Database user
dbUser=$(f_occ_get dbuser)

# Database password
dbPassword=$(f_occ_get dbpassword)

# File name for nextcloud database
fileNameBackupDb='nextcloud-db.sql'

{ echo '# Configuration for NC_DB_Export.sh'
  echo ''
  echo '# File names for backup files'
  echo "fileNameBackupDb='$fileNameBackupDb'"
  echo ''
  echo '# The directory of your Nextcloud installation (this is a directory under your web root)'
  echo "nextcloudFileDir='$nextcloudFileDir'"
  echo ''
  echo '# The directory of your Nextcloud data directory (outside the Nextcloud file directory)'
  echo '# If your data directory is located under Nextclouds file directory (somewhere in the web root),'
  echo '# the data directory should not be a separate part of the backup'
  echo "nextcloudDataDir='$nextcloudDataDir'"
  echo ''
  echo ''
  echo "# The service name of the web server. Used to start/stop web server (e.g. 'systemctl start <webserverServiceName>')"
  echo "webserverServiceName='$webserverServiceName'"
  echo ''
  echo "# Whether to start/stop the web server during backup/restore."
  echo "# If set to false, the web server will be left running, but the Nextcloud virtual host gets (temporarily) disabled."
  echo "stopWebserverDuringBackup=$stopWebserverDuringBackup"
  echo ""
  echo "# Virtual host file for Nextcloud."
  echo "# This is only required when 'stopWebserverDuringBackup' is set to false."
  echo "vHostFile='$vHostFile'"
  echo ''
  echo '# Your web server user'
  echo "webserverUser='$webserverUser'"
  echo ''
  echo '# The name of the database system (one of: mysql, mariadb, postgresql)'
  echo "databaseSystem='$databaseSystem'"
  echo ''
  echo '# Your Nextcloud database name'
  echo "nextcloudDatabase='$nextcloudDatabase'"
  echo ''
  echo '# Your Nextcloud database user'
  echo "dbUser='$dbUser'"
  echo ''
  echo '# The password of the Nextcloud database user'
  echo "dbPassword='$dbPassword'"
  echo ''
} > ./"${NC_DB_EXPORT_CONF}"

echo -e "\nFertig!\n\n"
echo -e "WICHTIG: Die gespeichertern Werte in $NC_DB_EXPORT_CONF \nVOR dem Start von NC_DB_Export.sh auf richtigkeit überprüfen!\n\n"
