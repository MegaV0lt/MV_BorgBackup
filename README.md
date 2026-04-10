<a rel="license" href="http://creativecommons.org/licenses/by-nc-sa/3.0/"><img alt="Creative Commons Lizenzvertrag" style="border-width:0" src="https://i.creativecommons.org/l/by-nc-sa/3.0/88x31.png" /></a><br />Dieses Werk ist lizenziert unter einer <a rel="license" href="http://creativecommons.org/licenses/by-nc-sa/3.0/">Creative Commons Namensnennung - Nicht-kommerziell - Weitergabe unter gleichen Bedingungen 3.0 Unported Lizenz</a>.

# MV_BorgBackup
Borg Backup Skript

Ein Backup-Skript für die Linux-Konsole (Bash/Terminal)

Abgeänderte Version meines Backup-Skripts "MV_Backup". Vorteile durch die Verwendung von borg sind z. B.:
- Sicherungen werden komprimiert
- Sicherungen können verschlüsselt gespeichert werden
- "Deduplizierung" von Inhalten
- Sicherungen können mit 'borg mount' einfach eingehängt werden

Zusätzliche Funktionen sind unter Anderem:
- Automatisches Ein- und Aushängen des Sicherungs-Ziels, wenn in der fstab vorhanden (noauto)
- Entfernen von alten Sicherungen und Log-Dateien nach einstellbarer Zeit
- Konfiguration ausgelagert, um den Einsatz auf mehreren Systemen zu vereinfachen
- Quelle als FTP definierbar. Zum Einhängen wird curlftps benötigt
- Versand der Logs per eMail (Optional nur bei Fehlern). Verschiedene Mailer werden unterstützt
- eMail-Bericht mit Angaben zu Fehlern, Belegung der Sicherungen und der Sicherungsziele (Auflistung abschaltbar)
- Sicherungsziel kann Profilabhängig definiert werden (mount[])
- Verschiedene Möglichkeiten den freien Platz auf dem Ziellaufwerk zu überwachen
- Verwendung von borg 1.x oder borg 2.x möglich. HINWEIS: Unbedingt ReadMe-Borg2.txt lesen!

![help](https://user-images.githubusercontent.com/2804301/151806725-1e939d46-3dff-4184-856f-1b4d293d1245.png)

Beispiel einer eMail (Abschaltbar oder nur im Fehlerfall) nach erfolgter Sicherung aus:
![Sicherungs-Bericht](https://user-images.githubusercontent.com/2804301/151801304-ae425ff4-0ed8-4966-afa4-3c013cacb06e.png)

Das Skript benötigt "GNU Bash" ab Version 4. Wenn möglich, wird auf externe Programme wie sed oder awk verzichtet. Trotzdem benötigt das Skript einige weitere externe Programme. Konfigurationsabhängig werden noch mount oder curlftpfs benötigt.
Die Verwendung geschieht wie immer auf eigene Gefahr. Wer Fehler findet, kann hier ein Ticket eröffnen oder im DEB eine Anfrage stellen. Auch neue Funktionen baue ich gerne ein, so sie mir denn als sinnvoll erscheinen.

Benötigt werden (U. a. Konfigurationsabhängig):
- GNU Bash ab Version 4
- borg (Zum Sichern der Dateien)
- find
- df
- grep
- curlftpfs (Sicherung von FTP)
- sendmail, uuencode, mpack, sendEmail, mail oder email (Für eMailversand; je nach Konfiguration)
- tar (Zusätzliche Sicherung und um gepackte Log-Dateien per eMail zu senden)
- ...


Die Konfiguration erfolgt über die .conf welche viele (hoffentlich) aussagekräftige Kommentare enthält.

Support im Forum (DEB): http://j.mp/1TblNNj oder hier im GIT
