Wichtige Hinweise zur verwendung von Borg 2.x

Borg2 ist nicht kompatiben mit Borg1. Das bedeuted, dass Repositories von Borg1
manuell in Borg2 Repositories umgewandelt werden müssen. 
Siehe https://borgbackup.readthedocs.io/en/latest/usage/transfer.html

Alternativ neue Repositories verwenden. MV_BorgBackup verwendet als Vorgabe für 
Borg 1.x Repositories 'borg_repository' und 'borg2_repository' für Borg 2.x

In der .conf kann die ausführbare Datei für Borg in der Variable BORG_BIN angegeben
werden. Vorgabe ist borg. Zusätzlich wird die Variable BORG_REPO_CREATE_OPT benötigt.
Beispiel in der .conf.dist

WICHTIG: Keine Beta-Version von Borg verwenden, da diese rein zu testzwecken dient!
