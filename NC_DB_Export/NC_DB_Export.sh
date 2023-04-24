#!/usr/bin/env bash

# Bash skript zum exportieren der Nextcloud Datenbank für Backup mit MV_BorgBackup.
# Skript wird via PRE_ACTION und POST_ACtion in MV_BorgBackup.conf aufgerufen:
# PRE_ACTION: "NC_DB_Export.sh before"
# POST_ACTION: "NC_DB_Export.sh after"
#
# Inspiriert durch Nextcloud-Backup-Restore: https://codeberg.org/DecaTec/Nextcloud-Backup-Restore
#
#
# Benötigt:
# - MV_BorgBackup.sh
# - borg
#
# Unterstützte Datenbanken:
# 	- MySQL/MariaDB
# 	- PostgreSQL
#
# VERSION=230424

set -Eeuo pipefail  # Beenden bei jedem Fehler
trap f_CtrlC INT    # CTRL+C

# Variablen
SELF="$(readlink /proc/$$/fd/255)" || SELF="$0"  # Eigener Pfad ($0)
SELF_PATH="${SELF%/*}"                           # Pfad
CONFIG_FILE='NC_DB_Export.conf'                  # Konfiguration

# Funktionen
f_errorecho() { cat <<< "$@" 1>&2 ;}

f_CtrlC() {
  read -p "Export abgebrochen. Wartungsmodus beibehalten? [j/n] " -n 1 -r
  echo
  if ! [[ "$REPLY" =~ ^[Jj]$ ]] ;	then
    f_MaintenanceMode off
  else
    echo "Wartungsmodus bleibt aktiviert."
  fi
  f_WebServer start
  exit 1
}

f_MaintenanceMode() {  # $1 'on' oder 'off'
  local mode="${1,,}"
  printf '%(%H:%M:%S)T: %b\n' -1 "Setze Wartungsmodus auf \"${mode}\"… "
  sudo -u "$webserverUser" php "${nextcloudFileDir}/occ" maintenance:mode "--${mode}"
  echo -e "Fertig\n"
}

f_WebServer() {  # $1 'start' oder 'stop'
  local action="$1"
  printf '%(%H:%M:%S)T: %b\n' -1 "Webserver: ${action^}…"  # Capitalize first letter
  systemctl "${action,,}" "$webserverServiceName"
  echo -e "Fertig\n"
}

# Konfiguration vorhanden?
if [[ -f "${SELF_PATH}/${CONFIG_FILE}" ]] ; then
  # shellcheck source=NC_DB_Export.conf.sample
  source "${SELF_PATH}/${CONFIG_FILE}" || exit 1  # Read configuration variables
else
  f_errorecho "FEHLER: Konfiguration ${SELF_PATH}/${CONFIG_FILE} nicht gefunden!"
  f_errorecho 'Die Datei kann mit dem Skript setup.sh automatisch erzeugt werden.'
  exit 1
fi

if [[ "$EUID" != '0' ]] ; then
  f_errorecho 'FEHLER: Dieses Skript benötigt root!'
  exit 1
fi

if [[ "$#" -ne 1 ]] ; then
  f_errorecho "FEHLER: Das Skript benötigt Parameter 'before' oder 'after'"
  exit 1
fi

case "$1" in
  before)
    f_MaintenanceMode on  # Wartungsmodus aktivieren
    f_WebServer stop      # Webserver anhalten
    # Backup DB
    mkdir --parents /tmp/.ncdb
    if [[ "${databaseSystem,,}" == 'mysql' || "${databaseSystem,,}" == 'mariadb' ]] ; then
      printf '%(%H:%M:%S)T: %b\n' -1 "Exportiere Nextcloud Datenbank (MySQL/MariaDB)…"
      if ! [[ -x "$(command -v mysqldump)" ]] ; then
        f_errorecho "FEHLER: MySQL/MariaDB ist nicht installiert (mysqldump nicht gefunden)."
        f_errorecho "FEHLER: Datenbank Export nicht möglich!"
      else
        mysqldump --single-transaction -h localhost -u "$dbUser" -p"$dbPassword" "$nextcloudDatabase" > "/tmp/.ncdb/${fileNameBackupDb}"
      fi
      echo -e "Done\n"
    elif [[ "${databaseSystem,,}" == 'postgresql' || "${databaseSystem,,}" == 'pgsql' ]] ; then
      printf '%(%H:%M:%S)T: %b\n' -1 "Exportiere Nextcloud Datenbank (PostgreSQL)…"
      if ! [[ -x "$(command -v pg_dump)" ]] ; then
        f_errorecho "FEHLER: PostgreSQL ist nicht installiert (pg_dump nicht gefunden)."
        f_errorecho "FEHLER: Datenbank Export nicht möglich!"
      else
        PGPASSWORD="$dbPassword" pg_dump "$nextcloudDatabase" -h localhost -U "$dbUser" -f "/tmp/.ncdb/${fileNameBackupDb}"
      fi
      echo -e "Fertig\n"
    fi
    ;;
  after)
    f_WebServer start      # Webserver starten
    f_MaintenanceMode off  # Wartungsmodus deaktivieren
    rm "/tmp/.ncdb/${fileNameBackupDb}"  # Temporäre Daten löschen
    ;;
  *) f_errorecho "Unbekannter Parameter <${1}>"  ;;
 esac

