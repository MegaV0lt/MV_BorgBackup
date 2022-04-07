#!/usr/bin/env bash
# = = = = = = = = = = = =  MV_BorgBackup.sh - Borg BACKUP  = = = = = = = = = = = = = =  #
#                                                                                       #
# Author: MegaV0lt                                                                      #
# Forum: http://j.mp/1TblNNj                                                            #
# GIT: https://github.com/MegaV0lt/MV_BorgBackup                                        #
#                                                                                       #
# Alle Anpassungen zum Skript, kann man in der HISTORY und in der .conf nachlesen. Wer  #
# sich erkenntlich zeigen möchte, kann mir gerne einen kleinen Betrag zukommen lassen:  #
# => http://paypal.me/SteBlo <= Der Betrag kann frei gewählt werden.                    #
#                                                                                       #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
VERSION=220407

# Dieses Skript sichert / synchronisiert Verzeichnisse mit borg.
# Dabei können beliebig viele Profile konfiguriert oder die Pfade direkt an das Skript übergeben werden.
# Eine kurze Anleitung kann mit der Option -h aufgerufen werden.

# Sämtliche Einstellungen werden in der *.conf vorgenommen.
# ---> Bitte ab hier nichts mehr ändern! <---
if ((BASH_VERSINFO[0] < 4)) ; then  # Test, ob min. Bash Version 4.0
  echo 'Sorry, dieses Skript benötigt Bash Version 4.0 oder neuer!' >&2 ; exit 1
fi

# Skriptausgaben zusätzlich in Datei speichern. (DEBUG)
# exec > >(tee -a /var/log/MV_BorgBackup.log) 2>&1

# --- INTERNE VARIABLEN ---
SELF="$(readlink /proc/$$/fd/255)" || SELF="$0"  # Eigener Pfad (besseres $0)
SELF_NAME="${SELF##*/}"                          # skript.sh
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/${SELF_NAME%.*}.XXXX")"   # Ordner für temporäre Dateien
declare -a BORG_CREATE_OPT BORGPROF BORGRC BORG_VERSION ERRLOGS LOGFILES
declare -a SSH_ERRLOG SSH_LOG SSH_TARGET UNMOUNT  # Einige Array's
declare -A _arg _target
msgERR='\e[1;41m FEHLER! \e[0;1m' ; nc="\e[0m"  # Anzeige "FEHLER!" ; Reset der Farben
msgINF='\e[42m \e[0m' ; msgWRN='\e[103m \e[0m'  # " " mit grünem/gelben Hintergrund

# --- FUNKTIONEN ---
trap 'f_exit 3' SIGHUP SIGINT SIGQUIT SIGABRT  # Bei unerwarteten Ende (Strg-C) aufräumen
set -o errtrace  # ERR Trap auch in Funktionen

f_errtrap() {  # ERR-Trap mit "ON" aktivieren, ansonsten nur ins ERRLOG
  if [[ "${1^^}" == 'ON' ]] ; then
    trap 'f_exit 2 "$BASH_COMMAND" "$LINENO" ${FUNCNAME:-$BASH_SOURCE} $?' ERR  # Bei Fehlern und nicht gefundenen Programmen
  else  # ERR-Trap nur loggen
    trap 'echo "=> Info (Fehler $?) in Zeile $LINENO (${FUNCNAME:-$BASH_SOURCE}): $BASH_COMMAND" >> "${ERRLOG:-/tmp/${SELF_NAME%.*}.log}"' ERR
  fi
}

f_exit() {  # Beenden und aufräumen $1 = ExitCode
  local EXIT="${1:-0}"  # Wenn leer, dann 0
  [[ "$EXIT" -eq 5 ]] && echo -e "$msgERR Ungültige Konfiguration! (\"${CONFIG}\") $2"
  if [[ "$EXIT" -eq 3 ]] ; then  # Strg-C
    echo -e "\n=> Aufräumen und beenden [$$]"
    [[ -n "$POST_ACTION" ]] && echo 'Achtung: POST_ACTION wird nicht ausgeführt!'
    [[ -n "$MAILADRESS" ]] && echo 'Achtung: Es erfolgt kein eMail-Versand!'
  fi
  [[ "$EXIT" -eq 2 ]] && echo -e "$msgERR (${5:-x}) in Zeile $3 ($4):${nc}\n$2\n" >&2
  if [[ "$EXIT" -ge 1 ]] ; then
    set -o posix ; set  > "/tmp/${SELF_NAME%.*}.env"  # Variablen speichern
    echo -e "$msgINF Skript- und Umgebungsvariablen wurden in \"/tmp/${SELF_NAME%.*}.env\" gespeichert!"
    [[ $EUID -ne 0 ]] && echo -e "$msgWRN Skript ohne root-Rechte gestartet!"
  fi
  [[ -n "${exfrom[*]}" ]] && rm "${exfrom[@]}" &>/dev/null
  [[ -d "$TMPDIR" ]] && rm --recursive --force "$TMPDIR" &>/dev/null  # Ordner für temporäre Dateien
  [[ -n "$MFS_PID" ]] && f_mfs_kill  # Hintergrundüberwachung beenden
  [[ "$EXIT" -ne 4 && -e "$PIDFILE" ]] && rm --force "$PIDFILE" &>/dev/null  # PID-Datei entfernen
  exit "$EXIT"
}

f_mfs_kill() {  # Beenden der Hintergrundüberwachung
  echo -e "$msgINF Beende Hintergrundüberwachung…"
  kill "$MFS_PID" &>/dev/null  # Hintergrundüberwachung beenden
  if ps --pid "$MFS_PID" &>/dev/null ; then  # Noch aktiv!
    echo '!> Hintergrundüberwachung konnte nicht beendet werden! Versuche erneut…'
    kill -9 "$MFS_PID" &>/dev/null  # Hintergrundüberwachung beenden
  else
    unset -v 'MFS_PID'
  fi
}

f_remove_slash() {  # "/" am Ende entfernen. $1=Variablenname ohne $
  local __retval="$1" tmp="${!1}"  # $1=NAME, ${!1}=Inhalt
  [[ ${#tmp} -ge 2 && "${tmp: -1}" == '/' ]] && tmp="${tmp%/}"
  eval "$__retval='$tmp'"  # Ergebis in Variable aus $1
}

# Wird in der Konsole angezeigt, wenn eine Option nicht angegeben oder definiert wurde
f_help() {
  echo -e "Aufruf: \e[1m$0 \e[34m-p${nc} \e[1;36mARGUMENT${nc} [\e[1;34m-p${nc} \e[1;36mARGUMENT${nc}]"
  echo -e "        \e[1m$0 \e[34m-m${nc} \e[1;36mQUELLE(n)${nc} \e[1;36mZIEL${nc}"
  echo
  echo -e "\e[37;100m Erforderlich $nc"
  if [[ -n "$CONFLOADED" ]] ; then
    for i in "${!arg[@]}" ; do
      echo -e "  \e[1;34m-p${nc} \e[1;36m${arg[i]}${nc}\tProfil \"${title[i]}\""
    done
  else
    echo -e "  \e[1;34m-p${nc} \e[1;36mx${nc}\tProfil (arg[nr]=)"
  fi  # CONFLOADED
  echo -e " oder\n  \e[1;34m-a${nc}\tAlle Sicherungs-Profile"
  echo -e " oder\n  \e[1;34m-m${nc}\tVerzeichnisse manuell angeben"
  echo
  echo -e "\e[37;100m Optional $nc"
  echo -e "  \e[1;34m-c${nc} \e[1;36mBeispiel.conf${nc} Konfigurationsdatei angeben (Pfad und Name)"
  echo -e "  \e[1;34m-e${nc} \e[1;36mmy@email.de${nc}   Sendet eMail inkl. angehängten Log(s)"
  echo -e "  \e[1;34m-f${nc}    eMail nur senden, wenn Fehler auftreten (-e muss angegeben werden)"
  echo -e "  \e[1;34m-d${nc} \e[1;36mx${nc}  Logdateien die älter als x Tage sind löschen (Vorgabe 30)"
  echo -e "  \e[1;34m-s${nc}    Nach Beendigung automatisch herunterfahren (benötigt u. U. Root-Rechte)"
  echo -e "  \e[1;34m-h${nc}    Hilfe anzeigen"
  echo
  echo -e "\e[37;100m Beispiele ${nc}"
  echo -e "  \e[32mProfil \"${title[2]}\"${nc} starten und den Computer anschließend \e[31mherunterfahren${nc}:"
  echo -e "\t$0 \e[32m-p${arg[2]}${nc} \e[31m-s${nc}\n"
  echo -e "  \e[33m\"/tmp/Quelle1/\"${nc} und \e[35m\"/Leer zeichen2/\"${nc} in \e[36m\"/media/extern\"${nc} sichern;\n  anschließend \e[31mherunterfahren${nc}:"
  echo -e "\t$0 \e[31m-s\e[0;4mm${nc} \e[33m/tmp/Quelle1${nc} \e[4m\"\e[0;35m/Leer zeichen2\e[0;4m\"${nc} \e[36m/media/extern${nc}"
  f_exit 1
}

f_settings() {
  local notset="\e[1;41m -LEER- $nc"  # Anzeige, wenn nicht gesetzt
  if [[ "$PROFIL" != 'customBak' ]] ; then
    # Benötigte Werte aus dem Array (.conf) holen
    for i in "${!arg[@]}" ; do  # Anzahl der vorhandenen Profile ermitteln
      if [[ "${arg[i]}" == "$PROFIL" ]] ; then  # Wenn das gewünschte Profil gefunden wurde
        # BORG_CREATE_OPT und MOUNT wieder herstelen
        if [[ -n "${_BORG_CREATE_OPT[*]}" ]] ; then
          read -r -a BORG_CREATE_OPT <<< "${_BORG_CREATE_OPT[@]}" ; unset -v '_BORG_CREATE_OPT'
        fi
        [[ -n "$_MOUNT" ]] && { MOUNT="$_MOUNT" ; unset -v '_MOUNT' ;}
        [[ "$MOUNT" == '0' ]] && unset -v 'MOUNT'  # MOUNT war nicht gesetzt
        TITLE="${title[i]}"   ; ARG="${arg[i]}"       ; MODE="${mode[i]}"
        IFS=';' read -r -a SOURCE <<< "${source[i]}"  ; TARGET="${target[i]}"
        FTPSRC="${ftpsrc[i]}" ; FTPMNT="${ftpmnt[i]}"
        ARCHIV="${archiv[i]}" ; BORG_PASSPHRASE="${passphrase[i]}"
        LOG="${log[i]}"       ; EXFROM="${exfrom[i]}" ; MINFREE="${minfree[i]}"
        SKIP_FULL="${skip_full[i]}" ; MINFREE_BG="${minfree_bg[i]}"
        # Erforderliche Werte prüfen, und ggf. Vorgaben setzen
        if [[ -z "${SOURCE[*]}" || -z "$TARGET" ]] ; then
          echo -e "$msgERR Quelle und/oder Ziel sind nicht konfiguriert!${nc}" >&2
          echo -e " Profil:    \"${TITLE:-$notset}\"\n Parameter: \"${ARG:-$notset}\" (Nummer: $i)"
          echo -e " Quelle:    \"${SOURCE[*]:-$notset}\"\n Ziel:      \"${TARGET:-$notset}\"" ; f_exit 1
        fi
        if [[ -n "$FTPSRC" && -z "$FTPMNT" ]] ; then
          echo -e "$msgERR FTP-Quelle und Einhängepunkt falsch konfiguriert!${nc}" >&2
          echo -e " Profil:        \"${TITLE:-$notset}\"\n Parameter:     \"${ARG:-$notset}\" (Nummer: $i)"
          echo -e " FTP-Quelle:    \"${FTPSRC:-$notset}\"\n Einhängepunkt: \"${FTPMNT:-$notset}\"" ; f_exit 1
        fi
        if [[ -n "$MINFREE" && -n "$MINFREE_BG" ]] ; then
          echo -e "$msgERR minfree und minfree_bg sind gesetzt! Bitte nur einen Wert verwenden!${nc}" >&2
          echo -e " Profil:     \"${TITLE:-$notset}\"\n Parameter:  \"${ARG:-$notset}\" (Nummer: $i)"
          echo -e " MINFREE:    \"${MINFREE:-$notset}\"\n MINFREE_BG: \"${MINFREE_BG:-$notset}\"" ; f_exit 1
        fi
        : "${TITLE:=Profil_${ARG}}"  # Wenn Leer, dann Profil_ gefolgt von Parameter
        : "${LOG:=${TMPDIR}/${SELF_NAME%.*}_${DT_NOW}.log}"  # Temporäre Logdatei
        ERRLOG="${LOG%.*}.err.log"                 # Fehlerlog im Logverzeichnis der Sicherung
        : "${FILES_DIR:=borg_repository}"          # Vorgabe für Sicherungsordner
        : "${ARCHIV:="{now:%Y-%m-%d_%H:%M}"}"      # Vorgabe für Archivname (Borg)
        ARCHIV="${TITLE}_${ARCHIV}"                # Name des Profils als Prefix im Archiv
        # Bei mehreren Profilen müssen die Werte erst gesichert und später wieder zurückgesetzt werden
        [[ -n "${mount[i]}" ]] && { _MOUNT="${MOUNT:-0}" ; MOUNT="${mount[i]}" ;}  # Eigener Einhängepunkt
        unset -v 'SSH_TARGET' 'SSH_LOG'
        if [[ "$TARGET" =~ '@' ]] ; then
          SSH_TARGET[0]="${TARGET##*//}"        # ohne 'ssh://'
          SSH_TARGET[1]="${SSH_TARGET[0]%%/*}"  # Pfade abschneiden (user@host[:port])
          SSH_TARGET[2]="/${SSH_TARGET[0]#*/}/${FILES_DIR}"  # Pfad zum Repository
          SSH_TARGET[3]="${SSH_TARGET[1]#*:}"   # Port
        fi
        if [[ "$LOG" =~ '@' ]] ; then
          SSH_LOG[0]="${LOG##*//}" ; SSH_ERRLOG[0]="${ERRLOG##*//}"              # ohne 'ssh://'
          SSH_LOG[1]="${SSH_LOG[0]%%/*}" ; SSH_ERRLOG[1]="${SSH_ERRLOG[0]%%/*}"  # Pfade abschneiden (user@host[:port])
          SSH_LOG[2]="/${SSH_LOG[0]#*/}" ; SSH_ERRLOG[2]="/${SSH_ERRLOG[0]#*/}"  # Pfad zum Log
          SSH_LOG[3]="${SSH_LOG[1]#*:}" ; SSH_ERRLOG[3]="${SSH_ERRLOG[1]#*:}"    # Port
		      LOG="${TMPDIR}/${LOG##*/}" ; ERRLOG="${TMPDIR}/${ERRLOG##*/}"
        fi
        case "${MODE^^}" in  # ${VAR^^} ergibt Großbuchstaben!
          *) MODE='N' ; MODE_TXT='Normal'  # Vorgabe: Normaler Modus
            if [[ -n "${borg_create_opt[i]}" ]] ; then
              read -r -a _BORG_CREATE_OPT <<< "${BORG_CREATE_OPT[@]}"
              read -r -a BORG_CREATE_OPT <<< "${borg_create_opt[i]}"
            fi
          ;;
        esac  # MODE
        [[ -n "$MINFREE_BG" ]] && MODE_TXT+=" + HÜ [${MINFREE_BG} MB]"
      fi
    done
  fi
  return 0
}

f_del_old_backup() {  # Archive älter als $DEL_OLD_BACKUP Tage löschen. $1 = repository
  local dt del_old_backup="${DEL_OLD_BACKUP:-30}"
  printf -v dt '%(%F %R.%S)T' -1
  echo -e "$msgINF Lösche alte Sicherungen aus ${1}…"
  { echo -e "[${dt}] Lösche alte Sicherungen aus ${1}…\n"
    export BORG_PASSPHRASE
    echo "borg prune ${BORG_PRUNE_OPT[*]} $1 ${BORG_PRUNE_OPT_KEEP[*]}"
    borg prune "${BORG_PRUNE_OPT[@]}" "$1" "${BORG_PRUNE_OPT_KEEP[@]}"
    [[ "${BORG_VERSION[1]}" -ge 1 && "${BORG_VERSION[2]}" -ge 2 ]] && borg compact "$1"  # Belegten Speicher frei geben
    [[ $del_old_backup -eq 0 ]] && { echo 'Löchen von Log-Dateien ist deaktiviert!' ; return ;}
    # Logdatei(en) löschen (Wenn $TITLE im Namen)
    if [[ -n "${SSH_LOG[*]}" ]] ; then
      echo "Lösche alte Logdateien (${del_old_backup} Tage) aus ${SSH_LOG[2]%/*}…"
      ssh -p "${SSH_LOG[3]:-22}" "${SSH_LOG[1]%:*}" \
        "find ${SSH_LOG[2]%/*} -maxdepth 1 -type f -mtime +${del_old_backup} \
          -name *${TITLE}* ! -name ${SSH_LOG[2]##*/} -delete -print"
    else
      echo "Lösche alte Logdateien (${del_old_backup} Tage) aus ${LOG%/*}…"
      find "${LOG%/*}" -maxdepth 1 -type f -mtime +"$del_old_backup" \
        -name "*${TITLE}*" ! -name "${LOG##*/}" -delete -print
    fi  # -n SSH_LOG
  } &>> "$LOG"
}

f_countdown_wait() {
  if [[ -t 1 ]] ; then
    # Länge des Strings [80] plus alle Steuerzeichen [21] (ohne \)
    printf '%-101b' "\n\e[30;46m  Profil \e[97m${TITLE}\e[30;46m wird in 5 Sekunden gestartet" ; printf '%b\n' '\e[0m'
    echo -e "\e[46m $nc Zum Abbrechen [Strg] + [C] drücken\n\e[46m $nc Zum Pausieren [Strg] + [Z] drücken (Fortsetzen mit \"fg\")\n"
    for i in {5..1} ; do  # Countdown ;)
      echo -e -n "\rStart in \e[97;44m  $i  ${nc} Sekunden"
      sleep 1
    done
  fi
  echo -e -n '\r' ; "$NOTIFY" "Sicherung startet (Profil: \"${TITLE}\")"
}

f_check_free_space() {  # Prüfen ob auf dem Ziel genug Platz ist
  local df_line df_free
  if [[ $MINFREE -gt 0 ]] ; then  # Aus *.conf
    mapfile -t < <(df -B M "$TARGET")  # Ausgabe von df (in Megabyte) in Array (Zwei Zeilen)
    read -r -a df_line <<< "${MAPFILE[1]}" ; df_free="${df_line[3]%M}"  # Drittes Element ist der freie Platz (M)
    if [[ $df_free -lt $MINFREE ]] ; then
      echo -e "$msgWRN Auf dem Ziel (${TARGET}) sind nur $df_free MegaByte frei! (MINFREE=${MINFREE})"
      echo "Auf dem Ziel (${TARGET}) sind nur $df_free MegaByte frei! (MINFREE=${MINFREE})" >> "$ERRLOG"
      if [[ -z "$SKIP_FULL" ]] ; then  # In der Konfig definiert
        echo -e "\nDie Sicherung (${TITLE}) ist vermutlich unvollständig!" >> "$ERRLOG"
        echo -e 'Bitte überprüfen Sie auch die Einträge in den Log-Dateien!\n' >> "$ERRLOG"
      else
        echo -e "\n\n => Die Sicherung (${TITLE}) wird nicht durchgeführt!" >> "$ERRLOG"
        FINISHEDTEXT='abgebrochen!'  # Text wird am Ende ausgegeben
      fi
      unset -v 'SKIP_FULL'  # Genug Platz! Variable löschen, falls gesetzt
    fi  # df_free
  elif [[ $MINFREE_BG -gt 0 ]] ; then  # Prüfung im Hintergrund
    unset -v 'SKIP_FULL'  # Löschen, falls gesetzt
    echo -e -n "$msgINF Starte Hintergrundüberwachung…"
    f_monitor_free_space &  # Prüfen, ob auf dem Ziel genug Platz ist (Hintergrundprozess)
    MFS_PID=$! ; echo " PID: $MFS_PID"  # PID merken
  fi  # MINFREE -gt 0
}

f_monitor_free_space() {  # Prüfen ob auf dem Ziel genug Platz ist (Hintergrundprozess [&])
  local df_line df_free
  while true ; do
    mapfile -t < <(df -B M "$TARGET")  # Ausgabe von df (in Megabyte) in Array (Zwei Zeilen)
    read -r -a df_line <<< "${MAPFILE[1]}" ; df_free="${df_line[3]%M}"  # Drittes Element ist der freie Platz (M)
    # echo "-> Auf dem Ziel (${TARGET}) sind $df_free MegaByte frei! (MINFREE_BG=${MINFREE_BG})"
    if [[ $df_free -lt $MINFREE_BG ]] ; then
      touch "${TMPDIR}/.stopflag"
      echo -e "$msgWRN Auf dem Ziel (${TARGET}) sind nur $df_free MegaByte frei! (MINFREE_BG=${MINFREE_BG})"
      { echo "Auf dem Ziel (${TARGET}) sind nur $df_free MegaByte frei! (MINFREE_BG=${MINFREE_BG})"
        echo -e "\n\n => Die Sicherung (${TITLE}) wird abgebrochen!" ;} >> "$ERRLOG"
      kill -TERM "$(pidof borg)" 2>/dev/null
      if pgrep --exact borg ; then
        echo "$msgERR Es laüft immer noch ein borg-Prozess! Versuche zu beenden…"
        killall --exact --verbose borg 2>> "$ERRLOG"
      fi
      break  # Beenden der while-Schleife
    fi
    sleep "${MFS_TIMEOUT:-300}"  # Wenn nicht gesetzt, dann 300 Sekunden (5 Min.)
  done
  unset -v 'MFS_PID'  # Hintergrundüberwachung ist beendet
}

f_source_config() {  # Konfiguration laden
  # shellcheck source=MV_BorgBackup.conf.dist
  [[ -n "$1" ]] && { source "$1" || f_exit 5 $? ;}
}

f_borg_init() {
local borg_repo="$1" do_init='false'
if [[ "$borg_repo" =~ '@' ]] ; then  # ssh
  if ! ssh "${SSH_TARGET[1]%:*}" -p "${SSH_TARGET[3]:-22}" "[ -d ${SSH_TARGET[2]} ]" ; then
    echo -e "$msgWRN Borg Repository nicht gefunden! (${borg_repo})" >&2
    do_init='true'
  fi
elif [[ ! -d "$R_TARGET" ]] ; then   # Das Repository muss vorhanden sein
    echo -e "$msgWRN Borg Repository nicht gefunden! (${borg_repo})" >&2
    do_init='true'
fi
if [[ "$PROFIL" != 'customBak' && "$do_init" == 'true' ]] ; then
  echo "Versuche das Repository anzulegen…"
  export BORG_PASSPHRASE
  if ! borg init "${BORG_INIT_OPT[@]}" "$borg_repo" &>>/dev/null ; then
    echo -e "$msgERR Anlegen des Repostorys fehlgeschlagen!${nc}" ; f_exit 1
  fi
  borg info --verbose "$borg_repo" &>> "$LOG"  # Daten in das Log
fi
}

# --- START ---
[[ -e "/tmp/${SELF_NAME%.*}.log" ]] && rm --force "/tmp/${SELF_NAME%.*}.log" &>/dev/null
[[ -e "/tmp/${SELF_NAME%.*}.env" ]] && rm --force "/tmp/${SELF_NAME%.*}.env" &>/dev/null
f_errtrap OFF  # Err-Trap deaktivieren und nur loggen
SCRIPT_TIMING[0]=$SECONDS  # Startzeit merken (Sekunden)

# --- AUSFÜHRBAR? ---
if [[ ! -x "$SELF" ]] ; then
  echo -e "$msgWRN Das Skript ist nicht ausführbar!"
  echo 'Bitte folgendes ausführen: chmod +x' "$SELF" ; f_exit 1
fi

# --- LOCKING ---
if [[ $EUID -eq 0 ]] ; then  # Nur wenn 'root'
  PIDFILE="/var/run/${SELF_NAME%.*}.pid"
  if [[ -f "$PIDFILE" ]] ; then  # PID-Datei existiert
    PID="$(< "$PIDFILE")"        # PID einlesen
    if ps --pid "$PID" &>/dev/null ; then  # Skript läuft schon!
      echo -e "$msgERR Das Skript läuft bereits!\e[0m (PID: $PID)" >&2
      f_exit 4                   # Beenden aber PID-Datei nicht löschen
    else  # Prozess nicht gefunden. PID-Datei überschreiben
      echo "$$" > "$PIDFILE" \
        || { echo -e "$msgWRN Die PID-Datei konnte nicht überschrieben werden!" >&2 ;}
    fi
  else                           # PID-Datei existiert nicht. Neu anlegen
    echo "$$" > "$PIDFILE" \
      || { echo -e "$msgWRN Die PID-Datei konnte nicht erzeugt werden!" >&2 ;}
  fi  # -f PIDFILE
fi  # EUID

# --- KONFIGURATION LADEN ---
# Testen, ob Konfiguration angegeben wurde (-c …)
while getopts ":c:" opt ; do
  case "$opt" in
    c) CONFIG="$OPTARG"
       if [[ -f "$CONFIG" ]] ; then  # Konfig wurde angegeben und existiert
         f_source_config "$CONFIG" ; CONFLOADED='Angegebene' ; break
       else
         echo -e "$msgERR Die angegebene Konfigurationsdatei fehlt!${nc} (\"${CONFIG}\")" >&2
         f_exit 1
       fi
    ;;
    ?) ;;
  esac
done

# Konfigurationsdatei laden [Wenn Skript=MV_Backup.sh Konfig=MV_Backup.conf]
if [[ -z "$CONFLOADED" ]] ; then  # Konfiguration wurde noch nicht geladen
  # Suche Konfig im aktuellen Verzeichnis, im Verzeichnis des Skripts und im eigenen etc
  CONFIG_DIRS=('.' "${SELF%/*}" "${HOME}/etc" "${0%/*}") ; CONFIG_NAME="${SELF_NAME%.*}.conf"
  for dir in "${CONFIG_DIRS[@]}" ; do
    CONFIG="${dir}/${CONFIG_NAME}"
    if [[ -f "$CONFIG" ]] ; then
      f_source_config "$CONFIG" ; CONFLOADED='Gefundene'
      break  # Die erste gefundene Konfiguration wird verwendet
    fi
  done
  if [[ -z "$CONFLOADED" ]] ; then  # Konfiguration wurde nicht gefunden
    echo -e "$msgERR Keine Konfigurationsdatei gefunden!${nc} (\"${CONFIG_DIRS[*]}\")" >&2
    f_help
  fi
fi

# Wenn eine grafische Oberfläche vorhanden ist, wird u.a. "notify-send" für Benachrichtigungen verwendet, ansonsten immer "echo"
if [[ -n "$DISPLAY" ]] ; then
  type notify-send-all &>/dev/null && NOTIFY='notify-send-all' || NOTIFY='notify-send'
  WALL='wall'
else
  NOTIFY='echo'
fi

tty --silent && clear
echo -e "\e[44m \e[0;1m MV_BorgBackup${nc}\e[0;32m => Version: ${VERSION}${nc} by MegaV0lt"
# Anzeigen, welche Konfiguration geladen wurde!
echo -e "\e[46m $nc $CONFLOADED Konfiguration:\e[1m ${CONFIG}${nc}\n"
[[ $EUID -ne 0 ]] && echo -e "$msgWRN Skript ohne root-Rechte gestartet!"

# Symlink /dev/fd fehlt bei manchen Systemen (BSD, OpenWRT, ...). https://bugzilla.redhat.com/show_bug.cgi?id=814850
if [[ ! -L /dev/fd ]] ; then
  echo -e "$msgWRN Der Symbolische Link \"/dev/fd -> /proc/self/fd\" fehlt!"
  echo -e "$msgINF Erstelle Symbolischen Link \"/dev/fd\"…"
  ln --symbolic --force /proc/self/fd /dev/fd || \
    { echo -e "$msgERR Fehler beim erstellen des Symbolischen Links!${nc}" >&2
      f_exit 1; }
fi

OPTIND=1  # Wird benötigt, weil getops ein weiteres mal verwendet wird!
optspec=':p:ac:m:sd:e:fh-:'
while getopts "$optspec" opt ; do
  case "$opt" in
    p) for i in $OPTARG ; do        # Bestimmte(s) Profil(e)
         P+=("$i")                  # Profil anhängen
       done
    ;;
    a) P=("${arg[@]}") ;;           # Alle Profile
    c) ;;                           # Wurde beim Start ausgewertet
    m) # Eigene Verzeichnisse an das Skript übergeben (Letzter Pfad als Zielverzeichnis)
      [[ -d "${*: -1}" ]] && { TARGET="${*: -1}" ;} \
        || { echo -e "$msgERR \"${*: -1}\" ist kein Verzeichnis!" >&2 ; f_exit 1 ;}
      for i in "${@:1:${#}-1}" ; do  # Alle übergebenen Verzeichnisse außer $TARGET als Quelle
        if [[ -d "$i" ]] ; then
          f_remove_slash i          # "/" am Ende entfernen
          SOURCE+=("$i")            # Verzeichnis anhängen
        fi
      done
      [[ -z "${SOURCE[*]}" ]] && \
        { echo -e "$msgERR Keine Quellverzeichnisse gefunden!" >&2 ; f_exit 1 ;}
      f_remove_slash TARGET         # "/" am Ende entfernen
      P=('customBak') ; TITLE='Benutzerdefinierte Sicherung'
      LOG="${TARGET}/../${TITLE}_log.txt"
      ARCHIV="Benutzerdefiniert_{now:%Y-%m-%d_%H:%M}"
      MOUNT='' ; MODE='N' ; MODE_TXT='Benutzerdefiniert'
    ;;
    s) SHUTDOWN='true' ;;           # Herunterfahren gewählt
    d) DEL_OLD_BACKUP="$OPTARG" ;;  # Alte Logdateien entfernen (Zahl entspricht Tage, die erhalten bleiben)
    e) MAILADRESS="$OPTARG" ;;      # eMail-Adresse verwenden um Logs zu senden
    f) MAILONLYERRORS='true' ;;     # eMail nur bei Fehlern senden
    h) f_help ;;                    # Hilfe anzeigen
    *) if [[ "$OPTERR" != 1 || "${optspec:0:1}" == ':' ]] ; then
         echo -e "$msgERR Unbekannte Option: -${OPTARG}${nc}\n" && f_help
       fi
    ;;
  esac
done

# Wenn $P leer ist, wurde die Option -p oder -a nicht angegeben
if [[ -z "${P[*]}" ]] ; then
  if [[ "${#arg[@]}" -eq 1 ]] ; then  # Wenn nur ein Profil definiert ist, dieses automatisch auswählen
    P=("${arg[@]}")  # Profil zuweisen
    msgAUTO='(auto)'  # Text zur Anzeige
  else
    echo -e "$msgERR Es wurde kein Profil angegeben!${nc}\n" >&2 ; f_help
  fi
  [[ -z "${arg[*]}" ]] && { echo -e "$msgERR arg[nr] darf nicht leer sein!${nc}" >&2 ; f_exit 1 ;}
fi

# Prüfen ob alle Profile eindeutige Buchstaben haben (arg[])
for parameter in "${arg[@]}" ; do
  [[ -z "${_arg[$parameter]+_}" ]] && { _arg[$parameter]=1 ;} \
    || { echo -e "$msgERR Profilkonfiguration ist fehlerhaft! (Keine eindeutigen Buchstaben)\n\t\t => arg[nr]=\"$parameter\" <= wird mehrfach verwendet${nc}\n" >&2 ; f_exit 1 ;}
done

# Prüfen ob alle Profile eindeutige Sicherungsziele verwenden (target[])
for parameter in "${target[@]}" ; do
  [[ -z "${_target[$parameter]+_}" ]] && { _target[$parameter]=1 ;} \
    || { echo -e "$msgERR Profilkonfiguration ist fehlerhaft! (Keine eindeutigen Sicherungsziele)\n  => \"$parameter\" <= wird mehrfach verwendet (target[nr] oder extra_target[nr])${nc}\n" >&2 ; f_exit 1 ;}
done

# Prüfen ob alle Profile POSIX-Kompatible Namen haben
for parameter in "${title[@]}" ; do
  LEN=$((${#parameter}-1)) ; i=0
  while [[ $i -le $LEN ]] ; do
    case "${parameter:$i:1}" in  # Zeichenweises Suchen
      [A-Za-z0-9]|[._-]) ;;  # OK (A-Za-z0-9._-)
        *) NOT_POSIX+=("$parameter") ; continue 2 ;;
    esac ; ((i+=1))
  done  # while
done  # title[@]

[[ -n "${NOT_POSIX[*]}" ]] && { echo -e "$msgWRN Profilnamen mit Sonderzeichen gefunden!" >&2
    echo "Profil(e) mit POSIX-Inkompatiblen Zeichen: \"${NOT_POSIX[*]}\" <=" >&2
    echo 'Bitte nur folgende POSIX-Kompatible Zeichenverwenden: A–Z a–z 0–9 . _ -' ; sleep 10 ;}

# Folgende Zeile auskommentieren, falls zum Herunterfahren des Computers Root-Rechte erforderlich sind
# [[ -n "$SHUTDOWN" && "$(whoami)" != "root" ]] && echo -e "$msgERR Zum automatischen Herunterfahren sind Root-Rechte erforderlich!\e[0m\n" && f_help

[[ -n "$SHUTDOWN" ]] && echo -e "  \e[1;31mDer Computer wird nach Durchführung der Sicherung(en) automatisch heruntergefahren!${nc}"

for PROFIL in "${P[@]}" ; do  # Anzeige der Einstellungen
  f_settings

  # Wurden der Option -p gültige Argument zugewiesen?
  if [[ "$PROFIL" != "$ARG" && "$PROFIL" != 'customBak' ]] ; then
    notset="\e[1;41m -LEER- $nc"  # Anzeige, wenn nicht gesetzt
    echo -e "$msgERR Option -p wurde nicht korrekt definiert!${nc}\n" >&2
    echo -e " Profil:        \"${TITLE:-$notset}\"\n Parameter:     \"${ARG:-$notset}\""
    echo -e " Variable PROFIL: \"${PROFIL:-$notset}\"" ; f_exit 1
  fi

  # Konfiguration zu allen gewählten Profilen anzeigen
  # Länge des Strings [80] plus alle Steuerzeichen [14] (ohne \)
  printf '%-94b' "\n\e[30;46m  Konfiguration von:    \e[97m${TITLE} $msgAUTO" ; printf '%b\n' "$nc"
  echo -e "\e[46m $nc Sicherungsmodus:\e[1m\t${MODE_TXT}${nc}"
  echo -e "\e[46m $nc Quellverzeichnis(se):\e[1m\t${SOURCE[*]}${nc}"
  echo -e "\e[46m $nc Zielverzeichnis:\e[1m\t${TARGET}${nc}"
  echo -e "\e[46m $nc Log-Datei:\e[1m\t\t${SSH_LOG[0]:-${LOG}}${nc}"
  if [[ "$PROFIL" != 'customBak' ]] ; then
    echo -e "\e[46m $nc Ausschluss:"
    while read -r ; do
      echo -e "\e[46m ${nc}\t\t\t${REPLY}"
    done < "$EXFROM"
  fi
  if [[ -n "$MAILADRESS" ]] ; then  # eMail-Adresse ist angegeben
    echo -e -n "\e[46m $nc eMail-Versand an:\e[1m\t${MAILADRESS}${nc}"
    [[ "$MAILONLYERRORS" == 'true' ]] && { echo ' [NUR bei Fehler(n)]' ;} || echo ''
  elif [[ "$MAILONLYERRORS" == 'true' ]] ; then
    echo -e "\e[1;43m $nc Es wurde \e[1mkeine eMail-Adresse${nc} für den Versand bei Fehler(n) angegeben!\n"
  fi
  if [[ -n "$DEL_OLD_BACKUP" ]] ; then
    case $MODE in
      [N]) if [[ $DEL_OLD_BACKUP =~ ^[0-9]+$ ]] ; then  # Prüfen, ob eine Zahl angegeben wurde
             if [[ $DEL_OLD_BACKUP -eq 0 ]] ; then
               echo -e "$msgWRN Log-Dateien:\t\t Werden \e[1mnicht gelöscht${nc} (-d $DEL_OLD_BACKUP)"
             else
               echo -e "$msgWRN Log-Dateien:\e[1m\tLÖSCHEN wenn älter als $DEL_OLD_BACKUP Tage${nc}"
             fi
           else
             echo -e "$msgERR Keine gültige Zahl!${nc} (-d $DEL_OLD_BACKUP)" >&2 ; f_exit 1
           fi
      ;;
    esac
  fi
done

# Sind die benötigen Programme installiert?
NEEDPROGS=(find mktemp borg)
[[ -n "$FTPSRC" ]] && NEEDPROGS+=(curlftpfs)
if [[ -n "$MAILADRESS" ]] ; then
  [[ "${MAILPROG^^}" == 'CUSTOMMAIL' ]] && { NEEDPROGS+=("${CUSTOM_MAIL[0]}") ;} || NEEDPROGS+=("$MAILPROG")
  [[ "$MAILPROG" == 'sendmail' ]] && NEEDPROGS+=(uuencode)
  NEEDPROGS+=(tar)
fi
for prog in "${NEEDPROGS[@]}" ; do
  type "$prog" &>/dev/null || MISSING+=("$prog")
done
if [[ -n "${MISSING[*]}" ]] ; then  # Fehlende Programme anzeigen
  echo -e "$msgERR Sie benötigen \"${MISSING[*]}\" zur Ausführung dieses Skriptes!" >&2
  f_exit 1
fi
# Borg Version prüfen und speichern
IFS=' .' read -r -a BORG_VERSION < <(borg --version)  # borg 1 1 17

# --- PRE_ACTION ---
if [[ -n "$PRE_ACTION" ]] ; then
  echo -e "$msgINF Führe PRE_ACTION-Befehl(e) aus…"
  eval "$PRE_ACTION" || { echo "$msgWRN Fehler beim Ausführen von \"${PRE_ACTION}\"!" ; sleep 10 ;}
fi

for PROFIL in "${P[@]}" ; do
  f_settings

  if [[ "$PROFIL" != 'customBak' ]] ; then  # Nicht bei benutzerdefinierter Sicherung
    # Festplatte (Ziel) eingebunden?
    if [[ -n "$MOUNT" && "$TARGET" == "$MOUNT"* ]] ; then
      if ! mountpoint --quiet "$MOUNT" ; then
        echo -e -n "$msgINF Versuche Sicherungsziel (${MOUNT}) einzuhängen…"
        mount "$MOUNT" &>/dev/null \
          || { echo -e "\n$msgERR Das Sicherungsziel konnte nicht eingebunden werden! (RC: $?)${nc} (\"${MOUNT}\")" >&2 ; f_exit 1 ;}
        echo -e "OK.\nDas Sicherungsziel (\"${MOUNT}\") wurde erfolgreich eingehängt."
        UNMOUNT+=("$MOUNT")  # Nach Sicherung wieder aushängen (Einhängepunkt merken)
      fi  # ! mountpoint
    fi
    # Ist die Quelle ein FTP und eingebunden?
    if [[ -n "$FTPSRC" ]] ; then
      if ! mountpoint --quiet "$FTPMNT" ; then
        echo -e -n "$msgINF Versuche FTP-Quelle (${FTPSRC}) unter \"${FTPMNT}\" einzuhängen…"
        curlftpfs "$FTPSRC" "$FTPMNT" &>/dev/null    # FTP einhängen
        grep --quiet "$FTPMNT" /proc/mounts \
          || { echo -e "\n$msgERR Die FTP-Quelle konnte nicht eingebunden werden! (RC: $?)${nc} (\"${FTPMNT}\")" >&2 ; f_exit 1 ;}
        echo -e "OK.\nDie FTP-Quelle (${FTPSRC}) wurde erfolgreich unter (\"${FTPMNT}\") eingehängt."
        UMOUNT_FTP=1  # Nach Sicherung wieder aushängen
      fi  # ! mountpoint
    fi
  fi  # ! customBak

  [[ -e "${TMPDIR}/.stopflag" ]] && rm --force "${TMPDIR}/.stopflag" &>/dev/null
  unset -v 'FINISHEDTEXT' 'MFS_PID'
  printf -v dt '%(%F %R)T' -1  # Datum für die erste Zeile im Log

  case $MODE in
    N) # Normale Sicherung (inkl. customBak)
      R_TARGET="${TARGET}/${FILES_DIR}"  # Ordner für das Repository
      f_borg_init "$R_TARGET"  # Prüfen, ob das Repository existiert und ggf. anlegen
      f_countdown_wait         # Countdown vor dem Start anzeigen
      if [[ $MINFREE -gt 0 || $MINFREE_BG -gt 0 ]] ; then
        f_check_free_space  # Platz auf dem Ziel überprüfen (MINFREE oder MINFREE_BG)
      fi

      # Keine Sicherung, wenn zu wenig Platz und "SKIP_FULL" gesetzt ist
      if [[ -z "$SKIP_FULL" ]] ; then
        # Sicherung mit borg starten
        echo "==> [${dt}] - $SELF_NAME [#${VERSION}] - Start:" >> "$LOG"  # Sicher stellen, dass ein Log existiert
        echo "borg create ${BORG_CREATE_OPT[*]} --exclude-from=${EXFROM:-'Nicht_gesetzt'} ${R_TARGET}::${ARCHIV} ${SOURCE[*]}" >> "$LOG"
        echo -e "$msgINF Starte Sicherung (borg)…"
        if [[ "$PROFIL" == 'customBak' ]] ; then  # Verzeichnisse wurden manuell übergeben
          export -n BORG_PASSPHRASE  # unexport
          borg create "${BORG_CREATE_OPT[@]}" "${R_TARGET}::${ARCHIV}" "${SOURCE[@]}" &>> "$LOG"
        else
          export BORG_PASSPHRASE
          borg create "${BORG_CREATE_OPT[@]}" --exclude-from="$EXFROM" "${R_TARGET}::${ARCHIV}" "${SOURCE[@]}" &>> "$LOG"
        fi
        RC=$? ; [[ $RC -ne 0 ]] && { BORGRC+=("$RC") ; BORGPROF+=("$TITLE") ;}  # Profilname und Fehlercode merken
        [[ -n "$MFS_PID" ]] && f_mfs_kill  # Hintergrundüberwachung beenden!
        if [[ -e "${TMPDIR}/.stopflag" ]] ; then
          FINISHEDTEXT='abgebrochen!'  # Platte voll!
        else  # Alte Daten nur löschen wenn nicht abgebrochen wurde!
          f_del_old_backup "$R_TARGET"  # Funktion zum Löschen alter Sicherungen aufrufen
        fi  # -e .stopflag
        if [[ "$SHOWBORGINFO" == 'true' ]] ; then  # Temporär speichern für Mail-Bericht
          tempinfo="${LOG##*/}" ; tempinfo="${tempinfo%*.log}_info.txt"
          borg info --last 1 "$R_TARGET" > "${TMPDIR}/${tempinfo}"
        fi
      fi  # SKIP_FULL
    ;;
    *) # Üngültiger Modus
      echo -e "$msgERR Unbekannter Sicherungsmodus!${nc} (\"${MODE}\")" >&2
      f_exit 1
    ;;
  esac

  # Log-Datei, Ziel und Name des Profils merken für Mail-Versand
  [[ -n "$MAILADRESS" ]] && { LOGFILES+=("$LOG") ; TARGETS+=("$TARGET") ; USEDPROFILES+=("$TITLE") ;}

  # Zuvor eingehängte FTP-Quelle wieder aushängen
  [[ -n "$UMOUNT_FTP" ]] && { umount "$FTPMNT" ; unset -v 'UMOUNT_FTP' ;}

  [[ ${RC:-0} -ne 0 ]] && ERRTEXT="\e[91mmit Fehler ($RC) \e[0;1m"
  echo -e -n "\a\n\n${msgINF} \e[1mProfil \"${TITLE}\" wurde ${ERRTEXT}${FINISHEDTEXT:=abgeschlossen}"
  printf ' (%(%x %X)T)\n' -1  # Datum und Zeit
  echo -e "  Weitere Informationen sind in der Datei:\n  \"${SSH_LOG[0]:-${LOG}}\" gespeichert.\n"
  if [[ -s "$ERRLOG" ]] ; then  # Existiert und ist nicht Leer
    if [[ $(stat -c %Y "$ERRLOG") -gt $(stat -c %Y "$TMPDIR") ]] ; then  # Fehler-Log merken, wenn neuer als "$TMPDIR"
      ERRLOGS+=("$ERRLOG")
      echo -e "$msgINF Fehlermeldungen wurden in der Datei:\n  \"${SSH_ERRLOG[0]:-${ERRLOG}}\" gespeichert.\n"
    fi
  else
    [[ -e "$ERRLOG" ]] && rm "$ERRLOG" &>/dev/null  # Leeres Log löschen
  fi
  unset -v 'RC' 'ERRTEXT'  # $RC und $ERRTEXT zurücksetzen
  # Falls nötig Log-Dateien zum SSH-Host kopieren
  if [[ -n "${SSH_LOG[*]}" ]] ; then
    #scp -P 2222 file.txt user@remote.host:/some/remote/directory
    [[ -e "$LOG" ]] && scp -q -P "${SSH_LOG[3]:-22}" "$LOG" "${SSH_LOG[1]%:*}:${SSH_LOG[2]}"
    [[ -e "$ERRLOG" ]] && scp -q -P "${SSH_ERRLOG[3]:-22}" "$ERRLOG" "${SSH_ERRLOG[1]%:*}:${SSH_ERRLOG[2]}"
    echo -e "$msgINF Log's wurden nach ${SSH_LOG[1]%:*}:${SSH_LOG[2]%/*} kopiert"
  fi
done # for PROFIL
SCRIPT_TIMING[1]=$SECONDS  # Zeit nach der Sicherung mit borg/tar/getfacl (Sekunden)

# --- eMail senden ---
if [[ -n "$MAILADRESS" ]] ; then
  # Variablen
  printf -v ARCH 'Logs_%(%F-%H%M)T'."${LOGARCH_FMT:=tar.xz}"  # Archiv mit Datum und Zeit (kein :)
  MAILARCHIV="${TMPDIR}/${ARCH}"              # Archiv mit Pfad
  MAILFILE="${TMPDIR}/~Mail.txt"              # Text für die eMail
  SUBJECT="[${HOSTNAME^^}] Sicherungs-Bericht von $SELF_NAME" # Betreff der Mail

  if [[ ${MAXLOGSIZE:=$((1024*1024))} -gt 0 ]] ; then  # Wenn leer dann Vorgabe 1 MB. 0 = deaktiviert
    # Log(s) packen
    echo -e "$msgINF Erstelle Archiv mit $((${#LOGFILES[@]}+${#ERRLOGS[@]})) Logdatei(en):\n  \"${MAILARCHIV}\" "
    tar --create --absolute-names --auto-compress --file="$MAILARCHIV" "${LOGFILES[@]}" "${ERRLOGS[@]}"
    FILESIZE="$(stat -c %s "$MAILARCHIV")"    # Größe des Archivs
    if [[ $FILESIZE -gt $MAXLOGSIZE ]] ; then
      rm "$MAILARCHIV" &>/dev/null            # Archiv ist zu groß für den eMail-Versand
      MAILARCHIV="${MAILARCHIV%%.*}.txt"      # Info-Datei als Ersatz
      { echo 'Das Archiv mit den Logdateien ist zu groß für den Versand per eMail.'
        echo "Der eingestellte Wert für die Maximalgröße ist $MAXLOGSIZE Bytes."
        echo -e '\n==> Liste der lokal angelegten Log-Datei(en):'
        for file in "${LOGFILES[@]}" "${ERRLOGS[@]}" ; do
          echo "$file"
        done
      } > "$MAILARCHIV"
    fi
  else  # MAXLOGSIZE=0
    MAILARCHIV="${MAILARCHIV%%.*}.txt"  # Info-Datei
    { echo 'Das Senden von Logdateien ist deaktiviert (MAXLOGSZE=0).'
      echo -e '\n==> Liste der lokal angelegten Log-Datei(en):'
      for file in "${LOGFILES[@]}" "${ERRLOGS[@]}" ; do
        echo "$file"
      done
    } > "$MAILARCHIV"
  fi

    echo -e "$msgINF Erzeuge eMail-Bericht…"  # Text der eMail erzeugen
  { echo -e "Sicherungs-Bericht von $SELF_NAME [#${VERSION}] auf ${HOSTNAME^^}.\n"
    echo -n 'Die letzte Sicherung wurde beendet. '
    [[ ${#LOGFILES[@]} -ge 1 ]] && echo "Es wurde(n) ${#LOGFILES[@]} Log-Datei(en) erstellt."
  } > "$MAILFILE"

  if [[ ${#ERRLOGS[@]} -ge 1 ]] ; then
    echo -e "\n==> Zusätzlich wurde(n) ${#ERRLOGS[@]} Fehler-Log(s) erstellt!" >> "$MAILFILE"
    SUBJECT="[${HOSTNAME^^}] FEHLER bei Sicherung von $SELF_NAME"  # Neuer Betreff der Mail bei Fehlern
  fi

  if [[ ${#BORGRC[@]} -ge 1 && "$SHOWERRORS" == 'true' ]] ; then  # Profile mit Fehlern anzeigen
    echo -e '\n==> Profil(e) mit Fehler(n):' >> "$MAILFILE"
    for i in "${!BORGRC[@]}" ; do
      echo "${BORGPROF[i]} (Rückgabecode ${BORGRC[i]})" >> "$MAILFILE"
    done
  fi  # SHOWERRORS

  if [[ "$SHOWOS" == 'true' && -f '/etc/os-release' ]] ; then
    while read -r ; do
      [[ ${REPLY^^} =~ PRETTY_NAME ]] && { OSNAME="${REPLY/*=}"
        OSNAME="${OSNAME//\"/}" ; break ;}
    done < /etc/os-release
    echo -e "\n==> Auf ${HOSTNAME^^} verwendetes Betriebssystem:\n${OSNAME:-'Unbekannt'}" >> "$MAILFILE"
  fi  # SHOWOS

  [[ "$SHOWOPTIONS" == 'true' ]] && echo -e "\n==> Folgende Optionen wurden verwendet:\n$*" >> "$MAILFILE"

  if [[ "$SHOWUSEDPROFILES" == 'true' ]] ; then
    echo -e "\n==> Folgende Profile wurden zur Sicherung ausgewählt:" >> "$MAILFILE"
    for i in "${!USEDPROFILES[@]}" ; do
      echo "${USEDPROFILES[i]}" >> "$MAILFILE"
    done
  fi  # SHOWUSEDPROFILES

  for i in "${!TARGETS[@]}" ; do
    if [[ -d "${TARGETS[i]}" ]] ; then  # Nur wenn das Verzeichnis existiert
      if [[ "$SHOWUSAGE" == 'true' ]] ; then  # Anzeige ist abschaltbar in der *.conf
        mapfile -t < <(df -Ph "${TARGETS[i]}")  # Ausgabe von df in Array (Zwei Zeilen)
        read -r -a TARGETLINE <<< "${MAPFILE[1]}" ; TARGETDEV="${TARGETLINE[0]}"  # Erstes Element ist das Device
        if [[ ! "${TARGETDEVS[*]}" =~ $TARGETDEV ]] ; then
          TARGETDEVS+=("$TARGETDEV")
          echo -e "\n==> Status des Sicherungsziels (${TARGETDEV}):" >> "$MAILFILE"
          echo -e "${MAPFILE[0]}\n${MAPFILE[1]}" >> "$MAILFILE"
        fi
      fi  # SHOWUSAGE
    fi  # -d TARGETS[i]
    if [[ "$SHOWCONTENT" == 'true' ]] ; then  # Auflistung ist abschaltbar in der *.conf
      LOGDIR="${LOGFILES[i]%/*}" ; [[ "${LOGDIRS[*]}" =~ $LOGDIR ]] && continue
      LOGDIRS+=("$LOGDIR")
      { echo -e "\n==> Inhalt von ${LOGDIR}:"
        ls -l --human-readable "$LOGDIR"
        # Anzeige der Belegung des Sicherungsverzeichnisses und Unterordner
        echo -e "\n==> Belegung von ${LOGDIR}:"
        du --human-readable --summarize "$LOGDIR"
        for dir in "${LOGDIR}"/*/ ; do
          du --human-readable --summarize "$dir"
          if [[ "$SHOWBORGINFO" == 'true' ]] ; then
            tempinfo="${LOGFILES[i]##*/}" ; tempinfo="${tempinfo%*.log}_info.txt"
            echo -e "\n==> Borg info:"
            cat "${TMPDIR}/${tempinfo}"  # Borg info zum Mailbericht
          fi  # SHOWBORGINFO
        done
      } >> "$MAILFILE"
    fi  # SHOWCONTENT
  done

  if [[ "$SHOWDURATION" == 'true' ]] ; then  # Auflistung ist abschaltbar in der *.conf
    SCRIPT_TIMING[2]=$SECONDS  # Zeit nach der Statistik
    SCRIPT_TIMING[10]=$((SCRIPT_TIMING[2] - SCRIPT_TIMING[0]))  # Gesamt
    SCRIPT_TIMING[11]=$((SCRIPT_TIMING[1] - SCRIPT_TIMING[0]))  # borg/tar
    SCRIPT_TIMING[12]=$((SCRIPT_TIMING[2] - SCRIPT_TIMING[1]))  # Statistik
    { echo -e '\n==> Ausführungszeiten:'
      echo "Skriptlaufzeit: $((SCRIPT_TIMING[10] / 60)) Minute(n) und $((SCRIPT_TIMING[10] % 60)) Sekunde(n)"
      echo "  Sicherung: $((SCRIPT_TIMING[11] / 60)) Minute(n) und $((SCRIPT_TIMING[11] % 60)) Sekunde(n)"
      echo "  Erstellen des Mailberichts: $((SCRIPT_TIMING[12] / 60)) Minute(n) und $((SCRIPT_TIMING[12] % 60)) Sekunde(n)"
    } >> "$MAILFILE"
  fi  # SHOWDURATION

  # eMail nur, wenn (a) MAILONLYERRORS=true und Fehler vorhanden sind oder (b) MAILONLYERRORS nicht true
  if [[ ${#ERRLOGS[@]} -ge 1 && "$MAILONLYERRORS" == 'true' || "$MAILONLYERRORS" != 'true' ]] ; then
    # eMail versenden
    echo -e "$msgINF Sende eMail an ${MAILADRESS}…"
    case "$MAILPROG" in
      mpack)  # Sende Mail mit mpack via ssmtp
        iconv --from-code=UTF-8 --to-code=iso-8859-1 --output="${MAILFILE}.x" "$MAILFILE"  #  Damit Umlaute richtig angezeigt werden
        mpack -s "$SUBJECT" -d "${MAILFILE}.x" "$MAILARCHIV" "$MAILADRESS"  # Kann "root" sein, wenn in sSMTP konfiguriert
      ;;
      sendmail)  # Variante mit sendmail und uuencode
        mail_to_send="${TMPDIR}/~mail_to_send"
        { echo "Subject: $SUBJECT" ; cat "$MAILFILE" ; uuencode "$MAILARCHIV" "$ARCH" ;} > "$mail_to_send"
        sendmail "$MAILADRESS" < "$mail_to_send"
      ;;
      send[Ee]mail)  # Variante mit "sendEmail". Keine " für die Variable $USETLS verwenden!
        sendEmail -f "$MAILSENDER" -t "$MAILADRESS" -u "$SUBJECT" -o message-file="$MAILFILE" -a "$MAILARCHIV" \
          -o message-charset=utf-8 -s "${MAILSERVER}:${MAILPORT}" -xu "$MAILUSER" -xp "$MAILPASS" "${USETLS[@]}"
      ;;
      e[Mm]ail)  # Sende Mail mit eMail (https://github.com/deanproxy/eMail)
        email -s "$SUBJECT" -attach "$MAILARCHIV" "$MAILADRESS" < "$MAILFILE"  # Die ausführbare Datei ist 'email'
      ;;
      mail)  # Sende Mail mit mail (http://j.mp/2kZlJdk)
        mail -s "$SUBJECT" -a "$MAILARCHIV" "$MAILADRESS" < "$MAILFILE"
      ;;
      custom[Mm]ail)  # Eigenes Mailprogramm verwenden. Siehe auch *.conf -> CUSTOM_MAIL
        for var in MAILADRESS SUBJECT MAILFILE MAILARCHIV ; do
          CUSTOM_MAIL=("${CUSTOM_MAIL[@]/$var/${!var}}")  # Platzhalter ersetzen
        done
        eval "${CUSTOM_MAIL[@]}"  # Gesamte Zeile ausführen
      ;;
      *) echo -e "\nUnbekanntes Mailprogramm: \"${MAILPROG}\"" ;;
    esac
    RC=$? ; [[ ${RC:-0} -eq 0 ]] && echo -e "\n${msgINF} Sicherungs-Bericht wurde mit \"${MAILPROG}\" an $MAILADRESS versendet.\n    Es wurde(n) ${#LOGFILES[@]} Logdatei(en) angelegt."
  fi  # MAILONLYERRORS
  unset -v 'MAILADRESS'
fi

# Zuvor eingehängte(s) Sicherungsziel(e) wieder aushängen
if [[ ${#UNMOUNT[@]} -ge 1 ]] ; then
  echo -e "$msgINF Manuell eingehängte Sicherungsziele werden wieder ausgehängt…"
  for volume in "${UNMOUNT[@]}" ; do
    umount --force "$volume"
  done
fi

# --- POST_ACTION ---
if [[ -n "$POST_ACTION" ]] ; then
  echo -e "$msgINF Führe POST_ACTION-Befehl(e) aus…"
  eval "$POST_ACTION" || { echo "$msgWRN Fehler beim Ausführen von \"${POST_ACTION}\"!" ; sleep 10 ;}
  unset -v 'POST_ACTION'
fi

# Ggf. Herunterfahren
if [[ -n "$SHUTDOWN" ]] ; then
  # Möglichkeit, das automatische Herunterfahren noch abzubrechen
  "$NOTIFY" "Sicherung(en) abgeschlossen. ACHTUNG: Der Computer wird in 5 Minuten heruntergefahren. Führen Sie \"kill -9 $(pgrep "${0##*/}")\" aus, um das Herunterfahren abzubrechen."
  sleep 1
  echo "This System is going DOWN for System halt in 5 minutes! Run \"kill -9 $(pgrep "${0##*/}")\" to cancel shutdown." | $WALL
  echo -e '\a\e[1;41m ACHTUNG \e[0m Der Computer wird in 5 Minuten heruntergefahren.\n'
  echo -e 'Bitte speichern Sie jetzt alle geöffneten Dokumente oder drücken Sie \e[1m[Strg] + [C]\e[0m,\nfalls der Computer nicht heruntergefahren werden soll.\n'
  sleep 5m
  # Verschiedene Befehle zum Herunterfahren mit Benutzerrechten [muss evtl. an das eigene System angepasst werden!]
  # Alle Systeme mit HAL || GNOME DBUS || KDE DBUS || GNOME || KDE
  # Root-Rechte i. d. R. erforderlich für "halt" und "shutdown"!
  dbus-send --print-reply --system --dest=org.freedesktop.Hal /org/freedesktop/Hal/devices/computer org.freedesktop.Hal.Device.SystemPowerManagement.Shutdown \
    || dbus-send --print-reply --dest=org.gnome.SessionManager /org/gnome/SessionManager org.gnome.SessionManager.RequestShutdown \
    || dbus-send --print-reply --dest=org.kde.ksmserver /KSMServer org.kde.KSMServerInterface.logout 0 2 2 \
    || gnome-power-cmd shutdown || dcop ksmserver ksmserver logout 0 2 2 \
    || halt || shutdown --halt now
else
  echo -e '\n' ; "$NOTIFY" "Sicherung(en) abgeschlossen."
fi

f_exit  # Aufräumen und beenden
