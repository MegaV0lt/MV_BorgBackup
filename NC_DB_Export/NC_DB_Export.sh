#!/usr/bin/env bash

# Bash skript zum exportieren der Nextcloud Datenbank für Backup mit MV_BorgBackup.
# Skript wird via PRE_ACTION und POST_ACTION in MV_BorgBackup.conf aufgerufen:
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
# VERSION=260410

set -Eeuo pipefail  # Beenden bei jedem Fehler
trap f_CtrlC INT    # CTRL+C

# Variablen
SELF="$(readlink /proc/$$/fd/255)" || SELF="$0"  # Eigener Pfad ($0)
SELF_PATH="${SELF%/*}"                           # Pfad
CONFIG_FILE='NC_DB_Export.conf'                  # Konfiguration

# Funktionen
f_errorecho() { cat <<< "$*" 1>&2 ;}

f_CtrlC() {
  echo -e "\nCTRL+C erkannt..."
  read -p "Export abgebrochen. Wartungsmodus beibehalten? [j/N] " -n 1 -r
  echo
  if [[ "${stopWebserverDuringBackup,,}" == 'true' ]] ; then
    f_WebServer start  # Webserver starten
  else
    f_NextcloudVHost enable  # Nextcloud VHost aktivieren
  fi

  if ! [[ "${REPLY,,}" == 'j' ]] ;	then
    f_MaintenanceMode off
  else
    echo "Wartungsmodus bleibt aktiviert."
  fi

  exit 1
}

f_MaintenanceMode() {  # $1 'on' oder 'off'
  local mode="${1,,}"
  printf '%(%H:%M:%S)T: %b\n' -1 "Setze Wartungsmodus auf \"${mode}\"… "
  sudo -u "$webserverUser" php "${nextcloudFileDir}/occ" maintenance:mode "--${mode}"
  echo -e "Fertig\n"
}

f_WebServer() {  # $1 'start' oder 'stop'
  local action="${1,,}"
  printf '%(%H:%M:%S)T: %b\n' -1 "Webserver: ${action^}…"  # Erstes Zeichen groß
  systemctl "$action" "$webserverServiceName"
  echo -e "Fertig\n"
}

f_NextcloudVHost() {  # $1 'enable' oder 'disable'
  local action="${1,,}"
  printf '%(%H:%M:%S)T: %b\n' -1 "NextcloudVirtual Host: ${action^}…"  # Erstes Zeichen groß
  local vHostFile
  if [[ "$webserverServiceName" == 'nginx' ]] ; then
    if [[ "$action" == 'enable' ]] ; then
      mv "${vHostFile}.disabled" "$vHostFile"
    else
      mv "$vHostFile" "$vHostFile.disabled"
    fi
    systemctl reload nginx
  else
    if [[ "$action" == 'enable' ]] ; then
      a2ensite "${vHostFile##*/}"  # Nur Dateiname
    else
      a2dissite "${vHostFile##*/}"  # Nur Dateiname
    fi
    systemctl reload apache2
  fi
  }

# Prüfen ob Skript mit root Rechten ausgeführt wird
if [[ "$EUID" != '0' ]] ; then
  f_errorecho 'FEHLER: Dieses Skript benötigt root!'
  exit 1
fi

# Konfiguration vorhanden?
if [[ -f "${SELF_PATH}/${CONFIG_FILE}" ]] ; then
  # shellcheck source=NC_DB_Export.conf.sample
  source "${SELF_PATH}/${CONFIG_FILE}" || {  # Read configuration variables
    f_errorecho "FEHLER: Konnte Konfigurationsdatei ${SELF_PATH}/${CONFIG_FILE} nicht lesen!"
    exit 1
  }
else
  f_errorecho "FEHLER: Konfiguration ${SELF_PATH}/${CONFIG_FILE} nicht gefunden!"
  f_errorecho 'Die Datei kann mit dem Skript setup.sh automatisch erzeugt werden.'
  exit 1
fi

# Prüfen ob Konfigurationsdatei aktuell ist
if [[ -z "$stopWebserverDuringBackup" ]] ; then
    f_errorecho "FEHLER: Konfigurationsdatei ist veraltet."
    f_errorecho "Bitte setup.sh erneut ausführen, um die Konfigurationsdatei zu aktualisieren."
    exit 1
fi

# Parameter prüfen
OPTION="${1,,}"  # Parameter in Kleinbuchstaben
if [[ "$OPTION" != 'before' && "$OPTION" != 'after' ]] ; then
  f_errorecho "FEHLER: Das Skript benötigt Parameter 'before' oder 'after'."
  exit 1
fi

case "$OPTION" in
  before)
    f_MaintenanceMode on  # Wartungsmodus aktivieren
    if [[ "${stopWebserverDuringBackup,,}" == 'true' ]] ; then
      f_WebServer stop    # Webserver anhalten
    else
      f_NextcloudVHost disable  # Nextcloud VHost deaktivieren
    fi
    # Backup DB
    mkdir --parents /tmp/.ncdb || {
      f_errorecho "FEHLER: Konnte temporäres Verzeichnis /tmp/.ncdb nicht erstellen!"
      exit 1
    }
    if [[ "${databaseSystem,,}" == 'mysql' || "${databaseSystem,,}" == 'mariadb' ]] ; then
      printf '%(%H:%M:%S)T: %b\n' -1 "Exportiere Nextcloud Datenbank (MySQL/MariaDB)…"
      if ! [[ -x "$(command -v mysqldump)" ]] ; then
        f_errorecho "FEHLER: MySQL/MariaDB ist nicht installiert (mysqldump nicht gefunden)."
        f_errorecho "FEHLER: Datenbank Export nicht möglich!"
      else
        mysqldump --single-transaction -h localhost -u "$dbUser" -p"$dbPassword" "$nextcloudDatabase" > "/tmp/.ncdb/${fileNameBackupDb}" 2>/tmp/.ncdb/db_export_error.log || {
          f_errorecho "FEHLER: Datenbank Export fehlgeschlagen!"
          f_errorecho "Details:"
          cat /tmp/.ncdb/db_export_error.log 1>&2
          rm /tmp/.ncdb/db_export_error.log
          exit 1
        }
      fi
      echo -e "Fertig\n"
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
    if [[ "${stopWebserverDuringBackup,,}" == 'true' ]] ; then
      f_WebServer start        # Webserver starten
    else
      f_NextcloudVHost enable  # Nextcloud VHost aktivieren
    fi
    f_MaintenanceMode off      # Wartungsmodus deaktivieren
    rm "/tmp/.ncdb/${fileNameBackupDb}"  # Temporäre Daten löschen
    ;;
  *)
    f_errorecho "Unbekannter Parameter <${1}>"
    exit 1
    ;;
 esac

